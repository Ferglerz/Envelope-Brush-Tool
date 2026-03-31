local M = {}
local EPSILON = 1e-12

local function get_bounds_metrics(bounds)
    local pix_w = bounds.right - bounds.left
    local pix_h = bounds.bottom - bounds.top
    local center_y = (bounds.top + bounds.bottom) * 0.5
    return pix_w, pix_h, center_y
end

function M.screen_to_envelope(state, get_envelope_properties, screen_x, screen_y, envelope)
    if not envelope then return nil, nil end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local bounds = state.envelope_bounds

    local pix_w, pix_h = get_bounds_metrics(bounds)
    if pix_w <= 0 or pix_h <= 0 then return nil, nil end

    local time_ratio = (screen_x - bounds.left) / pix_w
    local project_time = arrange_start + time_ratio * (arrange_end - arrange_start)

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return nil, nil end

    local v_span = max_val - min_val
    if math.abs(v_span) < EPSILON then
        return project_time, min_val
    end

    local normalized_y = (screen_y - bounds.top) / pix_h
    local envelope_value = max_val - (normalized_y * v_span)

    return project_time, envelope_value
end

function M.envelope_to_screen(state, get_envelope_properties, project_time, envelope_value, envelope)
    if not envelope then return nil, nil end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local bounds = state.envelope_bounds

    local time_range = arrange_end - arrange_start
    local pix_w, pix_h, center_y = get_bounds_metrics(bounds)
    if pix_w <= 0 or pix_h <= 0 then return nil, nil end

    if math.abs(time_range) < EPSILON then
        return bounds.left, center_y
    end

    local time_ratio = (project_time - arrange_start) / time_range
    local screen_x = bounds.left + time_ratio * pix_w

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return nil, nil end

    local v_span = max_val - min_val
    if math.abs(v_span) < EPSILON then
        return screen_x, center_y
    end

    local value_ratio = (max_val - envelope_value) / v_span
    local screen_y = bounds.top + value_ratio * pix_h

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
    if mx < bounds.left or mx > bounds.right or my < bounds.top or my > bounds.bottom then
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

    -- While LMB brush-drag is active, keep the locked lane even if SWS hover / lane-visible flickers off.
    if state.target_envelope and not deps.is_envelope_lane_visible(state.target_envelope) and not state.is_dragging then
        deps.clear_target_envelope_state_only()
    end

    if hit then
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
