local M = {}

function M.brush_hud_interactive(state)
    return state.sws_hover_detected and state.target_envelope ~= nil
end

--- Show brush rings: live hover, or settings mode with a frozen position on a locked lane.
function M.brush_hud_visible(state)
    if state.debug_disable_js_eat or not state.target_envelope then
        return false
    end
    if M.brush_hud_interactive(state) then
        return true
    end
    return state.brush_settings_mode == true and state.brush_settings_freeze_client ~= nil
end

--- Fade: ImGui U32 as 0xRRGGBBAA (same as Advanced Toolbars Utils/color_utils `toImGuiColor`); only scale A.
local function imgui_u32_with_alpha(c, alpha01)
    local a = math.floor(math.max(0, math.min(1, alpha01)) * 255 + 0.5)
    return (c & 0xFFFFFF00) | a
end

--- While envelope hover HUD is relevant: LMB hides text quickly; release fades in over hud.BRUSH_HUD_TEXT_FADE_IN_SEC.
--- Settings panel open: readout stays fully opaque (no fade).
function M.update_brush_hud_text_fade(state, config, lmb_down, hud_active)
    if not hud_active then
        state._brush_hud_fade_last_os = nil
        return
    end
    if state.brush_settings_mode then
        state.brush_hud_text_alpha = 1
        state._brush_hud_fade_last_os = nil
        return
    end
    local now = (reaper.time_precise and reaper.time_precise()) or 0
    local last = state._brush_hud_fade_last_os
    state._brush_hud_fade_last_os = now
    local dt = (last ~= nil) and (now - last) or 0
    dt = math.min(0.05, math.max(0, dt))
    local a = state.brush_hud_text_alpha or 1
    local hcfg = config.hud
    if lmb_down then
        local inv = 1 / math.max(1e-6, hcfg.BRUSH_HUD_TEXT_FADE_OUT_SEC)
        a = math.max(0, a - dt * inv)
    else
        local inv = 1 / math.max(1e-6, hcfg.BRUSH_HUD_TEXT_FADE_IN_SEC)
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

local function draw_padlock_icon(draw_list, ox, oy, color, scale)
    scale = scale or 1
    local r, body_t = 3.5 * scale, 6.5 * scale
    reaper.ImGui_DrawList_PathClear(draw_list)
    reaper.ImGui_DrawList_PathArcTo(draw_list, ox + 7 * scale, oy + 5.5 * scale, r, 3.85, 6.05, 10)
    reaper.ImGui_DrawList_PathStroke(draw_list, color, 0, 1.35 * scale)
    reaper.ImGui_DrawList_AddRect(draw_list, ox + 2.5 * scale, oy + body_t, ox + 11.5 * scale, oy + 15.5 * scale, color, 1.0 * scale, 0, 1.25 * scale)
end

local function imgui_col(c)
    if c == nil then return nil end
    if type(c) == "function" then return c() end
    return c
end

local function style_var_frame_rounding()
    local f = reaper.ImGuiStyleVar_FrameRounding
    if f == nil then return nil end
    if type(f) == "function" then return f() end
    return f
end

--- Tight layout: match draw-list HUD column (no window padding), reduce frame/item gaps so widgets align with plain text.
local function push_settings_layout(ctx)
    local n = 0
    local function push2(var, a, b)
        if var == nil then return end
        local id = type(var) == "function" and var() or var
        reaper.ImGui_PushStyleVar(ctx, id, a, b)
        n = n + 1
    end
    push2(reaper.ImGuiStyleVar_WindowPadding, 0, 0)
    push2(reaper.ImGuiStyleVar_FramePadding, 2, 2)
    push2(reaper.ImGuiStyleVar_ItemSpacing, 4, 3)
    push2(reaper.ImGuiStyleVar_ItemInnerSpacing, 4, 2)
    return n
end

local function pop_style_vars(ctx, count)
    for _ = 1, count do
        reaper.ImGui_PopStyleVar(ctx)
    end
end

