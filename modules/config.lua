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
        DEFAULT_INVERT_SCROLL = false,
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
            smoothstep = "S-curve",
            circle = "Spherical",
            gaussian = "Gaussian",
            cosine = "Cosine (Hann)",
        },
        DEFAULT_FALLOFF_STRENGTH = 1.0,
        MIN_FALLOFF_STRENGTH = 0.1,
        MAX_FALLOFF_STRENGTH = 3.0,
        --- Alt+scroll: 1 display-% per tick (0.01 underlying).
        FALLOFF_STRENGTH_PERCENT_STEP = 1,
        --- Inner dashed ring = brush radius where spatial falloff weight drops to this (0..1).
        FALLOFF_INNER_WEIGHT_THRESHOLD = 0.5,
    },

    --- Min screen gap when seeding new envelope points (not used for deletion).
    spacing = {
        DEFAULT_MIN_POINT_SPACING_PX = 10,
        MIN_MIN_POINT_SPACING_PX = 1,
        MAX_MIN_POINT_SPACING_PX = 48,
        --- Shift+scroll: min_point_spacing_px (1 px/tick; respects invert_scroll).
    },

    --- After Shift+smooth drag (LMB up): merge consecutive point windows with bezier/linear spans.
    cleanup = {
        --- Defaults for brush settings panel (project-persisted).
        DEFAULT_SMOOTH_CLEANUP_BEZIER_ENABLED = true,
        DEFAULT_SMOOTH_CLEANUP_ANGLE_ENABLED = true,
        DEFAULT_BEZIER_FIT_TOLERANCE = 0.015,
        BEZIER_FIT_TOLERANCE_MIN = 0.001,
        BEZIER_FIT_TOLERANCE_MAX = 0.05,
        --- Minimum interior points in a window (2 = 4 points → 2 anchors + 1 span).
        BEZIER_MERGE_MIN_INTERIOR = 2,
        --- Max interior points per window; 0 = no cap (longest fit within tolerance wins).
        BEZIER_MERGE_MAX_INTERIOR = 0,
        --- Max value error for linear span merges (strict).
        BEZIER_MERGE_MAX_ERR = 0.0001,
        --- Looser fit gate when the merged span uses bezier (shape 5); overridden by state.smooth_bezier_fit_tolerance.
        BEZIER_MERGE_MAX_ERR_BEZIER = 0.015,
        --- Value chord deviation above this → arc-like; require bezier (do not linearize).
        BEZIER_MERGE_ARC_CHORD_MIN = 0.0001,
        --- Schneider fit: Newton-Raphson passes to refine chord-length t per interior point.
        BEZIER_MERGE_SCHNEIDER_NEWTON_ITER = 2,
        --- Golden-section search for REAPER tension around Schneider hint (then full −1…1).
        BEZIER_MERGE_TENSION_SEARCH_RADIUS = 0.35,
        --- Use bezier only if it beats linear by at least this (ignored on arc-like windows).
        BEZIER_MERGE_BEZIER_MIN_GAIN = 0.00001,
        --- Mid-gap samples between knot times (interior count ≥ min below).
        BEZIER_MERGE_EXTRA_SAMPLES_PER_GAP = 2,
        BEZIER_MERGE_EXTRA_SAMPLES_MIN_INTERIOR = 2,
        --- Double gap samples when interior count ≥ this (longer arcs).
        BEZIER_MERGE_EXTRA_SAMPLES_LONG_INTERIOR = 5,
        --- Max greedy merge passes per smooth LMB release (stroke scope only).
        BEZIER_MERGE_MAX_PASSES = 16,
        --- After bezier merge: drop stroke points nearly collinear on screen (arrange client px).
        REDUNDANT_POINT_MIN_ANGLE_DEG = 175,
        ANGLE_CLEANUP_MAX_PASSES = 16,
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
        --- Cmd/Ctrl+scroll: 1 display-% per tick (0.01 underlying).
        SCULPT_POWER_PERCENT_STEP = 1,
    },

    --- Arrange overlay: brush rings, HUD text fade, padding hints
    hud = {
        --- Added to ImGui default font size for HUD panel + settings (main window text).
        HUD_FONT_SIZE_DELTA = 1,
        --- Vertical gap between text rows in the HUD panel (px).
        HUD_TEXT_ROW_GAP = 3,
        --- Secondary hint lines (scroll labels, settings hints); 0xRRGGBBAA.
        HUD_HINT_TEXT_COLOR = 0xFFFFFF99,
        DEFAULT_HUD_HINTS_ENABLED = true,
        DEFAULT_HUD_INFO_ENABLED = true,
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
