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
    DEFAULT_FALLOFF_STRENGTH = 1.0,
    MIN_FALLOFF_STRENGTH = 0.1,
    MAX_FALLOFF_STRENGTH = 3.0,
    FALLOFF_STRENGTH_STEP = 0.1,
    INNER_CIRCLE_RATIO = 0.5,
    OUTER_CIRCLE_COLOR = 0xFFFFFFCC,
    INNER_CIRCLE_COLOR = 0xFFFFFF66,
    CIRCLE_THICKNESS = 2.0,
    MIN_MOVEMENT_THRESHOLD = 0.5,
}

-- ===== STATE =====
local State = {
    -- Brush settings
    brush_size = CONFIG.DEFAULT_BRUSH_SIZE,
    falloff_type = 1,
    falloff_strength = CONFIG.DEFAULT_FALLOFF_STRENGTH,
    
    -- Mouse and interaction
    mouse_pos = {x = 0, y = 0},
    last_mouse_pos = {x = 0, y = 0},
    is_dragging = false,
    drag_mode = "sculpt",
    drag_start_pos = {x = 0, y = 0},
    captured_points = {},
    
    -- Envelope context
    target_envelope = nil,
    envelope_bounds = {top = 150, bottom = 600, left = 200, right = 1200},
    overlay_visible = false,
    cached_envelope = nil,
    envelope_detected = false,
    validation_failures = 0,
    
    -- Undo system
    undo_active = false,
    undo_operation_name = "",
    
    -- ImGui
    ctx = nil,
    
}

-- ===== UTILITIES =====
local function get_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

local function clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
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
    
    local arrange_start, arrange_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    local bounds = State.envelope_bounds
    
    -- Convert screen X to project time
    local time_ratio = (screen_x - bounds.left) / (bounds.right - bounds.left)
    local project_time = arrange_start + time_ratio * (arrange_end - arrange_start)
    
    -- Get envelope properties
    local br_env = reaper.BR_EnvAlloc(envelope, false)
    if not br_env then return nil, nil end
    local active, visible, armed, in_lane, lane_height, default_shape, min_val, max_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)
    
    -- Convert screen Y to envelope value
    local envelope_range = bounds.bottom - bounds.top
    local normalized_y = (screen_y - bounds.top) / envelope_range
    local envelope_value = max_val - (normalized_y * (max_val - min_val))
    
    return project_time, envelope_value
end

local function envelope_to_screen(project_time, envelope_value, envelope)
    if not envelope then return nil, nil end
    
    local arrange_start, arrange_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    local bounds = State.envelope_bounds
    
    -- Convert project time to screen X
    local time_ratio = (project_time - arrange_start) / (arrange_end - arrange_start)
    local screen_x = bounds.left + time_ratio * (bounds.right - bounds.left)
    
    -- Get envelope properties
    local br_env = reaper.BR_EnvAlloc(envelope, false)
    if not br_env then return nil, nil end
    local active, visible, armed, in_lane, lane_height, default_shape, min_val, max_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)
    
    -- Convert envelope value to screen Y
    local value_ratio = (max_val - envelope_value) / (max_val - min_val)
    local screen_y = bounds.top + value_ratio * (bounds.bottom - bounds.top)
    
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
        end
    end
end

local function validate_cached_envelope()
    if not State.cached_envelope then return false end
    
    -- Check if envelope still exists in project
    local retval, env_name = reaper.GetEnvelopeName(State.cached_envelope)
    if not retval then return false end
    
    -- Quick check: is mouse still over envelope area
    local window, segment, details = reaper.BR_GetMouseCursorContext()
    local envelope, istakeEnvelope = reaper.BR_GetMouseCursorContext_Envelope()
    
    -- Check if we're still over the same envelope
    local still_valid = (envelope == State.cached_envelope)
    
    if still_valid then
        State.validation_failures = 0  -- Reset failure count on success
        return true
    else
        State.validation_failures = State.validation_failures + 1
        -- Only invalidate after multiple consecutive failures (tolerance)
        return State.validation_failures < 3
    end
end

