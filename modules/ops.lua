local M = {}

local _mod_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_mod_dir .. "path.lua")
local EnvApi = Path.load_from_modules("envelope/envelope_api.lua")
local ValueScaling = Path.load_from_modules("envelope/value_scaling.lua")
local Mods = Path.load_from_modules("mods.lua")
local BezierFit = Path.load_from_modules("bezier_fit.lua")

local function count_envelope_points(envelope, autoitem_idx)
    return reaper.CountEnvelopePointsEx(envelope, autoitem_idx or -1)
end

local function get_envelope_point(envelope, autoitem_idx, i)
    local ok, t, v, shape, tension, selected = reaper.GetEnvelopePointEx(envelope, autoitem_idx or -1, i)
    if not ok then
        return false, nil, nil, shape, tension, selected
    end
    return true, t, ValueScaling.api_value_to_linear(envelope, v), shape, tension, selected
end

local function set_envelope_point(envelope, autoitem_idx, i, t, v, shape, tension, sel, no_sort)
    return reaper.SetEnvelopePointEx(envelope, autoitem_idx or -1, i, t, ValueScaling.linear_value_to_api(envelope, v), shape, tension, sel, no_sort)
end

local function insert_envelope_point(envelope, autoitem_idx, t, v, shape, tension, sel, no_sort)
    return reaper.InsertEnvelopePointEx(envelope, autoitem_idx or -1, t, ValueScaling.linear_value_to_api(envelope, v), shape, tension, sel, no_sort)
end

function M.sort_envelope_points_for_autoitem(envelope, autoitem_idx)
    if not envelope then return end
    reaper.Envelope_SortPointsEx(envelope, autoitem_idx or -1)
end

local function sort_envelope_points(envelope, autoitem_idx)
    M.sort_envelope_points_for_autoitem(envelope, autoitem_idx)
end

local function sanitize_raw_value(v, fallback)
    if type(v) ~= "number" or v ~= v then
        return fallback
    end
    return v
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

local ENVELOPE_SHAPE_LINEAR = 0
local ENVELOPE_SHAPE_BEZIER = 5

--- Outgoing segment at insert_t uses the time-left point's shape; new points on bezier spans → linear.
local function shape_and_tension_for_new_insert(envelope, autoitem_idx, insert_t, default_shape, eps_t)
    eps_t = eps_t or 1e-12
    local fallback = (type(default_shape) == "number" and default_shape) or ENVELOPE_SHAPE_LINEAR
    if not envelope or insert_t == nil or insert_t ~= insert_t then
        return fallback, 0
    end
    local left_time = -math.huge
    local left_shape = nil
    local n = count_envelope_points(envelope, autoitem_idx)
    for i = 0, n - 1 do
        local ok, t, _v, shape = get_envelope_point(envelope, autoitem_idx, i)
        if ok and t ~= nil and t <= insert_t + eps_t and t >= left_time then
            left_time = t
            left_shape = shape
        end
    end
    if left_shape == ENVELOPE_SHAPE_BEZIER then
        return ENVELOPE_SHAPE_LINEAR, 0
    end
    return fallback, 0
end

local function gap_samples_for_interior(interior_count, per_gap, min_interior, long_interior)
    if not per_gap or per_gap <= 0 or interior_count < 2 then
        return 0
    end
    min_interior = min_interior or 2
    long_interior = long_interior or 5
    if interior_count >= long_interior then
        return per_gap * 2
    end
    if interior_count >= min_interior then
        return per_gap
    end
    return 0
end

local function rebuild_sorted_rows(envelope, autoitem_idx)
    local n = count_envelope_points(envelope, autoitem_idx)
    local rows = {}
    for i = 0, n - 1 do
        local ok, t, v, shape, tension, selected = get_envelope_point(envelope, autoitem_idx, i)
        if ok and t ~= nil and v ~= nil then
            rows[#rows + 1] = {
                idx = i, time = t, val = v,
                shape = shape, tension = tension, selected = selected,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.idx < b.idx
    end)
    return rows
end

local function find_row_by_time(rows, time, eps_t)
    for i = 1, #rows do
        if math.abs(rows[i].time - time) <= eps_t then
            return rows[i]
        end
    end
    return nil
end

local function set_outgoing_segment(envelope, autoitem_idx, row, shape, tension)
    return set_envelope_point(
        envelope, autoitem_idx, row.idx, row.time, row.val,
        shape, tension, row.selected, true
    )
end

local function snapshot_row(row)
    return {
        idx = row.idx,
        time = row.time,
        val = row.val,
        shape = row.shape,
        tension = row.tension,
        selected = row.selected,
    }
end

