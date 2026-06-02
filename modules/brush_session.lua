-- Session-bound brush ops (replaces deps.lua closure table).

local M = {}

local JS_SHIFT = 8

local function shift_fine_active()
    return reaper.JS_Mouse_GetState and (reaper.JS_Mouse_GetState(JS_SHIFT) or 0) > 0
end

function M.get_mouse_client_xy(state, core)
    return core.get_mouse_client_xy(state.ctx, core.get_arrange_hwnd)
end

function M.screen_to_envelope(state, envelope_mod, x, y, env)
    return envelope_mod.screen_to_envelope(state, x, y, env)
end

function M.envelope_to_screen(state, envelope_mod, time, value, env)
    return envelope_mod.envelope_to_screen(state, time, value, env)
end

function M.value_for_insert(state, core, env, t)
    return core.envelope_value_for_insert(env, t, core.track_autoitem_idx(state))
end

function M.create_points_in_brush_area(state, config, core, envelope_mod, ops, mx, my, radius, env)
    local ai = core.track_autoitem_idx(state)
    return ops.create_points_in_brush_area(
        state, config, mx, my, radius, env, ai,
        function(t, v, e) return M.envelope_to_screen(state, envelope_mod, t, v, e) end,
        core.get_distance,
        function(e, pt) return M.value_for_insert(state, core, e, pt) end,
        core.get_envelope_default_point_shape(env, state),
        state.seed_hover_cache
    )
end

function M.seed_brush_width_at_client(state, config, core, envelope_mod, ops, mx, my)
    local env = state.target_envelope
    if not env or mx == nil or my == nil then return 0 end
    core.prepare_envelope_for_point_insert(env, state)
    local n = M.create_points_in_brush_area(state, config, core, envelope_mod, ops, mx, my, state.brush_size, env)
    state.seed_hover_cache = nil
    state.seed_hover_last_client = nil
    return n
end

function M.warm_seed_cache_for_hover(state, config, core, envelope_mod, ops, mx, my)
    local env = state.target_envelope
    if not env or mx == nil or my == nil or state.is_dragging then
        return false
    end
    local scfg = config.seed or {}
    if not scfg.HOVER_WARM_ENABLED then
        return false
    end
    local now = reaper.time_precise and reaper.time_precise() or 0
    local min_iv = scfg.HOVER_WARM_INTERVAL_SEC or 0.05
    local min_move = scfg.HOVER_WARM_MIN_MOUSE_MOVE_PX or 2
    local prev = state.seed_hover_last_client
    local moved = true
    if prev then
        local dx = mx - prev.x
        local dy = my - prev.y
        moved = (dx * dx + dy * dy) >= (min_move * min_move)
    end
    local cache = state.seed_hover_cache
    local age = (cache and cache.built_os) and (now - cache.built_os) or math.huge
    local ai = core.track_autoitem_idx(state)
    local same_env = cache
        and cache.envelope == env
        and (cache.autoitem_idx or -1) == ai
        and math.abs((cache.brush_size or 0) - (state.brush_size or 0)) <= 1e-9
    if not moved and same_env and age < min_iv then
        return false
    end
    state.seed_hover_cache = ops.build_seed_screen_point_cache(
        state,
        config,
        state._brush_center_time,
        state.brush_size,
        env,
        ai,
        function(t, v, e) return M.envelope_to_screen(state, envelope_mod, t, v, e) end,
        function(e, pt) return M.value_for_insert(state, core, e, pt) end
    )
    state.seed_hover_last_client = { x = mx, y = my }
    return state.seed_hover_cache ~= nil
end

function M.capture_points_in_radius(state, config, core, envelope_mod, ops, mx, my, radius, env)
    local ai = core.track_autoitem_idx(state)
    return ops.capture_points_in_radius(
        state, config, mx, my, radius, env, ai,
        function(t, v, e) return M.envelope_to_screen(state, envelope_mod, t, v, e) end,
        core.get_distance,
        core.calculate_falloff
    )
end

function M.sculpt_captured_points(state, config, core, envelope_mod, ops, points, dx, dy, env)
    local ai = core.track_autoitem_idx(state)
    return ops.sculpt_captured_points(
        state, config, points, dx, dy, env, ai,
        core.clamp,
        function(t, v, e) return M.envelope_to_screen(state, envelope_mod, t, v, e) end,
        function(x, y, e) return M.screen_to_envelope(state, envelope_mod, x, y, e) end,
        core.get_distance
    )
end

function M.sync_brush_point_selection(state, core, ops, env, captured_points)
    return ops.sync_envelope_selection_to_captured(env, core.track_autoitem_idx(state), captured_points)
end

function M.brush_drag_kind_key(state, input)
    return (state.is_dragging and state.active_sculpt_kind) or input.resolve_brush_drag_kind()
end

