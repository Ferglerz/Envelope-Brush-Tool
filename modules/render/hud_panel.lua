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

local CHECKMARK_CHIP_COLOR = 0xCCCCCCFF

local function settings_chip_label_row(ctx, Style, chip_size, selected, id_stem, right_label, tooltip, selected_palette, draw_chip)
    local label_gap = 6
    local label_tw, label_th = reaper.ImGui_CalcTextSize(ctx, right_label)
    if type(label_tw) ~= "number" then
        label_tw, label_th = select(1, label_tw), select(2, label_th)
    end
    label_th = label_th or (reaper.ImGui_GetTextLineHeight and reaper.ImGui_GetTextLineHeight(ctx)) or chip_size
    local row_h = chip_size
    local group_w = chip_size + label_gap + label_tw

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

    reaper.ImGui_SetCursorPos(ctx, base_x, base_y)
    local clicked = Style.chip_button(ctx, id_stem, selected, chip_size, chip_size, selected_palette)
    if draw_chip then
        draw_chip(ctx, chip_size)
    end

    if fp_id then
        reaper.ImGui_PopStyleVar(ctx)
    end
    if tooltip and reaper.ImGui_IsItemHovered and reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_SetTooltip then
        reaper.ImGui_SetTooltip(ctx, tooltip)
    end

    reaper.ImGui_SetCursorPos(ctx, base_x + chip_size + label_gap, base_y + (row_h - label_th) * 0.5)
    reaper.ImGui_Text(ctx, right_label)
    reaper.ImGui_Dummy(ctx, group_w, row_h)

    if reaper.ImGui_EndGroup then
        reaper.ImGui_EndGroup(ctx)
    end
    return clicked
end

local function axis_lock_chip_row(ctx, Style, chip_size, font_closed, font_open, locked, id_stem, axis_letter, tooltip, lock_font_px)
    local font_px = lock_font_px or C.LOCK_ICON_CHIP_FONT_PX or math.max(10, chip_size - 10)
    local font = locked and font_closed or font_open
    local palette = locked and C.LOCK_CHIP_SELECTED or nil

    local function draw_lock_chip(ctx, chip_size)
        local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
        if not draw_list then
            return
        end
        local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
        if type(rx) ~= "number" or type(ry) ~= "number" then
            return
        end
        reaper.ImGui_PushFont(ctx, font, font_px)
        local tw, th = reaper.ImGui_CalcTextSize(ctx, C.LOCK_GLYPH)
        if type(tw) ~= "number" then
            tw, th = select(1, tw), select(2, tw)
        end
        th = th or font_px
        local tx = rx + (chip_size - tw) * 0.5
        local ty = ry + (chip_size - th) * 0.5 + (C.LOCK_ICON_CHIP_Y_OFFSET or 0)
        reaper.ImGui_DrawList_AddText(draw_list, tx, ty, 0xEEEEEEFF, C.LOCK_GLYPH)
        reaper.ImGui_PopFont(ctx)
    end

    return settings_chip_label_row(
        ctx, Style, chip_size, locked, "##lock" .. id_stem, axis_letter, tooltip, palette, draw_lock_chip)
end

local function checkmark_chip_draw(Style, on)
    return function(ctx, chip_sz)
        if not on then
            return
        end
        local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
        if not draw_list then
            return
        end
        local rx, ry = reaper.ImGui_GetItemRectMin(ctx)
        if type(rx) ~= "number" or type(ry) ~= "number" then
            return
        end
        local mark_sz = chip_sz * 0.55
        local mx = rx + (chip_sz - mark_sz) * 0.5
        local my = ry + (chip_sz - mark_sz) * 0.5
        Style.draw_checkmark(draw_list, mx, my, mark_sz, CHECKMARK_CHIP_COLOR)
    end
end

local function checkmark_chip_row(ctx, Style, chip_size, on, id_stem, right_label, tooltip)
    return settings_chip_label_row(
        ctx, Style, chip_size, false, id_stem, right_label, tooltip, nil, checkmark_chip_draw(Style, on))
end

local function invert_scroll_chip_row(ctx, Style, chip_size, on, tooltip)
    return checkmark_chip_row(ctx, Style, chip_size, on, "##invert_scroll", "Invert Scroll", tooltip)
end

local function cleanup_toggle_chip_row(ctx, Style, chip_size, on, id_stem, right_label, tooltip)
    return checkmark_chip_row(ctx, Style, chip_size, on, id_stem, right_label, tooltip)
end

local function hud_row_gap(ctx, gap)
    if gap and gap > 0 then
        reaper.ImGui_Dummy(ctx, 0, gap)
    end
end

