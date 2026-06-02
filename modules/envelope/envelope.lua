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

local function get_prop(state, env)
    return EnvApi.get_envelope_properties(state, env)
end

function M.screen_to_envelope(state, sx, sy, env)
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

    local minv, maxv, centerv, scaling_mode = get_prop(state, env)
    if minv == nil then return nil, nil end
    local norm_y = (cy - v_top) / h
    local raw = raw_value_from_normalized(minv, maxv, centerv, scaling_mode, 1 - norm_y)
    return time, raw
end

function M.envelope_to_screen(state, t, v, env)
    if not env then return nil, nil end
    local b = state.envelope_bounds
    local w = b.right - b.left
    local arrange_start, arrange_end = state.frame_arrange_start, state.frame_arrange_end
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return nil, nil end
    local h = v_bottom - v_top
    if w <= 0 or h <= 0 then return nil, nil end

    local minv, maxv, centerv, scaling_mode = get_prop(state, env)
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
    if not EnvApi.apply_timeline_x_to_envelope_bounds(state, hwnd, l, r) then
        return false
    end
    local inset = config.arrange.ARRANGE_RULER_INSET or 0
    state.envelope_bounds.top = t + inset
    state.envelope_bounds.bottom = b
    return true
end

function M.point_hits_envelope_curve(state, config, env, mx, my)
    if not env or mx == nil or my == nil then return false end
    local b = state.envelope_bounds
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return false end
    local x = Util.clamp(mx, b.left, b.right)
    local tr = state.frame_arrange_end - state.frame_arrange_start
    local w = b.right - b.left
    if w <= 0 or math.abs(tr) < EPSILON then return false end
    local t = state.frame_arrange_start + ((x - b.left) / w) * tr
    local v = EnvApi.envelope_value_at_time(env, t)
    if v == nil then return false end
    local _, sy = M.envelope_to_screen(state, t, v, env)
    if not sy then return false end
    return math.abs(my - sy) <= config.arrange.ENVELOPE_HOVER_TOLERANCE_PIXELS
end

local function mouse_in_env_lane(state, env, mx, my)
    if not env or mx == nil or my == nil then return false end
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if v_top == nil or v_bottom == nil then return false end
    return my >= v_top and my <= v_bottom
end

local function update_lane_hover(state, mx, my, curve_on_curve)
    if not state.target_envelope or not state.sws_hover_detected then
        state.envelope_lane_hover = false
        return
    end
    local in_lane = false
    if mx ~= nil and my ~= nil then
        in_lane = mouse_in_env_lane(state, state.target_envelope, mx, my)
            and EnvApi.is_envelope_lane_visible(state.target_envelope)
    end
    state.envelope_lane_hover = in_lane
end

function M.detect_envelope(state, core, config)
    local freeze = state.is_dragging
    local mx, my = core.get_mouse_client_xy(state.ctx, core.get_arrange_hwnd)
    state.envelope_lane_hover = false

    local function curve_hit()
        if mx == nil or my == nil or not state.target_envelope then
            return false
        end
        return M.point_hits_envelope_curve(state, config, state.target_envelope, mx, my)
    end

    if state.brush_settings_mode and state.target_envelope and state.brush_settings_freeze_client then
        state.sws_hover_detected = true
        state.envelope_lane_hover = mouse_in_env_lane(state, state.target_envelope, mx, my)
            and EnvApi.is_envelope_lane_visible(state.target_envelope)
        return state.envelope_lane_hover
    end

    if freeze and state.target_envelope then
        state.sws_hover_detected = true
        local curve = curve_hit()
        update_lane_hover(state, mx, my, curve)
        return curve
    end

    if state.target_envelope
        and not EnvApi.envelope_has_automation_items(state.target_envelope, state)
        and mouse_in_env_lane(state, state.target_envelope, mx, my)
        and EnvApi.is_envelope_lane_visible(state.target_envelope) then
        state.envelope_autoitem_idx = -1
        state.sws_hover_detected = true
        local curve = curve_hit()
        update_lane_hover(state, mx, my, curve)
        return curve
    end

    local window, segment = reaper.BR_GetMouseCursorContext()
    local is_envelope_context = (window == "arrange" and segment == "envelope")
    local e, ai_idx = nil, -1
    if is_envelope_context then
        if reaper.BR_GetMouseCursorContext_EnvelopeEx then
            local take_env
            e, take_env, ai_idx = reaper.BR_GetMouseCursorContext_EnvelopeEx()
            if e and take_env then
                e = nil
                ai_idx = -1
            end
        else
            e = reaper.BR_GetMouseCursorContext_Envelope()
            ai_idx = -1
        end
        if e and EnvApi.envelope_is_take_envelope(e) then
            e = nil
            ai_idx = -1
        end
        if e and not mouse_in_env_lane(state, e, mx, my) then
            e = nil
            ai_idx = -1
        end
    end
    state.sws_hover_detected = (e ~= nil)

    local keep_prev = false
    if not e and state.target_envelope and mouse_in_env_lane(state, state.target_envelope, mx, my)
        and EnvApi.is_envelope_lane_visible(state.target_envelope) then
        if not EnvApi.envelope_has_automation_items(state.target_envelope, state) then
            keep_prev = true
            state.envelope_autoitem_idx = -1
            state.sws_hover_detected = true
        end
    end

    if state.target_envelope and not EnvApi.is_envelope_lane_visible(state.target_envelope) then
        EnvApi.clear_target_envelope_state_only(state)
    end
    if e then
        if state.target_envelope ~= e then
            state.cached_envelope_properties.envelope = nil
        end
        state.target_envelope = e
        state.envelope_autoitem_idx = (type(ai_idx) == "number" and ai_idx >= -1) and ai_idx or -1
        EnvApi.envelope_has_automation_items(e, state)
        M.setup_envelope_bounds(state, config, core.get_arrange_hwnd)
    elseif not keep_prev then
        EnvApi.clear_target_envelope_state_only(state)
    end

    local curve = curve_hit()
    update_lane_hover(state, mx, my, curve)
    return curve
end

return M
