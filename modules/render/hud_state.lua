local M = {}

function M.brush_hud_interactive(state)
    return state.sws_hover_detected and state.target_envelope ~= nil
end

--- Show brush rings: live hover, or settings mode with a frozen position on a locked lane.
function M.brush_hud_visible(state)
    if not state.target_envelope then
        return false
    end
    if M.brush_hud_interactive(state) then
        return true
    end
    return state.brush_settings_mode == true and state.brush_settings_freeze_client ~= nil
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