--- Grey widgets for settings (combo / slider / checkbox / popups). Packed u32 per Dear ImGui / ReaImGui ImGui_PushStyleColor (not DrawList 0xRRGGBBAA).
local function push_settings_grey_style(ctx)
    local list = {
        { reaper.ImGuiCol_Button, 0xFF3A3A3A },
        { reaper.ImGuiCol_ButtonHovered, 0xFF484848 },
        { reaper.ImGuiCol_ButtonActive, 0xFF303030 },
        { reaper.ImGuiCol_FrameBg, 0xFF2C2C2C },
        { reaper.ImGuiCol_FrameBgHovered, 0xFF383838 },
        { reaper.ImGuiCol_FrameBgActive, 0xFF444444 },
        { reaper.ImGuiCol_SliderGrab, 0xFF666666 },
        { reaper.ImGuiCol_SliderGrabActive, 0xFF767676 },
        { reaper.ImGuiCol_CheckMark, 0xFFCCCCCC },
        { reaper.ImGuiCol_Header, 0xFF353535 },
        { reaper.ImGuiCol_HeaderHovered, 0xFF434343 },
        { reaper.ImGuiCol_HeaderActive, 0xFF4D4D4D },
        { reaper.ImGuiCol_Separator, 0xFF505050 },
        { reaper.ImGuiCol_SeparatorHovered, 0xFF5A5A5A },
        { reaper.ImGuiCol_SeparatorActive, 0xFF646464 },
        { reaper.ImGuiCol_Border, 0xFF3D3D3D },
        { reaper.ImGuiCol_PopupBg, 0xFF252525 },
        { reaper.ImGuiCol_ChildBg, 0xFF252525 },
        { reaper.ImGuiCol_ScrollbarBg, 0xFF222222 },
        { reaper.ImGuiCol_ScrollbarGrab, 0xFF525252 },
        { reaper.ImGuiCol_ScrollbarGrabHovered, 0xFF606060 },
        { reaper.ImGuiCol_ScrollbarGrabActive, 0xFF6C6C6C },
        { reaper.ImGuiCol_TitleBg, 0xFF252525 },
        { reaper.ImGuiCol_TitleBgActive, 0xFF2C2C2C },
        { reaper.ImGuiCol_PlotHistogram, 0xFF3A3A3A },
        { reaper.ImGuiCol_PlotHistogramHovered, 0xFF484848 },
        { reaper.ImGuiCol_NavHighlight, 0x80666666 },
    }
    local n = 0
    for i = 1, #list do
        local id = imgui_col(list[i][1])
        if id then
            reaper.ImGui_PushStyleColor(ctx, id, list[i][2])
            n = n + 1
        end
    end
    return n
end

--- Grey chip button (AARRGGBB); selected state slightly lighter.
local function chip_button(ctx, label, selected, w, h)
    local svr = style_var_frame_rounding()
    if svr ~= nil then
        reaper.ImGui_PushStyleVar(ctx, svr, 10)
    end
    local cb = imgui_col(reaper.ImGuiCol_Button)
    local ch = imgui_col(reaper.ImGuiCol_ButtonHovered)
    local ca = imgui_col(reaper.ImGuiCol_ButtonActive)
    local pushed = 0
    if cb and ch and ca then
        if selected then
            reaper.ImGui_PushStyleColor(ctx, cb, 0xFF505050)
            reaper.ImGui_PushStyleColor(ctx, ch, 0xFF5E5E5E)
            reaper.ImGui_PushStyleColor(ctx, ca, 0xFF454545)
        else
            reaper.ImGui_PushStyleColor(ctx, cb, 0xFF3A3A3A)
            reaper.ImGui_PushStyleColor(ctx, ch, 0xFF484848)
            reaper.ImGui_PushStyleColor(ctx, ca, 0xFF303030)
        end
        pushed = 3
    end
    local clicked = reaper.ImGui_Button(ctx, label, w, h)
    if pushed > 0 then
        reaper.ImGui_PopStyleColor(ctx, pushed)
    end
    if svr ~= nil then
        reaper.ImGui_PopStyleVar(ctx)
    end
    return clicked
end

--- Lock + letter in one hit target (drawn on window draw list after InvisibleButton).
local function lock_letter_chip(ctx, letter, selected, tip, on_toggle)
    local w, h = 40, 26
    reaper.ImGui_InvisibleButton(ctx, "##chip" .. letter, w, h)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    if dl then
        local minx, miny = reaper.ImGui_GetItemRectMin(ctx)
        local maxx, maxy = reaper.ImGui_GetItemRectMax(ctx)
        local fill = selected and 0x555555DD or 0x2A2A2ACC
        reaper.ImGui_DrawList_AddRectFilled(dl, minx, miny, maxx, maxy, fill)
        reaper.ImGui_DrawList_AddRect(dl, minx, miny, maxx, maxy, 0x666666FF, 0, 0, 1)
        local scale = 0.78
        local icon_w = 12 * scale
        local icon_h = 15.5 * scale
        local gap = 4
        local tw = reaper.ImGui_CalcTextSize(ctx, letter)
        if type(tw) ~= "number" then
            tw = select(1, tw) or 8
        end
        local total = icon_w + gap + tw
        local x0 = minx + (w - total) * 0.5
        local font_sz = reaper.ImGui_GetFontSize(ctx)
        local icon_y = miny + (h - icon_h) * 0.5
        local text_y = miny + (h - font_sz) * 0.5
        draw_padlock_icon(dl, x0, icon_y, 0xCCCCCCFF, scale)
        reaper.ImGui_DrawList_AddText(dl, x0 + icon_w + gap, text_y, 0xFFFFFFFF, letter)
    end
    if tip and reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
        reaper.ImGui_SetTooltip(ctx, tip)
    end
    if reaper.ImGui_IsItemClicked and reaper.ImGui_IsItemClicked(ctx) then
        on_toggle()
    end
