local M = {}

local _render_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_render_dir .. "../path.lua")
local Style = Path.load("imgui_style.lua")
local Draw = Path.load("draw.lua")
local Util = Path.load_from_modules("util.lua")

local C = {
    LOCK_GLYPH = "A",
    LOCK_ICON_OVERLAY_Y_OFFSET = 1,
    LOCK_ICON_OVERLAY_LOCK_Y_OFFSET = 3,
}

local function smooth_drag_active(state)
    return state.is_dragging == true and state.active_sculpt_kind == "smooth"
end

function M.brush_hud_interactive(state)
    if state.brush_settings_mode and state.brush_settings_freeze_client then
        return state.target_envelope ~= nil and state.envelope_lane_hover == true
    end
    return Util.brush_tool_active(state)
end

function M.brush_hud_visible(state)
    if state.brush_settings_mode and state.brush_settings_freeze_client and state.target_envelope then
        return true
    end
    if not state.target_envelope or state.envelope_lane_hover ~= true then
        return false
    end
    if (state.brush_hud_text_alpha or 1) <= 0.02 and not smooth_drag_active(state) then
        return false
    end
    return true
end

function M.brush_center_imgui_xy(state, deps)
    if not deps or not deps.arrange_client_to_imgui then
        return nil, nil
    end
    if state.brush_settings_mode and state.brush_settings_freeze_client then
        return deps.arrange_client_to_imgui(
            state.brush_settings_freeze_client.x,
            state.brush_settings_freeze_client.y
        )
    end
    if not deps.get_mouse_client_xy or not deps.brush_center_client_xy then
        return nil, nil
    end
    local cx, cy = deps.get_mouse_client_xy()
    if cx == nil or cy == nil then
        return nil, nil
    end
    cx, cy = deps.brush_center_client_xy(cx, cy)
    if cx == nil or cy == nil then
        return nil, nil
    end
    return deps.arrange_client_to_imgui(cx, cy)
end

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

function M.render_brush_hud(state, config, deps)
    local ctx = state.ctx
    if state._shutdown_complete or not ctx then return end

    if not M.brush_hud_visible(state) then
        return
    end

    local il, it, cw, ch = deps.get_arrange_imgui_overlay_geometry()
    if il == nil or it == nil or cw == nil or ch == nil then return end

    local cx, cy = M.brush_center_imgui_xy(state, deps)
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
        local ring_px = min_px + (6 - 1)
        local dash_per_px = (2 * math.pi) / ring_px
        local dash_outer = math.max(2, math.floor(dash_per_px * radius + 0.5))
        local smooth_drag = state.is_dragging == true and state.active_sculpt_kind == "smooth"

        Draw.draw_dashed_circle(draw_list, cx, cy, radius, hcfg.OUTER_CIRCLE_COLOR, hcfg.CIRCLE_THICKNESS, dash_outer)

        if not smooth_drag then
            local inner_radius = deps.calc_inner_brush_radius(radius)
            local dash_inner = math.max(2, math.floor(dash_per_px * inner_radius + 0.5))
            Draw.draw_dashed_circle(draw_list, cx, cy, inner_radius, hcfg.INNER_CIRCLE_COLOR, hcfg.CIRCLE_THICKNESS - 1, dash_inner)
        end

        if state.lock_time_axis or state.lock_value_axis then
            local suffix = state.lock_time_axis and " X" or " Y"
            local font_sz = reaper.ImGui_GetFontSize(ctx)
            local tx = cx - radius
            local ty = (cy + radius) - font_sz - 2 + (C.LOCK_ICON_OVERLAY_Y_OFFSET or 0)
            local lock_ty = ty + (C.LOCK_ICON_OVERLAY_LOCK_Y_OFFSET or 0)
            local lf = state.font_lock_closed
            reaper.ImGui_PushFont(ctx, lf, font_sz)
            local tw1 = Style.calc_text_w(ctx, C.LOCK_GLYPH)
            reaper.ImGui_DrawList_AddText(draw_list, tx, lock_ty, 0xFFFFFFFF, C.LOCK_GLYPH)
            reaper.ImGui_PopFont(ctx)
            reaper.ImGui_DrawList_AddText(draw_list, tx + tw1 + 4, ty, 0xFFFFFFFF, suffix)
        end
    end

    reaper.ImGui_End(ctx)
end

return M
