local M = {}

local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""
local EnvScale = dofile(SCRIPT_DIR .. "BrushEnvelopeScale.lua")
local EnvApi = dofile(SCRIPT_DIR .. "BrushEnvelopeApi.lua")

local JS_SHIFT = 8 -- js extension modifier (same as BrushInput: Shift / smooth / Fine)

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

--- Calls fn(i, time, value) for each point on the envelope or automation item.
function M.for_each_envelope_point(envelope, autoitem_idx, fn)
    if not envelope or not fn then return end
    local ai = autoitem_idx ~= nil and autoitem_idx or -1
    local n = count_envelope_points(envelope, ai)
    for i = 0, n - 1 do
        local ok, t, v = get_envelope_point(envelope, ai, i)
        if ok then
            fn(i, t, v)
        end
    end
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

function M.sort_envelope_points_for_autoitem(envelope, autoitem_idx)
    if not envelope then return end
    local ai = autoitem_idx ~= nil and autoitem_idx or -1
    if type(ai) == "number" and ai >= 0 and reaper.Envelope_SortPointsEx then
        reaper.Envelope_SortPointsEx(envelope, ai)
    elseif reaper.Envelope_SortPoints then
        reaper.Envelope_SortPoints(envelope)
    end
end

local function sort_envelope_points(envelope, autoitem_idx)
    M.sort_envelope_points_for_autoitem(envelope, autoitem_idx)
end

--- After DeleteEnvelopePointEx at original index `deleted_idx`, fix live capture indices (sculpt drag).
local function adjust_captured_indices_after_delete(captured_points, deleted_idx)
    if not captured_points or deleted_idx == nil then return end
    local j = 1
    while j <= #captured_points do
        local p = captured_points[j]
        if p.index == deleted_idx then
            table.remove(captured_points, j)
        else
            if p.index > deleted_idx then
                p.index = p.index - 1
            end
            j = j + 1
        end
    end
end

--- Remove points that sit closer than `thresh` px (arrange client, Euclidean in time/value screen space).
--- Uses time-sorted evaluation without requiring Envelope_SortPoints first (safe while sculpt uses noSort).
--- Deletes higher original indices first. Optionally updates `captured_points` when points are removed.
function M.enforce_min_screen_spacing(state, envelope, autoitem_idx, envelope_to_screen, get_distance, captured_points)
    local thresh = state and state.min_point_spacing_px
    if not envelope or not envelope_to_screen or not get_distance or thresh == nil or thresh <= 0 then
        return 0
    end

    local n = count_envelope_points(envelope, autoitem_idx)
    if n < 2 then return 0 end

    local rows = {}
    for i = 0, n - 1 do
        local ok, t, v = get_envelope_point(envelope, autoitem_idx, i)
        if ok and t ~= nil and v ~= nil then
            rows[#rows + 1] = { idx = i, time = t, val = v }
        end
    end
    if #rows < 2 then return 0 end

    table.sort(rows, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.idx < b.idx
    end)

    local mark = {}
    local last_kept = rows[1]
    for k = 2, #rows do
        local row = rows[k]
        local sx0, sy0 = envelope_to_screen(last_kept.time, last_kept.val, envelope)
        local sx1, sy1 = envelope_to_screen(row.time, row.val, envelope)
        local d = (sx0 and sy0 and sx1 and sy1) and get_distance(sx0, sy0, sx1, sy1) or math.huge
        if d < thresh then
            mark[row.idx] = true
        else
            last_kept = row
        end
    end

    local dels = {}
    for idx, _ in pairs(mark) do
        dels[#dels + 1] = idx
    end
    table.sort(dels, function(a, b) return a > b end)

    local deleted = 0
    for _, d in ipairs(dels) do
        if reaper.DeleteEnvelopePointEx(envelope, autoitem_idx, d) then
            deleted = deleted + 1
            adjust_captured_indices_after_delete(captured_points, d)
        end
    end

    if deleted > 0 then
        reaper.UpdateArrange()
    end
    return deleted
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
                        falloff_strength = f,
                        -- Unclamped value-axis memory for this LMB drag only (nudge): survives min/max rail clamping.
                        virtual_sy = screen_y,
                        virtual_value_raw = value,
                    })
                end
            end
        end
    end

    return captured