local function detect_envelope()
    -- If we have a cached envelope, validate it first
    if State.cached_envelope then
        if validate_cached_envelope() then
            -- Cache is valid, maintain current state
            return State.envelope_detected
        else
            -- Cache invalid after multiple failures, clear envelope state
            State.cached_envelope = nil
            State.target_envelope = nil
            State.overlay_visible = false
            State.envelope_detected = false
            State.validation_failures = 0
        end
    end
    
    -- No cached envelope or cache was invalid - detect new one
    local window, segment, details = reaper.BR_GetMouseCursorContext()
    local envelope, istakeEnvelope = reaper.BR_GetMouseCursorContext_Envelope()
    
    local envelope_found = (envelope ~= nil)
    
    if envelope_found then
        -- Cache the new envelope
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
                    local falloff_strength = calculate_falloff(distance, radius, falloff_name, State.falloff_strength)
                    table.insert(captured, {
                        index = i,
                        original_time = time,
                        original_value = value,
                        original_shape = shape,
                        original_tension = tension,
                        original_selected = selected,
                        falloff_strength = falloff_strength
                    })
                end
            end
        end
    end
    
    return captured
end

local function sculpt_captured_points(captured_points, delta_x, delta_y, envelope)
    if not envelope or #captured_points == 0 then return 0 end
    
    -- Get envelope properties
    local br_env = reaper.BR_EnvAlloc(envelope, false)
    if not br_env then return 0 end
    local active, visible, armed, in_lane, lane_height, default_shape, min_val, max_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)
    
    -- Convert pixel deltas to time/value deltas
    local arrange_start, arrange_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    local time_range = arrange_end - arrange_start
    local bounds = State.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local delta_time = (delta_x / pixel_width) * time_range
    
    local value_range = max_val - min_val
    local pixel_height = bounds.bottom - bounds.top
    local delta_value = -(delta_y / pixel_height) * value_range
    
    local points_moved = 0
    
    for _, point_info in ipairs(captured_points) do
        local new_time = point_info.original_time + (delta_time * point_info.falloff_strength)
        local new_value = clamp(point_info.original_value + (delta_value * point_info.falloff_strength), min_val, max_val)
        
        reaper.SetEnvelopePoint(envelope, point_info.index, new_time, new_value, 
                               point_info.original_shape, point_info.original_tension, 
                               point_info.original_selected, true)
        points_moved = points_moved + 1
    end
    
    if points_moved > 0 then
        reaper.Envelope_SortPoints(envelope)
        reaper.UpdateArrange()
    end
    
    return points_moved
end

local function create_points_in_brush_area(mouse_x, mouse_y, radius, envelope)
    if not envelope then return 0 end
    
    local center_time, center_value = screen_to_envelope(mouse_x, mouse_y, envelope)
    if not center_time then return 0 end
    
    -- Calculate time range covered by brush radius
    local arrange_start, arrange_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    local time_range = arrange_end - arrange_start
    local bounds = State.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local radius_time = (radius / pixel_width) * time_range
    
    -- Determine optimal number of points
    local optimal_point_count = math.max(3, math.min(8, math.floor(radius / 15)))
    
    local points_created = 0
    local start_time = center_time - radius_time
    local end_time = center_time + radius_time
    
    for i = 0, optimal_point_count - 1 do
        local progress = i / (optimal_point_count - 1)
        local point_time = start_time + progress * (radius_time * 2)
        
        local time_distance = math.abs(point_time - center_time)
        local normalized_distance = time_distance / radius_time
        
        if normalized_distance <= 1.0 then
            local current_value = reaper.Envelope_Evaluate(envelope, point_time, 0, 0)
            local point_index = reaper.InsertEnvelopePoint(envelope, point_time, current_value, 0, 0, false, true)
            
            if point_index ~= -1 then
                points_created = points_created + 1
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

