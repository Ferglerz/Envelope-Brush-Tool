local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""

local CONFIG = dofile(SCRIPT_DIR .. "BrushConfig.lua")
local EnvApi = dofile(SCRIPT_DIR .. "BrushEnvelopeApi.lua")
local ArrangeMsg = dofile(SCRIPT_DIR .. "BrushArrangeMessages.lua")

local M = {}
M.CONFIG = CONFIG

for k, v in pairs(EnvApi) do
    M[k] = v
end

function M.new_state(config)
    return {
        -- Brush settings
        brush_size = config.DEFAULT_BRUSH_SIZE,
        falloff_type = 1,
        falloff_strength = config.DEFAULT_FALLOFF_STRENGTH,
        --- Set on LMB down: "nudge" | "sculpt" | "smooth" (see BrushInput.resolve_brush_drag_kind).
        active_sculpt_kind = nil,
        smooth_strength = config.DEFAULT_SMOOTH_STRENGTH,
        sculpt_power = config.DEFAULT_SCULPT_POWER,
        sculpt_seed_blend_to_cursor = config.DEFAULT_SCULPT_SEED_BLEND_TO_CURSOR,
        min_point_spacing_px = config.DEFAULT_MIN_POINT_SPACING_PX,
        lock_time_axis = false,
        lock_value_axis = false,

        -- Mouse and interaction
        mouse_pos = {x = 0, y = 0},
        is_dragging = false,
        drag_mode = "sculpt",
        drag_start_pos = {x = 0, y = 0},
        captured_points = {},
        last_create_client = nil,

        -- Envelope context (REAPER: autoitem_idx -1 = parent lane; >=0 = automation item on that envelope)
        target_envelope = nil,
        envelope_autoitem_idx = -1,
        envelope_bounds = {top = 150, bottom = 600, left = 200, right = 1200},
        overlay_visible = false,
        cached_envelope = nil,
        envelope_detected = false,
        sws_hover_detected = false,

        -- Cached envelope properties
        cached_envelope_properties = {envelope = nil, min_val = 0, max_val = 1},

        -- Per-frame cache (arrange view)
        frame_arrange_start = 0,
        frame_arrange_end = 0,

        -- Main window client size for overlay
        client_w = 2000,
        client_h = 2000,

        -- Last raw client rect from JS_Window_GetClientRect (for setup_envelope_bounds skip-if-unchanged)
        _arrange_client_rect_key = nil,

        -- Undo system
        undo_active = false,
        undo_operation_name = "",
        sculpt_sort_pending = false,
        sculpt_last_client = nil,
        --- reaper.time_precise() when Envelope_SortPoints* last ran during sculpt (nil = sort ASAP on next tick).
        last_envelope_sort_os = nil,
        --- Set when sculpt moved points; cleared when throttled sort runs (avoids sorting every 250ms while idle).
        envelope_points_dirty_sort = false,

        -- ImGui: editor window + brush HUD (same context).
        ctx = nil,

        -- Default point shape from chunk; invalidated with target envelope (see clear_target_envelope_state_only).
        cached_defshape_envelope = nil,
        cached_defshape_value = 0,

        -- Arrange: JS_WindowMessage_Intercept/Peek (wheel + LMB + optional MOVE while eating LMB).
        arrange_intercept_active = false,
        arrange_intercept_hwnd = nil,
        wm_wheel_last_time = 0,
        wm_lmb_down_last_time = 0,
        wm_lmb_up_last_time = 0,
        wm_mousemove_last_time = 0,
        brush_ate_arrange_lmb = false,
        arrange_move_intercept_active = false,

        -- Deferred envelope ops: run Insert/Set at start of next main_loop (after defer), not same pass as ImGui.
        envelope_flush_pending = false,
        suppress_imgui_control_this_frame = false,
        --- Set by keyboard (Escape): main_loop forces exit like closing the editor window.
        script_close_requested = false,

        -- Debug: release JS message intercepts, hide arrange HUD; test insert via button only.
        debug_disable_js_eat = false,
        _debug_js_eat_prev = false,
        --- Arrange HUD: label each envelope point with its arrange-client (x,y) used by brush/hit logic.
        debug_show_point_client_coords = false,

        -- Brush HUD text (next to cursor): alpha 0..1; updated in main_loop when envelope hover active.
        brush_hud_text_alpha = 1.0,
        _brush_hud_fade_last_os = nil,
        _vk_tab_down_prev = false,

        -- Wheel inertial coast for plain scroll (brush size) only.
        wheel_momentum_vel = 0,
        wheel_mom_size_accum = 0,

    }
