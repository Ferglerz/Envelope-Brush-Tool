-- REAPER Brush Envelope Editor - Clean Working Version
-- Sculpt and create envelope points with brush-like controls

-- ===== CONFIGURATION =====
local CONFIG = {
    MIN_POINT_SPACING_PIXELS = 10,
    DEFAULT_BRUSH_SIZE = 50,
    MIN_BRUSH_SIZE = 10,
    MAX_BRUSH_SIZE = 200,
    BRUSH_SIZE_STEP = 5,
    FALLOFF_TYPES = {"exponential", "linear", "inverse_exponential"},
    SCULPT_MODES = {"grab", "smooth"},
    DEFAULT_FALLOFF_STRENGTH = 1.0,
    MIN_FALLOFF_STRENGTH = 0.1,
    MAX_FALLOFF_STRENGTH = 3.0,
    FALLOFF_STRENGTH_STEP = 0.1,
    INNER_CIRCLE_RATIO = 0.5,
    OUTER_CIRCLE_COLOR = 0xFFFFFFCC,
    INNER_CIRCLE_COLOR = 0xFFFFFF66,
    CIRCLE_THICKNESS = 2.0,
    MIN_MOVEMENT_THRESHOLD = 0.5,
    -- Smooth sculpt: blend per step toward Envelope_Evaluate at each point's time
    DEFAULT_SMOOTH_STRENGTH = 0.2,
    MIN_SMOOTH_STRENGTH = 0.02,
    MAX_SMOOTH_STRENGTH = 1.0,
}

-- ===== STATE =====
local State = {
    -- Brush settings
    brush_size = CONFIG.DEFAULT_BRUSH_SIZE,
    falloff_type = 1,
    falloff_strength = CONFIG.DEFAULT_FALLOFF_STRENGTH,
    sculpt_mode = 1,
    smooth_strength = CONFIG.DEFAULT_SMOOTH_STRENGTH,
    lock_time_axis = false,
    lock_value_axis = false,

    -- Mode: false = LMB sculpts existing points; true = LMB drag creates points
    add_points_mode = false,

    -- Mouse and interaction
    mouse_pos = {x = 0, y = 0},
    is_dragging = false,
    drag_mode = "sculpt",
    drag_start_pos = {x = 0, y = 0},
    captured_points = {},
    last_create_client = nil,

    -- Envelope context
    target_envelope = nil,
    envelope_bounds = {top = 150, bottom = 600, left = 200, right = 1200},
    overlay_visible = false,
    cached_envelope = nil,
    envelope_detected = false,
    validation_failures = 0,

    -- Cached envelope properties
    cached_envelope_properties = {envelope = nil, min_val = 0, max_val = 1},

    -- Per-frame cache (arrange view)
    frame_arrange_start = 0,
    frame_arrange_end = 0,

    -- Main window client size for overlay
    client_w = 2000,
    client_h = 2000,

    -- Undo system
    undo_active = false,
    undo_operation_name = "",
    sculpt_sort_pending = false,
    sculpt_last_client = nil,

    -- ImGui
    ctx = nil,

    -- True after "Start Sculpt Test" until end — sculpt follows mouse without LMB
    manual_sculpt_active = false,
}

-- ===== UTILITIES =====
local function get_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

local function clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
end

local function refresh_frame_arrange()
    local a_start, a_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    State.frame_arrange_start = a_start
    State.frame_arrange_end = a_end
end

--- Mouse and math use main-window CLIENT coordinates (matches inset envelope_bounds).
local function get_mouse_client_xy()
    local mx, my = reaper.GetMousePosition()
    if reaper.JS_Window_ScreenToClient then
        local hwnd = reaper.GetMainHwnd()
        local ok, cx, cy = reaper.JS_Window_ScreenToClient(hwnd, mx, my)
        if ok then
            return cx, cy
        end
    end
    return mx, my
end

local function is_lmb_down()
    if reaper.JS_Mouse_GetState then
        local st = reaper.JS_Mouse_GetState()
        if st and st % 2 >= 1 then
            return true
        end
    end
    return false
