local M = {}

local JS_SHIFT = 8

local function shift_fine_active()
    return reaper.JS_Mouse_GetState and (reaper.JS_Mouse_GetState(JS_SHIFT) or 0) > 0
end

function M.new(state, config, modules)
    local core, envelope, ops, input = modules.core, modules.envelope, modules.ops, modules.input
    local deps = {}

    deps.get_mouse_client_xy = function() return core.get_mouse_client_xy(state.ctx, core.get_arrange_hwnd) end
    deps.get_arrange_imgui_overlay_geometry = function() return core.get_arrange_imgui_overlay_geometry(state.ctx, core.get_arrange_hwnd) end
    deps.get_mouse_imgui_xy = function() return core.get_mouse_imgui_xy(state.ctx) end
    deps.get_envelope_properties = function(target_envelope) return core.get_envelope_properties(state, target_envelope) end

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
        local ai, cmd_id = state.envelope_autoitem_idx or -1, config.arrange.INSERT_AT_MOUSE_ACTION_ID
        if type(cmd_id) == "number" and cmd_id > 0 and reaper.Main_OnCommand then
            reaper.Main_OnCommand(cmd_id, 0)
            reaper.UpdateArrange()
            ops.enforce_min_screen_spacing(state, env, ai, deps.envelope_to_screen, core.get_distance, nil)
            return true
        end
        core.prepare_envelope_for_point_insert(env)
        local ok = ops.insert_one_point_at_screen(
            env, ai, mx, my,
            deps.screen_to_envelope,
            core.envelope_value_for_insert,
            core.get_envelope_default_point_shape(env, state)
        )
        if ok then
            ops.enforce_min_screen_spacing(state, env, ai, deps.envelope_to_screen, core.get_distance, nil)
        end
        return ok
    end

    deps.create_points_in_brush_area = function(mx, my, radius, env)
        local ai = state.envelope_autoitem_idx or -1
        return ops.create_points_in_brush_area(
            state, config, mx, my, radius, env, ai,
            deps.screen_to_envelope, deps.envelope_to_screen, core.get_distance,
            deps.get_envelope_properties, core.envelope_value_for_insert, core.get_envelope_default_point_shape(env, state)
        )
    end

    deps.seed_brush_width_at_client = function(mx, my)
        local env = state.target_envelope
        if not env or mx == nil or my == nil then return 0 end
        core.prepare_envelope_for_point_insert(env)
        return deps.create_points_in_brush_area(mx, my, state.brush_size, env)
    end

    deps.capture_points_in_radius = function(mx, my, radius, env)
        local ai = state.envelope_autoitem_idx or -1
        return ops.capture_points_in_radius(
            state, config, mx, my, radius, env, ai,
            deps.envelope_to_screen, core.get_distance, core.calculate_falloff
        )
    end

    deps.sculpt_captured_points = function(points, dx, dy, env)
        local ai = state.envelope_autoitem_idx or -1
        return ops.sculpt_captured_points(
            state, config, points, dx, dy, env, ai,
            deps.get_envelope_properties, core.clamp, core.envelope_value_at_time,
            deps.envelope_to_screen, deps.screen_to_envelope, core.get_distance
        )
    end

    deps.refresh_captured_from_envelope = function(env)
        local ai = state.envelope_autoitem_idx or -1
        return ops.refresh_captured_from_envelope(state, env, ai)
    end

    deps.calc_inner_brush_radius = function(outer_radius)
        return core.calc_inner_brush_radius(state, config, outer_radius)
    end

    deps.primary_modifier_short_name = core.primary_modifier_short_name

    deps.brush_drag_kind_display = function()
        local k = (state.is_dragging and state.active_sculpt_kind) or input.resolve_brush_drag_kind()
        local label = (config.drag.BRUSH_DRAG_KIND_LABELS and config.drag.BRUSH_DRAG_KIND_LABELS[k]) or k
        if (k == "nudge" or k == "sculpt") and shift_fine_active() then
            label = label .. " (Fine)"
        end
        return label
    end

    deps.arrange_client_to_imgui = function(x, y)
        return core.arrange_client_to_imgui(state.ctx, core.get_arrange_hwnd, x, y)
    end

    deps.for_each_envelope_point = ops.for_each_envelope_point

    local function run_min_spacing_after_drag_if_needed()
        if state.target_envelope then
            ops.enforce_min_screen_spacing(state, state.target_envelope, state.envelope_autoitem_idx or -1, deps.envelope_to_screen, core.get_distance, nil)
        end
    end
    deps.run_min_spacing_after_drag_if_needed = run_min_spacing_after_drag_if_needed

    deps.end_drag_operation = function()
        return input.end_drag_operation(state, {
            sort_envelope_points_for_autoitem = ops.sort_envelope_points_for_autoitem,
            enforce_min_spacing_after_drag = run_min_spacing_after_drag_if_needed,
        })
    end

    return deps
end

return M