function M.brush_drag_kind_display(state, config, input)
    local k = M.brush_drag_kind_key(state, input)
    local label = (config.drag.BRUSH_DRAG_KIND_LABELS and config.drag.BRUSH_DRAG_KIND_LABELS[k]) or k
    if (k == "nudge" or k == "sculpt") and shift_fine_active() then
        label = label .. " (Fine)"
    end
    return label
end

function M.brush_mode_falloff_header(state, config, input, falloff_label)
    local k = M.brush_drag_kind_key(state, input)
    if k == "smooth" then
        return M.brush_drag_kind_display(state, config, input)
    end
    return M.brush_drag_kind_display(state, config, input) .. " - " .. falloff_label
end

function M.run_smooth_angle_cleanup_on_lmb_up(state, config, core, envelope_mod, ops, input)
    if state.active_sculpt_kind ~= "smooth" or not state.target_envelope then
        return
    end
    local autoitem_idx = core.track_autoitem_idx(state)
    ops.sort_envelope_points_for_autoitem(state.target_envelope, autoitem_idx)
    if state.captured_points and #state.captured_points > 0 then
        ops.refresh_captured_from_envelope(state, state.target_envelope, autoitem_idx)
        input.note_smooth_stroke_capture(state, state.captured_points)
    end
    local stroke_times = state.smooth_stroke_point_times
    local env = state.target_envelope
    local bezier_on = state.smooth_cleanup_bezier_enabled ~= false
    local angle_on = state.smooth_cleanup_angle_enabled ~= false
    if not bezier_on and not angle_on then
        return
    end
    local merge_opts = { bezier_max_err = state.smooth_bezier_fit_tolerance }
    local value_at = function(e, t) return core.envelope_value_at_time(e, t) end
    local to_screen = function(t, v, e) return M.envelope_to_screen(state, envelope_mod, t, v, e) end
    local deleted = 0
    if bezier_on then
        deleted = ops.merge_smooth_stroke_envelope_spans(
            config, env, autoitem_idx, nil, value_at, stroke_times, merge_opts
        )
    end
    if angle_on then
        deleted = deleted + ops.remove_redundant_envelope_points_by_angle(
            config, env, autoitem_idx, to_screen, nil, stroke_times
        )
    end
    if bezier_on then
        deleted = deleted + ops.merge_smooth_stroke_envelope_spans(
            config, env, autoitem_idx, nil, value_at, stroke_times, merge_opts
        )
    end
    if deleted > 0 then
        state.envelope_stroke_dirty = true
    end
end

function M.end_drag_operation(state, config, core, envelope_mod, ops, input)
    local cleanup = function()
        M.run_smooth_angle_cleanup_on_lmb_up(state, config, core, envelope_mod, ops, input)
    end
    return input.end_drag_operation(state, {
        config = config,
        sort_envelope_points_for_autoitem = ops.sort_envelope_points_for_autoitem,
        cleanup_redundant_points_after_drag = cleanup,
    })
end

function M.render_deps(state, config, core, input)
    return {
        calc_inner_brush_radius = function(outer) return core.calc_inner_brush_radius(state, config, outer) end,
        get_arrange_imgui_overlay_geometry = function() return core.get_arrange_imgui_overlay_geometry(state.ctx, core.get_arrange_hwnd) end,
        brush_center_client_xy = function(mx, my) return core.brush_center_client_xy(state, state.target_envelope, mx, my) end,
        get_mouse_client_xy = function() return M.get_mouse_client_xy(state, core) end,
        arrange_client_to_imgui = function(x, y) return core.arrange_client_to_imgui(state.ctx, core.get_arrange_hwnd, x, y) end,
        brush_drag_kind_key = function() return M.brush_drag_kind_key(state, input) end,
        brush_drag_kind_display = function() return M.brush_drag_kind_display(state, config, input) end,
        brush_mode_falloff_header = function(lbl) return M.brush_mode_falloff_header(state, config, input, lbl) end,
        primary_modifier_short_name = core.primary_modifier_short_name,
        falloff_strength_percent = function(s) return 100 * (s or 0) end,
        sculpt_power_percent = function(p) return 100 * (p or 0) end,
        calculate_falloff = core.calculate_falloff,
        clear_wheel_momentum = function(st) return input.clear_wheel_momentum(st) end,
    }
end

function M.drag_deps(state, config, core, envelope_mod, ops)
    return {
        seed_brush_width_at_client = function(mx, my) return M.seed_brush_width_at_client(state, config, core, envelope_mod, ops, mx, my) end,
        capture_points_in_radius = function(mx, my, r, env) return M.capture_points_in_radius(state, config, core, envelope_mod, ops, mx, my, r, env) end,
        sculpt_captured_points = function(pts, dx, dy, env) return M.sculpt_captured_points(state, config, core, envelope_mod, ops, pts, dx, dy, env) end,
        refresh_captured_from_envelope = function(env) return ops.refresh_captured_from_envelope(state, env, core.track_autoitem_idx(state)) end,
        sync_brush_point_selection = function(env, pts) return M.sync_brush_point_selection(state, core, ops, env, pts) end,
        get_distance = core.get_distance,
    }
end

return M
