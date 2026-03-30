local M = {}

function M.new(state, config, modules)
    local core = modules.core
    local envelope = modules.envelope
    local ops = modules.ops
    local render = modules.render
    local input = modules.input

    local deps = {}

    deps.get_mouse_client_xy = function()
        return core.get_mouse_client_xy(core.get_arrange_hwnd)
    end

    deps.get_arrange_imgui_overlay_geometry = function()
        return core.get_arrange_imgui_overlay_geometry(state.ctx, core.get_arrange_hwnd)
    end

    deps.get_mouse_imgui_xy = function()
        return core.get_mouse_imgui_xy(state.ctx)
    end

    deps.get_envelope_properties = function(target_envelope)
        return core.get_envelope_properties(state, target_envelope)
    end

    deps.screen_to_envelope = function(screen_x, screen_y, target_envelope)
        return envelope.screen_to_envelope(state, deps.get_envelope_properties, screen_x, screen_y, target_envelope)
    end

    deps.envelope_to_screen = function(project_time, envelope_value, target_envelope)
        return envelope.envelope_to_screen(state, deps.get_envelope_properties, project_time, envelope_value, target_envelope)
    end

    deps.setup_envelope_bounds = function()
        return envelope.setup_envelope_bounds(state, config, core.get_arrange_hwnd)
    end

    deps.clear_target_envelope_state_only = function()
        return core.clear_target_envelope_state_only(state)
    end

    deps.point_hits_envelope_curve = function(target_envelope, mx, my)
        return envelope.point_hits_envelope_curve(state, config, deps.envelope_to_screen, target_envelope, mx, my)
    end

    deps.create_points_in_brush_area = function(mouse_x, mouse_y, radius, target_envelope)
        return ops.create_points_in_brush_area(
            state, config, mouse_x, mouse_y, radius, target_envelope,
            deps.screen_to_envelope, deps.envelope_to_screen, core.get_distance, core.calculate_falloff
        )
    end

    deps.capture_points_in_radius = function(mouse_x, mouse_y, radius, target_envelope)
        return ops.capture_points_in_radius(
            state, config, mouse_x, mouse_y, radius, target_envelope,
            deps.envelope_to_screen, core.get_distance, core.calculate_falloff
        )
    end

    deps.sculpt_captured_points = function(captured_points, delta_x, delta_y, target_envelope, no_sort)
        return ops.sculpt_captured_points(
            state, config, captured_points, delta_x, delta_y, target_envelope, no_sort,
            deps.get_envelope_properties, core.clamp
        )
    end

    deps.refresh_captured_from_envelope = function(target_envelope)
        return ops.refresh_captured_from_envelope(state, target_envelope)
    end

    deps.calc_inner_brush_radius = function(outer_radius)
        return core.calc_inner_brush_radius(state, config, outer_radius)
    end

    deps.native_to_hud_coords = function(ctx, x_native, y_native)
        return core.native_to_hud_coords(ctx, x_native, y_native)
    end

    deps.brush_hud_interactive = function()
        return render.brush_hud_interactive(state)
    end

    deps.end_drag_operation = function()
        return input.end_drag_operation(state)
    end

    deps.clear_envelope_target = function()
        return input.clear_envelope_target(state, deps.end_drag_operation)
    end

    return deps
end

return M
