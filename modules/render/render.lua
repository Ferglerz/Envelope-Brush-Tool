--- Public render API: arrange overlay rings + HUD panel.
local M = {}

local _render_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_render_dir .. "../path.lua")

local Overlay = Path.load("overlay.lua")
local HudPanel = Path.load("hud_panel.lua")

M.brush_hud_interactive = Overlay.brush_hud_interactive
M.brush_hud_visible = Overlay.brush_hud_visible
M.update_brush_hud_text_fade = Overlay.update_brush_hud_text_fade

function M.render_brush_hud_panel(state, config, deps)
    return HudPanel.render_brush_hud_panel(state, config, deps, Overlay)
end

function M.render_brush_hud(state, config, deps)
    return Overlay.render_brush_hud(state, config, deps)
end

return M