local function render_brush_overlay()
    if not State.overlay_visible or not State.ctx then return end
    
    -- Use ImGui mouse position for proper coordinate system
    local mouse_x, mouse_y = reaper.ImGui_GetMousePos(State.ctx)
    local radius = State.brush_size
    
    -- Create a fullscreen transparent overlay that doesn't capture input
    reaper.ImGui_SetNextWindowPos(State.ctx, 0, 0)
    reaper.ImGui_SetNextWindowSize(State.ctx, 2000, 2000)
    
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
    -- Fix: Use a single transparent color value instead of separate RGBA components
    reaper.ImGui_PushStyleColor(State.ctx, reaper.ImGui_Col_WindowBg(), 0x00000000)
    
    local visible, open = reaper.ImGui_Begin(State.ctx, "Brush Overlay", true, window_flags)
    
    if visible then
        local draw_list = reaper.ImGui_GetWindowDrawList(State.ctx)
        
        if draw_list then
            -- Draw outer circle
            draw_dashed_circle(draw_list, mouse_x, mouse_y, radius, CONFIG.OUTER_CIRCLE_COLOR, CONFIG.CIRCLE_THICKNESS)
            
            -- Draw inner circle
            local inner_radius = radius * CONFIG.INNER_CIRCLE_RATIO
            draw_dashed_circle(draw_list, mouse_x, mouse_y, inner_radius, CONFIG.INNER_CIRCLE_COLOR, CONFIG.CIRCLE_THICKNESS - 1)
            
            -- Center dot
            reaper.ImGui_DrawList_AddCircleFilled(draw_list, mouse_x, mouse_y, 3, 0xFF00FFFF)
            
            -- Labels
            local text_x = mouse_x + radius + 10
            reaper.ImGui_DrawList_AddText(draw_list, text_x, mouse_y - 20, 0xFFFFFFFF, CONFIG.FALLOFF_TYPES[State.falloff_type])
            reaper.ImGui_DrawList_AddText(draw_list, text_x, mouse_y, 0xFFFFFFFF, "Size: " .. State.brush_size)
        end
        
        reaper.ImGui_End(State.ctx)
    end
    
    reaper.ImGui_PopStyleColor(State.ctx, 1)  -- Pop the style color we pushed
    reaper.ImGui_PopStyleVar(State.ctx, 2)  -- Pop the 2 style vars we pushed
end

-- ===== INPUT HANDLING =====
local function handle_wheel_input()
    if not State.ctx then return false end
    
    local wheel_delta = reaper.ImGui_GetMouseWheel(State.ctx)
    if wheel_delta ~= 0 then
        local shift_held = reaper.ImGui_IsKeyDown(State.ctx, reaper.ImGui_Key_LeftShift())
        
        if shift_held then
            -- Change falloff strength
            State.falloff_strength = clamp(State.falloff_strength + (wheel_delta > 0 and CONFIG.FALLOFF_STRENGTH_STEP or -CONFIG.FALLOFF_STRENGTH_STEP), 
                                         CONFIG.MIN_FALLOFF_STRENGTH, CONFIG.MAX_FALLOFF_STRENGTH)
        else
            -- Change brush size
            State.brush_size = clamp(State.brush_size + (wheel_delta > 0 and CONFIG.BRUSH_SIZE_STEP or -CONFIG.BRUSH_SIZE_STEP), 
                                   CONFIG.MIN_BRUSH_SIZE, CONFIG.MAX_BRUSH_SIZE)
        end
        return true  -- Input consumed
    end
    
    return false  -- Input not consumed
end

local function handle_keyboard_input()
    if not State.ctx then return false end
    
    -- Check for falloff type switching with Tab
    if reaper.ImGui_IsKeyPressed(State.ctx, reaper.ImGui_Key_Tab()) then
        State.falloff_type = State.falloff_type + 1
        if State.falloff_type > #CONFIG.FALLOFF_TYPES then
            State.falloff_type = 1
        end
        return true  -- Input consumed
    end
    
    return false  -- Input not consumed
end

-- Manual test functions
local function manual_start_sculpt()
    if not State.target_envelope then return end
    
    local mouse_x, mouse_y = reaper.GetMousePosition()
    State.is_dragging = true
    State.drag_start_pos = {x = mouse_x, y = mouse_y}
    State.drag_mode = "sculpt"
    
    State.captured_points = capture_points_in_radius(mouse_x, mouse_y, State.brush_size, State.target_envelope)
    if #State.captured_points > 0 then
        reaper.Undo_BeginBlock()
        State.undo_active = true
        State.undo_operation_name = "Brush Sculpt Envelope"
    end
end

local function manual_end_operation()
    if State.is_dragging then
        State.is_dragging = false
        State.captured_points = {}
        
        if State.undo_active then
            reaper.Undo_EndBlock(State.undo_operation_name, -1)
            State.undo_active = false
            State.undo_operation_name = ""
        end
    end
end

