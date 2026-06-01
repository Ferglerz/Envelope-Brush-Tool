-- Shared defaults for core.new_state and UI.

return {
    --- Arrange view, SWS hover, and defer/insert integration
    arrange = {
        DEFER_ENVELOPE_SUPPRESS_CONTROL_IMGUI = false, -- Suppress ImGui window after envelope flush (avoids flicker)
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
        --- Alt+scroll: 1 display-% per tick (0.01 underlying; Shift uses wheel fine 25%).
        FALLOFF_STRENGTH_PERCENT_STEP = 1,
        --- Inner dashed ring = brush radius where spatial falloff weight drops to this (0..1).
        FALLOFF_INNER_WEIGHT_THRESHOLD = 0.5,
    },

    --- Min screen gap when seeding new envelope points (not used for deletion).
    spacing = {
        DEFAULT_MIN_POINT_SPACING_PX = 10,
        MIN_MIN_POINT_SPACING_PX = 1,
        MAX_MIN_POINT_SPACING_PX = 48,
    },

    --- After Shift+smooth drag (LMB up): drop interior points nearly collinear in arrange screen space.
    cleanup = {
        REDUNDANT_POINT_MIN_ANGLE_DEG = 175,
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
        -- Smooth: blend per move = strength01 × brush falloff × this (cap 1). strength01 = (Power−MIN)/(MAX−MIN).
        SMOOTH_MAX_BLEND_PER_MOVE = 0.5,
        DEFAULT_SCULPT_POWER = 1.0,
        MIN_SCULPT_POWER = 0.25,
        MAX_SCULPT_POWER = 4.0,
        --- Cmd/Ctrl+scroll: 1 display-% per tick (0.01 underlying; Shift uses wheel fine 25%).
        SCULPT_POWER_PERCENT_STEP = 1,
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

    -- Warmup for brush-width seed: build min-distance point list while hovering, reuse on click.
    seed = {
        HOVER_WARM_ENABLED = true,
        HOVER_WARM_INTERVAL_SEC = 0.05,
        HOVER_WARM_MIN_MOUSE_MOVE_PX = 2,
        HOVER_WARM_PRECOMPUTE_INSERT_CANDIDATES = true,
        SEED_CACHE_REUSE_CENTER_TOLERANCE_PX = 3,
        SEED_CACHE_MAX_AGE_SEC = 0.25,
    },
}
