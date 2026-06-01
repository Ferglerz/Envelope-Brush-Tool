local M = {}

local _render_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_render_dir .. "../path.lua")
local Style = Path.load("imgui_style.lua")
local Draw = Path.load("draw.lua")
local C = Path.load("constants.lua")

local FALLOFF_PREVIEW_W = 36
local FALLOFF_PREVIEW_H = 20
local FALLOFF_ROW_H = 24
local FALLOFF_NAME_PREVIEW_GAP = 10
local FALLOFF_ROW_PAD_X = 8
--- Combo popup chrome (window padding, border, vs default line-height item sizing).
local FALLOFF_POPUP_CHROME_W = 24
local FALLOFF_POPUP_CHROME_H = 40

local function falloff_type_labels(ctx, fcfg)
    local labels = {}
    local name_col_w = 0
    for i = 1, #fcfg.FALLOFF_TYPES do
        local k = fcfg.FALLOFF_TYPES[i]
        labels[i] = (fcfg.FALLOFF_TYPE_LABELS and fcfg.FALLOFF_TYPE_LABELS[k]) or k
        local tw = Style.calc_text_w(ctx, labels[i])
        if tw > name_col_w then
            name_col_w = tw
        end
    end
    return labels, math.ceil(name_col_w + 12)
end

local function falloff_combo_row_metrics(name_col_w)
    local content_w = FALLOFF_ROW_PAD_X + name_col_w + FALLOFF_NAME_PREVIEW_GAP + FALLOFF_PREVIEW_W + FALLOFF_ROW_PAD_X
    return content_w, content_w + FALLOFF_POPUP_CHROME_W
end

local function falloff_combo_popup_height(n_rows)
    return n_rows * FALLOFF_ROW_H + FALLOFF_POPUP_CHROME_H
end

local function falloff_combo_draw_row(ctx, draw_list, deps, rx, ry, row_h, name_col_w, label, type_key, selected)
    if not draw_list or not deps.calculate_falloff then
        return
    end
    local tw, label_th = reaper.ImGui_CalcTextSize(ctx, label)
    if type(tw) ~= "number" then
        tw, label_th = select(1, tw), select(2, tw)
    end
    label_th = label_th or reaper.ImGui_GetFontSize(ctx)
    local cy = ry + row_h * 0.5
    local ty = cy - label_th * 0.5
    reaper.ImGui_DrawList_AddText(draw_list, rx + FALLOFF_ROW_PAD_X, ty, 0xEEEEEEFF, label)

    local px = rx + FALLOFF_ROW_PAD_X + name_col_w + FALLOFF_NAME_PREVIEW_GAP
    local py = cy - FALLOFF_PREVIEW_H * 0.5
    Draw.draw_falloff_preview(draw_list, px, py, FALLOFF_PREVIEW_W, FALLOFF_PREVIEW_H, type_key, deps.calculate_falloff, {
        line_color = selected and 0xFFFFFFFF or 0xAAAAAAFF,
        bg_color = selected and 0x353535FF or 0x2A2A2AFF,
    })
end