end

local function get_envelope_properties(envelope)
    if not envelope then return nil, nil end

    if State.cached_envelope_properties.envelope == envelope then
        return State.cached_envelope_properties.min_val, State.cached_envelope_properties.max_val
    end

    local br_env = reaper.BR_EnvAlloc(envelope, false)
    if not br_env then return nil, nil end
    local _, _, _, _, _, _, min_val, max_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)

    State.cached_envelope_properties.envelope = envelope
    State.cached_envelope_properties.min_val = min_val
    State.cached_envelope_properties.max_val = max_val

    return min_val, max_val
end


-- ===== FALLOFF CALCULATION =====
local function calculate_falloff(distance, radius, falloff_type_name, strength)
    if distance >= radius then return 0 end
    local normalized = distance / radius

    if falloff_type_name == "exponential" then
        return math.exp(-strength * 3 * normalized)
    elseif falloff_type_name == "linear" then
        return (1 - normalized) * strength
    else -- inverse_exponential
        return (1 - math.exp(-strength * 3 * (1 - normalized)))
    end
end

-- ===== COORDINATE CONVERSION =====
local function screen_to_envelope(screen_x, screen_y, envelope)
    if not envelope then return nil, nil end

    local arrange_start = State.frame_arrange_start
    local arrange_end = State.frame_arrange_end
    local bounds = State.envelope_bounds

    local pix_w = bounds.right - bounds.left
    local pix_h = bounds.bottom - bounds.top
    if pix_w <= 0 or pix_h <= 0 then return nil, nil end

    local time_ratio = (screen_x - bounds.left) / pix_w
    local project_time = arrange_start + time_ratio * (arrange_end - arrange_start)

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return nil, nil end

    local v_span = max_val - min_val
    if math.abs(v_span) < 1e-12 then
        return project_time, min_val
    end

    local normalized_y = (screen_y - bounds.top) / pix_h
    local envelope_value = max_val - (normalized_y * v_span)

    return project_time, envelope_value
end

local function envelope_to_screen(project_time, envelope_value, envelope)
    if not envelope then return nil, nil end

    local arrange_start = State.frame_arrange_start
    local arrange_end = State.frame_arrange_end
    local bounds = State.envelope_bounds

    local time_range = arrange_end - arrange_start
    local pix_w = bounds.right - bounds.left
    local pix_h = bounds.bottom - bounds.top
    if pix_w <= 0 or pix_h <= 0 then return nil, nil end

    if math.abs(time_range) < 1e-12 then
        return bounds.left, (bounds.top + bounds.bottom) * 0.5
    end

    local time_ratio = (project_time - arrange_start) / time_range
    local screen_x = bounds.left + time_ratio * pix_w

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return nil, nil end

    local v_span = max_val - min_val
    if math.abs(v_span) < 1e-12 then
        return screen_x, (bounds.top + bounds.bottom) * 0.5
    end

    local value_ratio = (max_val - envelope_value) / v_span
    local screen_y = bounds.top + value_ratio * pix_h

    return screen_x, screen_y
end

-- ===== ENVELOPE DETECTION =====
local function setup_envelope_bounds()
    if reaper.JS_Window_GetClientRect then
        local hwnd = reaper.GetMainHwnd()
        local retval, left, top, right, bottom = reaper.JS_Window_GetClientRect(hwnd)
        if retval then
            State.envelope_bounds.left = left + 50
            State.envelope_bounds.right = right - 50
            State.envelope_bounds.top = top + 150
            State.envelope_bounds.bottom = bottom - 150
            State.client_w = math.max(1, right - left)
            State.client_h = math.max(1, bottom - top)
        end
    end
end

local function validate_cached_envelope()
    if not State.cached_envelope then return false end

    local ok_name = reaper.GetEnvelopeName(State.cached_envelope)
    if not ok_name then return false end

    reaper.BR_GetMouseCursorContext()
    local envelope = reaper.BR_GetMouseCursorContext_Envelope()

    if envelope and envelope == State.cached_envelope then
        State.validation_failures = 0
        return true
    end

    if envelope and envelope ~= State.cached_envelope then
        State.cached_envelope = envelope
        State.target_envelope = envelope
        State.validation_failures = 0
        State.cached_envelope_properties.envelope = nil
        setup_envelope_bounds()
        return true
    end

    State.validation_failures = State.validation_failures + 1
    return State.validation_failures < 15
