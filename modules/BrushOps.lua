local M = {}

function M.min_screen_dist_to_envelope_points(envelope, sx, sy, envelope_to_screen, get_distance)
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

function M.capture_points_in_radius(state, config, mouse_x, mouse_y, radius, envelope, envelope_to_screen, get_distance, calculate_falloff)
    if not envelope then return {} end

    local captured = {}
    local point_count = reaper.CountEnvelopePoints(envelope)
    local falloff_name = config.FALLOFF_TYPES[state.falloff_type]

    for i = 0, point_count - 1 do
        local retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(envelope, i)
        if retval then
            local screen_x, screen_y = envelope_to_screen(time, value, envelope)
            if screen_x and screen_y then
                local distance = get_distance(mouse_x, mouse_y, screen_x, screen_y)
                if distance <= radius then
                    local f = calculate_falloff(distance, radius, falloff_name, state.falloff_strength)
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

function M.sculpt_captured_points(state, config, captured_points, delta_x, delta_y, envelope, no_sort, get_envelope_properties, clamp)
    if not envelope or #captured_points == 0 then return 0 end

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return 0 end

    local time_range = state.frame_arrange_end - state.frame_arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local pixel_height = bounds.bottom - bounds.top
    if pixel_width <= 0 or pixel_height <= 0 then return 0 end

    local mode_name = config.SCULPT_MODES[state.sculpt_mode] or "grab"
    local power = state.sculpt_power or 1.0
    local delta_time = (delta_x / pixel_width) * time_range * power
    local value_range = max_val - min_val
    local delta_value = -(delta_y / pixel_height) * value_range * power

    if state.lock_time_axis then delta_time = 0 end
    if state.lock_value_axis then delta_value = 0 end

    local points_moved = 0
    local eps_t = math.abs(time_range) * (state.brush_size / math.max(pixel_width, 1)) * 0.06
    if eps_t < 1e-9 then eps_t = 1e-6 end

    for _, point_info in ipairs(captured_points) do
        local f = point_info.falloff_strength
        local new_time = point_info.original_time
        local new_value = point_info.original_value

        if mode_name == "smooth" then
            if not state.lock_value_axis then
                local t0 = point_info.original_time
                local vm = reaper.Envelope_Evaluate(envelope, t0 - eps_t, 0, 0)
                local vp = reaper.Envelope_Evaluate(envelope, t0 + eps_t, 0, 0)
                local target_v = (vm + vp) * 0.5
                local step = clamp(state.smooth_strength, 0, 1) * f * power
                new_value = clamp(point_info.original_value + (target_v - point_info.original_value) * step, min_val, max_val)
            end
            if not state.lock_time_axis then
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

function M.create_points_in_brush_area(state, config, mouse_x, mouse_y, radius, envelope, screen_to_envelope, envelope_to_screen, get_distance, calculate_falloff)
    if not envelope then return 0 end

    local center_time, center_value = screen_to_envelope(mouse_x, mouse_y, envelope)
    if not center_time then return 0 end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local time_range = arrange_end - arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    if pixel_width <= 0 then return 0 end

    local radius_time = (radius / pixel_width) * time_range
    local falloff_name = config.FALLOFF_TYPES[state.falloff_type]

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
                local w = calculate_falloff(d_screen, radius, falloff_name, state.falloff_strength)
                local new_value = base_value + (center_value - base_value) * w

                if M.min_screen_dist_to_envelope_points(envelope, sx, sy, envelope_to_screen, get_distance) >= config.MIN_POINT_SPACING_PIXELS then
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

function M.refresh_captured_from_envelope(state, envelope)
    for _, p in ipairs(state.captured_points) do
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

return M