local function falloff_combo(ctx, state, config, deps)
    local fcfg = config.falloff
    local labels, name_col_w = falloff_type_labels(ctx, fcfg)
    local current = labels[state.falloff_type] or ""
    local n_types = #fcfg.FALLOFF_TYPES
    local row_w, popup_w = falloff_combo_row_metrics(name_col_w)
    local popup_h = falloff_combo_popup_height(n_types)

    local combo_flags = 0
    if reaper.ImGui_ComboFlags_HeightLargest then
        local f = reaper.ImGui_ComboFlags_HeightLargest
        combo_flags = Style.flag(f)
    end

    reaper.ImGui_SetNextItemWidth(ctx, popup_w)
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, popup_w, popup_h, popup_w, popup_h)
    if not reaper.ImGui_BeginCombo(ctx, "##falloffHud", current, combo_flags) then
        return
    end

    local spacing_pushed = 0
    local isv = reaper.ImGui_StyleVar_ItemSpacing
    local isv_id = isv and Style.flag(isv) or nil
    if isv_id then
        reaper.ImGui_PushStyleVar(ctx, isv_id, 0, 0)
        spacing_pushed = 1
    end

    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

    for i = 1, n_types do
        reaper.ImGui_PushID(ctx, i)
        local type_key = fcfg.FALLOFF_TYPES[i]
        local label = labels[i]
        local selected = state.falloff_type == i
        local clicked = reaper.ImGui_Selectable(ctx, "", selected, 0, row_w, FALLOFF_ROW_H)

        if draw_list then
            local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
            local rx2, ry2 = reaper.ImGui_GetItemRectMax(ctx)
            if type(rx) == "number" and type(ry) == "number" then
                local row_h = FALLOFF_ROW_H
                if type(rx2) == "number" and type(ry2) == "number" and ry2 > ry then
                    row_h = ry2 - ry
                end
                falloff_combo_draw_row(ctx, draw_list, deps, rx, ry, row_h, name_col_w, label, type_key, selected)
            end
        end

        if clicked then
            state.falloff_type = i
            if deps.clear_wheel_momentum then
                deps.clear_wheel_momentum(state)
            end
        end
        if selected and reaper.ImGui_SetItemDefaultFocus then
            reaper.ImGui_SetItemDefaultFocus(ctx)
        end
        reaper.ImGui_PopID(ctx)
    end

    if spacing_pushed > 0 then
        reaper.ImGui_PopStyleVar(ctx, spacing_pushed)
    end

    reaper.ImGui_EndCombo(ctx)
end

local function axis_lock_chip_row(ctx, Style, chip_size, font_closed, font_open, locked, id_stem, axis_letter, tooltip)
    local font_px = C.LOCK_ICON_CHIP_FONT_PX or math.max(10, chip_size - 10)
    local font = locked and font_closed or font_open
    local letter_gap = 6

    local letter_tw, letter_th = reaper.ImGui_CalcTextSize(ctx, axis_letter)
    if type(letter_tw) ~= "number" then
        letter_tw, letter_th = select(1, letter_tw), select(2, letter_tw)
    end
    letter_th = letter_th or (reaper.ImGui_GetTextLineHeight and reaper.ImGui_GetTextLineHeight(ctx)) or chip_size
    local row_h = math.max(chip_size, letter_th)
    local group_w = chip_size + letter_gap + letter_tw

    if reaper.ImGui_BeginGroup then
        reaper.ImGui_BeginGroup(ctx)
    end
    local base_x, base_y = reaper.ImGui_GetCursorPos(ctx)
    if type(base_x) ~= "number" or type(base_y) ~= "number" then
        base_x, base_y = 0, 0
    end

    local fp = reaper.ImGui_StyleVar_FramePadding
    local fp_id = fp and Style.flag(fp) or nil
    if fp_id then
        reaper.ImGui_PushStyleVar(ctx, fp_id, 0, 0)
    end

    reaper.ImGui_SetCursorPos(ctx, base_x, base_y + (row_h - chip_size) * 0.5)
    reaper.ImGui_PushFont(ctx, font, font_px)
    local clicked = Style.chip_button(ctx, "##lock" .. id_stem, locked, chip_size, chip_size)

    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    if draw_list then
        local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
        if type(rx) == "number" and type(ry) == "number" then
            local tw, th = reaper.ImGui_CalcTextSize(ctx, C.LOCK_GLYPH)
            if type(tw) ~= "number" then
                tw, th = select(1, tw), select(2, tw)
            end
            th = th or font_px
            local tx = rx + (chip_size - tw) * 0.5
            local ty = ry + (chip_size - th) * 0.5 + (C.LOCK_ICON_CHIP_Y_OFFSET or 0)
            reaper.ImGui_DrawList_AddText(draw_list, tx, ty, 0xEEEEEEFF, C.LOCK_GLYPH)
        end
    end
    reaper.ImGui_PopFont(ctx)

    if fp_id then
        reaper.ImGui_PopStyleVar(ctx)
    end
    if tooltip and reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
        reaper.ImGui_SetTooltip(ctx, tooltip)
    end

    reaper.ImGui_SetCursorPos(ctx, base_x + chip_size + letter_gap, base_y + (row_h - letter_th) * 0.5)
    reaper.ImGui_Text(ctx, axis_letter)
    reaper.ImGui_Dummy(ctx, group_w, row_h)

    if reaper.ImGui_EndGroup then
        reaper.ImGui_EndGroup(ctx)
    end
    return clicked
