local M = {}

local _mod_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_mod_dir .. "path.lua")
local Style = Path.load_from_modules("render/imgui_style.lua")

--- ReaImGui must see ImGui_Begin/End each defer tick when the arrange HUD skips Begin (no lane hover yet).
--- Invisible host window; size/scroll/falloff/power remain on the lane HUD + wheel + RMB panel.
function M.pump_imgui_frame(state)
    local ctx = state.ctx
    if not ctx then
        return false
    end

    local ok = pcall(function()
        local cond = Style.cond_always()
        reaper.ImGui_SetNextWindowPos(ctx, -10000, -10000, cond)
        reaper.ImGui_SetNextWindowSize(ctx, 10, 10, cond)

        local flags = 0
        local function add(f)
            flags = flags | Style.flag(f)
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
    end)

    if not ok then
        -- ReaImGui context can become stale on rapid toggle/restart; invalidate handle to force clean shutdown.
        state.ctx = nil
        return false
    end
    return true
end

return M