end

local function detect_envelope()
    if State.cached_envelope then
        if validate_cached_envelope() then
            return State.envelope_detected
        else
            State.cached_envelope = nil
            State.target_envelope = nil
            State.overlay_visible = false
            State.envelope_detected = false
            State.validation_failures = 0
            State.cached_envelope_properties.envelope = nil
        end
    end

    reaper.BR_GetMouseCursorContext()
    local envelope = reaper.BR_GetMouseCursorContext_Envelope()

    if envelope then
        State.cached_envelope = envelope
        State.target_envelope = envelope
        State.overlay_visible = true
        State.envelope_detected = true
        State.validation_failures = 0
        setup_envelope_bounds()
    end

    return State.envelope_detected
end

-- ===== POINT OPERATIONS =====
local function min_screen_dist_to_envelope_points(envelope, sx, sy)
    local best = math.huge
    local n = reaper.CountEnvelopePoints(envelope)
    for i = 0, n - 1 do
        local ok, t, v = reaper.GetEnvelopePoint(envelope, i)
        if ok then
            local px, py = envelope_to_screen(t, v, envelope)
            if px and py then
                local d = get_distance(sx, sy, px, py)
                if d < best then best = d end
            end
        end
    end
    return best
end

local function capture_points_in_radius(mouse_x, mouse_y, radius, envelope)
    if not envelope then return {} end

    local captured = {}
    local point_count = reaper.CountEnvelopePoints(envelope)
    local falloff_name = CONFIG.FALLOFF_TYPES[State.falloff_type]

    for i = 0, point_count - 1 do
        local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(envelope, i)
        if retval then
            local screen_x, screen_y = envelope_to_screen(time, value, envelope)
            if screen_x and screen_y then
                local distance = get_distance(mouse_x, mouse_y, screen_x, screen_y)
                if distance <= radius then
                    local f = calculate_falloff(distance, radius, falloff_name, State.falloff_strength)
                    table.insert(captured, {
                        index = i,
                        original_time = time,
                        original_value = value,
                        original_shape = shape,
                        original_tension = tension,
                        original_selected = selected,
                        falloff_strength = f
                    })
                end
            end
        end
    end

    return captured
end

--- no_sort: pass true during live drag so indices stay valid; sort once on mouse-up.
local function sculpt_captured_points(captured_points, delta_x, delta_y, envelope, no_sort)
    if not envelope or #captured_points == 0 then return 0 end

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return 0 end

    local time_range = State.frame_arrange_end - State.frame_arrange_start
    local bounds = State.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local pixel_height = bounds.bottom - bounds.top
    if pixel_width <= 0 or pixel_height <= 0 then return 0 end

    local mode_name = CONFIG.SCULPT_MODES[State.sculpt_mode] or "grab"
    local delta_time = (delta_x / pixel_width) * time_range
    local value_range = max_val - min_val
    local delta_value = -(delta_y / pixel_height) * value_range

    if State.lock_time_axis then delta_time = 0 end
    if State.lock_value_axis then delta_value = 0 end

    local points_moved = 0
    local eps_t = math.abs(time_range) * (State.brush_size / math.max(pixel_width, 1)) * 0.06
    if eps_t < 1e-9 then eps_t = 1e-6 end

    for _, point_info in ipairs(captured_points) do
        local f = point_info.falloff_strength
        local new_time = point_info.original_time
        local new_value = point_info.original_value

        if mode_name == "smooth" then
            if not State.lock_value_axis then
                local t0 = point_info.original_time
                local vm = reaper.Envelope_Evaluate(envelope, t0 - eps_t, 0, 0)
                local vp = reaper.Envelope_Evaluate(envelope, t0 + eps_t, 0, 0)
                local target_v = (vm + vp) * 0.5
                local step = clamp(State.smooth_strength, 0, 1) * f
                new_value = clamp(point_info.original_value + (target_v - point_info.original_value) * step, min_val, max_val)
            end
            if not State.lock_time_axis then
                new_time = point_info.original_time + (delta_time * f)
            end
        else
            new_time = point_info.original_time + (delta_time * f)
            new_value = clamp(point_info.original_value + (delta_value * f), min_val, max_val)
        end

        reaper.SetEnvelopePoint(envelope, point_info.index, new_time, new_value,
            point_info.original_shape, point_info.original_tension,
            point_info.original_selected, true)
        points_moved = points_moved + 1
    end

    if points_moved > 0 then
        if not no_sort then
            reaper.Envelope_SortPoints(envelope)
        end
        reaper.UpdateArrange()
    end

    return points_moved