-- ===== GUI =====
local function draw_control_window()
    if not State.ctx then return false end
    
    local visible, open = reaper.ImGui_Begin(State.ctx, "Brush Envelope Editor", true)
    
    if visible then
        reaper.ImGui_Text(State.ctx, "Brush Envelope Editor")
        reaper.ImGui_Separator(State.ctx)
        
        -- Brush size slider
        local size_changed, new_size = reaper.ImGui_SliderInt(State.ctx, "Brush Size", State.brush_size, CONFIG.MIN_BRUSH_SIZE, CONFIG.MAX_BRUSH_SIZE)
        if size_changed then State.brush_size = new_size end
        
        -- Falloff strength slider
        local strength_changed, new_strength = reaper.ImGui_SliderDouble(State.ctx, "Falloff Strength", State.falloff_strength, CONFIG.MIN_FALLOFF_STRENGTH, CONFIG.MAX_FALLOFF_STRENGTH, "%.1f")
        if strength_changed then State.falloff_strength = new_strength end
        
        -- Falloff type combo
        local falloff_names = table.concat(CONFIG.FALLOFF_TYPES, "\0") .. "\0"
        local falloff_changed, new_falloff = reaper.ImGui_Combo(State.ctx, "Falloff Type", State.falloff_type - 1, falloff_names)
        if falloff_changed then State.falloff_type = new_falloff + 1 end
        
        reaper.ImGui_Separator(State.ctx)
        
        -- Manual test buttons
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
                local mouse_x, mouse_y = reaper.GetMousePosition()
                reaper.Undo_BeginBlock()
                local created = create_points_in_brush_area(mouse_x, mouse_y, State.brush_size, State.target_envelope)
                reaper.Undo_EndBlock("Create Points Test", -1)
            end
        end
        
        reaper.ImGui_Separator(State.ctx)
        reaper.ImGui_Text(State.ctx, "Instructions:")
        reaper.ImGui_BulletText(State.ctx, "Hover over envelope lanes")
        reaper.ImGui_BulletText(State.ctx, "Use manual buttons to test")
        reaper.ImGui_BulletText(State.ctx, "Scroll to resize brush")
        reaper.ImGui_BulletText(State.ctx, "Shift+Scroll to change falloff strength")
        reaper.ImGui_BulletText(State.ctx, "Tab to cycle falloff types")
        
        -- Status
        reaper.ImGui_Separator(State.ctx)
        
        -- Debug info
        local mouse_x, mouse_y = reaper.GetMousePosition()
        reaper.ImGui_Text(State.ctx, string.format("Mouse: %d, %d", mouse_x, mouse_y))
        reaper.ImGui_Text(State.ctx, string.format("Overlay Visible: %s", tostring(State.overlay_visible)))
        reaper.ImGui_Text(State.ctx, string.format("Envelope Detected: %s", tostring(State.envelope_detected)))
        reaper.ImGui_Text(State.ctx, string.format("Cached Envelope: %s", tostring(State.cached_envelope ~= nil)))
        
        
        if State.target_envelope then
            reaper.ImGui_Text(State.ctx, "Status: Envelope detected ✓")
            local retval, env_name = reaper.GetEnvelopeName(State.target_envelope)
            reaper.ImGui_Text(State.ctx, "Envelope: " .. (env_name or "Unknown"))
            
            if State.is_dragging then
                reaper.ImGui_Text(State.ctx, string.format("Mode: %s (%d points)", State.drag_mode, #State.captured_points))
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
    -- Update mouse position (use raw coordinates for REAPER functions)
    local mouse_x, mouse_y = reaper.GetMousePosition()
    State.last_mouse_pos = {x = State.mouse_pos.x, y = State.mouse_pos.y}
    State.mouse_pos = {x = mouse_x, y = mouse_y}
    
    -- Detect envelope
    detect_envelope()
    
    -- Handle input and consume it if we use it
    local input_consumed = false
    if State.overlay_visible then
        input_consumed = handle_wheel_input() or handle_keyboard_input()
    end
    
    -- Render brush overlay
    render_brush_overlay()
    
    -- Draw control window
    local open = draw_control_window()
    
    if open then
        reaper.defer(main_loop)
    else
        -- Cleanup
        if State.undo_active then
            reaper.Undo_EndBlock(State.undo_operation_name, -1)
        end
    end
end

-- ===== SCRIPT ENTRY POINT =====
if init() then
    reaper.defer(main_loop)
end