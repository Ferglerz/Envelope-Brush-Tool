-- Shared defaults for BrushCore.new_state and UI.

return {
    --- Arrange view, SWS hover, and defer/insert integration
    arrange = {
        DEFER_ENVELOPE_SUPPRESS_CONTROL_IMGUI = false, -- Suppress ImGui window after envelope flush (avoids flicker)
        INSERT_AT_MOUSE_ACTION_ID = 0, -- 0: insert at mapped coords, >0: use OS cursor action
        ARRANGE_RULER_INSET = 28, -- Arrange view top padding (exclude ruler)
        ENVELOPE_HOVER_TOLERANCE_PIXELS = 8, -- Pixel proximity for curve hover UI (not for brush ops)
    },

    --- Brush radius and wheel step limits
    brush = {
        DEFAULT_BRUSH_SIZE = 50,
        MIN_BRUSH_SIZE = 10,
        MAX_BRUSH_SIZE = 200,
        BRUSH_SIZE_STEP = 1,
        --- When true, plain-scroll brush size uses the opposite direction from the default (natural) mapping.
        DEFAULT_INVERT_BRUSH_SIZE_SCROLL = false,
    },

    --- Falloff curve shape, strength, and inner-ring mapping
    falloff = {
        FALLOFF_TYPES = {
            "exponential",
            "linear",
            "inverse_exponential",
            "smoothstep",
            "circle",
            "gaussian",
            "cosine",
        },
        FALLOFF_TYPE_LABELS = {
            exponential = "Exponential",
            linear = "Linear",
            inverse_exponential = "Inverse exponential",
            smoothstep = "S-curve (smoothstep)",
            circle = "Circle (spherical)",
            gaussian = "Gaussian",
            cosine = "Cosine (Hann)",
        },
        DEFAULT_FALLOFF_STRENGTH = 1.0,
        MIN_FALLOFF_STRENGTH = 0.1,
        MAX_FALLOFF_STRENGTH = 3.0,
        FALLOFF_STRENGTH_STEP = 0.1,
        FALLOFF_INNER_RATIO_AT_MIN_STRENGTH = 0.88, -- Dashed inner ring at min strength (fraction of brush radius)
        FALLOFF_INNER_RATIO_AT_MAX_STRENGTH = 0.12, -- ...at max strength
    },

    --- Min spacing between points (screen px) after seed / on drag end
    spacing = {
        DEFAULT_MIN_POINT_SPACING_PX = 10,
        MIN_MIN_POINT_SPACING_PX = 1,
        MAX_MIN_POINT_SPACING_PX = 48,
    },

    --- LMB drag mode labels (nudge / sculpt / smooth)
    drag = {
        BRUSH_DRAG_KINDS = { "nudge", "sculpt", "smooth" },
        BRUSH_DRAG_KIND_LABELS = { nudge = "Nudge", sculpt = "Sculpt", smooth = "Smooth" },
    },

    --- Sculpt, smooth, and throttled envelope sort while dragging
    sculpt = {
        SCULPT_DRAG_MIN_MOVEMENT_PX = 0.02, -- Mouse move threshold per tick to apply sculpt
        ENVELOPE_SORT_INTERVAL_SEC = 0.25, -- Interval to sort points while sculpting
        SMOOTH_SETTLE_BASE_PER_MOVE = 0.2, -- Shift smooth: Laplacian value step × falloff × (power / MAX); time still evens across brush
        --- When true, Shift+smooth re-scans envelope points under the brush on each sculpt step (same threshold as sculpt drag).
        DEFAULT_ENABLE_CONTINUOUS_SMOOTHING = false,
        DEFAULT_SCULPT_POWER = 1.0,
        MIN_SCULPT_POWER = 0.25,
        MAX_SCULPT_POWER = 4.0,
        SCULPT_POWER_STEP = 0.05,
    },

    --- Arrange overlay: brush rings, HUD text fade, padding hints
    hud = {
        BRUSH_HUD_TEXT_FADE_IN_SEC = 1.5, -- HUD label fade in (on LMB up)
        BRUSH_HUD_TEXT_FADE_OUT_SEC = 0.12, -- HUD label fade out
        BRUSH_HUD_PAD_V = 36, -- HUD vertical pad around brush
        BRUSH_HUD_LABEL_EXTRA_W = 240, -- HUD label extra width to right
        -- 0xRRGGBBAA (ReaImGui DrawList / same packing as color_utils `toImGuiColor`).
        OUTER_CIRCLE_COLOR = 0xFFFFFFCC,
        INNER_CIRCLE_COLOR = 0xFFFFFF66,
        CIRCLE_THICKNESS = 2.0,
    },

    --- Inertial coast for plain scroll (brush size)
    wheel = {
        WHEEL_MOMENTUM_IMPULSE = 4.2,
        WHEEL_MOMENTUM_FRICTION = 0.78,
        WHEEL_MOMENTUM_MAX_VEL = 48,
        WHEEL_MOMENTUM_STOP = 0.045,
        WHEEL_MOMENTUM_SIZE_RATE = 0.28,
    },
}
