local _hud_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_hud_dir .. "../path.lua")
local Util = Path.load_from_modules("util.lua")

local M = {}

local function smooth_drag_active(state)
    return state.is_dragging == true and state.active_sculpt_kind == "smooth"
end

function M.brush_hud_interactive(state)
    if state.brush_settings_mode and state.brush_settings_freeze_client then
        return state.target_envelope ~= nil and state.envelope_lane_hover == true
    end
    return Util.brush_tool_active(state)
end

--- Show brush rings only on live lane hover (not committed stroke off-lane); same alpha gate as hud_panel.
--- Settings panel: stay visible while open (cursor may be on panel, off lane); REAPER foreground gate is in main loop.
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

--- Rings stay up during smooth LMB drag even while HUD text fades out.
function M.brush_hud_rings_visible(state)
    return M.brush_hud_visible(state)
end

--- ImGui (x,y) at brush center: frozen arrange client in settings mode, else live mouse via arrange client → ImGui.
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

return M
