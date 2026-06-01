local M = {}

local _render_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_render_dir .. "../path.lua")
local Style = Path.load("imgui_style.lua")
local C = Path.load("constants.lua")

--- TK/Sexan: GetRect + PointConvertNative for window; arrange client → ImGui for brush (same space).
function M.render_brush_hud(state, config, deps, hud, draw)
    local ctx = state.ctx
    if state._shutdown_complete or not ctx then return end

    if not hud.brush_hud_visible(state) then
        return
    end

    -- Must unpack here: assigning to a single variable drops other return values in Lua.
    local il, it, cw, ch = deps.get_arrange_imgui_overlay_geometry()
    if il == nil or it == nil or cw == nil or ch == nil then return end

    local cx, cy = hud.brush_center_imgui_xy(state, deps)
    if cx == nil or cy == nil then return end

    local cond = Style.cond_always()
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

        local hcfg = config.hud
        local spcfg = config.spacing
        local min_px = state.min_point_spacing_px or spcfg.DEFAULT_MIN_POINT_SPACING_PX
        min_px = math.max(spcfg.MIN_MIN_POINT_SPACING_PX, math.min(spcfg.MAX_MIN_POINT_SPACING_PX, min_px))
        -- Ring only: shift so UI min spacing 1 matches the former ring look at 6 px (6 − 1); envelope spacing is unchanged.
        local ring_px = min_px + (6 - 1)
        local dash_per_px = (2 * math.pi) / ring_px
        local dash_outer = math.max(2, math.floor(dash_per_px * radius + 0.5))
        local inner_radius = deps.calc_inner_brush_radius(radius)
        local dash_inner = math.max(2, math.floor(dash_per_px * inner_radius + 0.5))

        draw.draw_dashed_circle(draw_list, cx, cy, radius, hcfg.OUTER_CIRCLE_COLOR, hcfg.CIRCLE_THICKNESS, dash_outer)
        draw.draw_dashed_circle(draw_list, cx, cy, inner_radius, hcfg.INNER_CIRCLE_COLOR, hcfg.CIRCLE_THICKNESS - 1, dash_inner)

        if state.lock_time_axis or state.lock_value_axis then
            local suffix = state.lock_time_axis and " X" or " Y"
            local font_sz = reaper.ImGui_GetFontSize(ctx)
            local tx = cx - radius
            local ty = (cy + radius) - font_sz - 2 + (C.LOCK_ICON_OVERLAY_Y_OFFSET or 0)
            local lf = state.font_lock_closed
            reaper.ImGui_PushFont(ctx, lf, font_sz)
            local tw1 = Style.calc_text_w(ctx, C.LOCK_GLYPH)
            reaper.ImGui_DrawList_AddText(draw_list, tx, ty, 0xFFFFFFFF, C.LOCK_GLYPH)
            reaper.ImGui_PopFont(ctx)
            reaper.ImGui_DrawList_AddText(draw_list, tx + tw1 + 4, ty, 0xFFFFFFFF, suffix)
        end
    end

    reaper.ImGui_End(ctx)
end

return M