end

local function calc_text_w(ctx, s)
    local tw = reaper.ImGui_CalcTextSize(ctx, s)
    return type(tw) == "number" and tw or (select(1, tw) or 0)
end

local function push_style_alpha(ctx, a)
    local v = reaper.ImGuiStyleVar_Alpha
    if v == nil then
        return 0
    end
    local id = type(v) == "function" and v() or v
    reaper.ImGui_PushStyleVar(ctx, id, a)
    return 1
end

--- One window: HUD readout (mode, falloff as text or combo, stats, hints) + optional settings (RMB). Aligns with brush; no second window gap.
function M.render_brush_hud_panel(state, config, deps)
    if not state.ctx or not state.target_envelope or state.debug_disable_js_eat then
        return
    end
    if not M.brush_hud_visible(state) then
        return
    end

    local alpha = state.brush_hud_text_alpha or 1
    if not state.brush_settings_mode and alpha <= 0.02 then
        return
    end

    local ctx = state.ctx
    local cx, cy
    if state.brush_settings_mode and state.brush_settings_freeze_client then
        cx, cy = deps.arrange_client_to_imgui(
            state.brush_settings_freeze_client.x,
            state.brush_settings_freeze_client.y
        )
    else
        cx, cy = deps.get_mouse_imgui_xy()
    end
    if cx == nil or cy == nil then
        return
    end

    local radius = state.brush_size or 40
    local cond = reaper.ImGui_Cond_Always and reaper.ImGui_Cond_Always() or 0
    local text_x = cx + radius + 10
    reaper.ImGui_SetNextWindowPos(ctx, text_x, cy - 40, cond)

    if reaper.ImGui_SetNextWindowBgAlpha then
        reaper.ImGui_SetNextWindowBgAlpha(ctx, 0)
    end

    local flags = (reaper.ImGui_WindowFlags_NoTitleBar and reaper.ImGui_WindowFlags_NoTitleBar() or 0)
        | (reaper.ImGui_WindowFlags_NoResize and reaper.ImGui_WindowFlags_NoResize() or 0)
        | (reaper.ImGui_WindowFlags_AlwaysAutoResize and reaper.ImGui_WindowFlags_AlwaysAutoResize() or 0)
        | (reaper.ImGui_WindowFlags_NoDocking and reaper.ImGui_WindowFlags_NoDocking() or 0)
        | (reaper.ImGui_WindowFlags_NoSavedSettings and reaper.ImGui_WindowFlags_NoSavedSettings() or 0)
        | (reaper.ImGui_WindowFlags_NoNav and reaper.ImGui_WindowFlags_NoNav() or 0)
        | (reaper.ImGui_WindowFlags_NoBackground and reaper.ImGui_WindowFlags_NoBackground() or 0)
    if not state.brush_settings_mode then
        flags = flags | (reaper.ImGui_WindowFlags_NoInputs and reaper.ImGui_WindowFlags_NoInputs() or 0)
            | (reaper.ImGui_WindowFlags_NoMouseInputs and reaper.ImGui_WindowFlags_NoMouseInputs() or 0)
    end

    local col_w = 136
    local col_gap = 10
    local panel_inner_w = col_w * 2 + col_gap

    local layout_pushed = push_settings_layout(ctx)
    local visible = reaper.ImGui_Begin(ctx, "##BrushHudPanel", nil, flags)
    if not visible then
        reaper.ImGui_End(ctx)
        pop_style_vars(ctx, layout_pushed)
        return
    end

    local display_alpha = state.brush_settings_mode and 1 or alpha
    local alpha_pushed = push_style_alpha(ctx, display_alpha)

    local rel_base = reaper.ImGui_GetCursorPosX(ctx)

    local fcfg = config.falloff
    local ft_key = fcfg.FALLOFF_TYPES[state.falloff_type]
    local falloff_pretty = (fcfg.FALLOFF_TYPE_LABELS and fcfg.FALLOFF_TYPE_LABELS[ft_key]) or ft_key

    local mode_label = deps.brush_drag_kind_display and deps.brush_drag_kind_display() or "—"
    reaper.ImGui_Text(ctx, mode_label)

    if state.brush_settings_mode then
        local falloff_display = {}
        for i = 1, #fcfg.FALLOFF_TYPES do
            local k = fcfg.FALLOFF_TYPES[i]
            falloff_display[i] = (fcfg.FALLOFF_TYPE_LABELS and fcfg.FALLOFF_TYPE_LABELS[k]) or k
        end
        local falloff_names = table.concat(falloff_display, "\0") .. "\0"
        local w_label = 0
        for i = 1, #falloff_display do
            local tw = calc_text_w(ctx, falloff_display[i])
            if tw > w_label then
                w_label = tw
            end
        end
        reaper.ImGui_SetNextItemWidth(ctx, w_label + 28)
        local chg, new_ft = reaper.ImGui_Combo(ctx, "##falloffHud", state.falloff_type - 1, falloff_names)
        if chg then
            state.falloff_type = new_ft + 1
            if deps.clear_wheel_momentum then
                deps.clear_wheel_momentum(state)
            end
        end
    else
        reaper.ImGui_Text(ctx, falloff_pretty)
    end

    local size_txt = string.format("Size: %d", state.brush_size)
    local fall_txt = string.format("Falloff strength: %.1f", state.falloff_strength)
    local pow_txt = string.format("Power: %.2f", state.sculpt_power or 1)
    local gap = "   "
    reaper.ImGui_Text(ctx, size_txt .. gap .. fall_txt .. gap .. pow_txt)

    local font_sz = reaper.ImGui_GetFontSize(ctx)
    local w_size_gap = calc_text_w(ctx, size_txt .. gap)
    local w_fall_gap = calc_text_w(ctx, fall_txt .. gap)
    local mod_wheel = (deps.primary_modifier_short_name and deps.primary_modifier_short_name() or "Ctrl") .. " + scroll"
    local row_y = reaper.ImGui_GetCursorPosY(ctx) + 2

    local text_col = imgui_col(reaper.ImGuiCol_Text)
    if text_col then
        reaper.ImGui_PushStyleColor(ctx, text_col, 0xFF888888)
    end
    reaper.ImGui_SetCursorPos(ctx, rel_base, row_y)
    reaper.ImGui_Text(ctx, "Scroll")
    reaper.ImGui_SetCursorPos(ctx, rel_base + w_size_gap, row_y)
    reaper.ImGui_Text(ctx, "Alt + scroll")
    reaper.ImGui_SetCursorPos(ctx, rel_base + w_size_gap + w_fall_gap, row_y)
    reaper.ImGui_Text(ctx, mod_wheel)
    reaper.ImGui_SetCursorPos(ctx, rel_base, row_y + font_sz + 2)
    reaper.ImGui_Text(ctx, "Shift: fine (25%)")
    if text_col then
        reaper.ImGui_PopStyleColor(ctx, 1)
    end

    if state.brush_settings_mode then
        reaper.ImGui_Dummy(ctx, 0, 3)
        local grey_pushed = push_settings_grey_style(ctx)

        lock_letter_chip(ctx, "X", state.lock_time_axis, "Lock time (horizontal)", function()
            state.lock_time_axis = not state.lock_time_axis
            if state.lock_time_axis then
                state.lock_value_axis = false
            end
        end)
        reaper.ImGui_SameLine(ctx)
        lock_letter_chip(ctx, "Y", state.lock_value_axis, "Lock value (vertical)", function()
            state.lock_value_axis = not state.lock_value_axis
            if state.lock_value_axis then
                state.lock_time_axis = false
            end
        end)
        reaper.ImGui_SameLine(ctx, 0, 10)
        local cont_v = state.enable_continuous_smoothing and true or false
        local cont_chg, cont_on = reaper.ImGui_Checkbox(ctx, "Continuous Smoothing", cont_v)
        if cont_chg then
            state.enable_continuous_smoothing = cont_on
        end
        if reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
            reaper.ImGui_SetTooltip(ctx, "Shift+smooth: reselect envelope points under the brush on each move step so you can smooth along the lane in one drag.")
        end

        reaper.ImGui_Dummy(ctx, 0, 3)

        local spcfg = config.spacing
        reaper.ImGui_Text(ctx, "Min density (pixels)")
        reaper.ImGui_SetNextItemWidth(ctx, panel_inner_w)
        local sp_min, sp_max = spcfg.MIN_MIN_POINT_SPACING_PX, spcfg.MAX_MIN_POINT_SPACING_PX
        local sp_changed, new_sp = reaper.ImGui_SliderInt(ctx, "##mindens", state.min_point_spacing_px, sp_min, sp_max)
        if sp_changed then
            state.min_point_spacing_px = math.max(1, math.max(sp_min, math.min(sp_max, new_sp)))
        end

        reaper.ImGui_Dummy(ctx, 0, 2)
        local inv_v = state.invert_brush_size_scroll and true or false
        local inv_chg, inv_on = reaper.ImGui_Checkbox(ctx, "Invert brush size scroll", inv_v)
        if inv_chg then
            state.invert_brush_size_scroll = inv_on
            if deps.clear_wheel_momentum then
                deps.clear_wheel_momentum(state)
            end
        end
        if reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
            reaper.ImGui_SetTooltip(ctx, "When on, scroll direction for brush size matches the older (opposite) mapping.")
        end

        reaper.ImGui_Dummy(ctx, 0, 3)
        if reaper.ImGui_SeparatorText then
            reaper.ImGui_SeparatorText(ctx, "Debug")
        else
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Text(ctx, "Debug")
        end

        reaper.ImGui_Dummy(ctx, 0, 2)
        local dbg_btn_w = math.floor((panel_inner_w - 8) * 0.5 + 0.5)
        if chip_button(ctx, "No intercept", state.debug_disable_js_eat, dbg_btn_w, 26) then
            state.debug_disable_js_eat = not state.debug_disable_js_eat
        end
        if reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
            reaper.ImGui_SetTooltip(ctx, "Disable JS arrange intercept + arrange HUD (circles)")
        end
        reaper.ImGui_SameLine(ctx, 0, 8)
        if chip_button(ctx, "Pt coords", state.debug_show_point_client_coords, dbg_btn_w, 26) then
            state.debug_show_point_client_coords = not state.debug_show_point_client_coords
        end
        if reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
            reaper.ImGui_SetTooltip(ctx, "Show arrange-client (x,y) next to each envelope point (HUD)")
        end

        if grey_pushed > 0 then
            reaper.ImGui_PopStyleColor(ctx, grey_pushed)
        end
    end

    reaper.ImGui_End(ctx)
    if alpha_pushed > 0 then
        reaper.ImGui_PopStyleVar(ctx, alpha_pushed)
    end
    pop_style_vars(ctx, layout_pushed)
