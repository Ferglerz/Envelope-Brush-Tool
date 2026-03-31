local M = {}

function M.brush_hud_interactive(state)
    return state.sws_hover_detected and state.target_envelope ~= nil
end

function M.draw_dashed_circle(draw_list, center_x, center_y, radius, color, thickness)
    local DASH_SEGMENTS = 24
    local DASH_RATIO = 0.6
    local angle_step = (2 * math.pi) / DASH_SEGMENTS
    local dash_length = angle_step * DASH_RATIO

    for i = 0, DASH_SEGMENTS - 1 do
        local start_angle = i * angle_step
        local end_angle = start_angle + dash_length

        reaper.ImGui_DrawList_PathArcTo(draw_list, center_x, center_y, radius, start_angle, end_angle, 8)
        reaper.ImGui_DrawList_PathStroke(draw_list, color, 0, thickness)
    end
end

--- TK/Sexan: GetRect + PointConvertNative for window; PointConvertNative(GetMouse) for brush (same ImGui space).
function M.render_brush_hud(state, config, deps)
    local ctx = state.ctx
    if not ctx then return end

    if state.debug_disable_js_eat then
        return
    end

    if not M.brush_hud_interactive(state) then
        return
    end

    -- Must unpack here: assigning to a single variable drops other return values in Lua.
    local il, it, cw, ch = deps.get_arrange_imgui_overlay_geometry()
    if il == nil or it == nil or cw == nil or ch == nil then return end
    local cx, cy = deps.get_mouse_imgui_xy()
    if cx == nil or cy == nil then return end

    local cond = reaper.ImGui_Cond_Always and reaper.ImGui_Cond_Always() or 0
    reaper.ImGui_SetNextWindowPos(ctx, il, it, cond)
    reaper.ImGui_SetNextWindowSize(ctx, cw, ch, cond)

    local flags = reaper.ImGui_WindowFlags_NoTitleBar() |
        reaper.ImGui_WindowFlags_NoResize() |
        reaper.ImGui_WindowFlags_NoMove() |
        reaper.ImGui_WindowFlags_NoScrollbar() |
        reaper.ImGui_WindowFlags_NoCollapse() |
        reaper.ImGui_WindowFlags_NoBackground() |
        reaper.ImGui_WindowFlags_NoDecoration() |
        reaper.ImGui_WindowFlags_NoDocking() |
        reaper.ImGui_WindowFlags_NoSavedSettings() |
        reaper.ImGui_WindowFlags_NoNav() |
        reaper.ImGui_WindowFlags_NoInputs() |
        reaper.ImGui_WindowFlags_NoMouseInputs() |
        reaper.ImGui_WindowFlags_NoFocusOnAppearing() |
        reaper.ImGui_WindowFlags_TopMost()

    local visible = reaper.ImGui_Begin(ctx, "##EnvelopeBrushArrangeOverlay", nil, flags)
    if not visible then
        reaper.ImGui_End(ctx)
        return
    end

    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    if draw_list then
        local radius = state.brush_size

        M.draw_dashed_circle(draw_list, cx, cy, radius, config.OUTER_CIRCLE_COLOR, config.CIRCLE_THICKNESS)
        local inner_radius = deps.calc_inner_brush_radius(radius)
        M.draw_dashed_circle(draw_list, cx, cy, inner_radius, config.INNER_CIRCLE_COLOR, config.CIRCLE_THICKNESS - 1)
        reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, 3, 0xFF00FFFF)

        local mode_label = config.SCULPT_MODES[state.sculpt_mode] or "grab"
        local text_x = cx + radius + 10
        reaper.ImGui_DrawList_AddText(draw_list, text_x, cy - 40, 0xFFFFFFFF, mode_label)
        reaper.ImGui_DrawList_AddText(draw_list, text_x, cy - 20, 0xFFFFFFFF, config.FALLOFF_TYPES[state.falloff_type])
        reaper.ImGui_DrawList_AddText(draw_list, text_x, cy, 0xFFFFFFFF, string.format("Size: %d  Falloff: %.1f  Power: %.2f", state.brush_size, state.falloff_strength, state.sculpt_power or 1))
    end

    reaper.ImGui_End(ctx)
end

return M
