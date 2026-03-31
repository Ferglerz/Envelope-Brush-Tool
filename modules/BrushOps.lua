local M = {}

local function use_autoitem_ex(autoitem_idx)
    return type(autoitem_idx) == "number" and autoitem_idx >= 0
end

local function count_envelope_points(envelope, autoitem_idx)
    if use_autoitem_ex(autoitem_idx) then
        return reaper.CountEnvelopePointsEx(envelope, autoitem_idx)
    end
    return reaper.CountEnvelopePoints(envelope)
end

function M.count_envelope_points(envelope, autoitem_idx)
    if not envelope then return 0 end
    return count_envelope_points(envelope, autoitem_idx or -1)
end

local function get_envelope_point(envelope, autoitem_idx, i)
    if use_autoitem_ex(autoitem_idx) then
        return reaper.GetEnvelopePointEx(envelope, autoitem_idx, i)
    end
    return reaper.GetEnvelopePoint(envelope, i)
end

local function set_envelope_point(envelope, autoitem_idx, i, t, v, shape, tension, sel, no_sort)
    if use_autoitem_ex(autoitem_idx) then
        return reaper.SetEnvelopePointEx(envelope, autoitem_idx, i, t, v, shape, tension, sel, no_sort)
    end
    return reaper.SetEnvelopePoint(envelope, i, t, v, shape, tension, sel, no_sort)
end

local function insert_envelope_point(envelope, autoitem_idx, t, v, shape, tension, sel, no_sort)
    if use_autoitem_ex(autoitem_idx) then
        if not reaper.InsertEnvelopePointEx then return false end
        return reaper.InsertEnvelopePointEx(envelope, autoitem_idx, t, v, shape, tension, sel, no_sort)
    end
    return reaper.InsertEnvelopePoint(envelope, t, v, shape, tension, sel, no_sort)
end

local function sort_envelope_points(envelope, autoitem_idx)
    if use_autoitem_ex(autoitem_idx) and reaper.Envelope_SortPointsEx then
        return reaper.Envelope_SortPointsEx(envelope, autoitem_idx)
    end
    return reaper.Envelope_SortPoints(envelope)
end

function M.min_screen_dist_to_envelope_points(envelope, autoitem_idx, sx, sy, envelope_to_screen, get_distance)
    local best = math.huge
    local n = count_envelope_points(envelope, autoitem_idx)
    for i = 0, n - 1 do
        local ok, t, v = get_envelope_point(envelope, autoitem_idx, i)
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

function M.capture_points_in_radius(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, envelope_to_screen, get_distance, calculate_falloff)
    if not envelope then return {} end

    local captured = {}
    local point_count = count_envelope_points(envelope, autoitem_idx)
    local falloff_name = config.FALLOFF_TYPES[state.falloff_type]

    for i = 0, point_count - 1 do
        local retval, time, value, shape, tension, selected = get_envelope_point(envelope, autoitem_idx, i)
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

function M.sculpt_captured_points(state, config, captured_points, delta_x, delta_y, envelope, autoitem_idx, no_sort, get_envelope_properties, clamp, value_at_time)
    if not envelope or #captured_points == 0 or not value_at_time then return 0 end

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
                local vm = value_at_time(envelope, t0 - eps_t)
                local vp = value_at_time(envelope, t0 + eps_t)
                if vm ~= nil and vp ~= nil then
                    local target_v = (vm + vp) * 0.5
                    local step = clamp(state.smooth_strength, 0, 1) * f * power
                    new_value = clamp(point_info.original_value + (target_v - point_info.original_value) * step, min_val, max_val)
                end
            end
            if not state.lock_time_axis then
                new_time = point_info.original_time + (delta_time * f)
            end
        else
            new_time = point_info.original_time + (delta_time * f)
            new_value = clamp(point_info.original_value + (delta_value * f), min_val, max_val)
        end

        set_envelope_point(envelope, autoitem_idx, point_info.index, new_time, new_value,
            point_info.original_shape, point_info.original_tension,
            point_info.original_selected, true)
        points_moved = points_moved + 1
    end

    if points_moved > 0 then
        if not no_sort then
            sort_envelope_points(envelope, autoitem_idx)
        end
        reaper.UpdateArrange()
    end

    return points_moved
end