end

--- TK/Sexan: GetRect + PointConvertNative for window; PointConvertNative(GetMouse) for brush (same ImGui space).
function M.render_brush_hud(state, config, deps)
    local ctx = state.ctx
    if not ctx then return end

    if state.debug_disable_js_eat then
        return
    end

    --- Brush circles: live SWS hover or frozen position in settings mode.
    local show_brush = M.brush_hud_visible(state)
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
        if state.brush_settings_mode and state.brush_settings_freeze_client then
            cx, cy = deps.arrange_client_to_imgui(
                state.brush_settings_freeze_client.x,
                state.brush_settings_freeze_client.y
            )
        else
            cx, cy = deps.get_mouse_imgui_xy()
        end
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

            local hcfg = config.hud
            M.draw_dashed_circle(draw_list, cx, cy, radius, hcfg.OUTER_CIRCLE_COLOR, hcfg.CIRCLE_THICKNESS)
            local inner_radius = deps.calc_inner_brush_radius(radius)
            M.draw_dashed_circle(draw_list, cx, cy, inner_radius, hcfg.INNER_CIRCLE_COLOR, hcfg.CIRCLE_THICKNESS - 1)
            reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, 3, 0xFF00FFFF)

            if state.lock_time_axis or state.lock_value_axis then
                local scale = 0.78
                local icon_h = 15.5 * scale
                local ox = cx - radius
                local oy = (cy + radius) - icon_h
                local letter = state.lock_time_axis and "X" or "Y"
                local lock_col = 0xCCCCCCFF
                draw_padlock_icon(draw_list, ox, oy, lock_col, scale)
                local font_sz = reaper.ImGui_GetFontSize(ctx)
                local icon_w = 12 * scale + 4
                local text_y = oy + (icon_h - font_sz) * 0.5
                reaper.ImGui_DrawList_AddText(draw_list, ox + icon_w, text_y, 0xFFFFFFFF, letter)
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
