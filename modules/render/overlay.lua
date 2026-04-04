local M = {}

local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""
local C = dofile(SCRIPT_DIR .. "constants.lua")

--- TK/Sexan: GetRect + PointConvertNative for window; PointConvertNative(GetMouse) for brush (same ImGui space).
function M.render_brush_hud(state, config, deps, hud, draw)
    local ctx = state.ctx
    if state._shutdown_complete or not ctx then return end

    --- Brush circles: live SWS hover or frozen position in settings mode.
    local show_brush = hud.brush_hud_visible(state)
    if not show_brush then
        return
    end

    -- Must unpack here: assigning to a single variable drops other return values in Lua.
    local il, it, cw, ch = deps.get_arrange_imgui_overlay_geometry()
    if il == nil or it == nil or cw == nil or ch == nil then return end

    local cx, cy
    if show_brush then
        cx, cy = hud.brush_center_imgui_xy(state, deps)
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
                local ty = (cy + radius) - font_sz - 2
                local lf = state.font_lock_closed
                reaper.ImGui_PushFont(ctx, lf, font_sz)
                local tw = reaper.ImGui_CalcTextSize(ctx, C.LOCK_GLYPH)
                local tw1 = type(tw) == "number" and tw or (select(1, tw) or 0)
                reaper.ImGui_DrawList_AddText(draw_list, tx, ty, 0xFFFFFFFF, C.LOCK_GLYPH)
                reaper.ImGui_PopFont(ctx)
                reaper.ImGui_DrawList_AddText(draw_list, tx + tw1 + 4, ty, 0xFFFFFFFF, suffix)
            end
        end

    end

    reaper.ImGui_End(ctx)
end

return M
