local M = {}

M.CONFIG = {
    MIN_POINT_SPACING_PIXELS = 10,
    DEFAULT_BRUSH_SIZE = 50,
    MIN_BRUSH_SIZE = 10,
    MAX_BRUSH_SIZE = 200,
    BRUSH_SIZE_STEP = 1,
    FALLOFF_TYPES = {"exponential", "linear", "inverse_exponential"},
    SCULPT_MODES = {"grab", "smooth"},
    DEFAULT_FALLOFF_STRENGTH = 1.0,
    MIN_FALLOFF_STRENGTH = 0.1,
    MAX_FALLOFF_STRENGTH = 3.0,
    FALLOFF_STRENGTH_STEP = 0.1,
    -- Inner dashed radius as fraction of brush radius: scales with falloff strength.
    FALLOFF_INNER_RATIO_AT_MIN_STRENGTH = 0.88,
    FALLOFF_INNER_RATIO_AT_MAX_STRENGTH = 0.12,
    -- HUD: vertical pad around brush; horizontal extra for labels to the right of the brush.
    BRUSH_HUD_PAD_V = 36,
    BRUSH_HUD_LABEL_EXTRA_W = 240,
    -- Pixels to skip at top of arrange view (time ruler inside 0x3E8 child). Tune if value axis is offset.
    ARRANGE_RULER_INSET = 28,
    -- Point-based hover test against the locked envelope curve; independent of brush radius/HUD size.
    ENVELOPE_HOVER_TOLERANCE_PIXELS = 8,
    OUTER_CIRCLE_COLOR = 0xFFFFFFCC,
    INNER_CIRCLE_COLOR = 0xFFFFFF66,
    CIRCLE_THICKNESS = 2.0,
    MIN_MOVEMENT_THRESHOLD = 0.5,
    -- Smooth sculpt: blend per step toward Envelope_Evaluate at each point's time
    DEFAULT_SMOOTH_STRENGTH = 0.2,
    MIN_SMOOTH_STRENGTH = 0.02,
    MAX_SMOOTH_STRENGTH = 1.0,
    -- Shift+scroll: multiplies grab/smooth point movement (delta time/value).
    DEFAULT_SCULPT_POWER = 1.0,
    MIN_SCULPT_POWER = 0.25,
    MAX_SCULPT_POWER = 4.0,
    SCULPT_POWER_STEP = 0.05,
}

function M.new_state(config)
    return {
        -- Brush settings
        brush_size = config.DEFAULT_BRUSH_SIZE,
        falloff_type = 1,
        falloff_strength = config.DEFAULT_FALLOFF_STRENGTH,
        sculpt_mode = 1,
        smooth_strength = config.DEFAULT_SMOOTH_STRENGTH,
        sculpt_power = config.DEFAULT_SCULPT_POWER,
        lock_time_axis = false,
        lock_value_axis = false,

        -- Mouse and interaction
        mouse_pos = {x = 0, y = 0},
        is_dragging = false,
        drag_mode = "sculpt",
        drag_start_pos = {x = 0, y = 0},
        captured_points = {},
        last_create_client = nil,

        -- Envelope context
        target_envelope = nil,
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

        -- Undo system
        undo_active = false,
        undo_operation_name = "",
        sculpt_sort_pending = false,
        sculpt_last_client = nil,

        -- ImGui: editor window + separate HUD for brush.
        ctx = nil,
        ctx_brush = nil,

        -- Native wheel: JS_WindowMessage_Intercept/Peek on arrange (passthrough).
        wheel_intercept_active = false,
        wheel_intercept_hwnd = nil,
        wm_wheel_last_time = 0,
    }
end

function M.get_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

function M.clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
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

function M.get_mouse_client_xy(get_arrange_hwnd_fn)
    local mx, my = reaper.GetMousePosition()
    local arrange = get_arrange_hwnd_fn()
    if not arrange or not reaper.JS_Window_ScreenToClient then return nil, nil end
    return reaper.JS_Window_ScreenToClient(arrange, mx, my)
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

function M.native_to_hud_coords(ctx, x_native, y_native)
    local os_name = reaper.GetOS() or ""
    local is_mac = os_name:match("OSX") or os_name:match("macOS")
    if not is_mac then
        return x_native, y_native
    end

    local vp = reaper.ImGui_GetMainViewport(ctx)
    local _, vp_y = reaper.ImGui_Viewport_GetPos(vp)
    local _, vp_h = reaper.ImGui_Viewport_GetSize(vp)
    local y_hud = vp_y + vp_h - y_native
    return x_native, y_hud
end

function M.is_lmb_down_js()
    if not reaper.JS_Mouse_GetState then return false end
    local st = reaper.JS_Mouse_GetState(1) or 0
    if (st % 2) >= 1 then return true end
    local ok, st_all = pcall(reaper.JS_Mouse_GetState, -1)
    if ok and st_all and (st_all % 2) >= 1 then return true end
    return false
end