end

--- One window: HUD readout (mode, falloff as text or combo, stats, hints) + optional settings (RMB). Aligns with brush; no second window gap.
function M.render_brush_hud_panel(state, config, deps, hud)
    state._brush_settings_panel_rect_imgui = nil
    if state._shutdown_complete or not state.ctx or not state.target_envelope then
        return
    end
    if not hud.brush_hud_visible(state) then
        return
    end

    local alpha = state.brush_hud_text_alpha or 1
    if not state.brush_settings_mode and alpha <= 0.02 then
        return
    end

    local ctx = state.ctx
    local cx, cy = hud.brush_center_imgui_xy(state, deps)
    if cx == nil or cy == nil then
        return
    end

    local radius = state.brush_size or 40
    local cond = Style.cond_always()
    local text_x = cx + radius + 10
    reaper.ImGui_SetNextWindowPos(ctx, text_x, cy - radius, cond)

    if reaper.ImGui_SetNextWindowBgAlpha then
        reaper.ImGui_SetNextWindowBgAlpha(ctx, 0)
    end

    local flags = Style.flags_or(
        reaper.ImGui_WindowFlags_NoTitleBar,
        reaper.ImGui_WindowFlags_NoResize,
        reaper.ImGui_WindowFlags_AlwaysAutoResize,
        reaper.ImGui_WindowFlags_NoDocking,
        reaper.ImGui_WindowFlags_NoSavedSettings,
        reaper.ImGui_WindowFlags_NoBackground
    )
    if not state.brush_settings_mode then
        flags = flags | Style.flags_or(
            reaper.ImGui_WindowFlags_NoNav,
            reaper.ImGui_WindowFlags_NoInputs,
            reaper.ImGui_WindowFlags_NoMouseInputs
        )
    end

    local col_w = 136
    local col_gap = 10
    local panel_inner_w = col_w * 2 + col_gap

    local layout_pushed = Style.push_settings_layout(ctx)
    local visible = reaper.ImGui_Begin(ctx, "##BrushHudPanel", nil, flags)
    if not visible then
        reaper.ImGui_End(ctx)
        Style.pop_style_vars(ctx, layout_pushed)
        return
    end

    local display_alpha = state.brush_settings_mode and 1 or alpha
    local alpha_pushed = Style.push_style_alpha(ctx, display_alpha)

    local rel_base = reaper.ImGui_GetCursorPosX(ctx)
    local settings_grey_n = 0

    local fcfg = config.falloff
    local ft_key = fcfg.FALLOFF_TYPES[state.falloff_type]
    local falloff_pretty = (fcfg.FALLOFF_TYPE_LABELS and fcfg.FALLOFF_TYPE_LABELS[ft_key]) or ft_key

    local mode_label = deps.brush_drag_kind_display and deps.brush_drag_kind_display() or "—"
    reaper.ImGui_Text(ctx, mode_label)

    if state.brush_settings_mode then
        settings_grey_n = Style.push_settings_grey_style(ctx)
        falloff_combo(ctx, state, config, deps)
    else
        reaper.ImGui_Text(ctx, falloff_pretty)
    end

    local size_txt = string.format("Size: %d", state.brush_size)
    local fall_pct = deps.falloff_strength_percent(state.falloff_strength)
    local fall_txt = string.format("Falloff: %.1f%%", fall_pct)
    local pow_pct = deps.sculpt_power_percent(state.sculpt_power)
    local pow_txt = string.format("Power: %.1f%%", pow_pct)
    local gap = "   "
    reaper.ImGui_Text(ctx, size_txt .. gap .. fall_txt .. gap .. pow_txt)

    if not state.brush_settings_mode then
        local font_sz = reaper.ImGui_GetFontSize(ctx)
        local w_size_gap = Style.calc_text_w(ctx, size_txt .. gap)
        local w_fall_gap = Style.calc_text_w(ctx, fall_txt .. gap)
        local mod_wheel = (deps.primary_modifier_short_name and deps.primary_modifier_short_name() or "Ctrl") .. " + scroll"
        local row_y = reaper.ImGui_GetCursorPosY(ctx) + 2

        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
        reaper.ImGui_SetCursorPos(ctx, rel_base, row_y)
        reaper.ImGui_Text(ctx, "Scroll")
        reaper.ImGui_SetCursorPos(ctx, rel_base + w_size_gap, row_y)
        reaper.ImGui_Text(ctx, "Alt + scroll")
        reaper.ImGui_SetCursorPos(ctx, rel_base + w_size_gap + w_fall_gap, row_y)
        reaper.ImGui_Text(ctx, mod_wheel)
        reaper.ImGui_SetCursorPos(ctx, rel_base, row_y + font_sz + 2)
        reaper.ImGui_Text(ctx, "Shift: fine (25%)")
        reaper.ImGui_PopStyleColor(ctx, 1)
    end

    if state.brush_settings_mode then
        reaper.ImGui_Dummy(ctx, 0, 3)

        local chip_size = 28
        local fc, fo = state.font_lock_closed, state.font_lock_open
        if axis_lock_chip_row(ctx, Style, chip_size, fc, fo, state.lock_time_axis, "lx", "X", "Lock time (horizontal). X key toggles.") then
            state.lock_time_axis = not state.lock_time_axis
            if state.lock_time_axis then
                state.lock_value_axis = false
            end
        end
        reaper.ImGui_SameLine(ctx, 0, 10)
        if axis_lock_chip_row(ctx, Style, chip_size, fc, fo, state.lock_value_axis, "ly", "Y", "Lock value (vertical). Y key toggles.") then
            state.lock_value_axis = not state.lock_value_axis
            if state.lock_value_axis then
                state.lock_time_axis = false
            end
        end
        reaper.ImGui_SameLine(ctx, 0, 10)
        if reaper.ImGui_AlignTextToFramePadding then
            reaper.ImGui_AlignTextToFramePadding(ctx)
        end
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

        local spcfg = config.spacing
        reaper.ImGui_Text(ctx, "Min density (pixels, new points)")
        reaper.ImGui_SetNextItemWidth(ctx, panel_inner_w)
        local sp_min, sp_max = spcfg.MIN_MIN_POINT_SPACING_PX, spcfg.MAX_MIN_POINT_SPACING_PX
        local sp_changed, new_sp = reaper.ImGui_SliderInt(ctx, "##mindens", state.min_point_spacing_px, sp_min, sp_max)
        if sp_changed then
            state.min_point_spacing_px = math.max(1, math.max(sp_min, math.min(sp_max, new_sp)))
        end

        if settings_grey_n > 0 then
            reaper.ImGui_PopStyleColor(ctx, settings_grey_n)
            settings_grey_n = 0
        end
    end

    if state.brush_settings_mode and reaper.ImGui_GetWindowPos and reaper.ImGui_GetWindowSize then
        local px, py = reaper.ImGui_GetWindowPos(ctx)
        local pw, ph = reaper.ImGui_GetWindowSize(ctx)
        if type(px) == "number" and type(py) == "number" and type(pw) == "number" and type(ph) == "number"
            and pw > 0 and ph > 0 then
            state._brush_settings_panel_rect_imgui = { px, py, px + pw, py + ph }
        end
    end

    reaper.ImGui_End(ctx)
    if alpha_pushed > 0 then
        reaper.ImGui_PopStyleVar(ctx, alpha_pushed)
    end
    Style.pop_style_vars(ctx, layout_pushed)
end

return M