end

local function create_points_in_brush_area(mouse_x, mouse_y, radius, envelope)
    if not envelope then return 0 end

    local center_time, center_value = screen_to_envelope(mouse_x, mouse_y, envelope)
    if not center_time then return 0 end

    local arrange_start = State.frame_arrange_start
    local arrange_end = State.frame_arrange_end
    local time_range = arrange_end - arrange_start
    local bounds = State.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    if pixel_width <= 0 then return 0 end

    local radius_time = (radius / pixel_width) * time_range
    local falloff_name = CONFIG.FALLOFF_TYPES[State.falloff_type]

    local optimal_point_count = math.max(3, math.min(8, math.floor(radius / 15)))
    local points_created = 0
    local start_time = center_time - radius_time

    local denom = optimal_point_count - 1
    if denom < 1 then denom = 1 end

    for i = 0, optimal_point_count - 1 do
        local progress = i / denom
        local point_time = start_time + progress * (radius_time * 2)

        local time_distance = math.abs(point_time - center_time)
        local normalized_distance = radius_time > 1e-12 and (time_distance / radius_time) or 0

        if normalized_distance <= 1.0 then
            local base_value = reaper.Envelope_Evaluate(envelope, point_time, 0, 0)
            local sx, sy = envelope_to_screen(point_time, base_value, envelope)
            if sx and sy then
                local d_screen = get_distance(mouse_x, mouse_y, sx, sy)
                local w = calculate_falloff(d_screen, radius, falloff_name, State.falloff_strength)
                local new_value = base_value + (center_value - base_value) * w

                if min_screen_dist_to_envelope_points(envelope, sx, sy) >= CONFIG.MIN_POINT_SPACING_PIXELS then
                    local ins = reaper.InsertEnvelopePoint(envelope, point_time, new_value, 0, 0, false, true)
                    local inserted = (type(ins) == "number" and ins >= 0) or (ins == true)
                    if inserted then
                        points_created = points_created + 1
                    end
                end
            end
        end
    end

    if points_created > 0 then
        reaper.Envelope_SortPoints(envelope)
        reaper.UpdateArrange()
    end

    return points_created
end

-- ===== RENDERING =====
local function draw_dashed_circle(draw_list, center_x, center_y, radius, color, thickness)
    local DASH_SEGMENTS = 24
    local DASH_RATIO = 0.6
    local angle_step = (2 * math.pi) / DASH_SEGMENTS
    local dash_length = angle_step * DASH_RATIO

    for i = 0, DASH_SEGMENTS - 1 do
        local start_angle = i * angle_step
        local end_angle = start_angle + dash_length

        reaper.ImGui_DrawList_PathArcTo(draw_list, center_x, center_y, radius, start_angle, end_angle)
        reaper.ImGui_DrawList_PathStroke(draw_list, color, 0, thickness)
    end
end

