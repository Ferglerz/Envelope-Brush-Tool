local M = {}

--- ReaImGui must see ImGui_Begin/End each defer tick when the arrange HUD skips Begin (no lane hover yet).
--- Invisible host window; size/scroll/falloff/power remain on the lane HUD + wheel + RMB panel.
function M.pump_imgui_frame(state)
    local ctx = state.ctx
    if not ctx then
        return
    end

    local cond = reaper.ImGui_Cond_Always and reaper.ImGui_Cond_Always() or 0
    reaper.ImGui_SetNextWindowPos(ctx, -10000, -10000, cond)
    reaper.ImGui_SetNextWindowSize(ctx, 10, 10, cond)

    local flags = 0
    local function add(f)
        if f == nil then return end
        local v = type(f) == "function" and f() or f
        flags = flags | v
    end
    add(reaper.ImGui_WindowFlags_NoTitleBar)
    add(reaper.ImGui_WindowFlags_NoResize)
    add(reaper.ImGui_WindowFlags_NoMove)
    add(reaper.ImGui_WindowFlags_NoScrollbar)
    add(reaper.ImGui_WindowFlags_NoCollapse)
    add(reaper.ImGui_WindowFlags_NoNav)
    add(reaper.ImGui_WindowFlags_NoBackground)
    add(reaper.ImGui_WindowFlags_NoSavedSettings)
    add(reaper.ImGui_WindowFlags_NoDocking)
    add(reaper.ImGui_WindowFlags_NoInputs)
    add(reaper.ImGui_WindowFlags_NoMouseInputs)
    add(reaper.ImGui_WindowFlags_NoFocusOnAppearing)

    reaper.ImGui_Begin(ctx, "##EnvelopeBrushHost", nil, flags)
    reaper.ImGui_End(ctx)
end

return M