function M.get_envelope_properties(state, envelope)
    if not envelope then return nil, nil end

    if state.cached_envelope_properties.envelope == envelope then
        return state.cached_envelope_properties.min_val, state.cached_envelope_properties.max_val
    end

    local br_env = reaper.BR_EnvAlloc(envelope, false)
    if not br_env then return nil, nil end
    local _, _, _, _, _, _, min_val, max_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)

    state.cached_envelope_properties.envelope = envelope
    state.cached_envelope_properties.min_val = min_val
    state.cached_envelope_properties.max_val = max_val

    return min_val, max_val
end

function M.is_envelope_lane_visible(envelope)
    if not envelope then return false end
    local br_env = reaper.BR_EnvAlloc(envelope, false)
    if not br_env then return false end
    -- BR_EnvGetProperties returns: active, visible, armed, ...
    -- Use the 2nd value (visible), not armed.
    local _, visible = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)
    return visible == true
end

function M.clear_target_envelope_state_only(state)
    state.target_envelope = nil
    state.cached_envelope = nil
    state.cached_envelope_properties.envelope = nil
end

function M.calculate_falloff(distance, radius, falloff_type_name, strength)
    if distance >= radius then return 0 end
    local normalized = distance / radius

    if falloff_type_name == "exponential" then
        return math.exp(-strength * 3 * normalized)
    elseif falloff_type_name == "linear" then
        return (1 - normalized) * strength
    else -- inverse_exponential
        return (1 - math.exp(-strength * 3 * (1 - normalized)))
    end
end

local function wparam_wheel_delta_hiword(wph)
    if wph == nil or wph == 0 then return 0 end
    if math.abs(wph) <= 2000 then
        return wph
    end
    local hi = math.floor(wph / 65536) % 65536
    if hi >= 32768 then hi = hi - 65536 end
    return hi
end

local function forward_wm_mousewheel(hwnd, wpl, wph, lpl, lph)
    if not hwnd or not reaper.JS_WindowMessage_Send then return end
    if reaper.JS_WindowMessage_PassThrough then
        pcall(reaper.JS_WindowMessage_PassThrough, hwnd, "WM_MOUSEWHEEL", true)
    end
    pcall(reaper.JS_WindowMessage_Send, hwnd, "WM_MOUSEWHEEL", wpl or 0, wph or 0, lpl or 0, lph or 0)
    if reaper.JS_WindowMessage_PassThrough then
        pcall(reaper.JS_WindowMessage_PassThrough, hwnd, "WM_MOUSEWHEEL", false)
    end
end

--- Intercept WM_MOUSEWHEEL on arrange without passthrough (blocked until Peek + optional forward).
function M.ensure_wheel_intercept(state)
    if state.wheel_intercept_active then return true end
    if not reaper.JS_WindowMessage_Intercept or not reaper.JS_WindowMessage_Peek then return false end
    local hwnd = M.get_arrange_hwnd()
    if not hwnd then return false end
    local ok = pcall(reaper.JS_WindowMessage_Intercept, hwnd, "WM_MOUSEWHEEL", false)
    if not ok then return false end
    state.wheel_intercept_hwnd = hwnd
    state.wheel_intercept_active = true
    return true
end

function M.release_wheel_intercept(state)
    if not state.wheel_intercept_active then return end
    local hwnd = state.wheel_intercept_hwnd
    state.wheel_intercept_hwnd = nil
    state.wheel_intercept_active = false
    state.wm_wheel_last_time = 0
    if hwnd then
        if reaper.JS_WindowMessage_PassThrough then
            pcall(reaper.JS_WindowMessage_PassThrough, hwnd, "WM_MOUSEWHEEL", true)
        end
        if reaper.JS_WindowMessage_Release then
            pcall(reaper.JS_WindowMessage_Release, hwnd, "WM_MOUSEWHEEL")
        end
    end
end

--- Peek one WM_MOUSEWHEEL. If brush_eat and delta usable, return ImGui-scale delta and do not forward.
--- Otherwise re-inject so REAPER still zooms (PassThrough + Send + PassThrough).
function M.take_arrange_wheel_or_forward(state, brush_eat)
    if not state.wheel_intercept_active or not reaper.JS_WindowMessage_Peek then return 0 end
    local hwnd = state.wheel_intercept_hwnd or M.get_arrange_hwnd()
    if not hwnd then return 0 end
    local ret, _, time, wpl, wph, lpl, lph = reaper.JS_WindowMessage_Peek(hwnd, "WM_MOUSEWHEEL")
    if not ret or not time or time == 0 then return 0 end
    if time == state.wm_wheel_last_time then return 0 end
    state.wm_wheel_last_time = time

    if not brush_eat then
        forward_wm_mousewheel(hwnd, wpl, wph, lpl, lph)
        return 0
    end

    local d = wparam_wheel_delta_hiword(wph)
    if d == 0 then
        forward_wm_mousewheel(hwnd, wpl, wph, lpl, lph)
        return 0
    end

    local ad = math.abs(d)
    if ad >= 120 then
        return d / 120.0
    end
    return d > 0 and 1 or -1
end

return M
