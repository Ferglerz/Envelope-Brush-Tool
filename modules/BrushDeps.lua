local M = {}

--- JS_Mouse_GetState(8): Shift — Fine (half strength on Sculpt drag; matches BrushOps).
local JS_SHIFT = 8

local function shift_fine_active()
    if not reaper.JS_Mouse_GetState then return false end
    return (reaper.JS_Mouse_GetState(JS_SHIFT) or 0) > 0
end

function M.new(state, config, modules)
    local core = modules.core
    local envelope = modules.envelope
    local ops = modules.ops
    local input = modules.input

    local deps = {}

    deps.get_mouse_client_xy = function()
        return core.get_mouse_client_xy(state.ctx, core.get_arrange_hwnd)
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
        return envelope.point_hits_envelope_curve(state, config, deps.envelope_to_screen, target_envelope, mx, my, core.envelope_value_at_time)
    end

    --- One point at mouse: Main_OnCommand(INSERT_AT_MOUSE_ACTION_ID) when configured (matches shortcut path), else API insert.
    deps.insert_one_point_at_arrange_client = function(mx, my)
        if not state.target_envelope or mx == nil or my == nil then
            return false
        end
        local env = state.target_envelope
        local ai = state.envelope_autoitem_idx or -1
        local cmd_id = config.INSERT_AT_MOUSE_ACTION_ID
        if type(cmd_id) == "number" and cmd_id > 0 and reaper.Main_OnCommand then
            reaper.Main_OnCommand(cmd_id, 0)
            reaper.UpdateArrange()
            ops.enforce_min_screen_spacing(state, env, ai, deps.envelope_to_screen, core.get_distance, nil)
            return true
        end
        core.prepare_envelope_for_point_insert(env)
        local def_shape = core.get_envelope_default_point_shape(env, state)
        local ok = ops.insert_one_point_at_screen(
            env,
            ai,
            mx,
            my,
            function(x, y, e)
                return deps.screen_to_envelope(x, y, e)
            end,
            core.envelope_value_for_insert,
            def_shape
        )
        if ok then
            ops.enforce_min_screen_spacing(state, env, ai, deps.envelope_to_screen, core.get_distance, nil)
        end
        return ok
    end

    deps.create_points_in_brush_area = function(mouse_x, mouse_y, radius, target_envelope)
        local ai = state.envelope_autoitem_idx or -1
        local def_shape = core.get_envelope_default_point_shape(target_envelope, state)
        return ops.create_points_in_brush_area(
            state, config, mouse_x, mouse_y, radius, target_envelope, ai,
            deps.screen_to_envelope, deps.envelope_to_screen, core.get_distance, core.calculate_falloff,
            deps.get_envelope_properties, core.envelope_value_for_insert, def_shape
        )
    end

    --- Sculpt (Cmd): first LMB — prepare + spread points across brush width in time (InsertEnvelopePoint* only).
    deps.seed_brush_width_at_client = function(mx, my)
        if not state.target_envelope or mx == nil or my == nil then return 0 end
        core.prepare_envelope_for_point_insert(state.target_envelope)
        return deps.create_points_in_brush_area(mx, my, state.brush_size, state.target_envelope)
    end

    deps.capture_points_in_radius = function(mouse_x, mouse_y, radius, target_envelope)
        local ai = state.envelope_autoitem_idx or -1
        return ops.capture_points_in_radius(
            state, config, mouse_x, mouse_y, radius, target_envelope, ai,
            deps.envelope_to_screen, core.get_distance, core.calculate_falloff
        )
    end

    deps.sculpt_captured_points = function(captured_points, delta_x, delta_y, target_envelope)
        local ai = state.envelope_autoitem_idx or -1
        return ops.sculpt_captured_points(
            state, config, captured_points, delta_x, delta_y, target_envelope, ai,
            deps.get_envelope_properties, core.clamp, core.envelope_value_at_time, deps.envelope_to_screen,
            deps.screen_to_envelope, core.get_distance
        )
    end

    deps.refresh_captured_from_envelope = function(target_envelope)
        local ai = state.envelope_autoitem_idx or -1
        return ops.refresh_captured_from_envelope(state, target_envelope, ai)
    end

    deps.calc_inner_brush_radius = function(outer_radius)
        return core.calc_inner_brush_radius(state, config, outer_radius)
    end

    deps.primary_modifier_short_name = function()
        return core.primary_modifier_short_name()
    end

    deps.brush_drag_kind_display = function()
        local labels = config.BRUSH_DRAG_KIND_LABELS
        local k
        if state.is_dragging and state.active_sculpt_kind then
            k = state.active_sculpt_kind
        else
            k = input.resolve_brush_drag_kind()
        end
        local label = (labels and labels[k]) or k
        if (k == "nudge" or k == "sculpt") and shift_fine_active() then
            label = label .. " (Fine)"
        end
        return label
    end

    deps.arrange_client_to_imgui = function(client_x, client_y)
        return core.arrange_client_to_imgui(state.ctx, core.get_arrange_hwnd, client_x, client_y)
    end

    deps.for_each_envelope_point = function(envelope, ai, fn)
        return ops.for_each_envelope_point(envelope, ai, fn)
    end

    local function run_min_spacing_after_drag_if_needed()
        if not state.target_envelope then
            return
        end
        ops.enforce_min_screen_spacing(state, state.target_envelope, state.envelope_autoitem_idx or -1, deps.envelope_to_screen, core.get_distance, nil)
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