function M.create_points_in_brush_area(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, screen_to_envelope, envelope_to_screen, get_distance, calculate_falloff, value_at_time)
    if not envelope or not value_at_time then return 0 end

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
    local min_space = config.MIN_POINT_SPACING_PIXELS
    local points_created = 0

    local span_t = 2 * math.abs(radius_time)
    if span_t < 1e-18 then
        return 0
    end

    -- Sample timeline across brush diameter; spacing derived from min pixel gap (screen X ~ proportional to time).
    local abs_tr = math.abs(time_range)
    local step_target = abs_tr > 1e-18 and (min_space * 0.45 / pixel_width) * abs_tr or span_t
    if step_target < 1e-24 or step_target ~= step_target then
        step_target = span_t
    end
    if step_target > span_t then
        step_target = span_t
    end

    local n = math.max(1, math.ceil(span_t / step_target))
    if n > 256 then
        n = 256
    end
    local actual_step = span_t / n
    local t0 = center_time - math.abs(radius_time)

    for k = 0, n do
        local point_time = t0 + k * actual_step
        local time_distance = math.abs(point_time - center_time)
        local normalized_distance = math.abs(radius_time) > 1e-12 and (time_distance / math.abs(radius_time)) or 0

        if normalized_distance <= 1.0 + 1e-9 then
            local base_value = value_at_time(envelope, point_time)
            if base_value ~= nil then
                local sx_c, sy_c = envelope_to_screen(point_time, base_value, envelope)
                if sx_c and sy_c then
                    local d_screen = get_distance(mouse_x, mouse_y, sx_c, sy_c)
                    local w = calculate_falloff(d_screen, radius, falloff_name, state.falloff_strength)
                    local new_value = base_value + (center_value - base_value) * w
                    local sx, sy = envelope_to_screen(point_time, new_value, envelope)
                    if sx and sy then
                        if M.min_screen_dist_to_envelope_points(envelope, autoitem_idx, sx, sy, envelope_to_screen, get_distance) >= min_space then
                            local shape, tension, selected, noSortIn = 0, 0, false, true
                            if insert_envelope_point(envelope, autoitem_idx, point_time, new_value, shape, tension, selected, noSortIn) then
                                points_created = points_created + 1
                            end
                        end
                    end
                end
            end
        end
    end

    if points_created > 0 then
        sort_envelope_points(envelope, autoitem_idx)
        reaper.UpdateArrange()
    end

    return points_created
end

--- Single InsertEnvelopePoint*. Caller should run Core.prepare_envelope_for_point_insert first (BrushDeps does).
--- Project time from screen_to_envelope X; value from value_at_time (Envelope_Evaluate with project SR + samplesRequested).
--- Second return is a debug table (for UI); safe to ignore.
function M.insert_one_point_at_screen(envelope, autoitem_idx, mx, my, screen_to_envelope, value_at_time)
    local dbg = {
        insert_fn = use_autoitem_ex(autoitem_idx) and "InsertEnvelopePointEx" or "InsertEnvelopePoint",
        insert_ex_available = reaper.InsertEnvelopePointEx ~= nil,
        autoitem_idx = autoitem_idx,
        mx = mx,
        my = my,
        t = nil,
        v_evaluate = nil,
        v_insert = nil,
        v_from_screen_map = nil,
        insert_returned = false,
        fail_reason = nil,
    }
    if not envelope or not screen_to_envelope or not value_at_time then
        dbg.fail_reason = "missing envelope, screen_to_envelope, or value_at_time"
        return false, dbg
    end
    local t, v_map = screen_to_envelope(mx, my, envelope)
    dbg.t = t
    dbg.v_from_screen_map = v_map
    if not t then
        dbg.fail_reason = "screen_to_envelope returned no time (check bounds / min_max from SWS)"
        return false, dbg
    end
    local v = value_at_time(envelope, t)
    if v == nil then
        dbg.fail_reason = "Envelope_Evaluate (via value_at_time) returned nil"
        return false, dbg
    end
    dbg.v_evaluate = v
    dbg.v_insert = v
    local ok = insert_envelope_point(envelope, autoitem_idx, t, v, 0, 0, false, false)
    dbg.insert_returned = ok and true or false
    if not ok then
        dbg.fail_reason = dbg.insert_fn .. " returned false"
    end
    if ok then
        sort_envelope_points(envelope, autoitem_idx)
        reaper.UpdateArrange()
    end
    return ok, dbg
end

function M.refresh_captured_from_envelope(state, envelope, autoitem_idx)
    for _, p in ipairs(state.captured_points) do
        local ok, t, v, shape, tension, sel = get_envelope_point(envelope, autoitem_idx, p.index)
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
