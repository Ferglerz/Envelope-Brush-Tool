local M = {}
local EPSILON = 1e-12

local DIR = debug.getinfo(1,"S").source:match("^@(.+[\\/])") or ""
local EnvApi = dofile(DIR .. "envelope_api.lua")

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function normalized_display_value(minv, maxv, centerv, scaling_mode, raw_value)
    local v = clamp(raw_value, minv, maxv)
    if scaling_mode ~= 0 then
        local vmax = reaper.ScaleToEnvelopeMode(scaling_mode, maxv)
        return clamp(reaper.ScaleToEnvelopeMode(scaling_mode, v) / vmax, 0, 1)
    end
    if v > centerv then
        return ((v - centerv) / (maxv - centerv) + 1) * 0.5
    end
    return ((v - minv) / (centerv - minv)) * 0.5
end

local function raw_value_from_normalized(minv, maxv, centerv, scaling_mode, normalized)
    local n = clamp(normalized, 0, 1)
    if scaling_mode ~= 0 then
        local vmax = reaper.ScaleToEnvelopeMode(scaling_mode, maxv)
        return clamp(reaper.ScaleFromEnvelopeMode(scaling_mode, n * vmax), minv, maxv)
    end
    if n > 0.5 then
        return centerv + (2 * n - 1) * (maxv - centerv)
    end
    return minv + (n / 0.5) * (centerv - minv)
end

-- Convert screen xy to envelope time/value
function M.screen_to_envelope(state, get_prop, sx, sy, env)
    if not env then return nil, nil end
    local b = state.envelope_bounds
    local w, arrange_start, arrange_end = b.right - b.left, state.frame_arrange_start, state.frame_arrange_end
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return nil, nil end
    local h = v_bottom - v_top
    if w <= 0 or h <= 0 then return nil, nil end

    local time = arrange_start + ((sx - b.left) / w) * (arrange_end - arrange_start)
    local minv, maxv, centerv, scaling_mode = get_prop(env)
    if not minv then return nil, nil end
    local span = maxv - minv
    if math.abs(span) < EPSILON then return time, minv end

    local y = EnvApi.clamp_client_y_to_value_axis(state, env, sy)
    local norm_y = (y - v_top) / h
    local raw = raw_value_from_normalized(minv, maxv, centerv, scaling_mode, 1 - norm_y)
    return time, raw
end

-- Convert envelope time/value to screen xy
function M.envelope_to_screen(state, get_prop, t, v, env)
    if not env then return nil, nil end
    local b = state.envelope_bounds
    local arrange_start, arrange_end = state.frame_arrange_start, state.frame_arrange_end
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return nil, nil end
    local w = b.right - b.left
    local h = v_bottom - v_top
    local center_y = 0.5 * (v_top + v_bottom)
    if w <= 0 or h <= 0 then return nil, nil end
    local time_range = arrange_end - arrange_start
    if math.abs(time_range) < EPSILON then return b.left, center_y end
    local sx = b.left + (t - arrange_start) / time_range * w

    local minv, maxv, centerv, scaling_mode = get_prop(env)
    if not minv then return nil, nil end
    local span = maxv - minv
    if math.abs(span) < EPSILON then return sx, center_y end
    local ratio = 1 - normalized_display_value(minv, maxv, centerv, scaling_mode, v)
    local sy = v_top + ratio * h
    return sx, sy
end

-- Setup state.envelope_bounds to current arrange view, bail if cannot get info
function M.setup_envelope_bounds(state, config, get_hwnd)
    if not reaper.JS_Window_GetClientRect then return false end
    local hwnd = get_hwnd()
    if not hwnd then return false end
    local ok, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
    if not ok then return false end
    l, r = math.min(l, r), math.max(l, r)
    t, b = math.min(t, b), math.max(t, b)

    if not EnvApi.apply_timeline_x_to_envelope_bounds(state, hwnd, l, r) then
        return false
    end
    local key = string.format("%.6g:%.6g:%.6g:%.6g", l, r, t, b)
    state._arrange_client_rect_key = key

    state.envelope_bounds.top    = t
    state.envelope_bounds.bottom = b
    state.client_w = math.max(1, r - l)
    state.client_h = math.max(1, b - t)
    return true
end

-- Return true if mx,my (client) is close to the envelope curve on screen
function M.point_hits_envelope_curve(state, config, envelope_to_screen, env, mx, my, value_at_time)
    if not env or not value_at_time then return false end
    local b = state.envelope_bounds
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return false end
    if my < v_top or my > v_bottom then return false end
    local w, tr = b.right-b.left, state.frame_arrange_end-state.frame_arrange_start
    if w <= 0 or math.abs(tr) < EPSILON then return false end

    local x = clamp(mx, b.left, b.right)
    local t = state.frame_arrange_start + ((x - b.left)/w)*tr
    local v = value_at_time(env, t)
    if not v then return false end
    local _, sy = envelope_to_screen(t, v, env)
    if not sy then return false end
    return math.abs(my - sy) <= config.arrange.ENVELOPE_HOVER_TOLERANCE_PIXELS
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
        state.envelope_detected = mouse_in_target_lane()
        state.overlay_visible = true
        return state.envelope_detected
    end

    -- Keep active drag target stable; no reacquire while stroke is active.
    if freeze and state.target_envelope then
        state.sws_hover_detected = true
        state.envelope_detected = (mx and my) and deps.point_hits_envelope_curve(state.target_envelope, mx, my) or false
        state.overlay_visible = true
        return state.envelope_detected
    end

    -- Fast path: while hovering same target lane, keep target without re-querying SWS.
    if state.target_envelope and mouse_in_target_lane() and deps.is_envelope_lane_visible(state.target_envelope) then
        state.sws_hover_detected = true
        state.envelope_detected = true
        state.overlay_visible = true
        return true
    end

    local e, ai = nil, -1
    local window, segment = reaper.BR_GetMouseCursorContext()
    local is_envelope_context = (window == "arrange" and segment == "envelope")
    if is_envelope_context then
        e = reaper.BR_GetMouseCursorContext_Envelope()
        if e and not mouse_in_env_lane(e) then
            e = nil
            ai = -1
        end
    end
    state.sws_hover_detected = (e ~= nil)

    if state.target_envelope and not deps.is_envelope_lane_visible(state.target_envelope) then
        deps.clear_target_envelope_state_only()
    end
    if e then
        if state.target_envelope ~= e then state.cached_envelope_properties.envelope = nil end
        state.target_envelope = e
        state.cached_envelope = e
        state.envelope_autoitem_idx = ai
        deps.setup_envelope_bounds()
    else
        deps.clear_target_envelope_state_only()
    end

    state.envelope_detected = (mx and my) and deps.point_hits_envelope_curve(state.target_envelope, mx, my) or false
    state.overlay_visible = (state.sws_hover_detected and state.target_envelope ~= nil)
    return state.envelope_detected
end

return M
