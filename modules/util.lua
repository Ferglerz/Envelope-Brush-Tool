local M = {}

function M.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

function M.stroke_time_key(t)
    return math.floor(t * 1e9 + 0.5)
end

--- SWS cursor timeline position (one BR_GetMouseCursorContext per call).
function M.mouse_cursor_time()
    if not reaper.BR_GetMouseCursorContext_Position or not reaper.BR_GetMouseCursorContext then
        return nil
    end
    reaper.BR_GetMouseCursorContext()
    local t = reaper.BR_GetMouseCursorContext_Position()
    if type(t) ~= "number" or t ~= t then
        return nil
    end
    return t
end

--- Returns current target autoitem_idx (-1 for parent/track envelope lane, >=0 for automation item on that envelope).
function M.track_autoitem_idx(state)
    return state.envelope_autoitem_idx or -1
end

--- Brush HUD + sculpt ops: live lane hover when idle, or a stroke committed on LMB-down in-lane until release.
function M.brush_tool_active(state)
    if not state or not state.target_envelope then
        return false
    end
    if state.is_dragging then
        return state.brush_stroke_committed == true
    end
    return state.envelope_lane_hover == true
end

--- LMB-down edge occurred while in envelope lane (arm for on_lmb_pressed; cleared on LMB up).
function M.brush_lmb_may_start_stroke(state)
    if not state or not state.target_envelope then
        return false
    end
    if state.is_dragging then
        return state.brush_stroke_committed == true
    end
    return state.brush_lmb_press_armed == true
end

return M