end

function M.get_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

function M.clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
end

--- While sculpt_sort_pending: sort at most every ENVELOPE_SORT_INTERVAL_SEC. nil last_envelope_sort_os => sort on next call.
function M.tick_throttled_envelope_sort_if_due(state, config, ops)
    if not state.sculpt_sort_pending or not state.target_envelope or not state.envelope_points_dirty_sort then
        return false
    end
    local now = reaper.time_precise and reaper.time_precise() or 0
    local iv = config.ENVELOPE_SORT_INTERVAL_SEC or 0.25
    local last = state.last_envelope_sort_os
    if last ~= nil and (now - last) < iv then
        return false
    end
    if ops and ops.sort_envelope_points_for_autoitem then
        ops.sort_envelope_points_for_autoitem(state.target_envelope, state.envelope_autoitem_idx or -1)
    end
    state.last_envelope_sort_os = now
    state.envelope_points_dirty_sort = false
    reaper.UpdateArrange()
    return true
end

function M.calc_inner_brush_radius(state, config, outer_radius)
    local span = config.MAX_FALLOFF_STRENGTH - config.MIN_FALLOFF_STRENGTH
    local t = span > 1e-9 and (state.falloff_strength - config.MIN_FALLOFF_STRENGTH) / span or 0.5
    t = M.clamp(t, 0, 1)
    local rmin = config.FALLOFF_INNER_RATIO_AT_MAX_STRENGTH
    local rmax = config.FALLOFF_INNER_RATIO_AT_MIN_STRENGTH
    local ratio = rmax - t * (rmax - rmin)
    return outer_radius * ratio
end

function M.refresh_frame_arrange(state)
    local a_start, a_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    state.frame_arrange_start = a_start
    state.frame_arrange_end = a_end
end

function M.get_arrange_hwnd()
    if not reaper.JS_Window_FindChildByID then return nil end
    local main = reaper.GetMainHwnd()
    if not main then return nil end
    return reaper.JS_Window_FindChildByID(main, 0x3E8)
end

--- Arrange HWND **client** mouse position, in the same ImGui/native space as the brush HUD
--- (GetRect + PointConvertNative → proportional map into GetClientRect). Not ScreenToClient(GetMouse).
function M.get_mouse_client_xy(ctx, get_arrange_hwnd_fn)
    if not ctx or not get_arrange_hwnd_fn or not reaper.GetMousePosition then return nil, nil end
    if not reaper.ImGui_PointConvertNative or not reaper.JS_Window_GetClientRect then return nil, nil end
    local mx, my = reaper.GetMousePosition()
    local imx, imy = reaper.ImGui_PointConvertNative(ctx, mx, my, false)
    if imx == nil or imy == nil then return nil, nil end
    local il, it, iw, ih = M.get_arrange_imgui_overlay_geometry(ctx, get_arrange_hwnd_fn)
    if not il or not it or not iw or not ih or iw <= 0 or ih <= 0 then return nil, nil end
    local hwnd = get_arrange_hwnd_fn()
    if not hwnd then return nil, nil end
    local ok, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
    if not ok then return nil, nil end
    local nl, nr = math.min(l, r), math.max(l, r)
    local nt, nb = math.min(t, b), math.max(t, b)
    local cw, ch = nr - nl, nb - nt
    if cw <= 0 or ch <= 0 then return nil, nil end
    local u = (imx - il) / iw
    local v = (imy - it) / ih
    u = M.clamp(u, 0, 1)
    v = M.clamp(v, 0, 1)
    return nl + u * cw, nt + v * ch
end

