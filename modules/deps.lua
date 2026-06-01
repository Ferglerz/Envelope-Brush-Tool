local M = {}

local _mod_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_mod_dir .. "path.lua")
local Mods = Path.load_from_modules("mods.lua")

local function shift_fine_active()
    return reaper.JS_Mouse_GetState and (reaper.JS_Mouse_GetState(Mods.JS_SHIFT) or 0) > 0
end

function M.new(state, config, modules)
    local core, envelope, ops, input = modules.core, modules.envelope, modules.ops, modules.input
    local deps = {}

    deps.get_mouse_client_xy = function() return core.get_mouse_client_xy(state.ctx, core.get_arrange_hwnd) end
    deps.brush_center_client_xy = function(mx, my)
        return core.brush_center_client_xy(state, state.target_envelope, mx, my)
    end
    deps.get_arrange_imgui_overlay_geometry = function() return core.get_arrange_imgui_overlay_geometry(state.ctx, core.get_arrange_hwnd) end
    deps.get_mouse_imgui_xy = function() return core.get_mouse_imgui_xy(state.ctx) end
    deps.get_envelope_properties = function(target_envelope) return core.get_envelope_properties(state, target_envelope) end
    deps.envelope_value_at_time = function(env, t) return core.envelope_value_at_time(env, t) end
    deps.envelope_value_for_insert = function(env, t)
        return core.envelope_value_for_insert(env, t, core.track_autoitem_idx(state))
    end

    deps.screen_to_envelope = function(x, y, env)
        return envelope.screen_to_envelope(state, deps.get_envelope_properties, x, y, env)
    end
    deps.envelope_to_screen = function(time, value, env)
        return envelope.envelope_to_screen(state, deps.get_envelope_properties, time, value, env)
    end
    deps.setup_envelope_bounds = function()
        return envelope.setup_envelope_bounds(state, config, core.get_arrange_hwnd)
    end
    deps.clear_target_envelope_state_only = function()
        return core.clear_target_envelope_state_only(state)
    end
    deps.point_hits_envelope_curve = function(env, mx, my)
        return envelope.point_hits_envelope_curve(state, config, deps.envelope_to_screen, env, mx, my, core.envelope_value_at_time)
    end

    deps.insert_one_point_at_arrange_client = function(mx, my)
        local env = state.target_envelope
        if not env or mx == nil or my == nil then return false end
        local ai = core.track_autoitem_idx(state)
        core.prepare_envelope_for_point_insert(env, state)
        local ok = ops.insert_one_point_at_screen(
            env, ai, mx, my,
            deps.screen_to_envelope,
            core.envelope_value_for_insert,
            core.get_envelope_default_point_shape(env, state)
        )
        return ok
    end

    deps.create_points_in_brush_area = function(mx, my, radius, env)
        local ai = core.track_autoitem_idx(state)
        return ops.create_points_in_brush_area(
            state, config, mx, my, radius, env, ai,
            deps.screen_to_envelope, deps.envelope_to_screen, core.get_distance,
            deps.get_envelope_properties, core.envelope_value_for_insert, core.get_envelope_default_point_shape(env, state),
            state.seed_hover_cache
        )
    end

    deps.seed_brush_width_at_client = function(mx, my)
        local env = state.target_envelope
        if not env or mx == nil or my == nil then return 0 end
        core.prepare_envelope_for_point_insert(env, state)
        local n = deps.create_points_in_brush_area(mx, my, state.brush_size, env)
        state.seed_hover_cache = nil
        state.seed_hover_last_client = nil
        return n
    end

    deps.warm_seed_cache_for_hover = function(mx, my)
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
            mx,
            my,
            state.brush_size,
            env,
            ai,
            deps.screen_to_envelope,
            deps.envelope_to_screen,
            deps.get_envelope_properties,
            core.envelope_value_for_insert
        )
        state.seed_hover_last_client = { x = mx, y = my }
        return state.seed_hover_cache ~= nil
    end

    deps.capture_points_in_radius = function(mx, my, radius, env)
        local ai = core.track_autoitem_idx(state)
        return ops.capture_points_in_radius(
            state, config, mx, my, radius, env, ai,
            deps.envelope_to_screen, core.get_distance, core.calculate_falloff
        )
    end

    deps.sculpt_captured_points = function(points, dx, dy, env)
        local ai = core.track_autoitem_idx(state)
        return ops.sculpt_captured_points(
            state, config, points, dx, dy, env, ai,
            deps.get_envelope_properties, core.clamp, core.envelope_value_at_time,
            deps.envelope_to_screen, deps.screen_to_envelope, core.get_distance
        )
    end

    deps.refresh_captured_from_envelope = function(env)
        local ai = core.track_autoitem_idx(state)
        return ops.refresh_captured_from_envelope(state, env, ai)
    end

    deps.sync_brush_point_selection = function(env, captured_points)
        local ai = core.track_autoitem_idx(state)
        return ops.sync_envelope_selection_to_captured(env, ai, captured_points)
    end

    deps.calc_inner_brush_radius = function(outer_radius)
        return core.calc_inner_brush_radius(state, config, outer_radius)
    end

    deps.falloff_strength_percent = function(strength)
        return core.falloff_strength_percent(strength, config)
    end

    deps.sculpt_power_percent = function(power)
        return core.sculpt_power_percent(power, config)
    end

    deps.primary_modifier_short_name = core.primary_modifier_short_name

    deps.brush_drag_kind_key = function()
        return (state.is_dragging and state.active_sculpt_kind) or input.resolve_brush_drag_kind()
    end

    deps.brush_drag_kind_display = function()
        local k = deps.brush_drag_kind_key()
        local label = (config.drag.BRUSH_DRAG_KIND_LABELS and config.drag.BRUSH_DRAG_KIND_LABELS[k]) or k
        if (k == "nudge" or k == "sculpt") and shift_fine_active() then
            label = label .. " (Fine)"
        end
        return label
    end

    deps.brush_mode_falloff_header = function(falloff_label)
        local k = deps.brush_drag_kind_key()
        if k == "smooth" then
            return deps.brush_drag_kind_display()
        end
        return deps.brush_drag_kind_display() .. " - " .. falloff_label
    end

    deps.arrange_client_to_imgui = function(x, y)
        return core.arrange_client_to_imgui(state.ctx, core.get_arrange_hwnd, x, y)
    end

    --- Smooth LMB up: bezier merge → angle cleanup → bezier merge; see input.end_drag_operation.
    local function run_smooth_angle_cleanup_on_lmb_up()
        if state.active_sculpt_kind ~= "smooth" or not state.target_envelope then
            return
        end
        local autoitem_idx = core.track_autoitem_idx(state)
        ops.sort_envelope_points_for_autoitem(state.target_envelope, autoitem_idx)
        if state.captured_points and #state.captured_points > 0 then
            deps.refresh_captured_from_envelope(state.target_envelope)
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
        local deleted = 0
        if bezier_on then
            deleted = ops.merge_smooth_stroke_envelope_spans(
                config, env, autoitem_idx, nil, deps.envelope_value_at_time, stroke_times, merge_opts
            )
        end
        if angle_on then
            deleted = deleted + ops.remove_redundant_envelope_points_by_angle(
                config, env, autoitem_idx, deps.envelope_to_screen, nil, stroke_times
            )
        end
        if bezier_on then
            deleted = deleted + ops.merge_smooth_stroke_envelope_spans(
                config, env, autoitem_idx, nil, deps.envelope_value_at_time, stroke_times, merge_opts
            )
        end
        if deleted > 0 then
            state.envelope_stroke_dirty = true
        end
    end
    deps.run_smooth_angle_cleanup_on_lmb_up = run_smooth_angle_cleanup_on_lmb_up

    deps.end_drag_operation = function()
        return input.end_drag_operation(state, {
            config = config,
            sort_envelope_points_for_autoitem = ops.sort_envelope_points_for_autoitem,
            cleanup_redundant_points_after_drag = run_smooth_angle_cleanup_on_lmb_up,
        })
    end

    return deps
end

return M
