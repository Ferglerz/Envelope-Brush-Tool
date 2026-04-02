local M = {}
local EPSILON = 1e-12

local DIR = debug.getinfo(1,"S").source:match("^@(.+[\\/])") or ""
local EnvScale = dofile(DIR .. "BrushEnvelopeScale.lua")
local EnvApi = dofile(DIR .. "BrushEnvelopeApi.lua")

-- Convert screen xy to envelope time/value
function M.screen_to_envelope(state, get_prop, sx, sy, env)
    if not env then return nil, nil end
    local b = state.envelope_bounds
    local w, arrange_start, arrange_end = b.right - b.left, state.frame_arrange_start, state.frame_arrange_end
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    local h = v_bottom - v_top
    if w <= 0 or h <= 0 then return nil, nil end

    local time = arrange_start + ((sx - b.left) / w) * (arrange_end - arrange_start)
    local minv, maxv = get_prop(env)
    if not minv then return nil, nil end

    local mode = EnvScale.scaling_mode(env)
    local dl, dh = EnvScale.raw_to_display(mode, minv), EnvScale.raw_to_display(mode, maxv)
    local dspan = dh - dl
    if math.abs(dspan) < EPSILON then return time, minv end

    local y = EnvApi.clamp_client_y_to_value_axis(state, env, sy)
    local norm_y = (y - v_top) / h
    local d = dh - norm_y * dspan
    return time, EnvScale.display_to_raw(mode, d)
end

-- Convert envelope time/value to screen xy
function M.envelope_to_screen(state, get_prop, t, v, env)
    if not env then return nil, nil end
    local b = state.envelope_bounds
    local arrange_start, arrange_end = state.frame_arrange_start, state.frame_arrange_end
    local w, h = b.right - b.left, select(2, EnvApi.envelope_value_axis_screen_for_mapping(state, env)) - select(1, EnvApi.envelope_value_axis_screen_for_mapping(state, env))
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    local center_y = 0.5 * (v_top + v_bottom)
    if w <= 0 or h <= 0 then return nil, nil end
    local time_range = arrange_end - arrange_start
    if math.abs(time_range) < EPSILON then return b.left, center_y end
    local sx = b.left + (t - arrange_start) / time_range * w

    local minv, maxv = get_prop(env)
    if not minv then return nil, nil end
    local mode = EnvScale.scaling_mode(env)
    local dl, dh = EnvScale.raw_to_display(mode, minv), EnvScale.raw_to_display(mode, maxv)
    local dspan = dh - dl
    if math.abs(dspan) < EPSILON then return sx, center_y end

    local d = EnvScale.raw_to_display(mode, v)
    local ratio = (dh - d) / dspan
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

    local key = string.format("%.6g:%.6g:%.6g:%.6g", l, r, t, b)
    if state._arrange_client_rect_key == key then return true end
    state._arrange_client_rect_key = key

    state.envelope_bounds.left   = l + 2
    state.envelope_bounds.right  = r - 2
    state.envelope_bounds.top    = t + config.arrange.ARRANGE_RULER_INSET
    state.envelope_bounds.bottom = b - 2
    if state.envelope_bounds.top >= state.envelope_bounds.bottom then
        state.envelope_bounds.top, state.envelope_bounds.bottom = t, b
    end
    state.client_w = math.max(1, r - l)
    state.client_h = math.max(1, b - t)
    return true
end

-- Return true if mx,my (client) is close to the envelope curve on screen
function M.point_hits_envelope_curve(state, config, envelope_to_screen, env, mx, my, value_at_time)
    if not env or not value_at_time then return false end
    local b = state.envelope_bounds
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, env)
    if mx < b.left or mx > b.right or my < v_top or my > v_bottom then return false end
    local w, tr = b.right-b.left, state.frame_arrange_end-state.frame_arrange_start
    if w <= 0 or math.abs(tr) < EPSILON then return false end

    local t = state.frame_arrange_start + ((mx - b.left)/w)*tr
    local v = value_at_time(env, t)
    if not v then return false end
    local _, sy = envelope_to_screen(t, v, env)
    if not sy then return false end
    return math.abs(my - sy) <= config.arrange.ENVELOPE_HOVER_TOLERANCE_PIXELS
end

-- Hit-test REAPER envelope hover under mouse, update state accordingly
function M.detect_envelope(state, deps)
    reaper.BR_GetMouseCursorContext()
    local e, ai = nil, -1
    if reaper.BR_GetMouseCursorContext_EnvelopeEx then
        e, _, ai = reaper.BR_GetMouseCursorContext_EnvelopeEx()
        ai = (type(ai) == "number" and ai >= 0) and math.floor(ai) or -1
    else
        e = reaper.BR_GetMouseCursorContext_Envelope()
    end
    state.sws_hover_detected = (e ~= nil)
    local lmb_down = deps.lmb_down
    local freeze = lmb_down == true or state.is_dragging

    if state.target_envelope and not deps.is_envelope_lane_visible(state.target_envelope) and not freeze then
        deps.clear_target_envelope_state_only()
    end
    if e and not freeze then
        if state.target_envelope ~= e then state.cached_envelope_properties.envelope = nil end
        state.target_envelope = e
        state.cached_envelope = e
        state.envelope_autoitem_idx = ai
        deps.setup_envelope_bounds()
    elseif state.target_envelope then
        if not reaper.GetEnvelopeName(state.target_envelope) then
            deps.clear_target_envelope_state_only()
        end
    end

    local mx, my = deps.get_mouse_client_xy()
    state.envelope_detected = (mx and my) and deps.point_hits_envelope_curve(state.target_envelope, mx, my) or false
    state.overlay_visible = (state.sws_hover_detected and state.target_envelope ~= nil)
    return state.envelope_detected
end

return M