local function interpolate_sorted_rows_value(rows, t)
    if not rows or #rows == 0 or t == nil or t ~= t then
        return nil
    end
    if t <= rows[1].time then
        return rows[1].val
    end
    if t >= rows[#rows].time then
        return rows[#rows].val
    end
    for k = 1, #rows - 1 do
        local a, b = rows[k], rows[k + 1]
        if t >= a.time and t <= b.time then
            local dt = b.time - a.time
            if dt <= 1e-18 then
                return a.val
            end
            local u = (t - a.time) / dt
            return a.val + (b.val - a.val) * u
        end
    end
    return nil
end

local function measure_targets_fit_error(envelope_value_at_time, envelope, targets)
    local max_val = 0
    for i = 1, #targets do
        local s = targets[i]
        local v_fit = envelope_value_at_time(envelope, s.t)
        if v_fit == nil or v_fit ~= v_fit then
            return math.huge
        end
        local dv = math.abs(v_fit - s.v)
        if dv > max_val then
            max_val = dv
        end
    end
    return max_val
end

local function fit_within_tolerance(max_val, tol_val)
    if not tol_val or tol_val <= 0 then
        return false
    end
    return max_val <= tol_val
end

local function build_span_fit_targets(rows, left_i, right_i, extra_samples_per_gap)
    local targets = {}
    local seen = {}
    local function add_target(t, v)
        if t == nil or t ~= t or v == nil or v ~= v then
            return false
        end
        local key = math.floor(t * 1e12 + 0.5)
        if seen[key] then
            return true
        end
        seen[key] = true
        targets[#targets + 1] = { t = t, v = v }
        return true
    end

    for k = left_i + 1, right_i - 1 do
        if not add_target(rows[k].time, rows[k].val) then
            return nil
        end
    end

    extra_samples_per_gap = extra_samples_per_gap or 0
    if extra_samples_per_gap > 0 then
        for k = left_i, right_i - 1 do
            local t0, t1 = rows[k].time, rows[k + 1].time
            if t1 > t0 then
                for s = 1, extra_samples_per_gap do
                    local t = t0 + (t1 - t0) * (s / (extra_samples_per_gap + 1))
                    local v = interpolate_sorted_rows_value(rows, t)
                    if not add_target(t, v) then
                        return nil
                    end
                end
            end
        end
    end

    return targets
end

local function fit_outgoing_to_targets(
    envelope, autoitem_idx, left, right, targets, envelope_value_at_time,
    tol_linear, tol_bezier, bezier_min_gain, chord_dev, arc_chord_min, schneider_newton_iters, tension_search_radius
)
    arc_chord_min = arc_chord_min or tol_linear
    local arc_like = chord_dev ~= nil and chord_dev > arc_chord_min

    set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_LINEAR, 0)
    local linear_val = measure_targets_fit_error(envelope_value_at_time, envelope, targets)

    if fit_within_tolerance(linear_val, tol_linear) and not arc_like then
        return ENVELOPE_SHAPE_LINEAR, 0, linear_val
    end

    local norm_pts = BezierFit.window_points_normalized(
        left.time, left.val, right.time, right.val, targets
    )
    if not norm_pts then
        if arc_like then
            return nil, nil, nil
        end
        if fit_within_tolerance(linear_val, tol_linear) then
            return ENVELOPE_SHAPE_LINEAR, 0, linear_val
        end
        return ENVELOPE_SHAPE_LINEAR, 0, linear_val
    end

    local schneider = BezierFit.schneider_cubic(norm_pts, { newton_iters = schneider_newton_iters or 2 })
    if not schneider then
        if arc_like then
            return nil, nil, nil
        end
        if fit_within_tolerance(linear_val, tol_linear) then
            return ENVELOPE_SHAPE_LINEAR, 0, linear_val
        end
        return ENVELOPE_SHAPE_LINEAR, 0, linear_val
    end

    local function set_bezier_tension(tens)
        set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_BEZIER, tens)
    end

    local function measure_err()
        return measure_targets_fit_error(envelope_value_at_time, envelope, targets)
    end

    local best_tension, best_val = BezierFit.find_best_reaper_tension(
        set_bezier_tension,
        measure_err,
        schneider.tension_hint,
        tension_search_radius,
        12
    )

    if not best_tension or best_val == nil then
        if arc_like then
            set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_LINEAR, 0)
            return nil, nil, nil
        end
        if fit_within_tolerance(linear_val, tol_linear) then
            return ENVELOPE_SHAPE_LINEAR, 0, linear_val
        end
        set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_LINEAR, 0)
        return ENVELOPE_SHAPE_LINEAR, 0, linear_val
    end

    if not fit_within_tolerance(best_val, tol_bezier) then
        if arc_like then
            set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_LINEAR, 0)
            return nil, nil, nil
        end
        if fit_within_tolerance(linear_val, tol_linear) then
            set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_LINEAR, 0)
            return ENVELOPE_SHAPE_LINEAR, 0, linear_val
        end
        set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_LINEAR, 0)
        return ENVELOPE_SHAPE_LINEAR, 0, linear_val
    end

    bezier_min_gain = bezier_min_gain or 0
    if bezier_min_gain < 0 then bezier_min_gain = 0 end
    if not arc_like and bezier_min_gain > 0 and (linear_val - best_val) < bezier_min_gain then
        if fit_within_tolerance(linear_val, tol_linear) then
            set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_LINEAR, 0)
            return ENVELOPE_SHAPE_LINEAR, 0, linear_val
        end
    end

    set_outgoing_segment(envelope, autoitem_idx, left, ENVELOPE_SHAPE_BEZIER, best_tension)
    return ENVELOPE_SHAPE_BEZIER, best_tension, best_val
end

