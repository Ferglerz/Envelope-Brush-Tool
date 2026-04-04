local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""

local CONFIG = dofile(SCRIPT_DIR .. "config.lua")
local EnvApi = dofile(SCRIPT_DIR .. "envelope/envelope_api.lua")
local ArrangeMsg = dofile(SCRIPT_DIR .. "arrange_messages.lua")

local M = {}
M.CONFIG = CONFIG

for k, v in pairs(EnvApi) do
    M[k] = v
end

function M.new_state(config)
    local b, f, s = config.brush, config.falloff, config.sculpt
    return {
        -- Brush settings
        brush_size = b.DEFAULT_BRUSH_SIZE,
        invert_brush_size_scroll = b.DEFAULT_INVERT_BRUSH_SIZE_SCROLL,
        falloff_type = 1,
        falloff_strength = f.DEFAULT_FALLOFF_STRENGTH,
        --- Set on LMB down: "nudge" | "sculpt" | "smooth" (see input.resolve_brush_drag_kind).
        active_sculpt_kind = nil,
        sculpt_power = s.DEFAULT_SCULPT_POWER,
        min_point_spacing_px = config.spacing.DEFAULT_MIN_POINT_SPACING_PX,
        lock_time_axis = false,
        lock_value_axis = false,
        --- RMB click (no drag) on lane: freeze brush HUD and show inline settings under the brush.
        brush_settings_mode = false,
        brush_settings_freeze_client = nil,
        _rmb_down_prev = false,
        _rmb_press_client = nil,
        _rmb_dragged = false,

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
        cached_envelope_properties = {
            envelope = nil,
            min_val = 0,
            max_val = 1,
            center_val = 0.5,
            scaling_mode = 0,
        },

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
        --- reaper.time_precise() when Envelope_SortPoints* last ran during sculpt. Set at LMB so the first move does not
        --- immediately sort (same frame as first SetEnvelopePoint* was causing a large hitch on dense envelopes).
        last_envelope_sort_os = nil,
        --- Set when sculpt moved points; cleared when throttled sort runs (avoids sorting every 250ms while idle).
        envelope_points_dirty_sort = false,

        -- ImGui: editor window + brush HUD (same context).
        ctx = nil,
        --- Lock axis chips + overlay: `Lock Closed.ttf` / `Lock Open.ttf` next to script (glyph U+0041).
        font_lock_closed = nil,
        font_lock_open = nil,

        -- Default point shape from chunk; invalidated with target envelope (see clear_target_envelope_state_only).
        cached_defshape_envelope = nil,
        cached_defshape_value = 0,

        --- True after `on_script_close` (Escape / toggle / atexit) so cleanup runs once.
        _shutdown_complete = false,

        -- Arrange: JS_WindowMessage_Intercept/Peek (wheel + LMB + optional MOVE while eating LMB).
        arrange_intercept_active = false,
        arrange_intercept_hwnd = nil,
        brush_ate_arrange_rmb = false,
        wm_wheel_last_time = 0,
        wm_lmb_down_last_time = 0,
        wm_lmb_up_last_time = 0,
        wm_rmb_down_last_time = 0,
        wm_rmb_up_last_time = 0,
        wm_contextmenu_last_time = 0,
        wm_mousemove_last_time = 0,
        brush_ate_arrange_lmb = false,
        arrange_move_intercept_active = false,

        -- Deferred envelope ops: run Insert/Set at start of next main_loop (after defer), not same pass as ImGui.
        envelope_flush_pending = false,
        suppress_imgui_control_this_frame = false,
        --- Set by keyboard (Escape): main_loop forces exit like closing the editor window.
        script_close_requested = false,

        -- Brush HUD text (next to cursor): alpha 0..1; updated in main_loop when envelope hover active.
        brush_hud_text_alpha = 1.0,
        _brush_hud_fade_last_os = nil,
        --- Escape edge while brush settings open (JS + ImGui; arrange keeps keyboard focus).
        _brush_settings_esc_prev = nil,
        _vk_prev_esc = nil,
        _vk_prev_x = nil,
        _vk_prev_y = nil,

        -- Wheel inertial coast for plain scroll (brush size) only.
        wheel_momentum_vel = 0,
        wheel_mom_size_accum = 0,

        -- Prepare-once cache for insert path (track select + BR_Env arm/commit).
        prepared_insert_envelope = nil,

        -- Hover-time seed warm cache: prebuilt point-distance list reused on first sculpt click.
        seed_hover_cache = nil,
        seed_hover_last_client = nil,

    }
end

function M.get_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

function M.clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
end

