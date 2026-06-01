local M = {}
local EPSILON = 1e-12

local _env_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_env_dir .. "../path.lua")
local Util = Path.load_from_modules("util.lua")
local EnvApi = Path.load("envelope_api.lua")

local function normalized_display_value(minv, maxv, centerv, scaling_mode, raw_value)
    local v = Util.clamp(raw_value, minv, maxv)
    if scaling_mode ~= 0 then
        local vmax = reaper.ScaleToEnvelopeMode(scaling_mode, maxv)
        return Util.clamp(reaper.ScaleToEnvelopeMode(scaling_mode, v) / vmax, 0, 1)
    end
    local span = maxv - minv
    if span <= 0 then return 0.5 end
    return (v - minv) / span
end

local function raw_value_from_normalized(minv, maxv, centerv, scaling_mode, normalized)
    local n = Util.clamp(normalized, 0, 1)
    if scaling_mode ~= 0 then
        local vmax = reaper.ScaleToEnvelopeMode(scaling_mode, maxv)
        return Util.clamp(reaper.ScaleFromEnvelopeMode(scaling_mode, n * vmax), minv, maxv)
    end
    local span = maxv - minv
    if span <= 0 then return centerv end
    return minv + n * span
end

function M.screen_to_envelope(state, get_prop, sx, sy, env)
    if not env then return nil, nil end
    local b = state.envelope_bounds
    local w = b.right - b.left
    local arrange_start, arrange_end = state.frame_arrange_start, state.frame_arrange_end
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return nil, nil end
    local h = v_bottom - v_top
    if w <= 0 or h <= 0 then return nil, nil end

    local x = Util.clamp(sx, b.left, b.right)
    local cy = EnvApi.clamp_client_y_to_value_axis(state, env, sy)
    local time_range = arrange_end - arrange_start
    if math.abs(time_range) < EPSILON then return arrange_start, nil end
    local time = arrange_start + ((x - b.left) / w) * time_range

    local minv, maxv, centerv, scaling_mode = get_prop(env)
    if minv == nil then return nil, nil end
    local norm_y = (cy - v_top) / h
    local raw = raw_value_from_normalized(minv, maxv, centerv, scaling_mode, 1 - norm_y)
    return time, raw
end

function M.envelope_to_screen(state, get_prop, t, v, env)
    if not env then return nil, nil end
    local b = state.envelope_bounds
    local w = b.right - b.left
    local arrange_start, arrange_end = state.frame_arrange_start, state.frame_arrange_end
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return nil, nil end
    local h = v_bottom - v_top
    if w <= 0 or h <= 0 then return nil, nil end

    local minv, maxv, centerv, scaling_mode = get_prop(env)
    if minv == nil then return nil, nil end

    local time_range = arrange_end - arrange_start
    if math.abs(time_range) < EPSILON then return b.left, (v_top + v_bottom) * 0.5 end
    local sx = b.left + ((t - arrange_start) / time_range) * w

    if math.abs(h) < EPSILON then return sx, (v_top + v_bottom) * 0.5 end
    local ratio = 1 - normalized_display_value(minv, maxv, centerv, scaling_mode, v)
    local sy = v_top + ratio * h
    return sx, sy
end

function M.setup_envelope_bounds(state, config, get_hwnd)
    local hwnd = get_hwnd()
    if not hwnd then return false end
    local ok, left, top, right, bottom = reaper.JS_Window_GetClientRect(hwnd)
    if not ok or left == nil then return false end
    local l, r = math.min(left, right), math.max(left, right)
    local t, b = math.min(top, bottom), math.max(top, bottom)
    local rect_key = string.format("%.0f:%.0f:%.0f:%.0f", l, r, t, b)
    if state._arrange_client_rect_key == rect_key then
        return true
    end
    state._arrange_client_rect_key = rect_key
    state.client_w = r - l
    state.client_h = b - t
    if not EnvApi.apply_timeline_x_to_envelope_bounds(state, hwnd, l, r) then
        return false
    end
    local inset = config.arrange.ARRANGE_RULER_INSET or 0
    state.envelope_bounds.top = t + inset
    state.envelope_bounds.bottom = b
    return true
end

function M.point_hits_envelope_curve(state, config, envelope_to_screen, env, mx, my, value_at_time)
    if not env or mx == nil or my == nil then return false end
    local b = state.envelope_bounds
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return false end
    local x = Util.clamp(mx, b.left, b.right)
    local tr = state.frame_arrange_end - state.frame_arrange_start
    local w = b.right - b.left
    if w <= 0 or math.abs(tr) < EPSILON then return false end
    local t = state.frame_arrange_start + ((x - b.left) / w) * tr
    local v = value_at_time(env, t)
    if v == nil then return false end
    local _, sy = envelope_to_screen(t, v, env)
    if not sy then return false end
    return math.abs(my - sy) <= config.arrange.ENVELOPE_HOVER_TOLERANCE_PIXELS
end

local function curve_hit(state, deps, mx, my)
    if mx == nil or my == nil or not state.target_envelope then
        return false
    end
    return deps.point_hits_envelope_curve(state.target_envelope, mx, my)
end

-- Hit-test REAPER envelope hover under mouse, update state accordingly
function M.detect_envelope(state, deps)
    local freeze = state.is_dragging
    local mx, my = deps.get_mouse_client_xy()

    local function mouse_in_env_lane(env)
        if not env or mx == nil or my == nil then return false end
        local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
        if v_top == nil or v_bottom == nil then return false end
        return my >= v_top and my <= v_bottom
    end

    local function mouse_in_target_lane()
        return mouse_in_env_lane(state.target_envelope)
    end

    -- Settings mode is pinned to the envelope captured on RMB open.
    if state.brush_settings_mode and state.target_envelope and state.brush_settings_freeze_client then
        state.sws_hover_detected = true
        state.overlay_visible = true
        return mouse_in_target_lane()
    end

    -- Keep active drag target stable; no reacquire while stroke is active.
    if freeze and state.target_envelope then
        state.sws_hover_detected = true
        state.overlay_visible = true
        return curve_hit(state, deps, mx, my)
    end

    -- Fast path: while hovering same target lane, keep target without re-querying SWS.
    if state.target_envelope and mouse_in_target_lane() and deps.is_envelope_lane_visible(state.target_envelope) then
        state.sws_hover_detected = true
        state.overlay_visible = true
        return true
    end

    local e = nil
    local window, segment = reaper.BR_GetMouseCursorContext()
    local is_envelope_context = (window == "arrange" and segment == "envelope")
    if is_envelope_context then
        e = reaper.BR_GetMouseCursorContext_Envelope()
        if e and not mouse_in_env_lane(e) then
            e = nil
        end
    end
    state.sws_hover_detected = (e ~= nil)

    if state.target_envelope and not deps.is_envelope_lane_visible(state.target_envelope) then
        deps.clear_target_envelope_state_only()
    end
    if e then
        if state.target_envelope ~= e then state.cached_envelope_properties.envelope = nil end
        state.target_envelope = e
        state.envelope_autoitem_idx = -1
        deps.setup_envelope_bounds()
    else
        deps.clear_target_envelope_state_only()
    end

    state.overlay_visible = (state.sws_hover_detected and state.target_envelope ~= nil)
    return curve_hit(state, deps, mx, my)
end

return M
