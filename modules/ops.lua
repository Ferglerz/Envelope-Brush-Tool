local M = {}

local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""
local EnvApi = dofile(SCRIPT_DIR .. "envelope/envelope_api.lua")
local Mods = dofile(SCRIPT_DIR .. "mods.lua")

local function scaling_mode(envelope)
    if not envelope then return 0 end
    return reaper.GetEnvelopeScalingMode(envelope) or 0
end

local function api_value_to_linear(envelope, value)
    if type(value) ~= "number" then return value end
    local mode = scaling_mode(envelope)
    if mode == 0 then return value end
    return reaper.ScaleFromEnvelopeMode(mode, value)
end

local function linear_value_to_api(envelope, value)
    if type(value) ~= "number" then return value end
    local mode = scaling_mode(envelope)
    if mode == 0 then return value end
    return reaper.ScaleToEnvelopeMode(mode, value)
end

local function count_envelope_points(envelope, autoitem_idx)
    return reaper.CountEnvelopePoints(envelope)
end

function M.count_envelope_points(envelope, autoitem_idx)
    if not envelope then return 0 end
    return count_envelope_points(envelope, autoitem_idx or -1)
end

local function get_envelope_point(envelope, autoitem_idx, i)
    local ok, t, v, shape, tension, selected = reaper.GetEnvelopePoint(envelope, i)
    if not ok then
        return false, nil, nil, shape, tension, selected
    end
    return true, t, api_value_to_linear(envelope, v), shape, tension, selected
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
    return reaper.SetEnvelopePoint(envelope, i, t, linear_value_to_api(envelope, v), shape, tension, sel, no_sort)
end

local function insert_envelope_point(envelope, autoitem_idx, t, v, shape, tension, sel, no_sort)
    return reaper.InsertEnvelopePoint(envelope, t, linear_value_to_api(envelope, v), shape, tension, sel, no_sort)
end

function M.sort_envelope_points_for_autoitem(envelope, autoitem_idx)
    if not envelope then return end
    if reaper.Envelope_SortPoints then
        reaper.Envelope_SortPoints(envelope)
    end
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

local function interior_angle_deg(sax, say, sbx, sby, scx, scy)
    local bax, bay = sax - sbx, say - sby
    local bcx, bcy = scx - sbx, scy - sby
    local len_a = math.sqrt(bax * bax + bay * bay)
    local len_c = math.sqrt(bcx * bcx + bcy * bcy)
    if len_a < 1e-6 or len_c < 1e-6 then
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

--- Remove interior points nearly collinear in arrange screen space (time-sorted neighbors).
--- Repeats until no removals. Caller: smooth mode, LMB release only (not min_point_spacing_px).
function M.remove_redundant_envelope_points_by_angle(config, envelope, autoitem_idx, envelope_to_screen, captured_points)
    if not envelope or not envelope_to_screen or not config then
        return 0
    end
    local ccfg = config.cleanup
    local min_angle = (ccfg and ccfg.REDUNDANT_POINT_MIN_ANGLE_DEG) or 175
    if min_angle < 0 then min_angle = 0 elseif min_angle > 180 then min_angle = 180 end

    local total_deleted = 0
    while true do
        local n = count_envelope_points(envelope, autoitem_idx)
        if n < 3 then break end

        local rows = {}
        for i = 0, n - 1 do
            local ok, t, v = get_envelope_point(envelope, autoitem_idx, i)
            if ok and t ~= nil and v ~= nil then
                rows[#rows + 1] = { idx = i, time = t, val = v }
            end
        end
        if #rows < 3 then break end

        table.sort(rows, function(a, b)
            if a.time ~= b.time then return a.time < b.time end
            return a.idx < b.idx
        end)

        local mark = {}
        for k = 2, #rows - 1 do
            local prev, mid, nxt = rows[k - 1], rows[k], rows[k + 1]
            local sax, say = envelope_to_screen(prev.time, prev.val, envelope)
            local sbx, sby = envelope_to_screen(mid.time, mid.val, envelope)
            local scx, sccy = envelope_to_screen(nxt.time, nxt.val, envelope)
            if sax and say and sbx and sby and scx and sccy then
                local ang = interior_angle_deg(sax, say, sbx, sby, scx, sccy)
                if ang and ang >= min_angle then
                    mark[mid.idx] = true
                end
            end
        end

        local dels = {}
        for idx, _ in pairs(mark) do
            dels[#dels + 1] = idx
        end
        if #dels == 0 then break end

        table.sort(dels, function(a, b) return a > b end)
        for _, d in ipairs(dels) do
            if reaper.DeleteEnvelopePointEx(envelope, autoitem_idx, d) then
                total_deleted = total_deleted + 1
                adjust_captured_indices_after_delete(captured_points, d)
            end
        end
    end

    if total_deleted > 0 then
        reaper.UpdateArrange()
    end
    return total_deleted
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

    local shape_in = (type(default_point_shape) == "number" and default_point_shape) or 0

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
                    local tension, selected, noSortIn = 0, false, true
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
                                local tension, selected, noSortIn = 0, false, true
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
    local shape_in = (type(default_point_shape) == "number" and default_point_shape) or 0
    local ok = insert_envelope_point(envelope, autoitem_idx, ins_t, v, shape_in, 0, false, false)
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

--- Clear all point selection on the envelope, then select indices in `captured_points` (sculpt/nudge drag start).
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
