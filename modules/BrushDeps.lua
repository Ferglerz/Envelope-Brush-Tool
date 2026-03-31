local M = {}

function M.new(state, config, modules)
    local core = modules.core
    local envelope = modules.envelope
    local ops = modules.ops
    local render = modules.render
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

    local function record_insert_debug(mx, my, payload)
        if not state.debug_show_insert_panel then return end
        local env = state.target_envelope
        local ai = state.envelope_autoitem_idx or -1
        local proj = reaper.EnumProjects and reaper.EnumProjects(-1) or 0
        local env_name
        if env then
            _, env_name = reaper.GetEnvelopeName(env)
        end
        local tr = env and reaper.GetEnvelopeInfo_Value(env, "P_TRACK")
        local ptr_env = env and reaper.ValidatePtr2 and reaper.ValidatePtr2(proj, env, "TrackEnvelope*")
        local scaling = env and reaper.GetEnvelopeScalingMode and reaper.GetEnvelopeScalingMode(env)
        local snap_after = env and core.get_envelope_sws_snapshot(env)
        local min_c, max_c = deps.get_envelope_properties(env)
        local b = state.envelope_bounds
        payload = payload or {}
        payload.when_os = (reaper.time_precise and reaper.time_precise()) or 0
        payload.mx = mx
        payload.my = my
        payload.arrange_start = state.frame_arrange_start
        payload.arrange_end = state.frame_arrange_end
        payload.bounds = b and { left = b.left, top = b.top, right = b.right, bottom = b.bottom } or nil
        payload.cached_min_max = { min_val = min_c, max_val = max_c }
        payload.envelope_name = env_name
        payload.envelope_ptr_ok = ptr_env
        payload.autoitem_idx = ai
        payload.insert_action_id = config.INSERT_AT_MOUSE_ACTION_ID
        payload.track_ptr = tr
        payload.scaling_mode = scaling
        payload.sws_after = snap_after
        payload.sws_hover = state.sws_hover_detected
        payload.envelope_detected = state.envelope_detected
        state.debug_insert_last = payload
    end

    --- One point at mouse: Main_OnCommand(INSERT_AT_MOUSE_ACTION_ID) when configured (matches shortcut path), else API insert.
    deps.insert_one_point_at_arrange_client = function(mx, my)
        if not state.target_envelope or mx == nil or my == nil then
            if state.debug_show_insert_panel then
                record_insert_debug(mx, my, {
                    path = "none",
                    success = false,
                    fail_reason = not state.target_envelope and "no target_envelope" or "nil mouse coords",
                })
            end
            return false
        end
        local env = state.target_envelope
        local ai = state.envelope_autoitem_idx or -1
        local cmd_id = config.INSERT_AT_MOUSE_ACTION_ID
        if type(cmd_id) == "number" and cmd_id > 0 and reaper.Main_OnCommand then
            local n_before = state.debug_show_insert_panel and ops.count_envelope_points(env, ai) or 0
            reaper.Main_OnCommand(cmd_id, 0)
            reaper.UpdateArrange()
            local n_after = state.debug_show_insert_panel and ops.count_envelope_points(env, ai) or 0
            if state.debug_show_insert_panel then
                record_insert_debug(mx, my, {
                    path = "Main_OnCommand",
                    success = true,
                    cmd_id = cmd_id,
                    n_points_before = n_before,
                    n_points_after = n_after,
                    point_delta = n_after - n_before,
                })
            end
            return true
        end
        local n_before = state.debug_show_insert_panel and ops.count_envelope_points(env, ai) or 0
        local snap_before = state.debug_show_insert_panel and core.get_envelope_sws_snapshot(env) or nil
        core.prepare_envelope_for_point_insert(env)
        local ok, idbg = ops.insert_one_point_at_screen(
            env,
            ai,
            mx,
            my,
            function(x, y, e)
                return deps.screen_to_envelope(x, y, e)
            end,
            core.envelope_value_at_time
        )
        local n_after = state.debug_show_insert_panel and ops.count_envelope_points(env, ai) or 0
        if state.debug_show_insert_panel then
            record_insert_debug(mx, my, {
                path = "InsertEnvelopePoint*",
                success = ok,
                n_points_before = n_before,
                n_points_after = n_after,
                point_delta = n_after - n_before,
                sws_before_prepare = snap_before,
                api_debug = idbg,
                fail_reason = (idbg and idbg.fail_reason) or (not ok and "insert failed") or nil,
            })
        end
        return ok
    end

    deps.create_points_in_brush_area = function(mouse_x, mouse_y, radius, target_envelope)
        local ai = state.envelope_autoitem_idx or -1
        return ops.create_points_in_brush_area(
            state, config, mouse_x, mouse_y, radius, target_envelope, ai,
            deps.screen_to_envelope, deps.envelope_to_screen, core.get_distance, core.calculate_falloff,
            core.envelope_value_at_time
        )
    end

    --- Grab mode: first LMB — prepare + spread points across brush width in time (InsertEnvelopePoint* only).
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

    deps.sculpt_captured_points = function(captured_points, delta_x, delta_y, target_envelope, no_sort)
        local ai = state.envelope_autoitem_idx or -1
        return ops.sculpt_captured_points(
            state, config, captured_points, delta_x, delta_y, target_envelope, ai, no_sort,
            deps.get_envelope_properties, core.clamp, core.envelope_value_at_time
        )
    end

    deps.refresh_captured_from_envelope = function(target_envelope)
        local ai = state.envelope_autoitem_idx or -1
        return ops.refresh_captured_from_envelope(state, target_envelope, ai)
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

    --- Call immediately after ImGui_Button; uses that button's rect: Y = vertical center, X = right edge + DEBUG_SYNTHETIC_OFFSET_X.
    deps.debug_synthetic_insert_from_last_item = function(ctx)
        if not ctx or not state.target_envelope then return end
        if not reaper.ImGui_GetItemRectMin or not reaper.ImGui_GetItemRectMax then return end
        local l, t = reaper.ImGui_GetItemRectMin(ctx)
        local r, b = reaper.ImGui_GetItemRectMax(ctx)
        if not l or not t or not r or not b then return end
        local mid_y = (t + b) * 0.5
        local lx = r + config.DEBUG_SYNTHETIC_OFFSET_X
        local ly = mid_y
        local cx, cy = core.imgui_window_local_to_arrange_client(ctx, lx, ly, core.get_arrange_hwnd)
        if cx == nil or cy == nil then return end
        local bounds = state.envelope_bounds
        cx = core.clamp(cx, bounds.left, bounds.right)
        cy = core.clamp(cy, bounds.top, bounds.bottom)
        if reaper.PreventUIRefresh then
            reaper.PreventUIRefresh(1)
        end
        reaper.Undo_BeginBlock()
        local n = ops.create_points_in_brush_area(
            state, config, cx, cy, state.brush_size, state.target_envelope, state.envelope_autoitem_idx or -1,
            deps.screen_to_envelope, deps.envelope_to_screen, core.get_distance, core.calculate_falloff,
            core.envelope_value_at_time
        ) or 0
        reaper.Undo_EndBlock("Debug synthetic brush insert", -1)
        if reaper.PreventUIRefresh then
            reaper.PreventUIRefresh(-1)
        end
        reaper.UpdateArrange()
        return n
    end

    return deps
end

return M