--- Inverse of get_mouse_client_xy: arrange client (same space as envelope_to_screen) -> ImGui overlay draw-list coords.
function M.arrange_client_to_imgui(ctx, get_arrange_hwnd_fn, client_x, client_y)
    if not ctx or not get_arrange_hwnd_fn or client_x == nil or client_y == nil then return nil, nil end
    local il, it, iw, ih = M.get_arrange_imgui_overlay_geometry(ctx, get_arrange_hwnd_fn)
    if not il or not it or not iw or not ih or iw <= 0 or ih <= 0 then return nil, nil end
    local hwnd = get_arrange_hwnd_fn()
    if not hwnd then return nil, nil end
    local ok, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
    if not ok then return nil, nil end
    local nl, nr = math.min(l, r), math.max(l, r)
    local nt, nb = math.min(t, b), math.max(t, b)
    local cw, ch = nr - nl, nb - nt
    if cw <= 0 or ch <= 0 then return nil, nil end
    local u = (client_x - nl) / cw
    local v = (client_y - nt) / ch
    u = M.clamp(u, 0, 1)
    v = M.clamp(v, 0, 1)
    return il + u * iw, it + v * ih
end

--- TK/Sexan: native arrange HWND rect -> ImGui coordinates (HiDPI / macOS safe).
function M.get_arrange_imgui_overlay_geometry(ctx, get_arrange_hwnd_fn)
    if not ctx or not reaper.JS_Window_GetRect or not reaper.ImGui_PointConvertNative then return nil end
    local hwnd = get_arrange_hwnd_fn()
    if not hwnd then return nil end
    local ok, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
    if not ok then return nil end
    local il, it = reaper.ImGui_PointConvertNative(ctx, left, top, false)
    local ir, ib = reaper.ImGui_PointConvertNative(ctx, right, bottom, false)
    if il == nil or it == nil or ir == nil or ib == nil then return nil end
    local w = ir - il
    local h = ib - it
    if w <= 0 or h <= 0 then return nil end
    return il, it, w, h
end

--- Native screen mouse -> ImGui coordinates (same space as overlay + draw list).
function M.get_mouse_imgui_xy(ctx)
    if not ctx or not reaper.ImGui_PointConvertNative then return nil, nil end
    local mx, my = reaper.GetMousePosition()
    return reaper.ImGui_PointConvertNative(ctx, mx, my, false)
end

--- Bitmask 1 = left button (js_ReaScript JS_Mouse_GetState).
function M.is_lmb_down_js()
    if not reaper.JS_Mouse_GetState then return false end
    local st = reaper.JS_Mouse_GetState(1) or 0
    return (st % 2) >= 1
end

function M.ensure_arrange_intercepts(state)
    return ArrangeMsg.ensure_arrange_intercepts(state, M.get_arrange_hwnd)
end

function M.release_arrange_intercepts(state)
    return ArrangeMsg.release_arrange_intercepts(state)
end

function M.process_arrange_lmb_or_forward(state, eat_lmb)
    return ArrangeMsg.process_arrange_lmb_or_forward(state, eat_lmb, M.get_arrange_hwnd)
end

function M.sync_arrange_mouse_eat_with_os(state, lmb_down)
    return ArrangeMsg.sync_arrange_mouse_eat_with_os(state, lmb_down)
end

function M.take_arrange_wheel_or_forward(state, brush_eat)
    return ArrangeMsg.take_arrange_wheel_or_forward(state, brush_eat, M.get_arrange_hwnd)
end

--- "Cmd" on macOS, "Ctrl" on Windows/Linux (REAPER GetOS: OSX vs Win32/Linux).
function M.primary_modifier_short_name()
    local os = reaper.GetOS and reaper.GetOS() or ""
    if os == "OSX" then
        return "Cmd"
    end
    return "Ctrl"
end

function M.calculate_falloff(distance, radius, falloff_type_name, strength)
    if distance > radius then return 0 end
    local normalized = radius > 1e-12 and (distance / radius) or 0

    if falloff_type_name == "exponential" then
        return math.exp(-strength * 3 * normalized)
    elseif falloff_type_name == "linear" then
        -- Cap center weight at 1; strength still steepens the falloff toward the edge (cf. exponential modes).
        return math.min(1, (1 - normalized) * strength)
    else -- inverse_exponential
        return (1 - math.exp(-strength * 3 * (1 - normalized)))
    end
end

return M