local function delete_envelope_rows(envelope, autoitem_idx, row_snaps, captured_points)
    local idxs = {}
    for i = 1, #row_snaps do
        idxs[#idxs + 1] = row_snaps[i].idx
    end
    table.sort(idxs, function(a, b) return a > b end)
    local deleted = 0
    for _, d in ipairs(idxs) do
        if reaper.DeleteEnvelopePointEx(envelope, autoitem_idx, d) then
            deleted = deleted + 1
            adjust_captured_indices_after_delete(captured_points, d)
        end
    end
    return deleted
end

local function restore_interior_rows(envelope, autoitem_idx, interior_snaps)
    for i = 1, #interior_snaps do
        local p = interior_snaps[i]
        insert_envelope_point(
            envelope, autoitem_idx, p.time, p.val,
            p.shape or ENVELOPE_SHAPE_LINEAR, p.tension or 0,
            p.selected or false, true
        )
    end
    sort_envelope_points(envelope, autoitem_idx)
end

local function restore_left_outgoing_segment(envelope, autoitem_idx, left_time, left_seg)
    local rows = rebuild_sorted_rows(envelope, autoitem_idx)
    local left = find_row_by_time(rows, left_time, 1e-9)
    if left then
        set_outgoing_segment(
            envelope, autoitem_idx, left,
            left_seg.shape or ENVELOPE_SHAPE_LINEAR, left_seg.tension or 0
        )
    end
end

local function rollback_window_trial(envelope, autoitem_idx, interior_snaps, left_time, left_seg)
    restore_interior_rows(envelope, autoitem_idx, interior_snaps)
    restore_left_outgoing_segment(envelope, autoitem_idx, left_time, left_seg)
end

--- Average |value − chord| for interior points (linear between left/right anchors in time).
local function interior_chord_deviation_val(rows, left_i, right_i)
    local left, right = rows[left_i], rows[right_i]
    local t0, t1 = left.time, right.time
    local v0, v1 = left.val, right.val
    local dt = t1 - t0
    if dt <= 1e-18 then
        return 0
    end
    local sum = 0
    local n = 0
    for k = left_i + 1, right_i - 1 do
        local mid = rows[k]
        local u = (mid.time - t0) / dt
        local v_line = v0 + (v1 - v0) * u
        sum = sum + math.abs(mid.val - v_line)
        n = n + 1
    end
    if n == 0 then
        return 0
    end
    return sum / n
end

local function stroke_time_key(t)
    return math.floor(t * 1e9 + 0.5)
end

local function freeze_stroke_point_times(stroke_point_times)
    if not stroke_point_times or next(stroke_point_times) == nil then
        return nil, nil
    end
    local frozen = {}
    local t_lo, t_hi = math.huge, -math.huge
    for _, t in pairs(stroke_point_times) do
        if type(t) == "number" and t == t then
            frozen[stroke_time_key(t)] = t
            if t < t_lo then t_lo = t end
            if t > t_hi then t_hi = t end
        end
    end
    if next(frozen) == nil then
        return nil, nil
    end
    local span = t_hi - t_lo
    local eps_t = math.max(1e-6, span * 1e-7)
    return frozen, eps_t
end

local function row_time_in_stroke(t, stroke_point_times, eps_t)
    if not stroke_point_times or t == nil or t ~= t then
        return false
    end
    local key = math.floor(t * 1e9 + 0.5)
    if stroke_point_times[key] then
        return true
    end
    for _, st in pairs(stroke_point_times) do
        if math.abs(st - t) <= eps_t then
            return true
        end
    end
    return false
end

local function window_interiors_in_stroke(rows, left_i, right_i, stroke_point_times, eps_t)
    for k = left_i + 1, right_i - 1 do
        if not row_time_in_stroke(rows[k].time, stroke_point_times, eps_t) then
            return false
        end
    end
    return true
end

local function build_stroke_row_scope(rows, stroke_point_times, min_interior, eps_t)
    if not stroke_point_times then
        return nil
    end
    local lo, hi, stroke_count = nil, nil, 0
    for i = 1, #rows do
        if row_time_in_stroke(rows[i].time, stroke_point_times, eps_t) then
            lo = lo or i
            hi = i
            stroke_count = stroke_count + 1
        end
    end
    if not lo or stroke_count < min_interior then
        return nil
    end
    local left_i_min = math.max(1, lo - 1)
    local left_i_max = hi - min_interior
    if left_i_max < left_i_min then
        return nil
    end
    return {
        lo = lo,
        hi = hi,
        stroke_count = stroke_count,
        left_i_min = left_i_min,
        left_i_max = left_i_max,
        max_right_cap = math.min(#rows, hi + 1),
    }
end

--- Trial merge: delete interiors, fit span to pre-merge point curve, restore unless commit.
local function try_window_merge(
    envelope, autoitem_idx, rows, left_i, right_i,
    envelope_value_at_time, tol_linear, tol_bezier, bezier_min_gain, arc_chord_min,
    schneider_newton_iters, tension_search_radius,
    captured_points, extra_samples_per_gap, extra_samples_min_interior, extra_samples_long_interior,
    stroke_point_times, eps_t, commit
)
    local interior_count = right_i - left_i - 1
    if interior_count < 1 then
        return nil
    end
    if stroke_point_times and not window_interiors_in_stroke(rows, left_i, right_i, stroke_point_times, eps_t) then
        return nil
    end

    local chord_dev = interior_chord_deviation_val(rows, left_i, right_i)

    local gap_samples = gap_samples_for_interior(
        interior_count, extra_samples_per_gap, extra_samples_min_interior, extra_samples_long_interior
    )
    local targets = build_span_fit_targets(rows, left_i, right_i, gap_samples)
    if not targets or #targets == 0 then
        return nil
    end

    local left_row = rows[left_i]
    local left_seg = snapshot_row(left_row)
    local interior_snaps = {}
    for k = left_i + 1, right_i - 1 do
        interior_snaps[#interior_snaps + 1] = snapshot_row(rows[k])
    end

    local deleted = delete_envelope_rows(envelope, autoitem_idx, interior_snaps, captured_points)
    if deleted ~= interior_count then
        rollback_window_trial(envelope, autoitem_idx, interior_snaps, left_row.time, left_seg)
        return nil
    end

    local post_rows = rebuild_sorted_rows(envelope, autoitem_idx)
    local left = find_row_by_time(post_rows, left_row.time, 1e-9)
    if not left then
        rollback_window_trial(envelope, autoitem_idx, interior_snaps, left_row.time, left_seg)
        return nil
    end

    local right_row = rows[right_i]

    local best_shape, best_tension, fit_val = fit_outgoing_to_targets(
        envelope, autoitem_idx, left, right_row, targets, envelope_value_at_time,
        tol_linear, tol_bezier, bezier_min_gain, chord_dev, arc_chord_min,
        schneider_newton_iters, tension_search_radius
    )

    if not best_shape or fit_val == nil then
        rollback_window_trial(envelope, autoitem_idx, interior_snaps, left_row.time, left_seg)
        return nil
    end

    local fit_tol = (best_shape == ENVELOPE_SHAPE_BEZIER) and tol_bezier or tol_linear
    if not fit_within_tolerance(fit_val, fit_tol) then
        rollback_window_trial(envelope, autoitem_idx, interior_snaps, left_row.time, left_seg)
        return nil
    end

    -- Curved interiors must survive as bezier; linear merge only when already nearly collinear in value.
    if best_shape == ENVELOPE_SHAPE_LINEAR and chord_dev > tol_linear then
        rollback_window_trial(envelope, autoitem_idx, interior_snaps, left_row.time, left_seg)
        return nil
    end

    local fit_cost = fit_val + 1e-9
    local score = interior_count * interior_count * (chord_dev + 1.0) / fit_cost
    if best_shape == ENVELOPE_SHAPE_BEZIER then
        score = score * (1.0 + chord_dev)
    end
    local result = {
        left_i = left_i,
        right_i = right_i,
        left_time = left_row.time,
        interior_count = interior_count,
        best_shape = best_shape,
        best_tension = best_tension,
        fit_val = fit_val,
        chord_dev = chord_dev,
        score = score,
    }

    if not commit then
        rollback_window_trial(envelope, autoitem_idx, interior_snaps, left_row.time, left_seg)
    end

    return result
end

--- Apply a trial result without re-running fit search (commit path).
local function apply_window_merge(envelope, autoitem_idx, rows, left_i, right_i, merge, captured_points)
    local interior_count = right_i - left_i - 1
    if interior_count < 1 or not merge then
        return 0
    end
    local left_row = rows[left_i]
    local interior_snaps = {}
    for k = left_i + 1, right_i - 1 do
        interior_snaps[#interior_snaps + 1] = snapshot_row(rows[k])
    end
    local deleted = delete_envelope_rows(envelope, autoitem_idx, interior_snaps, captured_points)
    if deleted ~= interior_count then
        return 0
    end
    local post_rows = rebuild_sorted_rows(envelope, autoitem_idx)
    local left = find_row_by_time(post_rows, left_row.time, 1e-9)
    if not left then
        return 0
    end
    set_outgoing_segment(
        envelope, autoitem_idx, left,
        merge.best_shape or ENVELOPE_SHAPE_LINEAR,
        merge.best_tension or 0
    )
    return interior_count
end

--- Longest window from left_i that still fits tolerance (binary search on right anchor).
local function find_longest_merge_from_left(
    envelope, autoitem_idx, rows, left_i, min_interior, max_interior,
    envelope_value_at_time, tol_linear, tol_bezier, bezier_min_gain, arc_chord_min,
    schneider_newton_iters, tension_search_radius,
    captured_points, extra_samples_per_gap, extra_samples_min_interior, extra_samples_long_interior,
    stroke_point_times, eps_t, max_right_cap
)
    local min_right = left_i + min_interior + 1
    local max_right = math.min(#rows, left_i + max_interior + 1, max_right_cap or #rows)
    if min_right > max_right then
        return nil
    end

    local best = nil
    local lo, hi = min_right, max_right
    while lo <= hi do
        local mid = math.floor((lo + hi) * 0.5)
        local cand = try_window_merge(
            envelope, autoitem_idx, rows, left_i, mid,
            envelope_value_at_time, tol_linear, tol_bezier, bezier_min_gain, arc_chord_min,
            schneider_newton_iters, tension_search_radius,
            captured_points, extra_samples_per_gap, extra_samples_min_interior, extra_samples_long_interior,
            stroke_point_times, eps_t, false
        )
        if cand then
            best = cand
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return best
end

local function effective_max_interior(ccfg, row_count, min_interior)
    local cap = ccfg.BEZIER_MERGE_MAX_INTERIOR
    if cap == nil then
        cap = 64
    end
    if cap <= 0 then
        cap = math.max(min_interior, row_count - 2)
    end
    return cap
end

local function interior_angle_deg(ax, ay, bx, by, cx, cy)
    local bax, bay = ax - bx, ay - by
    local bcx, bcy = cx - bx, cy - by
    local len_a = math.sqrt(bax * bax + bay * bay)
    local len_c = math.sqrt(bcx * bcx + bcy * bcy)
    if len_a < 1e-12 or len_c < 1e-12 then
        return nil
    end
    local cos_a = (bax * bcx + bay * bcy) / (len_a * len_c)
    if cos_a > 1 then
        cos_a = 1
    elseif cos_a < -1 then
        cos_a = -1
    end
    return math.deg(math.acos(cos_a))
end

--- Greedy window merge on smooth LMB up: stroke-scoped anchors, drop interiors when a span fits.
function M.merge_smooth_stroke_envelope_spans(
    config, envelope, autoitem_idx, captured_points, envelope_value_at_time, stroke_point_times, merge_opts
)
    if not envelope or not config or not envelope_value_at_time then
        return 0
    end
    local frozen_stroke, eps_t = freeze_stroke_point_times(stroke_point_times)
    if not frozen_stroke then
        return 0
    end

    local ccfg = config.cleanup or {}
    local min_interior = ccfg.BEZIER_MERGE_MIN_INTERIOR or 2
    if min_interior < 1 then min_interior = 1 end
    local tol_linear = ccfg.BEZIER_MERGE_MAX_ERR or 0.0001
    if tol_linear < 0 then tol_linear = 0 end
    local tol_bezier = (merge_opts and merge_opts.bezier_max_err) or ccfg.BEZIER_MERGE_MAX_ERR_BEZIER or 0.015
    if tol_bezier < 0 then tol_bezier = 0 end
    local bezier_min_gain = ccfg.BEZIER_MERGE_BEZIER_MIN_GAIN or 0.00001
    if bezier_min_gain < 0 then bezier_min_gain = 0 end
    local arc_chord_min = ccfg.BEZIER_MERGE_ARC_CHORD_MIN or tol_linear
    if arc_chord_min < 0 then arc_chord_min = 0 end
    local schneider_newton_iters = ccfg.BEZIER_MERGE_SCHNEIDER_NEWTON_ITER or 2
    if schneider_newton_iters < 0 then schneider_newton_iters = 0 end
    local tension_search_radius = ccfg.BEZIER_MERGE_TENSION_SEARCH_RADIUS or 0.35
    if tension_search_radius <= 0 then tension_search_radius = 0.35 end
    local extra_samples = ccfg.BEZIER_MERGE_EXTRA_SAMPLES_PER_GAP or 2
    if extra_samples < 0 then extra_samples = 0 end
    local extra_samples_min_interior = ccfg.BEZIER_MERGE_EXTRA_SAMPLES_MIN_INTERIOR or 2
    if extra_samples_min_interior < 1 then extra_samples_min_interior = 1 end
    local extra_samples_long_interior = ccfg.BEZIER_MERGE_EXTRA_SAMPLES_LONG_INTERIOR or 5
    if extra_samples_long_interior < 1 then extra_samples_long_interior = 1 end
    local max_passes = ccfg.BEZIER_MERGE_MAX_PASSES or 16
    if max_passes < 1 then max_passes = 1 end

    local total_deleted = 0
    local pass = 0
    while pass < max_passes do
        pass = pass + 1
        local rows = rebuild_sorted_rows(envelope, autoitem_idx)
        local scope = build_stroke_row_scope(rows, frozen_stroke, min_interior, eps_t)
        if not scope then
            break
        end
        local max_interior = effective_max_interior(ccfg, #rows, min_interior)
        max_interior = math.min(max_interior, scope.hi - scope.lo + 1)

        local best = nil
        for left_i = scope.left_i_min, scope.left_i_max do
            local cand = find_longest_merge_from_left(
                envelope, autoitem_idx, rows, left_i, min_interior, max_interior,
                envelope_value_at_time, tol_linear, tol_bezier, bezier_min_gain, arc_chord_min,
                schneider_newton_iters, tension_search_radius,
                captured_points, extra_samples, extra_samples_min_interior, extra_samples_long_interior,
                frozen_stroke, eps_t, scope.max_right_cap
            )
            if cand and (not best or cand.score > best.score) then
                best = cand
            end
        end

        if not best then
            break
        end

        rows = rebuild_sorted_rows(envelope, autoitem_idx)
        local left_i, right_i = nil, nil
        for i = 1, #rows do
            if math.abs(rows[i].time - best.left_time) <= eps_t then
                left_i = i
                break
            end
        end
        if not left_i then
            break
        end
        right_i = left_i + best.interior_count + 1
        if right_i > #rows then
            break
        end

        local n = apply_window_merge(envelope, autoitem_idx, rows, left_i, right_i, best, captured_points)
        if n <= 0 then
            break
        end
        total_deleted = total_deleted + n
    end

    if total_deleted > 0 then
        sort_envelope_points(envelope, autoitem_idx)
        reaper.UpdateArrange()
    end
    return total_deleted
end

--- After bezier merge: remove stroke-scoped interior points nearly collinear on screen.
function M.remove_redundant_envelope_points_by_angle(
    config, envelope, autoitem_idx, envelope_to_screen, captured_points, stroke_point_times
)
    if not envelope or not envelope_to_screen or not config then
        return 0
    end
    local frozen_stroke, eps_t = freeze_stroke_point_times(stroke_point_times)
    if not frozen_stroke then
        return 0
    end

    local ccfg = config.cleanup or {}
    local min_angle = ccfg.REDUNDANT_POINT_MIN_ANGLE_DEG or 175
    if min_angle < 0 then min_angle = 0 elseif min_angle > 180 then min_angle = 180 end
    local max_passes = ccfg.ANGLE_CLEANUP_MAX_PASSES or 64
    if max_passes < 1 then max_passes = 1 end

    local total_deleted = 0
    local pass = 0
    while pass < max_passes do
        pass = pass + 1
        local rows = rebuild_sorted_rows(envelope, autoitem_idx)
        if #rows < 3 then
            break
        end

        local mark = {}
        for k = 2, #rows - 1 do
            local prev, mid, nxt = rows[k - 1], rows[k], rows[k + 1]
            if row_time_in_stroke(mid.time, frozen_stroke, eps_t) then
                local sax, say = envelope_to_screen(prev.time, prev.val, envelope)
                local sbx, sby = envelope_to_screen(mid.time, mid.val, envelope)
                local scx, scy = envelope_to_screen(nxt.time, nxt.val, envelope)
                if sax and say and sbx and sby and scx and scy then
                    local ang = interior_angle_deg(sax, say, sbx, sby, scx, scy)
                    if ang and ang >= min_angle then
                        mark[mid.idx] = true
                    end
                end
            end
        end

        local dels = {}
        for idx, _ in pairs(mark) do
            dels[#dels + 1] = idx
        end
        if #dels == 0 then
            break
        end

        table.sort(dels, function(a, b) return a > b end)
        local deleted_this_pass = 0
        for _, d in ipairs(dels) do
            if reaper.DeleteEnvelopePointEx(envelope, autoitem_idx, d) then
                deleted_this_pass = deleted_this_pass + 1
                adjust_captured_indices_after_delete(captured_points, d)
            end
        end
        if deleted_this_pass == 0 then
            break
        end
        total_deleted = total_deleted + deleted_this_pass
    end

    if total_deleted > 0 then
        sort_envelope_points(envelope, autoitem_idx)
        reaper.UpdateArrange()
    end
    return total_deleted
end

--- Same insert time in one seed pass (quantized grid + rim) → duplicate envelope times → vertical spikes.
local function insert_t_already_placed(list, insert_t, eps_t)
    for i = 1, #list do
        if math.abs(list[i] - insert_t) <= eps_t then
            return true
        end
    end
    return false
end

local function mouse_cursor_time()
    if not reaper.BR_GetMouseCursorContext_Position or not reaper.BR_GetMouseCursorContext then
        return nil
    end
    -- SWS updates cursor-position context on BR_GetMouseCursorContext(); without this,
    -- BR_GetMouseCursorContext_Position can return stale values intermittently.
    reaper.BR_GetMouseCursorContext()
    local t = reaper.BR_GetMouseCursorContext_Position()
    if type(t) ~= "number" or t ~= t then
        return nil
    end
    return t
end

local function build_seed_screen_point_cache(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, screen_to_envelope, envelope_to_screen, _get_envelope_properties, value_for_insert)
    if not envelope or not screen_to_envelope or not envelope_to_screen then return nil end
    local center_time = mouse_cursor_time()
    if not center_time then return nil end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local time_range = arrange_end - arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    if pixel_width <= 0 then return nil end

    local min_space = math.max(1, state.min_point_spacing_px or 1)
    local abs_tr = math.abs(time_range)
    local radius_time = (radius / pixel_width) * time_range
    local pad_t = math.abs(radius_time)
    if min_space > 0 and abs_tr > 1e-18 then
        pad_t = pad_t + (min_space / pixel_width) * abs_tr
    end
    local t_lo = center_time - pad_t
    local t_hi = center_time + pad_t

    local screen_pt_list = {}
    local point_count = count_envelope_points(envelope, autoitem_idx)
    for i = 0, point_count - 1 do
        local ok, t, v = get_envelope_point(envelope, autoitem_idx, i)
        if ok and t ~= nil and v ~= nil and t >= t_lo and t <= t_hi then
            local sx0, sy0 = envelope_to_screen(t, v, envelope)
            if sx0 and sy0 then
                screen_pt_list[#screen_pt_list + 1] = { sx0, sy0 }
            end
        end
    end

    local now = reaper.time_precise and reaper.time_precise() or 0
    local scfg = config and config.seed or {}
    local px_tol = scfg.SEED_CACHE_REUSE_CENTER_TOLERANCE_PX or 3
    local tol_t = (abs_tr > 1e-18 and pixel_width > 0) and ((px_tol / pixel_width) * abs_tr) or 0

    local seed_candidates = nil
    if value_for_insert and (scfg.HOVER_WARM_PRECOMPUTE_INSERT_CANDIDATES ~= false) then
        local span_t = 2 * math.abs(radius_time)
        if span_t >= 1e-18 then
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
            local eps_ins = math.max(1e-12, math.abs(time_range) * 1e-14)
            local placed_insert_t = {}
            seed_candidates = {}
            for k = 0, n do
                local point_time = t0 + k * actual_step
                local time_distance = math.abs(point_time - center_time)
                local normalized_distance = math.abs(radius_time) > 1e-12 and (time_distance / math.abs(radius_time)) or 0
                if normalized_distance <= 1.0 + 1e-9 then
                    local base_value, insert_t, eval_t = value_for_insert(envelope, point_time, autoitem_idx)
                    if base_value ~= nil and insert_t ~= nil and not insert_t_already_placed(placed_insert_t, insert_t, eps_ins) then
                        local t_vis = eval_t or point_time
                        local new_value = base_value
                        local sx, sy = envelope_to_screen(t_vis, new_value, envelope)
                        if sx and sy then
                            seed_candidates[#seed_candidates + 1] = {
                                insert_t = insert_t,
                                value = new_value,
                                sx = sx,
                                sy = sy,
                            }
                            placed_insert_t[#placed_insert_t + 1] = insert_t
                        end
                    end
                end
            end
        end
    end

    return {
        envelope = envelope,
        autoitem_idx = autoitem_idx,
        brush_size = radius,
        min_space = min_space,
        center_time = center_time,
        time_range = time_range,
        pixel_width = pixel_width,
        t_lo = t_lo,
        t_hi = t_hi,
        point_count_snapshot = point_count,
        built_os = now,
        max_age_sec = scfg.SEED_CACHE_MAX_AGE_SEC or 0.25,
        reuse_tolerance_t = tol_t,
        screen_pt_list = screen_pt_list,
        seed_candidates = seed_candidates,
    }
end

local function can_reuse_seed_screen_point_cache(cache, envelope, autoitem_idx, center_time, radius, min_space, time_range, pixel_width)
    if not cache then return false end
    if cache.envelope ~= envelope then return false end
    if (cache.autoitem_idx or -1) ~= (autoitem_idx or -1) then return false end
    if math.abs((cache.brush_size or 0) - (radius or 0)) > 1e-9 then return false end
    if math.abs((cache.min_space or 0) - (min_space or 0)) > 1e-9 then return false end
    if math.abs((cache.time_range or 0) - (time_range or 0)) > 1e-9 then return false end
    if math.abs((cache.pixel_width or 0) - (pixel_width or 0)) > 1e-9 then return false end
    local now = reaper.time_precise and reaper.time_precise() or 0
    if (cache.max_age_sec or 0) > 0 and (now - (cache.built_os or 0)) > cache.max_age_sec then return false end
    if math.abs((cache.center_time or 0) - center_time) > (cache.reuse_tolerance_t or 0) then return false end
    local point_count = count_envelope_points(envelope, autoitem_idx)
    if point_count ~= (cache.point_count_snapshot or -1) then return false end
    return true
end

function M.build_seed_screen_point_cache(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, screen_to_envelope, envelope_to_screen, get_envelope_properties, value_for_insert)
    return build_seed_screen_point_cache(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, screen_to_envelope, envelope_to_screen, get_envelope_properties, value_for_insert)
end

function M.capture_points_in_radius(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, envelope_to_screen, get_distance, calculate_falloff)
    if not envelope then return {} end

    local _brush_cx, brush_cy = EnvApi.brush_center_client_xy(state, envelope, mouse_x, mouse_y)
    local center_time = mouse_cursor_time()
    local time_range = state.frame_arrange_end - state.frame_arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local abs_time_range = math.abs(time_range)
    if center_time == nil or brush_cy == nil or pixel_width <= 0 or abs_time_range <= 1e-18 then
        return {}
    end
    local radius_time = (radius / pixel_width) * abs_time_range

    local captured = {}
    local point_count = count_envelope_points(envelope, autoitem_idx)
    local falloff_name = config.falloff.FALLOFF_TYPES[state.falloff_type]

    for i = 0, point_count - 1 do
        local retval, time, value, shape, tension, selected = get_envelope_point(envelope, autoitem_idx, i)
        if retval then
            local _screen_x, screen_y = envelope_to_screen(time, value, envelope)
            if screen_y then
                local dx_px = (math.abs(time - center_time) / abs_time_range) * pixel_width
                local dy_px = math.abs(screen_y - brush_cy)
                local distance = get_distance(0, 0, dx_px, dy_px)
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

function M.sculpt_captured_points(state, config, captured_points, delta_x, delta_y, envelope, autoitem_idx, _get_envelope_properties, clamp, value_at_time, envelope_to_screen, screen_to_envelope, get_distance)
    if not envelope or #captured_points == 0 or not envelope_to_screen or not screen_to_envelope or not get_distance then return 0 end

    local time_range = state.frame_arrange_end - state.frame_arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    local v_top, v_bottom = EnvApi.envelope_value_axis_screen_for_mapping(state, envelope)
    local pixel_height = v_bottom - v_top
    if pixel_width <= 0 or pixel_height <= 0 then return 0 end

    local kind = state.active_sculpt_kind or "nudge"
    -- Smooth uses Shift as mode key (no Fine scaling here). Sculpt + Shift: Fine (25% strength).
    local strength_scale = 1.0
    if kind ~= "smooth" and reaper.JS_Mouse_GetState then
        if (reaper.JS_Mouse_GetState(Mods.JS_SHIFT) or 0) > 0 then
            strength_scale = 0.25
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

    --- Shift smooth: time = midpoint between envelope neighbors, or brush time edge for first point;
    --- last envelope point (by time) is not adjusted; value = Laplacian on interior points.
    local smooth_t_target_by_index
    local smooth_env_sorted -- { { idx, time, val }, ... } sorted by time
    local smooth_env_pos_by_idx -- envelope point index -> 1-based rank in smooth_env_sorted
    if kind == "smooth" and #captured_points > 0 then
        local need_env_sort = (not state.lock_value_axis or not state.lock_time_axis) and point_count >= 2
        if need_env_sort then
            smooth_env_sorted = {}
            for i = 0, point_count - 1 do
                local ok, t, v = get_envelope_point(envelope, autoitem_idx, i)
                if ok and t ~= nil and v ~= nil then
                    smooth_env_sorted[#smooth_env_sorted + 1] = { idx = i, time = t, val = v }
                end
            end
            table.sort(smooth_env_sorted, function(a, b)
                if a.time ~= b.time then return a.time < b.time end
                return a.idx < b.idx
            end)
            if #smooth_env_sorted >= 2 then
                smooth_env_pos_by_idx = {}
                for k, row in ipairs(smooth_env_sorted) do
                    smooth_env_pos_by_idx[row.idx] = k
                end
            else
                smooth_env_sorted = nil
            end
        end

        smooth_t_target_by_index = {}
        if not state.lock_time_axis then
            local center_time = mouse_cursor_time()
            local radius_time = (center_time ~= nil) and ((state.brush_size / pixel_width) * math.abs(time_range)) or nil
            local t_lo = (center_time ~= nil and radius_time ~= nil) and (center_time - radius_time) or nil
            local t_hi = (center_time ~= nil and radius_time ~= nil) and (center_time + radius_time) or nil
            if smooth_env_sorted and smooth_env_pos_by_idx then
                local rows = smooth_env_sorted
                local nrows = #rows
                for _, pi in ipairs(captured_points) do
                    local pos = smooth_env_pos_by_idx[pi.index]
                    local tt
                    if not pos or nrows < 2 then
                        tt = pi.original_time
                    elseif pos == nrows then
                        tt = pi.original_time
                    elseif pos > 1 and pos < nrows then
                        tt = (rows[pos - 1].time + rows[pos + 1].time) * 0.5
                    elseif pos == 1 then
                        tt = t_lo or pi.original_time
                    else
                        tt = t_hi or pi.original_time
                    end
                    smooth_t_target_by_index[pi.index] = tt
                end
            else
                for _, pi in ipairs(captured_points) do
                    smooth_t_target_by_index[pi.index] = pi.original_time
                end
            end
        end
    end

    for _, point_info in ipairs(captured_points) do
        -- falloff_strength from capture at LMB: 0 at outer edge, 1 at center; outside brush not in list.
        local falloff = point_info.falloff_strength or 0
        local f = falloff * power
        local new_time = point_info.original_time
        local new_value = point_info.original_value

        if kind == "smooth" then
            local skip_smooth = point_count <= 1
            if not skip_smooth and smooth_env_pos_by_idx and smooth_env_sorted then
                local pos = smooth_env_pos_by_idx[point_info.index]
                skip_smooth = pos ~= nil and pos == #smooth_env_sorted
            end
            if not skip_smooth then
            local scfg = config.sculpt
            local pw = clamp(state.sculpt_power or 1, scfg.MIN_SCULPT_POWER, scfg.MAX_SCULPT_POWER)
            local p_span = scfg.MAX_SCULPT_POWER - scfg.MIN_SCULPT_POWER
            local strength01 = (p_span >= 1e-12) and ((pw - scfg.MIN_SCULPT_POWER) / p_span) or 1
            strength01 = math.max(0, math.min(1, strength01))
            local cap = scfg.SMOOTH_MAX_BLEND_PER_MOVE or 1
            -- Linear in Power slider × spatial falloff: fraction of (neighbor target − current) applied this tick.
            local alpha = math.min(1, strength01 * falloff * cap)
            -- Laplacian in raw space: interior → blend toward mean of time-adjacent envelope neighbors; endpoints → toward sole neighbor.
            if not state.lock_value_axis and smooth_env_sorted and smooth_env_pos_by_idx then
                local pos = smooth_env_pos_by_idx[point_info.index]
                if pos then
                    local rows = smooth_env_sorted
                    local v_i = point_info.original_value
                    local v_prev = pos > 1 and rows[pos - 1].val or nil
                    local v_next = pos < #rows and rows[pos + 1].val or nil
                    local v_target
                    if v_prev and v_next then
                        v_target = (v_prev + v_next) * 0.5
                    elseif v_next then
                        v_target = v_next
                    elseif v_prev then
                        v_target = v_prev
                    else
                        v_target = v_i
                    end
                    new_value = v_i + (v_target - v_i) * alpha
                end
            end
            if not state.lock_time_axis and smooth_t_target_by_index then
                local t_tgt = smooth_t_target_by_index[point_info.index]
                if t_tgt ~= nil then
                    local t_i = point_info.original_time
                    new_time = t_i + (t_tgt - t_i) * alpha
                end
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
                    local _, mapped_raw = screen_to_envelope(sx1, new_vsy, envelope)
                    if mapped_raw ~= nil then
                        point_info.virtual_value_raw = mapped_raw
                        new_value = sanitize_raw_value(mapped_raw, point_info.original_value)
                    end
                end
            else
                local delta_time = (delta_x / pixel_width) * time_range * f
                if not state.lock_time_axis then
                    new_time = point_info.original_time + delta_time
                end
            end
        end

        tent_t[point_info.index] = new_time
        tent_v[point_info.index] = sanitize_raw_value(new_value, point_info.original_value)
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

function M.create_points_in_brush_area(state, config, mouse_x, mouse_y, radius, envelope, autoitem_idx, screen_to_envelope, envelope_to_screen, get_distance, _get_envelope_properties, value_for_insert, default_point_shape, seed_screen_point_cache)
    if not envelope or not value_for_insert then return 0 end

    local center_time = mouse_cursor_time()
    if not center_time then return 0 end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    local time_range = arrange_end - arrange_start
    local bounds = state.envelope_bounds
    local pixel_width = bounds.right - bounds.left
    if pixel_width <= 0 then return 0 end

    local radius_time = (radius / pixel_width) * time_range
    local points_created = 0
    local eps_ins = math.max(1e-12, math.abs(time_range) * 1e-14)
    --- Insert times committed this pass (avoids duplicate REAPER insert times in one seed pass).
    local placed_insert_t = {}

    local min_space = math.max(1, state.min_point_spacing_px or 1)
    local abs_tr = math.abs(time_range)
    local span_t = 2 * math.abs(radius_time)
    local cache_ok = can_reuse_seed_screen_point_cache(
        seed_screen_point_cache,
        envelope,
        autoitem_idx,
        center_time,
        radius,
        min_space,
        time_range,
        pixel_width
    )
    local active_seed_cache = seed_screen_point_cache
    if not cache_ok then
        active_seed_cache = build_seed_screen_point_cache(
            state,
            config,
            mouse_x,
            mouse_y,
            radius,
            envelope,
            autoitem_idx,
            screen_to_envelope,
            envelope_to_screen,
            get_envelope_properties,
            value_for_insert
        )
    end
    local screen_pt_list = (active_seed_cache and active_seed_cache.screen_pt_list) or {}
    local cached_seed_candidates = (active_seed_cache and active_seed_cache.seed_candidates) or nil

    local function min_dist_to_point_list(sx, sy)
        local best = math.huge
        for j = 1, #screen_pt_list do
            local p = screen_pt_list[j]
            local d = get_distance(sx, sy, p[1], p[2])
            if d < best then best = d end
        end
        return best
    end

    if span_t < 1e-18 then
        if points_created > 0 then
            sort_envelope_points(envelope, autoitem_idx)
            reaper.UpdateArrange()
        end
        return points_created
    end

    if cached_seed_candidates and #cached_seed_candidates > 0 then
        for i = 1, #cached_seed_candidates do
            local c = cached_seed_candidates[i]
            local insert_t = c.insert_t
            local new_value = c.value
            local sx, sy = c.sx, c.sy
            if insert_t ~= nil and new_value ~= nil and sx and sy and not insert_t_already_placed(placed_insert_t, insert_t, eps_ins) then
                if min_space <= 0 or min_dist_to_point_list(sx, sy) >= min_space then
                    local shape_in, tension = shape_and_tension_for_new_insert(
                        envelope, autoitem_idx, insert_t, default_point_shape, eps_ins
                    )
                    local selected, noSortIn = false, true
                    if insert_envelope_point(envelope, autoitem_idx, insert_t, new_value, shape_in, tension, selected, noSortIn) then
                        points_created = points_created + 1
                        placed_insert_t[#placed_insert_t + 1] = insert_t
                        screen_pt_list[#screen_pt_list + 1] = { sx, sy }
                    end
                end
            end
        end
    else
        -- Sample timeline across brush diameter; spacing derived from min pixel gap (screen X ~ proportional to time).
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
                local base_value, insert_t, eval_t = value_for_insert(envelope, point_time, autoitem_idx)
                if base_value ~= nil and insert_t ~= nil and not insert_t_already_placed(placed_insert_t, insert_t, eps_ins) then
                    local t_vis = eval_t or point_time
                    local sx_c, sy_c = envelope_to_screen(t_vis, base_value, envelope)
                    if sx_c and sy_c then
                        local new_value = sanitize_raw_value(base_value, nil)
                        if new_value == nil then
                            goto continue_seed_insert
                        end
                        local sx, sy = envelope_to_screen(t_vis, new_value, envelope)
                        if sx and sy then
                            if min_space <= 0 or min_dist_to_point_list(sx, sy) >= min_space then
                                local shape_in, tension = shape_and_tension_for_new_insert(
                                    envelope, autoitem_idx, insert_t, default_point_shape, eps_ins
                                )
                                local selected, noSortIn = false, true
                                if insert_envelope_point(envelope, autoitem_idx, insert_t, new_value, shape_in, tension, selected, noSortIn) then
                                    points_created = points_created + 1
                                    placed_insert_t[#placed_insert_t + 1] = insert_t
                                    screen_pt_list[#screen_pt_list + 1] = { sx, sy }
                                end
                            end
                        end
                    end
                end
            end
            ::continue_seed_insert::
        end
    end

    if points_created > 0 then
        sort_envelope_points(envelope, autoitem_idx)
        reaper.UpdateArrange()
    end

    return points_created
end

--- Single InsertEnvelopePoint*. Caller should run Core.prepare_envelope_for_point_insert first (deps does).
--- Project time from screen_to_envelope X; value and insert time from value_for_insert (device SRATE/BSIZE + take remap when applicable).
function M.insert_one_point_at_screen(envelope, autoitem_idx, mx, my, screen_to_envelope, value_for_insert, default_point_shape)
    if not envelope or not screen_to_envelope or not value_for_insert then
        return false
    end
    local t = screen_to_envelope(mx, my, envelope)
    if not t then
        return false
    end
    local v, ins_t, eval_t = value_for_insert(envelope, t, autoitem_idx)
    if v == nil then
        return false
    end
    if ins_t == nil then
        return false
    end
    local shape_in, tension = shape_and_tension_for_new_insert(envelope, autoitem_idx, ins_t, default_point_shape)
    local ok = insert_envelope_point(envelope, autoitem_idx, ins_t, v, shape_in, tension, false, false)
    if ok then
        sort_envelope_points(envelope, autoitem_idx)
        reaper.UpdateArrange()
    end
    return ok
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

--- Clear all point selection on the envelope, then select indices in `captured_points` (nudge/sculpt drag start; not smooth).
function M.sync_envelope_selection_to_captured(envelope, autoitem_idx, captured_points)
    if not envelope then return end
    local select_idx = {}
    for _, p in ipairs(captured_points or {}) do
        if type(p.index) == "number" then
            select_idx[p.index] = true
            p.original_selected = true
        end
    end
    local n = count_envelope_points(envelope, autoitem_idx)
    local changed = false
    for i = 0, n - 1 do
        local ok, t, v, shape, tension, sel = get_envelope_point(envelope, autoitem_idx, i)
        if ok then
            local want = select_idx[i] or false
            if sel ~= want then
                set_envelope_point(envelope, autoitem_idx, i, t, v, shape, tension, want, true)
                changed = true
            end
        end
    end
    if changed then
        reaper.UpdateArrange()
    end
end

return M
