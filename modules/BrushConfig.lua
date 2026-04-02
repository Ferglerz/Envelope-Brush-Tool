-- Shared defaults for BrushCore.new_state and UI.

return {
    -- After deferred envelope flush, skip drawing the editor ImGui window for that tick (visible flicker; can help APIs stick).
    DEFER_ENVELOPE_SUPPRESS_CONTROL_IMGUI = false,
    -- >0: Main_OnCommand(id,0). Inserts at the real OS cursor, not brush-mapped arrange-client coords. 0: InsertEnvelopePoint* (mapped mx,my).
    INSERT_AT_MOUSE_ACTION_ID = 0,
    --- Default / slider bounds for min distance between envelope points in arrange-client pixels (time + value on screen). Enforced after seed + on mouse-up after drag, not every sculpt tick.
    DEFAULT_MIN_POINT_SPACING_PX = 10,
    MIN_MIN_POINT_SPACING_PX = 0,
    MAX_MIN_POINT_SPACING_PX = 48,
    DEFAULT_BRUSH_SIZE = 50,
    MIN_BRUSH_SIZE = 10,
    MAX_BRUSH_SIZE = 200,
    BRUSH_SIZE_STEP = 1,
    FALLOFF_TYPES = {"exponential", "linear", "inverse_exponential"},
    --- HUD / readable labels (internal names in FALLOFF_TYPES unchanged for BrushCore.calculate_falloff).
    FALLOFF_TYPE_LABELS = {
        exponential = "Exponential",
        linear = "Linear",
        inverse_exponential = "Inverse exponential",
    },
    -- Brush HUD: label fade when LMB up (seconds).
    BRUSH_HUD_TEXT_FADE_IN_SEC = 1.5,
    BRUSH_HUD_TEXT_FADE_OUT_SEC = 0.12,
    --- Modifier-driven drag kinds: plain LMB = nudge, Cmd/Ctrl = sculpt, Shift = smooth.
    BRUSH_DRAG_KINDS = {"nudge", "sculpt", "smooth"},
    BRUSH_DRAG_KIND_LABELS = { nudge = "Nudge", sculpt = "Sculpt", smooth = "Smooth" },
    DEFAULT_FALLOFF_STRENGTH = 1.0,
    MIN_FALLOFF_STRENGTH = 0.1,
    MAX_FALLOFF_STRENGTH = 3.0,
    FALLOFF_STRENGTH_STEP = 0.1,
    -- Inner dashed radius as fraction of brush radius: scales with falloff strength.
    FALLOFF_INNER_RATIO_AT_MIN_STRENGTH = 0.88,
    FALLOFF_INNER_RATIO_AT_MAX_STRENGTH = 0.12,
    -- HUD: vertical pad around brush; horizontal extra for labels to the right of the brush.
    BRUSH_HUD_PAD_V = 36,
    BRUSH_HUD_LABEL_EXTRA_W = 240,
    -- Pixels to skip at top of arrange view (time ruler inside 0x3E8 child). Tune if value axis is offset.
    ARRANGE_RULER_INSET = 28,
    -- Point-based curve proximity test (BrushEnvelope.point_hits_envelope_curve); UI readout only, not brush gating.
    ENVELOPE_HOVER_TOLERANCE_PIXELS = 8,
    OUTER_CIRCLE_COLOR = 0xFFFFFFCC,
    INNER_CIRCLE_COLOR = 0xFFFFFF66,
    CIRCLE_THICKNESS = 2.0,
    -- Min mouse delta (arrange client px) per defer tick to apply sculpt; smaller deltas accumulate until exceeded.
    SCULPT_DRAG_MIN_MOVEMENT_PX = 0.02,
    --- Envelope_SortPoints* cadence while sculpting (seconds). First tick after drag start sorts immediately (no prior time).
    ENVELOPE_SORT_INTERVAL_SEC = 0.25,
    -- Smooth (Shift+LMB): per mouse move, blend toward mean Y and even time spacing across brush; base × this slider × falloff × power.
    SMOOTH_SETTLE_BASE_PER_MOVE = 0.0005, -- 0.05% per move before strength slider
    DEFAULT_SMOOTH_STRENGTH = 0.2,
    MIN_SMOOTH_STRENGTH = 0.02,
    MAX_SMOOTH_STRENGTH = 1.0,
    -- Cmd/Ctrl+scroll: sculpt power; Shift+scroll: finer wheel steps; Shift while dragging Sculpt: half strength (Fine).
    DEFAULT_SCULPT_POWER = 1.0,
    MIN_SCULPT_POWER = 0.25,
    MAX_SCULPT_POWER = 4.0,
    SCULPT_POWER_STEP = 0.05,
    --- Sculpt first click: blend seeded point values toward cursor Y using falloff. Off = place points on the existing curve only.
    DEFAULT_SCULPT_SEED_BLEND_TO_CURSOR = true,
    --- Plain-scroll (brush size) wheel coast; modifier scrolls (falloff / power) are discrete only.
    WHEEL_MOMENTUM_IMPULSE = 2.6,
    WHEEL_MOMENTUM_FRICTION = 0.872,
    WHEEL_MOMENTUM_MAX_VEL = 32,
    WHEEL_MOMENTUM_STOP = 0.032,
    WHEEL_MOMENTUM_SIZE_RATE = 0.13,
}
