local M = {}
local EPSILON = 1e-12

local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""
local EnvScale = dofile(SCRIPT_DIR .. "BrushEnvelopeScale.lua")
local EnvApi = dofile(SCRIPT_DIR .. "BrushEnvelopeApi.lua")

function M.screen_to_envelope(state, get_envelope_properties, screen_x, screen_y, envelope)
    if not envelope then return nil, nil end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local bounds = state.envelope_bounds

    local pix_w = bounds.right - bounds.left
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, envelope)
    local pix_h = v_bottom - v_top
    if pix_w <= 0 or pix_h <= 0 then return nil, nil end

    local time_ratio = (screen_x - bounds.left) / pix_w
    local project_time = arrange_start + time_ratio * (arrange_end - arrange_start)

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return nil, nil end

    local mode = EnvScale.scaling_mode(envelope)
    local d_lo = EnvScale.raw_to_display(mode, min_val)
    local d_hi = EnvScale.raw_to_display(mode, max_val)
    local d_span = d_hi - d_lo
    if math.abs(d_span) < EPSILON then
        return project_time, min_val
    end

    local y_in_lane = EnvApi.clamp_client_y_to_value_axis(state, envelope, screen_y)
    local normalized_y = (y_in_lane - v_top) / pix_h
    local d = d_hi - (normalized_y * d_span)
    local envelope_value = EnvScale.display_to_raw(mode, d)

    return project_time, envelope_value
end

function M.envelope_to_screen(state, get_envelope_properties, project_time, envelope_value, envelope)
    if not envelope then return nil, nil end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local bounds = state.envelope_bounds

    local time_range = arrange_end - arrange_start
    local pix_w = bounds.right - bounds.left
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, envelope)
    local pix_h = v_bottom - v_top
    local center_y = (v_top + v_bottom) * 0.5
    if pix_w <= 0 or pix_h <= 0 then return nil, nil end

    if math.abs(time_range) < EPSILON then
        return bounds.left, center_y
    end

    local time_ratio = (project_time - arrange_start) / time_range
    local screen_x = bounds.left + time_ratio * pix_w

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return nil, nil end

    local mode = EnvScale.scaling_mode(envelope)
    local d_lo = EnvScale.raw_to_display(mode, min_val)
    local d_hi = EnvScale.raw_to_display(mode, max_val)
    local d_span = d_hi - d_lo
    if math.abs(d_span) < EPSILON then
        return screen_x, center_y
    end

    local d = EnvScale.raw_to_display(mode, envelope_value)
    local value_ratio = (d_hi - d) / d_span
    local screen_y = v_top + value_ratio * pix_h

    return screen_x, screen_y
end

function M.setup_envelope_bounds(state, config, get_arrange_hwnd)
    if not reaper.JS_Window_GetClientRect then return false end
    local arrange = get_arrange_hwnd()
    if not arrange then return false end
    local retval, left, top, right, bottom = reaper.JS_Window_GetClientRect(arrange)
    if not retval then return false end
    -- macOS / some SWELL builds can return top>bottom or left>right; negative height breaks mapping.
    local l, r = math.min(left, right), math.max(left, right)
    local t, b = math.min(top, bottom), math.max(top, bottom)

    local key = string.format("%.6g:%.6g:%.6g:%.6g", l, r, t, b)
    if state._arrange_client_rect_key == key then
        return true
    end
    state._arrange_client_rect_key = key

    state.envelope_bounds.left = l + 2
    state.envelope_bounds.right = r - 2
    state.envelope_bounds.top = t + config.ARRANGE_RULER_INSET
    state.envelope_bounds.bottom = b - 2
    if state.envelope_bounds.top >= state.envelope_bounds.bottom then
        state.envelope_bounds.top, state.envelope_bounds.bottom = t, b
    end
    state.client_w = math.max(1, r - l)
    state.client_h = math.max(1, b - t)
    return true
end

function M.point_hits_envelope_curve(state, config, envelope_to_screen, envelope, mx, my, value_at_time)
    if not envelope or not value_at_time then return false end

    local bounds = state.envelope_bounds
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, envelope)
    if mx < bounds.left or mx > bounds.right or my < v_top or my > v_bottom then
        return false
    end

    local pixel_width = bounds.right - bounds.left
    local time_range = state.frame_arrange_end - state.frame_arrange_start
    if pixel_width <= 0 or math.abs(time_range) < EPSILON then
        return false
    end

    local t = state.frame_arrange_start + ((mx - bounds.left) / pixel_width) * time_range
    local v = value_at_time(envelope, t)
    if v == nil then return false end
    local _, sy = envelope_to_screen(t, v, envelope)
    if not sy then return false end

    return math.abs(my - sy) <= config.ENVELOPE_HOVER_TOLERANCE_PIXELS
end

function M.detect_envelope(state, deps)
    reaper.BR_GetMouseCursorContext()
    local hit, hover_ai = nil, -1
    if reaper.BR_GetMouseCursorContext_EnvelopeEx then
        -- C API: envelope, take_envelope, automation_item_id, point_id_under_cursor
        hit, _, hover_ai = reaper.BR_GetMouseCursorContext_EnvelopeEx()
        if type(hover_ai) ~= "number" or hover_ai < 0 then
            hover_ai = -1
        else
            hover_ai = math.floor(hover_ai)
        end
    else
        hit = reaper.BR_GetMouseCursorContext_Envelope()
    end
    state.sws_hover_detected = (hit ~= nil)

    -- While LMB is down, keep the locked envelope and auto-item index; SWS hover follows the cursor across lanes.
    local lmb_down = deps.lmb_down
    local freeze_envelope_target = (lmb_down == true) or state.is_dragging

    if state.target_envelope and not deps.is_envelope_lane_visible(state.target_envelope) and not freeze_envelope_target then
        deps.clear_target_envelope_state_only()
    end

    if hit and not freeze_envelope_target then
        if state.target_envelope ~= hit then
            state.cached_envelope_properties.envelope = nil
        end
        state.target_envelope = hit
        state.cached_envelope = hit
        state.envelope_autoitem_idx = hover_ai
        deps.setup_envelope_bounds()
    elseif state.target_envelope then
        local ok_name = reaper.GetEnvelopeName(state.target_envelope)
        if not ok_name then
            deps.clear_target_envelope_state_only()
        end
    end

    local mx, my = deps.get_mouse_client_xy()
    if mx == nil or my == nil then
        state.envelope_detected = false
    else
        state.envelope_detected = deps.point_hits_envelope_curve(state.target_envelope, mx, my)
    end
    -- HUD visibility is strictly tied to real-time SWS hover hit.
    state.overlay_visible = (state.sws_hover_detected and state.target_envelope ~= nil)

    return state.envelope_detected
end

return M
