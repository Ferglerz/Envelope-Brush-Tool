local M = {}

-- Lock Closed/Open fonts map lock icon to glyph U+0041.
M.LOCK_GLYPH = "A"
--- Lock glyph size inside 28px chip buttons (centered via measured bounds).
M.LOCK_ICON_CHIP_FONT_PX = 16
--- Icon font metrics sit below visual center in chip buttons (negative = draw higher).
M.LOCK_ICON_CHIP_Y_OFFSET = -7
--- Extra Y for lock glyph beside brush (screen space, down = positive).
M.LOCK_ICON_OVERLAY_Y_OFFSET = 1

return M
