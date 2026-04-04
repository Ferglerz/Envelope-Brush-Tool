--- Public render API: compose HUD state, draw primitives, ImGui panel, and arrange overlay.
local M = {}

local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""

local HudState = dofile(SCRIPT_DIR .. "hud_state.lua")
local Draw = dofile(SCRIPT_DIR .. "draw.lua")
local HudPanel = dofile(SCRIPT_DIR .. "hud_panel.lua")
local Overlay = dofile(SCRIPT_DIR .. "overlay.lua")

M.brush_hud_interactive = HudState.brush_hud_interactive
M.brush_hud_visible = HudState.brush_hud_visible
M.update_brush_hud_text_fade = HudState.update_brush_hud_text_fade
M.draw_dashed_circle = Draw.draw_dashed_circle
M.draw_falloff_preview = Draw.draw_falloff_preview

function M.render_brush_hud_panel(state, config, deps)
    return HudPanel.render_brush_hud_panel(state, config, deps, HudState)
end

function M.render_brush_hud(state, config, deps)
    return Overlay.render_brush_hud(state, config, deps, HudState, Draw)
end

return M