end

--- Keep each captured point strictly between its envelope neighbors in time (indices i-1 / i+1).
--- Captured neighbors use tentative times from `tent_t`; others use `initial_time`. Iterates until stable.
local function clamp_captured_times_to_neighbors(tent_t, captured_points, initial_time, point_count, eps_t)
    if eps_t < 1e-18 or eps_t ~= eps_t then
        eps_t = 1e-12
    end
    local is_cap = {}
    for _, p in ipairs(captured_points) do
        is_cap[p.index] = true
    end
    local max_passes = math.max(16, #captured_points * 4)
    for _ = 1, max_passes do
        local changed = false
        for i = 0, point_count - 1 do
            if is_cap[i] then
                local lo = -math.huge
                if i > 0 then
                    local tleft = is_cap[i - 1] and tent_t[i - 1] or initial_time[i - 1]
                    lo = tleft + eps_t
                end
                if tent_t[i] < lo then
                    tent_t[i] = lo
                    changed = true
                end
            end
        end
        for i = point_count - 1, 0, -1 do
            if is_cap[i] then
                local hi = math.huge
                if i < point_count - 1 then
                    local tright = is_cap[i + 1] and tent_t[i + 1] or initial_time[i + 1]
                    hi = tright - eps_t
                end
                if tent_t[i] > hi then
                    tent_t[i] = hi
                    changed = true
                end
            end
        end
        if not changed then
            break
        end
    end
end

function M.sculpt_captured_points(state, config, captured_points, delta_x, delta_y, envelope, autoitem_idx, get_envelope_properties, clamp, value_at_time, envelope_to_screen, screen_to_envelope, get_distance)
    if not envelope or #captured_points == 0 or not envelope_to_screen or not get_distance then return 0 end

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return 0 end

    local time_range = state.frame_arrange_end - state.frame_arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, envelope)
    local pixel_height = v_bottom - v_top
    if pixel_width <= 0 or pixel_height <= 0 then return 0 end

    local scale_mode = EnvScale.scaling_mode(envelope)
    local d_lo = EnvScale.raw_to_display(scale_mode, min_val)
    local d_hi = EnvScale.raw_to_display(scale_mode, max_val)
    local d_span = d_hi - d_lo

    local kind = state.active_sculpt_kind or "nudge"
    -- Smooth uses Shift as mode key (no Fine halving here). Sculpt + Shift: Fine (half strength).
    local strength_scale = 1.0
    if kind ~= "smooth" and reaper.JS_Mouse_GetState then
        if (reaper.JS_Mouse_GetState(JS_SHIFT) or 0) > 0 then
            strength_scale = 0.5
        end
    end
    local power = (state.sculpt_power or 1.0) * strength_scale

    local points_moved = 0

    local point_count = count_envelope_points(envelope, autoitem_idx)
    local initial_time
    local eps_order = math.max(1e-12, math.abs(time_range) * 1e-14)
    if not state.lock_time_axis and point_count > 0 then
        initial_time = {}
        for i = 0, point_count - 1 do
            local ok, t = get_envelope_point(envelope, autoitem_idx, i)
            initial_time[i] = (ok and t) or 0
        end
    end

    local tent_t = {}
    local tent_v = {}

    local smooth_mean_d
    local smooth_t_target_by_index
    if kind == "smooth" and #captured_points > 0 then
        local ncap = #captured_points
        local sumd = 0
        for _, pi in ipairs(captured_points) do
            sumd = sumd + EnvScale.raw_to_display(scale_mode, pi.original_value)
        end
        smooth_mean_d = sumd / ncap
        local sorted = {}
        for _, pi in ipairs(captured_points) do
            sorted[#sorted + 1] = { pi = pi, t = pi.original_time }
        end
        table.sort(sorted, function(a, b)
            if a.t ~= b.t then return a.t < b.t end
            return a.pi.index < b.pi.index
        end)
        local cx = state.drag_start_pos.x
        local r = state.brush_size
        local sx_l = clamp(cx - r, bounds.left, bounds.right)
        local sx_r = clamp(cx + r, bounds.left, bounds.right)
        local t_lo = state.frame_arrange_start + ((sx_l - bounds.left) / pixel_width) * time_range
        local t_hi = state.frame_arrange_start + ((sx_r - bounds.left) / pixel_width) * time_range
        if t_lo > t_hi then
            t_lo, t_hi = t_hi, t_lo
        end
        smooth_t_target_by_index = {}
        for k, row in ipairs(sorted) do
            local tt
            if ncap <= 1 then
                tt = row.t
            else
                tt = t_lo + ((k - 1) / (ncap - 1)) * (t_hi - t_lo)
            end
            smooth_t_target_by_index[row.pi.index] = tt
        end
    end

    for _, point_info in ipairs(captured_points) do
        -- falloff_strength from capture at LMB: 0 at outer edge, 1 at center; outside brush not in list.
        local f = (point_info.falloff_strength or 0) * power
        local new_time = point_info.original_time
        local new_value = point_info.original_value

        if kind == "smooth" then
            local base = config.SMOOTH_SETTLE_BASE_PER_MOVE * clamp(state.smooth_strength,
                config.MIN_SMOOTH_STRENGTH, config.MAX_SMOOTH_STRENGTH)
            local alpha = base * f
            if not state.lock_value_axis and smooth_mean_d ~= nil then
                local d_i = EnvScale.raw_to_display(scale_mode, point_info.original_value)
                local d_new = d_i + (smooth_mean_d - d_i) * alpha
                new_value = clamp(EnvScale.display_to_raw(scale_mode, d_new), min_val, max_val)
            end
            if not state.lock_time_axis and smooth_t_target_by_index then
                local t_tgt = smooth_t_target_by_index[point_info.index]
                if t_tgt ~= nil then
                    local t_i = point_info.original_time
                    new_time = t_i + (t_tgt - t_i) * alpha
                end
            end
        else
            local sx0, sy0 = envelope_to_screen(point_info.original_time, point_info.original_value, envelope)
            if sx0 and sy0 then
                local dx_s = state.lock_time_axis and 0 or (delta_x * f)
                local dy_s = state.lock_value_axis and 0 or (delta_y * f)
                local sx1 = clamp(sx0 + dx_s, bounds.left, bounds.right)
                if not state.lock_time_axis then
                    new_time = state.frame_arrange_start + ((sx1 - bounds.left) / pixel_width) * time_range
                end
                if not state.lock_value_axis then
                    -- Accumulate screen Y without lane clamp so points past min/max can be pulled back in one drag
                    -- with preserved relative spacing (virtual_sy scrapped on LMB release with captured_points).
                    local vsy = point_info.virtual_sy
                    if vsy == nil or vsy ~= vsy then
                        vsy = sy0
                    end
                    local new_vsy = vsy + dy_s
                    point_info.virtual_sy = new_vsy
                    if math.abs(d_span) >= 1e-12 then
                        local ny = (new_vsy - v_top) / pixel_height
                        local d = d_hi - ny * d_span
                        local unclamped = EnvScale.display_to_raw(scale_mode, d)
                        point_info.virtual_value_raw = unclamped
                        new_value = clamp(unclamped, min_val, max_val)
                    else
                        new_value = point_info.original_value
                    end
                end
            else
                local delta_time = (delta_x / pixel_width) * time_range * f
                if not state.lock_time_axis then
                    new_time = point_info.original_time + delta_time
                end
                if not state.lock_value_axis then
                    if math.abs(d_span) >= 1e-12 then
                        local vbase = point_info.virtual_value_raw
                        if vbase == nil or vbase ~= vbase then
                            vbase = point_info.original_value
                        end
                        local d0 = EnvScale.raw_to_display(scale_mode, vbase)
                        local d1 = d0 - (delta_y / pixel_height) * d_span * f
                        local unclamped = EnvScale.display_to_raw(scale_mode, d1)
                        point_info.virtual_value_raw = unclamped
                        new_value = clamp(unclamped, min_val, max_val)
                    else
                        new_value = point_info.original_value
                    end
                end
            end
        end

        tent_t[point_info.index] = new_time
        tent_v[point_info.index] = new_value
    end

    if not state.lock_time_axis and initial_time then
        clamp_captured_times_to_neighbors(tent_t, captured_points, initial_time, point_count, eps_order)
    end

    for _, point_info in ipairs(captured_points) do
        set_envelope_point(envelope, autoitem_idx, point_info.index, tent_t[point_info.index], tent_v[point_info.index],
            point_info.original_shape, point_info.original_tension,
            point_info.original_selected, true)
        points_moved = points_moved + 1
    end

    if points_moved > 0 then
        state.envelope_points_dirty_sort = true
        reaper.UpdateArrange()
    end

    return points_moved
end

function M.create_points_in_brush_area(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, screen_to_envelope, envelope_to_screen, get_distance, calculate_falloff, get_envelope_properties, value_for_insert, default_point_shape)
    if not envelope or not value_for_insert or not get_envelope_properties then return 0 end

    local my_lane = EnvApi.clamp_client_y_to_value_axis(state, envelope, mouse_y)
    local center_time = select(1, screen_to_envelope(mouse_x, my_lane, envelope))
    if not center_time then return 0 end

    local min_val, max_val = get_envelope_properties(envelope)
    if not min_val then return 0 end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local time_range = arrange_end - arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, envelope)
    local pixel_height = v_bottom - v_top
    if pixel_width <= 0 or pixel_height <= 0 then return 0 end

    local scale_mode = EnvScale.scaling_mode(envelope)
    local seed_blend = state.sculpt_seed_blend_to_cursor
    local d_center_blend
    if seed_blend then
        local v_center, _, _ = value_for_insert(envelope, center_time, autoitem_idx)
        if v_center == nil then return 0 end
        local _, sy_curve = envelope_to_screen(center_time, v_center, envelope)
        if not sy_curve then return 0 end
        local d_lo = EnvScale.raw_to_display(scale_mode, min_val)
        local d_hi = EnvScale.raw_to_display(scale_mode, max_val)
        local d_span = d_hi - d_lo
        local d_curve = EnvScale.raw_to_display(scale_mode, v_center)
        d_center_blend = d_curve
        if math.abs(d_span) >= 1e-12 then
            d_center_blend = d_curve - ((my_lane - sy_curve) / pixel_height) * d_span
        end
    end

    local shape_in = (type(default_point_shape) == "number" and default_point_shape) or 0

    local radius_time = (radius / pixel_width) * time_range
    local falloff_name = config.FALLOFF_TYPES[state.falloff_type]
    local min_space = (state.min_point_spacing_px ~= nil and state.min_point_spacing_px > 0) and state.min_point_spacing_px or 0
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

    -- Min-distance list: only points in a time window around the brush (plus min-spacing slack in time). Full O(n) scan not needed.
    local pad_t = math.abs(radius_time)
    if min_space > 0 and abs_tr > 1e-18 and pixel_width > 0 then
        pad_t = pad_t + (min_space / pixel_width) * abs_tr
    end
    local t_lo = center_time - pad_t
    local t_hi = center_time + pad_t

    local screen_pt_list = {}
    local pt_count_init = count_envelope_points(envelope, autoitem_idx)
    for i = 0, pt_count_init - 1 do
        local ok, t, v = get_envelope_point(envelope, autoitem_idx, i)
        if ok and t ~= nil and v ~= nil and t >= t_lo and t <= t_hi then
            local sx0, sy0 = envelope_to_screen(t, v, envelope)
            if sx0 and sy0 then
                screen_pt_list[#screen_pt_list + 1] = { sx0, sy0 }
            end
        end
    end

    local function min_dist_to_point_list(sx, sy)
        local best = math.huge
        for j = 1, #screen_pt_list do
            local p = screen_pt_list[j]
            local d = get_distance(sx, sy, p[1], p[2])
            if d < best then best = d end
        end
        return best
    end

    for k = 0, n do
        local point_time = t0 + k * actual_step
        local time_distance = math.abs(point_time - center_time)
        local normalized_distance = math.abs(radius_time) > 1e-12 and (time_distance / math.abs(radius_time)) or 0

        if normalized_distance <= 1.0 + 1e-9 then
            local base_value, insert_t = value_for_insert(envelope, point_time, autoitem_idx)
            if base_value ~= nil and insert_t ~= nil then
                local sx_c, sy_c = envelope_to_screen(point_time, base_value, envelope)
                if sx_c and sy_c then
                    local new_value
                    if seed_blend then
                        local d_screen = get_distance(mouse_x, my_lane, sx_c, sy_c)
                        local w = calculate_falloff(d_screen, radius, falloff_name, state.falloff_strength)
                        local d_base = EnvScale.raw_to_display(scale_mode, base_value)
                        local d_new = d_base + (d_center_blend - d_base) * w
                        new_value = EnvScale.display_to_raw(scale_mode, d_new)
                        new_value = math.max(min_val, math.min(max_val, new_value))
                    else
                        new_value = math.max(min_val, math.min(max_val, base_value))
                    end
                    local sx, sy = envelope_to_screen(point_time, new_value, envelope)
                    if sx and sy then
                        if min_space <= 0 or min_dist_to_point_list(sx, sy) >= min_space then
                            local tension, selected, noSortIn = 0, false, true
                            if insert_envelope_point(envelope, autoitem_idx, insert_t, new_value, shape_in, tension, selected, noSortIn) then
                                points_created = points_created + 1
                                screen_pt_list[#screen_pt_list + 1] = { sx, sy }
                            end
                        end
                    end
                end
            end
        end
    end

    if points_created > 0 then
        sort_envelope_points(envelope, autoitem_idx)
        M.enforce_min_screen_spacing(state, envelope, autoitem_idx, envelope_to_screen, get_distance, nil)
        reaper.UpdateArrange()
    end

    return points_created
end

--- Single InsertEnvelopePoint*. Caller should run Core.prepare_envelope_for_point_insert first (BrushDeps does).
--- Project time from screen_to_envelope X; value and insert time from value_for_insert (device SRATE/BSIZE + take remap when applicable).
--- Second return is a debug table (for UI); safe to ignore.
function M.insert_one_point_at_screen(envelope, autoitem_idx, mx, my, screen_to_envelope, value_for_insert, default_point_shape)
    local dbg = {
        insert_fn = use_autoitem_ex(autoitem_idx) and "InsertEnvelopePointEx" or "InsertEnvelopePoint",
        insert_ex_available = reaper.InsertEnvelopePointEx ~= nil,
        autoitem_idx = autoitem_idx,
        mx = mx,
        my = my,
        t = nil,
        insert_time = nil,
        evaluate_time = nil,
        v_evaluate = nil,
        v_insert = nil,
        v_from_screen_map = nil,
        insert_returned = false,
        fail_reason = nil,
    }
    if not envelope or not screen_to_envelope or not value_for_insert then
        dbg.fail_reason = "missing envelope, screen_to_envelope, or value_for_insert"
        return false, dbg
    end
    local t, v_map = screen_to_envelope(mx, my, envelope)
    dbg.t = t
    dbg.v_from_screen_map = v_map
    if not t then
        dbg.fail_reason = "screen_to_envelope returned no time (check bounds / min_max from SWS)"
        return false, dbg
    end
    local v, ins_t, eval_t = value_for_insert(envelope, t, autoitem_idx)
    dbg.insert_time = ins_t
    dbg.evaluate_time = eval_t
    if v == nil then
        dbg.fail_reason = "Envelope_Evaluate (insert path) returned nil"
        return false, dbg
    end
    if ins_t == nil then
        dbg.fail_reason = "insert time unresolved"
        return false, dbg
    end
    dbg.v_evaluate = v
    dbg.v_insert = v
    local shape_in = (type(default_point_shape) == "number" and default_point_shape) or 0
    local ok = insert_envelope_point(envelope, autoitem_idx, ins_t, v, shape_in, 0, false, false)
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
