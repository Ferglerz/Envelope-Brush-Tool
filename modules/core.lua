local _mod_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_mod_dir .. "path.lua")
local Util = Path.load_from_modules("util.lua")
local CONFIG = Path.load_from_modules("config.lua")
local EnvApi = Path.load_from_modules("envelope/envelope_api.lua")
local ArrangeMsg = Path.load_from_modules("arrange_messages.lua")

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
        invert_scroll = b.DEFAULT_INVERT_SCROLL,
        falloff_type = 1,
        falloff_strength = f.DEFAULT_FALLOFF_STRENGTH,
        --- Set on LMB down: "nudge" | "sculpt" | "smooth" (see input.resolve_brush_drag_kind).
        active_sculpt_kind = nil,
        sculpt_power = s.DEFAULT_SCULPT_POWER,
        min_point_spacing_px = config.spacing.DEFAULT_MIN_POINT_SPACING_PX,
        lock_time_axis = false,
        lock_value_axis = false,
        --- Smooth LMB-up cleanup (settings panel + project ext).
        smooth_cleanup_bezier_enabled = config.cleanup.DEFAULT_SMOOTH_CLEANUP_BEZIER_ENABLED,
        smooth_cleanup_angle_enabled = config.cleanup.DEFAULT_SMOOTH_CLEANUP_ANGLE_ENABLED,
        smooth_bezier_fit_tolerance = config.cleanup.DEFAULT_BEZIER_FIT_TOLERANCE,
        hud_hints_enabled = (config.hud and config.hud.DEFAULT_HUD_HINTS_ENABLED) ~= false,
        hud_info_enabled = (config.hud and config.hud.DEFAULT_HUD_INFO_ENABLED) ~= false,
        --- RMB click (no drag) on lane: freeze brush HUD and show inline settings under the brush.
        brush_settings_mode = false,
        brush_settings_freeze_client = nil,
        _rmb_down_prev = false,
        _rmb_press_client = nil,
        _rmb_dragged = false,

        -- Mouse and interaction
        mouse_pos = {x = 0, y = 0},
        is_dragging = false,
        --- True from successful on_lmb_pressed (lane hover at press) until LMB up; keeps HUD/ops for whole stroke.
        brush_stroke_committed = false,
        --- Set on LMB-down edge while envelope_lane_hover; consumed by on_lmb_pressed (blocks mid-hold lane entry).
        brush_lmb_press_armed = false,
        _lmb_was_down_prev = false,
        drag_mode = "sculpt",
        drag_start_pos = {x = 0, y = 0},
        captured_points = {},
        --- Smooth LMB stroke: project times of every point that entered the brush (merge scope on release).
        smooth_stroke_point_times = nil,
        last_create_client = nil,

        -- Envelope context (REAPER: autoitem_idx -1 = parent lane; >=0 = automation item on that envelope)
        target_envelope = nil,
        envelope_autoitem_idx = -1,
        envelope_bounds = {top = 150, bottom = 600, left = 200, right = 1200},
        overlay_visible = false,
        sws_hover_detected = false,
        --- True when cursor is in the target envelope lane (Y + SWS envelope context). Gates HUD, LMB, and point ops.
        envelope_lane_hover = false,
        --- True when cursor is near the envelope curve within the lane (proximity hit-test).
        envelope_curve_hover = false,

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

        -- Undo: one Undo_OnStateChangeEx2 per completed LMB stroke (no Begin/End — avoids open blocks merging strokes).
        pending_undo_label = nil,
        envelope_stroke_dirty = false,
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

        -- Hover-time seed warm cache: prebuilt point-distance list reused on first sculpt click.
        seed_hover_cache = nil,
        seed_hover_last_client = nil,

        -- Per-envelope: true if CountAutomationItems > 0 (see envelope_api.envelope_has_automation_items).
        envelope_ai_lane_cache = nil,

    }
end

function M.get_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

function M.clamp(value, min_val, max_val)
    return Util.clamp(value, min_val, max_val)
end

function M.track_autoitem_idx(state)
    return Util.track_autoitem_idx(state)
end

function M.brush_tool_active(state)
    return Util.brush_tool_active(state)