--- While sculpt_sort_pending: sort at most every ENVELOPE_SORT_INTERVAL_SEC.
--- If last_envelope_sort_os is nil (e.g. after target reset), sort on the next due call. LMB sets it to "now" so the
--- first sculpt tick does not also pay for a full Envelope_SortPoints (see input.on_lmb_pressed).
function M.tick_throttled_envelope_sort_if_due(state, config, ops)
    if not state.sculpt_sort_pending or not state.target_envelope or not state.envelope_points_dirty_sort then
        return false
    end
    local now = reaper.time_precise and reaper.time_precise() or 0
    local iv = config.sculpt.ENVELOPE_SORT_INTERVAL_SEC or 0.25
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
    local f = config.falloff
    local span = f.MAX_FALLOFF_STRENGTH - f.MIN_FALLOFF_STRENGTH
    local t = span > 1e-9 and (state.falloff_strength - f.MIN_FALLOFF_STRENGTH) / span or 0.5
    t = M.clamp(t, 0, 1)
    local rmin = f.FALLOFF_INNER_RATIO_AT_MAX_STRENGTH
    local rmax = f.FALLOFF_INNER_RATIO_AT_MIN_STRENGTH
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

--- True when the OS foreground window is REAPER main or a descendant (hide TopMost HUD when alt-tabbed away).
function M.is_reaper_foreground()
    local fg = reaper.JS_Window_GetForeground()
    if not fg then
        return false
    end
    local main = reaper.GetMainHwnd()
    if not main then
        return false
    end
    local hwnd = fg
    while hwnd do
        if hwnd == main then
            return true
        end
        hwnd = reaper.JS_Window_GetParent(hwnd)
    end
    return false
end

--- Arrange HWND client mouse (JS_Window_ScreenToClient). Same space as envelope_to_screen / I_TCP* lane math.
function M.get_mouse_client_xy(_ctx, get_arrange_hwnd_fn)
    if not get_arrange_hwnd_fn or not reaper.GetMousePosition or not reaper.JS_Window_ScreenToClient then
        return nil, nil
    end
    local hwnd = get_arrange_hwnd_fn()
    if not hwnd then return nil, nil end
    local sx, sy = reaper.GetMousePosition()
    return reaper.JS_Window_ScreenToClient(hwnd, sx, sy)
end

--- Arrange client -> ImGui overlay draw-list (ClientToScreen + PointConvertNative). Inverse of get_mouse_client_xy.
function M.arrange_client_to_imgui(ctx, get_arrange_hwnd_fn, client_x, client_y)
    if not ctx or not get_arrange_hwnd_fn or client_x == nil or client_y == nil then return nil, nil end
    if not reaper.JS_Window_ClientToScreen or not reaper.ImGui_PointConvertNative then return nil, nil end
    local hwnd = get_arrange_hwnd_fn()
    if not hwnd then return nil, nil end
    local sx, sy = reaper.JS_Window_ClientToScreen(hwnd, client_x, client_y)
    if sx == nil or sy == nil then return nil, nil end
    return reaper.ImGui_PointConvertNative(ctx, sx, sy, false)
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

--- Bitmask 2 = right button (js_ReaScript JS_Mouse_GetState).
function M.is_rmb_down_js()
    if not reaper.JS_Mouse_GetState then return false end
    return ((reaper.JS_Mouse_GetState(2) or 0) > 0)
end

function M.ensure_arrange_intercepts(state)
    return ArrangeMsg.ensure_arrange_intercepts(state, M.get_arrange_hwnd)
end

function M.release_arrange_intercepts(state)
    return ArrangeMsg.release_arrange_intercepts(state, M.get_arrange_hwnd)
end

function M.process_arrange_lmb_or_forward(state, eat_lmb, eat_rmb)
    return ArrangeMsg.process_arrange_lmb_or_forward(state, eat_lmb, M.get_arrange_hwnd, eat_rmb)
end

function M.sync_arrange_mouse_eat_with_os(state, lmb_down, rmb_down)
    return ArrangeMsg.sync_arrange_mouse_eat_with_os(state, lmb_down, rmb_down)
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
    elseif falloff_type_name == "inverse_exponential" then
        return (1 - math.exp(-strength * 3 * (1 - normalized)))
    elseif falloff_type_name == "smoothstep" then
        -- 3u² − 2u³ on (1 − t): flat center / flat edge, steep mid transition; strength scales like linear.
        local u = 1 - normalized
        if u <= 0 then return 0 end
        if u >= 1 then u = 1 end
        local w = u * u * (3 - 2 * u)
        return math.min(1, w * strength)
    elseif falloff_type_name == "circle" then
        -- Hemisphere √(1 − t²): spherical cap; zero slope at center (smooth top).
        local inner = 1 - normalized * normalized
        if inner <= 0 then return 0 end
        local w = math.sqrt(inner)
        return math.min(1, w * strength)
    elseif falloff_type_name == "gaussian" then
        -- Quadratic in distance: tighter bell than exponential at same strength.
        return math.exp(-strength * 4 * normalized * normalized)
    elseif falloff_type_name == "cosine" then
        -- Half raised cosine: smooth Hann-like edge, no cusp at brush rim.
        return math.min(1, 0.5 * (1 + math.cos(math.pi * normalized)) * strength)
    else
        return math.exp(-strength * 3 * normalized)
    end
end

return M
