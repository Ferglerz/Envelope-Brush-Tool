local M = {}

local function style_var_frame_rounding()
    local f = reaper.ImGuiStyleVar_FrameRounding
    if f == nil then return nil end
    if type(f) == "function" then return f() end
    return f
end

--- Tight layout: match draw-list HUD column (no window padding), reduce frame/item gaps so widgets align with plain text.
function M.push_settings_layout(ctx)
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

function M.pop_style_vars(ctx, count)
    for _ = 1, count do
        reaper.ImGui_PopStyleVar(ctx)
    end
end

--- Grey widgets for settings (combo / slider / checkbox / popups). ReaImGui `PushStyleColor` uses packed **0xRRGGBBAA** (alpha in the low byte); see ReaImGui `Color::Color(uint32_t rgba)` — not IM_COL32 / DrawList order.
function M.push_settings_grey_style(ctx)
    local list = {
        { reaper.ImGui_Col_Text(), 0xEEEEEEFF },
        { reaper.ImGui_Col_TextDisabled(), 0x888888FF },
        { reaper.ImGui_Col_Button(), 0x3A3A3AFF },
        { reaper.ImGui_Col_ButtonHovered(), 0x484848FF },
        { reaper.ImGui_Col_ButtonActive(), 0x282828FF },
        { reaper.ImGui_Col_FrameBg(), 0x2C2C2CFF },
        { reaper.ImGui_Col_FrameBgHovered(), 0x383838FF },
        { reaper.ImGui_Col_FrameBgActive(), 0x1E1E1EFF },
        { reaper.ImGui_Col_SliderGrab(), 0x666666FF },
        { reaper.ImGui_Col_SliderGrabActive(), 0x767676FF },
        { reaper.ImGui_Col_CheckMark(), 0xCCCCCCFF },
        { reaper.ImGui_Col_Header(), 0x353535FF },
        { reaper.ImGui_Col_HeaderHovered(), 0x434343FF },
        { reaper.ImGui_Col_HeaderActive(), 0x4D4D4DFF },
        { reaper.ImGui_Col_Separator(), 0x505050FF },
        { reaper.ImGui_Col_SeparatorHovered(), 0x5A5A5AFF },
        { reaper.ImGui_Col_SeparatorActive(), 0x646464FF },
        { reaper.ImGui_Col_Border(), 0x3D3D3DFF },
        { reaper.ImGui_Col_PopupBg(), 0x252525FF },
        { reaper.ImGui_Col_ChildBg(), 0x252525FF },
        { reaper.ImGui_Col_ScrollbarBg(), 0x222222FF },
        { reaper.ImGui_Col_ScrollbarGrab(), 0x525252FF },
        { reaper.ImGui_Col_ScrollbarGrabHovered(), 0x606060FF },
        { reaper.ImGui_Col_ScrollbarGrabActive(), 0x6C6C6CFF },
        { reaper.ImGui_Col_TitleBg(), 0x252525FF },
        { reaper.ImGui_Col_TitleBgActive(), 0x2C2C2CFF },
        { reaper.ImGui_Col_PlotHistogram(), 0x3A3A3AFF },
        { reaper.ImGui_Col_PlotHistogramHovered(), 0x484848FF },
    }
    local n = #list
    for i = 1, n do
        reaper.ImGui_PushStyleColor(ctx, list[i][1], list[i][2])
    end
    return n
end

--- Grey chip button; colors 0xRRGGBBAA for ReaImGui PushStyleColor.
function M.chip_button(ctx, label, selected, w, h)
    local svr = style_var_frame_rounding()
    if svr ~= nil then
        reaper.ImGui_PushStyleVar(ctx, svr, 10)
    end
    local cb = reaper.ImGui_Col_Button()
    local ch = reaper.ImGui_Col_ButtonHovered()
    local ca = reaper.ImGui_Col_ButtonActive()
    local pushed = 3
    if selected then
        reaper.ImGui_PushStyleColor(ctx, cb, 0x505050FF)
        reaper.ImGui_PushStyleColor(ctx, ch, 0x5E5E5EFF)
        reaper.ImGui_PushStyleColor(ctx, ca, 0x454545FF)
    else
        reaper.ImGui_PushStyleColor(ctx, cb, 0x3A3A3AFF)
        reaper.ImGui_PushStyleColor(ctx, ch, 0x484848FF)
        reaper.ImGui_PushStyleColor(ctx, ca, 0x303030FF)
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

function M.calc_text_w(ctx, s)
    local tw = reaper.ImGui_CalcTextSize(ctx, s)
    return type(tw) == "number" and tw or (select(1, tw) or 0)
end

function M.push_style_alpha(ctx, a)
    local v = reaper.ImGuiStyleVar_Alpha
    if v == nil then
        return 0
    end
    local id = type(v) == "function" and v() or v
    reaper.ImGui_PushStyleVar(ctx, id, a)
    return 1
end

return M
