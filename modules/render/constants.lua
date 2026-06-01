local M = {}

-- Lock Closed/Open fonts map lock icon to glyph U+0041.
M.LOCK_GLYPH = "A"
--- Lock glyph size inside 28px chip buttons (centered via measured bounds).
M.LOCK_ICON_CHIP_FONT_PX = 16
--- Icon font metrics sit below visual center in chip buttons (negative = draw higher).
M.LOCK_ICON_CHIP_Y_OFFSET = -7
--- Shared Y for lock + axis readout row (bottom-left of brush circle; down = positive).
M.LOCK_ICON_OVERLAY_Y_OFFSET = 1
--- Extra Y for lock glyph only (icon font sits above default text at same ty).
M.LOCK_ICON_OVERLAY_LOCK_Y_OFFSET = 3

--- Pale red chip fill when an axis lock is active (ReaImGui 0xRRGGBBAA).
M.LOCK_CHIP_SELECTED = {
    normal = 0xB87878FF,
    hover = 0xC88888FF,
    active = 0xA06868FF,
}

return M