end

function M.brush_lmb_may_start_stroke(state)
    return Util.brush_lmb_may_start_stroke(state)
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
        ops.sort_envelope_points_for_autoitem(state.target_envelope, M.track_autoitem_idx(state))
    end
    state.last_envelope_sort_os = now
    state.envelope_points_dirty_sort = false
    reaper.UpdateArrange()
    return true
end

function M.falloff_strength_percent(strength, _config)
    return 100 * (strength or 0)
end

function M.clamp_falloff_strength(strength, config)
    local f = config.falloff
    return M.clamp(strength, f.MIN_FALLOFF_STRENGTH, f.MAX_FALLOFF_STRENGTH)
end

function M.falloff_wheel_step(config, fine_mul)
    local f = config.falloff
    local pct = f.FALLOFF_STRENGTH_PERCENT_STEP or 1
    fine_mul = fine_mul or 1
    return (pct / 100) * fine_mul
end

function M.sculpt_power_percent(power, _config)
    return 100 * (power or 0)
end

function M.clamp_sculpt_power(power, config)
    local s = config.sculpt
    return M.clamp(power, s.MIN_SCULPT_POWER, s.MAX_SCULPT_POWER)
end

function M.sculpt_wheel_step(config, fine_mul)
    local s = config.sculpt
    local pct = s.SCULPT_POWER_PERCENT_STEP or 1
    fine_mul = fine_mul or 1
    return (pct / 100) * fine_mul
end

--- Radius of dashed inner ring: largest distance from center where falloff weight >= threshold.
function M.calc_inner_brush_radius(state, config, outer_radius)
    if not outer_radius or outer_radius <= 0 then return 0 end
    local f = config.falloff
    local types = f.FALLOFF_TYPES
    local idx = state.falloff_type or 1
    if idx < 1 or idx > #types then idx = 1 end
    local falloff_name = types[idx]
    local strength = state.falloff_strength
    local threshold = f.FALLOFF_INNER_WEIGHT_THRESHOLD or 0.5
    threshold = M.clamp(threshold, 1e-6, 1 - 1e-6)

    if M.calculate_falloff(0, outer_radius, falloff_name, strength) < threshold then
        return 0
    end
    if M.calculate_falloff(outer_radius, outer_radius, falloff_name, strength) >= threshold then
        return outer_radius
    end

    local lo, hi = 0.0, 1.0
    for _ = 1, 24 do
        local mid = (lo + hi) * 0.5
        if M.calculate_falloff(mid * outer_radius, outer_radius, falloff_name, strength) >= threshold then
            lo = mid
        else
            hi = mid
        end
    end
    return outer_radius * lo
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

local FALLOFF_CURVES = {
    exponential = function(normalized, strength)
        return math.exp(-strength * 3 * normalized)
    end,
    linear = function(normalized, strength)
        return math.min(1, (1 - normalized) * strength)
    end,
    inverse_exponential = function(normalized, strength)
        return 1 - math.exp(-strength * 3 * (1 - normalized))
    end,
    smoothstep = function(normalized, strength)
        local u = 1 - normalized
        if u <= 0 then return 0 end
        if u >= 1 then u = 1 end
        local w = u * u * (3 - 2 * u)
        return math.min(1, w * strength)
    end,
    circle = function(normalized, strength)
        local inner = 1 - normalized * normalized
        if inner <= 0 then return 0 end
        return math.min(1, math.sqrt(inner) * strength)
    end,
    gaussian = function(normalized, strength)
        return math.exp(-strength * 4 * normalized * normalized)
    end,
    cosine = function(normalized, strength)
        return math.min(1, 0.5 * (1 + math.cos(math.pi * normalized)) * strength)
    end,
}

function M.calculate_falloff(distance, radius, falloff_type_name, strength)
    if distance > radius then return 0 end
    local normalized = radius > 1e-12 and (distance / radius) or 0
    local curve = FALLOFF_CURVES[falloff_type_name]
    if not curve then
        error(string.format("Envelope Brush Tool: unknown falloff type %q", tostring(falloff_type_name)))
    end
    return curve(normalized, strength)
end

return M
