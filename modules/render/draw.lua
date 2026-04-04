local M = {}

--- Mini falloff graph: mirrored brush profile (edges low, center peak) at strength 1.
function M.draw_falloff_preview(draw_list, x, y, w, h, falloff_type_name, calculate_falloff, opts)
    if not draw_list or not calculate_falloff then return end
    opts = opts or {}
    local strength = opts.strength or 1.0
    local line_col = opts.line_color or 0xCCCCCCFF
    local bg_col = opts.bg_color or 0x2A2A2AFF
    local border_col = opts.border_color or 0x505050FF
    local thickness = opts.thickness or 1.5
    local rounding = opts.rounding or 3

    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + w, y + h, bg_col, rounding)
    reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + w, y + h, border_col, rounding, 0, 1)

    local pad = 2
    local ix, iy = x + pad, y + pad
    local iw, ih = w - pad * 2, h - pad * 2
    if iw <= 1 or ih <= 1 then return end

    local segments = math.max(12, math.floor(iw))
    reaper.ImGui_DrawList_PathClear(draw_list)
    for s = 0, segments do
        local u = s / segments
        local t = math.abs(u - 0.5) * 2
        local val = calculate_falloff(t, 1.0, falloff_type_name, strength)
        val = math.max(0, math.min(1, val))
        local px = ix + u * iw
        local py = iy + ih - val * ih
        reaper.ImGui_DrawList_PathLineTo(draw_list, px, py)
    end
    reaper.ImGui_DrawList_PathStroke(draw_list, line_col, 0, thickness)
end

--- @param dash_count integer Target dash count around the circle (e.g. circumference_px / min_point_spacing_px).
function M.draw_dashed_circle(draw_list, center_x, center_y, radius, color, thickness, dash_count)
    local DASH_RATIO = 0.6
    local n = math.max(2, math.floor(dash_count + 0.5))
    local angle_step = (2 * math.pi) / n
    local dash_length = angle_step * DASH_RATIO

    for i = 0, n - 1 do
        local start_angle = i * angle_step
        local end_angle = start_angle + dash_length
        local arc_px = radius * dash_length
        local arc_segments = math.max(3, math.ceil(arc_px / 4))

        reaper.ImGui_DrawList_PathArcTo(draw_list, center_x, center_y, radius, start_angle, end_angle, arc_segments)
        reaper.ImGui_DrawList_PathStroke(draw_list, color, 0, thickness)
    end
end

return M
