local M = {}

function M.brush_hud_interactive(state)
    return state.sws_hover_detected and state.target_envelope ~= nil
end

--- ARGB -> ARGB with new alpha channel (0..1).
local function color_with_alpha(argb, alpha)
    local a = math.floor(math.max(0, math.min(1, alpha)) * 255 + 0.5)
    local rgb = argb & 0x00FFFFFF
    return (a << 24) | rgb
end

--- While envelope hover HUD is relevant: LMB hides text quickly; release fades in over BRUSH_HUD_TEXT_FADE_IN_SEC.
function M.update_brush_hud_text_fade(state, config, lmb_down, hud_active)
    if not hud_active then
        state._brush_hud_fade_last_os = nil
        return
    end
    local now = (reaper.time_precise and reaper.time_precise()) or 0
    local last = state._brush_hud_fade_last_os
    state._brush_hud_fade_last_os = now
    local dt = (last ~= nil) and (now - last) or 0
    dt = math.min(0.05, math.max(0, dt))
    local a = state.brush_hud_text_alpha or 1
    if lmb_down then
        local inv = 1 / math.max(1e-6, config.BRUSH_HUD_TEXT_FADE_OUT_SEC)
        a = math.max(0, a - dt * inv)
    else
        local inv = 1 / math.max(1e-6, config.BRUSH_HUD_TEXT_FADE_IN_SEC)
        a = math.min(1, a + dt * inv)
    end
    state.brush_hud_text_alpha = a
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

    --- Brush circles need a live SWS envelope hover; point-index labels only need a locked target + checkbox.
    local show_brush = M.brush_hud_interactive(state)
    local show_point_debug = state.debug_show_point_client_coords == true
        and state.target_envelope ~= nil
        and deps.for_each_envelope_point and deps.envelope_to_screen and deps.arrange_client_to_imgui

    if not show_brush and not show_point_debug then
        return
    end

    -- Must unpack here: assigning to a single variable drops other return values in Lua.
    local il, it, cw, ch = deps.get_arrange_imgui_overlay_geometry()
    if il == nil or it == nil or cw == nil or ch == nil then return end

    local cx, cy
    if show_brush then
        cx, cy = deps.get_mouse_imgui_xy()
        if cx == nil or cy == nil then return end
    else
        cx, cy = 0, 0
    end

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
        if show_brush then
            local radius = state.brush_size

            M.draw_dashed_circle(draw_list, cx, cy, radius, config.OUTER_CIRCLE_COLOR, config.CIRCLE_THICKNESS)
            local inner_radius = deps.calc_inner_brush_radius(radius)
            M.draw_dashed_circle(draw_list, cx, cy, inner_radius, config.INNER_CIRCLE_COLOR, config.CIRCLE_THICKNESS - 1)
            reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, 3, 0xFF00FFFF)

            local alpha = state.brush_hud_text_alpha or 1
            if alpha > 0.02 then
                local col = color_with_alpha(0xFFFFFFFF, alpha)
                local col_grey = color_with_alpha(0xFF888888, alpha)

                local mode_label = deps.brush_drag_kind_display and deps.brush_drag_kind_display() or "—"
                local text_x = cx + radius + 10
                reaper.ImGui_DrawList_AddText(draw_list, text_x, cy - 40, col, mode_label)

                local ft_key = config.FALLOFF_TYPES[state.falloff_type]
                local falloff_pretty = (config.FALLOFF_TYPE_LABELS and config.FALLOFF_TYPE_LABELS[ft_key]) or ft_key
                reaper.ImGui_DrawList_AddText(draw_list, text_x, cy - 20, col, falloff_pretty)

                local size_txt = string.format("Size: %d", state.brush_size)
                local fall_txt = string.format("Falloff strength: %.1f", state.falloff_strength)
                local pow_txt = string.format("Sculpt power: %.2f", state.sculpt_power or 1)
                local gap = "   "
                reaper.ImGui_DrawList_AddText(draw_list, text_x, cy, col, size_txt .. gap .. fall_txt .. gap .. pow_txt)

                local font_sz = reaper.ImGui_GetFontSize(ctx)
                local y_mod = cy + font_sz + 2
                local x_fall = text_x + reaper.ImGui_CalcTextSize(ctx, size_txt .. gap)
                local x_pow = x_fall + reaper.ImGui_CalcTextSize(ctx, fall_txt .. gap)
                reaper.ImGui_DrawList_AddText(draw_list, text_x, y_mod, col_grey, "Scroll")
                reaper.ImGui_DrawList_AddText(draw_list, x_fall, y_mod, col_grey, "Alt + scroll")
                local mod_wheel = (deps.primary_modifier_short_name and deps.primary_modifier_short_name() or "Ctrl") .. " + scroll"
                reaper.ImGui_DrawList_AddText(draw_list, x_pow, y_mod, col_grey, mod_wheel)
                local y_fine = y_mod + font_sz + 2
                reaper.ImGui_DrawList_AddText(draw_list, text_x, y_fine, col_grey, "Shift: fine adjust")
            end
        end

        if show_point_debug then
            local env = state.target_envelope
            local ai = state.envelope_autoitem_idx or -1
            local label_col = 0xFFFFFFFF
            deps.for_each_envelope_point(env, ai, function(i, t, v)
                local sx, sy = deps.envelope_to_screen(t, v, env)
                if sx and sy then
                    local ix, iy = deps.arrange_client_to_imgui(sx, sy)
                    if ix and iy then
                        local txt = string.format("#%d  %.0f, %.0f", i, sx, sy)
                        reaper.ImGui_DrawList_AddText(draw_list, ix + 5, iy + 5, label_col, txt)
                    end
                end
            end)
        end
    end

    reaper.ImGui_End(ctx)
end

return M