local function render_brush_overlay(client_mouse_x, client_mouse_y)
    if not State.overlay_visible or not State.ctx then return end

    local mouse_x, mouse_y = client_mouse_x, client_mouse_y
    local radius = State.brush_size

    reaper.ImGui_SetNextWindowPos(State.ctx, 0, 0)
    reaper.ImGui_SetNextWindowSize(State.ctx, State.client_w, State.client_h)

    local window_flags = reaper.ImGui_WindowFlags_NoTitleBar() |
        reaper.ImGui_WindowFlags_NoResize() |
        reaper.ImGui_WindowFlags_NoMove() |
        reaper.ImGui_WindowFlags_NoScrollbar() |
        reaper.ImGui_WindowFlags_NoCollapse() |
        reaper.ImGui_WindowFlags_NoBackground() |
        reaper.ImGui_WindowFlags_NoMouseInputs() |
        reaper.ImGui_WindowFlags_NoDecoration() |
        reaper.ImGui_WindowFlags_NoFocusOnAppearing() |
        reaper.ImGui_WindowFlags_NoSavedSettings()

    reaper.ImGui_PushStyleVar(State.ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    reaper.ImGui_PushStyleVar(State.ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)
    reaper.ImGui_PushStyleColor(State.ctx, reaper.ImGui_Col_WindowBg(), 0x00000000)

    local visible = reaper.ImGui_Begin(State.ctx, "Brush Overlay", true, window_flags)

    if visible then
        local draw_list = reaper.ImGui_GetWindowDrawList(State.ctx)

        if draw_list then
            draw_dashed_circle(draw_list, mouse_x, mouse_y, radius, CONFIG.OUTER_CIRCLE_COLOR, CONFIG.CIRCLE_THICKNESS)

            local inner_radius = radius * CONFIG.INNER_CIRCLE_RATIO
            draw_dashed_circle(draw_list, mouse_x, mouse_y, inner_radius, CONFIG.INNER_CIRCLE_COLOR, CONFIG.CIRCLE_THICKNESS - 1)

            reaper.ImGui_DrawList_AddCircleFilled(draw_list, mouse_x, mouse_y, 3, 0xFF00FFFF)

            local mode_label = State.add_points_mode and "add" or (CONFIG.SCULPT_MODES[State.sculpt_mode] or "grab")
            local text_x = mouse_x + radius + 10
            reaper.ImGui_DrawList_AddText(draw_list, text_x, mouse_y - 40, 0xFFFFFFFF, mode_label)
            reaper.ImGui_DrawList_AddText(draw_list, text_x, mouse_y - 20, 0xFFFFFFFF, CONFIG.FALLOFF_TYPES[State.falloff_type])
            reaper.ImGui_DrawList_AddText(draw_list, text_x, mouse_y, 0xFFFFFFFF, "Size: " .. State.brush_size)
        end

        reaper.ImGui_End(State.ctx)
    end

    reaper.ImGui_PopStyleColor(State.ctx, 1)
    reaper.ImGui_PopStyleVar(State.ctx, 2)
end

-- ===== INPUT HANDLING =====
local function handle_wheel_input()
    if not State.ctx then return false end

    local wheel_delta = reaper.ImGui_GetMouseWheel(State.ctx)
    if wheel_delta ~= 0 then
        local shift_held = reaper.ImGui_IsKeyDown(State.ctx, reaper.ImGui_Key_LeftShift())

        if shift_held then
            State.falloff_strength = clamp(State.falloff_strength + (wheel_delta > 0 and CONFIG.FALLOFF_STRENGTH_STEP or -CONFIG.FALLOFF_STRENGTH_STEP),
                CONFIG.MIN_FALLOFF_STRENGTH, CONFIG.MAX_FALLOFF_STRENGTH)
        else
            State.brush_size = clamp(State.brush_size + (wheel_delta > 0 and CONFIG.BRUSH_SIZE_STEP or -CONFIG.BRUSH_SIZE_STEP),
                CONFIG.MIN_BRUSH_SIZE, CONFIG.MAX_BRUSH_SIZE)
        end
        return true
    end

    return false
end

local function handle_keyboard_input()
    if not State.ctx then return false end

    if reaper.ImGui_IsKeyPressed(State.ctx, reaper.ImGui_Key_Tab()) then
        State.falloff_type = State.falloff_type + 1
        if State.falloff_type > #CONFIG.FALLOFF_TYPES then
            State.falloff_type = 1
        end
        return true
    end

    return false
end

local function end_drag_operation()
    if not State.is_dragging then return end

    State.is_dragging = false
    State.captured_points = {}
    State.last_create_client = nil
    State.manual_sculpt_active = false
    State.sculpt_last_client = nil

    if State.sculpt_sort_pending and State.target_envelope then
        reaper.Envelope_SortPoints(State.target_envelope)
        reaper.UpdateArrange()
        State.sculpt_sort_pending = false
    end

    if State.undo_active then
        reaper.Undo_EndBlock(State.undo_operation_name, -1)
        State.undo_active = false
        State.undo_operation_name = ""
    end
end

local function begin_undo_once(name)
    if not State.undo_active then
        reaper.Undo_BeginBlock()
        State.undo_active = true
        State.undo_operation_name = name
    end
end

local function refresh_captured_from_envelope(envelope)
    for _, p in ipairs(State.captured_points) do
        local ok, t, v, shape, tension, sel = reaper.GetEnvelopePoint(envelope, p.index)
        if ok then
            p.original_time = t
            p.original_value = v
            p.original_shape = shape
            p.original_tension = tension
            p.original_selected = sel
        end
    end
end

local function try_apply_sculpt_drag(mx, my)
    if not State.target_envelope or State.drag_mode ~= "sculpt" then return end
    if #State.captured_points == 0 then return end

    if not State.sculpt_last_client then
        State.sculpt_last_client = { x = State.drag_start_pos.x, y = State.drag_start_pos.y }
    end

    local dx = mx - State.sculpt_last_client.x
    local dy = my - State.sculpt_last_client.y
    if math.sqrt(dx * dx + dy * dy) < CONFIG.MIN_MOVEMENT_THRESHOLD then
        return
    end

    local undo_name = (CONFIG.SCULPT_MODES[State.sculpt_mode] == "smooth") and "Brush Smooth Envelope" or "Brush Sculpt Envelope"
    begin_undo_once(undo_name)
    sculpt_captured_points(State.captured_points, dx, dy, State.target_envelope, true)
    refresh_captured_from_envelope(State.target_envelope)
    State.sculpt_last_client = { x = mx, y = my }
    State.sculpt_sort_pending = true
end

local function try_apply_add_drag(mx, my)
    if not State.target_envelope or State.drag_mode ~= "add" then return end

    if State.last_create_client then
        if get_distance(mx, my, State.last_create_client.x, State.last_create_client.y) < CONFIG.MIN_POINT_SPACING_PIXELS then
            return
        end
    end

    begin_undo_once("Brush Add Envelope Points")
    local n = create_points_in_brush_area(mx, my, State.brush_size, State.target_envelope)
    if n > 0 then
        State.last_create_client = { x = mx, y = my }
    end
end

local function on_lmb_pressed(mx, my)
    if not State.target_envelope or not State.envelope_detected then return end

    State.manual_sculpt_active = false
    State.is_dragging = true
    State.drag_start_pos = { x = mx, y = my }
    State.last_create_client = nil
    State.sculpt_sort_pending = false
    State.sculpt_last_client = { x = mx, y = my }

    if State.add_points_mode then
        State.drag_mode = "add"
        local n = create_points_in_brush_area(mx, my, State.brush_size, State.target_envelope)
        if n > 0 then
            reaper.Undo_BeginBlock()
            State.undo_active = true
            State.undo_operation_name = "Brush Add Envelope Points"
            State.last_create_client = { x = mx, y = my }
        end
    else
        State.drag_mode = "sculpt"
        State.captured_points = capture_points_in_radius(mx, my, State.brush_size, State.target_envelope)
    end
end

-- Manual test functions
local function manual_start_sculpt()
    if not State.target_envelope then return end

    local mouse_x, mouse_y = get_mouse_client_xy()
    State.is_dragging = true
    State.drag_start_pos = { x = mouse_x, y = mouse_y }
    State.drag_mode = "sculpt"
    State.sculpt_sort_pending = false
    State.last_create_client = nil
    State.manual_sculpt_active = true
    State.sculpt_last_client = { x = mouse_x, y = mouse_y }

    State.captured_points = capture_points_in_radius(mouse_x, mouse_y, State.brush_size, State.target_envelope)
    if #State.captured_points > 0 then
        reaper.Undo_BeginBlock()
        State.undo_active = true
        State.undo_operation_name = (CONFIG.SCULPT_MODES[State.sculpt_mode] == "smooth") and "Brush Smooth Envelope" or "Brush Sculpt Envelope"
    end
end

local function manual_end_operation()
    end_drag_operation()
end

-- ===== GUI =====
local function draw_control_window()
    if not State.ctx then return false end

    local visible, open = reaper.ImGui_Begin(State.ctx, "Brush Envelope Editor", true)

    if visible then
        reaper.ImGui_Text(State.ctx, "Brush Envelope Editor")
        reaper.ImGui_Separator(State.ctx)

        local size_changed, new_size = reaper.ImGui_SliderInt(State.ctx, "Brush Size", State.brush_size, CONFIG.MIN_BRUSH_SIZE, CONFIG.MAX_BRUSH_SIZE)
        if size_changed then State.brush_size = new_size end

        local strength_changed, new_strength = reaper.ImGui_SliderDouble(State.ctx, "Falloff Strength", State.falloff_strength, CONFIG.MIN_FALLOFF_STRENGTH, CONFIG.MAX_FALLOFF_STRENGTH, "%.1f")
        if strength_changed then State.falloff_strength = new_strength end

        local falloff_names = table.concat(CONFIG.FALLOFF_TYPES, "\0") .. "\0"
        local falloff_changed, new_falloff = reaper.ImGui_Combo(State.ctx, "Falloff Type", State.falloff_type - 1, falloff_names)
        if falloff_changed then State.falloff_type = new_falloff + 1 end

        local sculpt_names = table.concat(CONFIG.SCULPT_MODES, "\0") .. "\0"
        local sculpt_changed, new_sculpt = reaper.ImGui_Combo(State.ctx, "Sculpt mode", State.sculpt_mode - 1, sculpt_names)
        if sculpt_changed then State.sculpt_mode = new_sculpt + 1 end

        local sm = CONFIG.SCULPT_MODES[State.sculpt_mode] or "grab"
        if sm == "smooth" then
            local sm_ch, sm_v = reaper.ImGui_SliderDouble(State.ctx, "Smooth strength", State.smooth_strength, CONFIG.MIN_SMOOTH_STRENGTH, CONFIG.MAX_SMOOTH_STRENGTH, "%.2f")
            if sm_ch then State.smooth_strength = sm_v end
        end

        _, State.lock_time_axis = reaper.ImGui_Checkbox(State.ctx, "Lock time (horizontal)", State.lock_time_axis)
        _, State.lock_value_axis = reaper.ImGui_Checkbox(State.ctx, "Lock value (vertical)", State.lock_value_axis)

        local add_changed, add_val = reaper.ImGui_Checkbox(State.ctx, "Add points (LMB drag)", State.add_points_mode)
        if add_changed then State.add_points_mode = add_val end

        reaper.ImGui_Separator(State.ctx)

        reaper.ImGui_Text(State.ctx, "Manual Controls:")
        if reaper.ImGui_Button(State.ctx, "Start Sculpt Test") then
            manual_start_sculpt()
        end
        reaper.ImGui_SameLine(State.ctx)
        if reaper.ImGui_Button(State.ctx, "End Operation") then
            manual_end_operation()
        end

        if reaper.ImGui_Button(State.ctx, "Create Points at Mouse") then
            if State.target_envelope then
                local mouse_x, mouse_y = get_mouse_client_xy()
                reaper.Undo_BeginBlock()
                local created = create_points_in_brush_area(mouse_x, mouse_y, State.brush_size, State.target_envelope)
                reaper.Undo_EndBlock(created > 0 and "Create Points at Mouse" or "Create Points (no change)", -1)
            end
        end

        reaper.ImGui_Separator(State.ctx)
        reaper.ImGui_Text(State.ctx, "Instructions:")
        reaper.ImGui_BulletText(State.ctx, "Hover over envelope lanes to target a lane")
        reaper.ImGui_BulletText(State.ctx, "LMB drag on main window: sculpt (or add if checkbox on)")
        if not reaper.JS_Mouse_GetState then
            reaper.ImGui_BulletText(State.ctx, "Install ReaJS for LMB drag (or use manual buttons)")
        end
        reaper.ImGui_BulletText(State.ctx, "Scroll: brush size; Shift+Scroll: falloff strength")
        reaper.ImGui_BulletText(State.ctx, "Tab: cycle falloff types")
        reaper.ImGui_BulletText(State.ctx, "Grab: move points; Smooth: relax toward local average (falloff-weighted)")
        reaper.ImGui_BulletText(State.ctx, "Axis locks: edit only time or only value")

        reaper.ImGui_Separator(State.ctx)

        local mouse_x, mouse_y = get_mouse_client_xy()
        reaper.ImGui_Text(State.ctx, string.format("Mouse (client): %d, %d", mouse_x, mouse_y))
        reaper.ImGui_Text(State.ctx, string.format("Overlay Visible: %s", tostring(State.overlay_visible)))
        reaper.ImGui_Text(State.ctx, string.format("Envelope Detected: %s", tostring(State.envelope_detected)))

        if State.target_envelope then
            reaper.ImGui_Text(State.ctx, "Status: Envelope detected")
            local _, env_name = reaper.GetEnvelopeName(State.target_envelope)
            reaper.ImGui_Text(State.ctx, "Envelope: " .. (env_name or "Unknown"))

            if State.is_dragging then
                reaper.ImGui_Text(State.ctx, string.format("Mode: %s (%d pts)", State.drag_mode, #State.captured_points))
            end
        else
            reaper.ImGui_Text(State.ctx, "Status: No envelope under cursor")
        end

        reaper.ImGui_End(State.ctx)
    end

    return open
end

-- ===== MAIN APPLICATION =====
local function init()
    if not reaper.ImGui_CreateContext then
        reaper.ShowMessageBox("This script requires ReaImGui.", "Missing ReaImGui", 0)
        return false
    end

    if not reaper.BR_GetMouseCursorContext then
        reaper.ShowMessageBox("This script requires the SWS extension.", "Missing SWS Extension", 0)
        return false
    end

    State.ctx = reaper.ImGui_CreateContext('Brush Envelope Editor')
    setup_envelope_bounds()
    return true
end

local function main_loop()
    refresh_frame_arrange()

    local mouse_x, mouse_y = get_mouse_client_xy()
    State.mouse_pos = { x = mouse_x, y = mouse_y }

    detect_envelope()

    local lmb = is_lmb_down()
    local js_mouse = (reaper.JS_Mouse_GetState ~= nil)

    if State.is_dragging and State.drag_mode == "sculpt" and #State.captured_points > 0 then
        local apply_sculpt = State.manual_sculpt_active or (js_mouse and lmb) or not js_mouse
        if apply_sculpt then
            try_apply_sculpt_drag(mouse_x, mouse_y)
        end
    end

    if js_mouse then
        if lmb and State.envelope_detected and State.target_envelope then
            if not State.is_dragging then
                on_lmb_pressed(mouse_x, mouse_y)
            elseif State.add_points_mode then
                try_apply_add_drag(mouse_x, mouse_y)
            end
        elseif not lmb and State.is_dragging and not State.manual_sculpt_active then
            end_drag_operation()
        end
    end

    if State.overlay_visible then
        handle_wheel_input()
        handle_keyboard_input()
    end

    render_brush_overlay(mouse_x, mouse_y)

    local open = draw_control_window()

    if open then
        reaper.defer(main_loop)
    else
        if State.undo_active then
            if State.sculpt_sort_pending and State.target_envelope then
                reaper.Envelope_SortPoints(State.target_envelope)
            end
            reaper.Undo_EndBlock(State.undo_operation_name, -1)
        end
    end
end

-- ===== SCRIPT ENTRY POINT =====
if init() then
    reaper.defer(main_loop)
end