local function hud_panel_has_content(state)
    if state.brush_settings_mode then
        return true
    end
    if state.hud_info_enabled ~= false then
        return true
    end
    if state.hud_hints_enabled ~= false then
        return true
    end
    return false
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
    if not hud_panel_has_content(state) then
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

    local hcfg = config.hud or {}
    local row_gap = hcfg.HUD_TEXT_ROW_GAP or 3
    local font_delta = hcfg.HUD_FONT_SIZE_DELTA or 1
    local hint_col = hcfg.HUD_HINT_TEXT_COLOR or 0xFFFFFF99

    local layout_pushed = Style.push_settings_layout(ctx, row_gap)
    local visible = reaper.ImGui_Begin(ctx, "##BrushHudPanel", nil, flags)
    if not visible then
        reaper.ImGui_End(ctx)
        Style.pop_style_vars(ctx, layout_pushed)
        return
    end

    local display_alpha = state.brush_settings_mode and 1 or alpha
    local alpha_pushed = Style.push_style_alpha(ctx, display_alpha)
    local font_pushed = Style.push_hud_font(ctx, font_delta)

    local rel_base = reaper.ImGui_GetCursorPosX(ctx)
    local settings_grey_n = 0

    local fcfg = config.falloff
    local ft_key = fcfg.FALLOFF_TYPES[state.falloff_type]
    local falloff_pretty = (fcfg.FALLOFF_TYPE_LABELS and fcfg.FALLOFF_TYPE_LABELS[ft_key]) or ft_key

    local show_info = state.hud_info_enabled ~= false

    if state.brush_settings_mode then
        local drag_key = deps.brush_drag_kind_key and deps.brush_drag_kind_key() or nil
        if drag_key and drag_key ~= "smooth" then
            local mode_label = deps.brush_drag_kind_display and deps.brush_drag_kind_display() or "—"
            reaper.ImGui_Text(ctx, mode_label)
            reaper.ImGui_SameLine(ctx, 0, 6)
        end
        settings_grey_n = Style.push_settings_grey_style(ctx)
        falloff_combo(ctx, state, config, deps)
    elseif show_info then
        local header = (deps.brush_mode_falloff_header and deps.brush_mode_falloff_header(falloff_pretty)) or falloff_pretty
        reaper.ImGui_Text(ctx, header)
    end

    local size_txt = string.format("Size: %d", state.brush_size)
    local fall_pct = deps.falloff_strength_percent(state.falloff_strength)
    local fall_txt = string.format("Falloff: %.1f%%", fall_pct)
    local pow_pct = deps.sculpt_power_percent(state.sculpt_power)
    local pow_txt = string.format("Power: %.1f%%", pow_pct)
    local stat_gap = "   "

    if show_info then
        hud_row_gap(ctx, row_gap)
        reaper.ImGui_Text(ctx, size_txt .. stat_gap .. fall_txt .. stat_gap .. pow_txt)
    end

    if not state.brush_settings_mode and state.hud_hints_enabled ~= false then
        local mod_wheel = (deps.primary_modifier_short_name and deps.primary_modifier_short_name() or "Ctrl") .. " + scroll"

        hud_row_gap(ctx, row_gap)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), hint_col)
        if show_info then
            local w_size_gap = Style.calc_text_w(ctx, size_txt .. stat_gap)
            local w_fall_gap = Style.calc_text_w(ctx, fall_txt .. stat_gap)
            reaper.ImGui_Text(ctx, "Scroll")
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_SetCursorPosX(ctx, rel_base + w_size_gap)
            reaper.ImGui_Text(ctx, "Alt + scroll")
            reaper.ImGui_SameLine(ctx, 0, 0)
            reaper.ImGui_SetCursorPosX(ctx, rel_base + w_size_gap + w_fall_gap)
            reaper.ImGui_Text(ctx, mod_wheel)
        else
            reaper.ImGui_Text(ctx, "Scroll")
            reaper.ImGui_SameLine(ctx, 0, 8)
            reaper.ImGui_Text(ctx, "Alt + scroll")
            reaper.ImGui_SameLine(ctx, 0, 8)
            reaper.ImGui_Text(ctx, mod_wheel)
        end

        hud_row_gap(ctx, row_gap)
        reaper.ImGui_SetCursorPosX(ctx, rel_base)
        reaper.ImGui_Text(ctx, "Shift: Smooth")

        hud_row_gap(ctx, row_gap)
        reaper.ImGui_SetCursorPosX(ctx, rel_base)
        reaper.ImGui_Text(ctx, "Shift + scroll: Density")

        hud_row_gap(ctx, row_gap)
        reaper.ImGui_SetCursorPosX(ctx, rel_base)
        reaper.ImGui_Text(ctx, "Settings: Right Click")
        reaper.ImGui_PopStyleColor(ctx, 1)
    end

    if state.brush_settings_mode then
        hud_row_gap(ctx, row_gap)

        local chip_size = 28
        local lock_chip_font_px = (C.LOCK_ICON_CHIP_FONT_PX or math.max(10, chip_size - 10)) + font_delta
        local fc, fo = state.font_lock_closed, state.font_lock_open
        if axis_lock_chip_row(ctx, Style, chip_size, fc, fo, state.lock_time_axis, "lx", "X", "Lock time (horizontal). X key toggles.", lock_chip_font_px) then
            state.lock_time_axis = not state.lock_time_axis
            if state.lock_time_axis then
                state.lock_value_axis = false
            end
        end
        reaper.ImGui_SameLine(ctx, 0, 10)
        if axis_lock_chip_row(ctx, Style, chip_size, fc, fo, state.lock_value_axis, "ly", "Y", "Lock value (vertical). Y key toggles.", lock_chip_font_px) then
            state.lock_value_axis = not state.lock_value_axis
            if state.lock_value_axis then
                state.lock_time_axis = false
            end
        end

        hud_row_gap(ctx, row_gap)
        if invert_scroll_chip_row(ctx, Style, chip_size, state.invert_scroll,
            "When on, scroll direction for size, falloff (Alt+scroll), and min density (Shift+scroll) matches the older mapping.") then
            state.invert_scroll = not state.invert_scroll
            if deps.clear_wheel_momentum then
                deps.clear_wheel_momentum(state)
            end
        end
        reaper.ImGui_SameLine(ctx, 0, 10)
        if checkmark_chip_row(ctx, Style, chip_size, state.hud_hints_enabled ~= false,
            "##hud_hints", "Hints",
            "When on, show shortcut hint lines on the brush HUD (scroll, Shift smooth/density, settings).") then
            state.hud_hints_enabled = not state.hud_hints_enabled
        end
        reaper.ImGui_SameLine(ctx, 0, 10)
        if checkmark_chip_row(ctx, Style, chip_size, state.hud_info_enabled ~= false,
            "##hud_info", "Info",
            "When on, show mode header and Size / Falloff / Power on the brush HUD.") then
            state.hud_info_enabled = not state.hud_info_enabled
        end

        hud_row_gap(ctx, row_gap)

        local spcfg = config.spacing
        reaper.ImGui_Text(ctx, "Min density (pixels, new points)")
        reaper.ImGui_SetNextItemWidth(ctx, panel_inner_w)
        local sp_min, sp_max = spcfg.MIN_MIN_POINT_SPACING_PX, spcfg.MAX_MIN_POINT_SPACING_PX
        local sp_changed, new_sp = reaper.ImGui_SliderInt(ctx, "##mindens", state.min_point_spacing_px, sp_min, sp_max)
        if sp_changed then
            state.min_point_spacing_px = math.max(1, math.max(sp_min, math.min(sp_max, new_sp)))
        end
        if state.hud_hints_enabled ~= false then
            hud_row_gap(ctx, row_gap)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), hint_col)
            reaper.ImGui_Text(ctx, "Shift + scroll")
            reaper.ImGui_PopStyleColor(ctx, 1)
        end

        hud_row_gap(ctx, row_gap)
        reaper.ImGui_Text(ctx, "Smooth Cleanup:")
        hud_row_gap(ctx, row_gap)
        if cleanup_toggle_chip_row(ctx, Style, chip_size, state.smooth_cleanup_bezier_enabled ~= false,
            "##smooth_cleanup_bezier", "Bezier merge",
            "After Shift+smooth drag: merge points into bezier spans (twice, with angle pass between).") then
            state.smooth_cleanup_bezier_enabled = not state.smooth_cleanup_bezier_enabled
        end
        reaper.ImGui_SameLine(ctx, 0, 14)
        if cleanup_toggle_chip_row(ctx, Style, chip_size, state.smooth_cleanup_angle_enabled ~= false,
            "##smooth_cleanup_angle", "Angle cleanup",
            "After bezier merge: remove stroke points nearly collinear on screen.") then
            state.smooth_cleanup_angle_enabled = not state.smooth_cleanup_angle_enabled
        end
        if state.smooth_cleanup_bezier_enabled ~= false then
            hud_row_gap(ctx, row_gap)
            local ccfg = config.cleanup
            local tol_min = ccfg.BEZIER_FIT_TOLERANCE_MIN or 0.001
            local tol_max = ccfg.BEZIER_FIT_TOLERANCE_MAX or 0.05
            reaper.ImGui_Text(ctx, "Bezier fit tolerance (value)")
            reaper.ImGui_SetNextItemWidth(ctx, panel_inner_w)
            local tol_changed, new_tol = reaper.ImGui_SliderDouble(
                ctx, "##smooth_bezier_tol", state.smooth_bezier_fit_tolerance, tol_min, tol_max, "%.4f"
            )
            if tol_changed and type(new_tol) == "number" then
                state.smooth_bezier_fit_tolerance = math.max(tol_min, math.min(tol_max, new_tol))
            end
            if state.hud_hints_enabled ~= false then
                hud_row_gap(ctx, row_gap)
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), hint_col)
                reaper.ImGui_Text(ctx, "Lower = stricter fit · higher = more merging")
                reaper.ImGui_PopStyleColor(ctx, 1)
            end
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

    Style.pop_hud_font(ctx, font_pushed)
    if alpha_pushed > 0 then
        reaper.ImGui_PopStyleVar(ctx, alpha_pushed)
    end
    reaper.ImGui_End(ctx)
    Style.pop_style_vars(ctx, layout_pushed)
end

return M
