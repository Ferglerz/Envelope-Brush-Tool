--- Public render API: compose HUD state, draw primitives, ImGui panel, and arrange overlay.
local M = {}

local _render_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_render_dir .. "../path.lua")

local HudState = Path.load("hud_state.lua")
local Draw = Path.load("draw.lua")
local HudPanel = Path.load("hud_panel.lua")
local Overlay = Path.load("overlay.lua")

M.brush_hud_interactive = HudState.brush_hud_interactive
M.brush_hud_visible = HudState.brush_hud_visible
M.brush_hud_rings_visible = HudState.brush_hud_rings_visible
M.update_brush_hud_text_fade = HudState.update_brush_hud_text_fade

function M.render_brush_hud_panel(state, config, deps)
    return HudPanel.render_brush_hud_panel(state, config, deps, HudState)
end

function M.render_brush_hud(state, config, deps)
    return Overlay.render_brush_hud(state, config, deps, HudState, Draw)
end

return M
