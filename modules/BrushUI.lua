local M = {}

function M.draw_control_window(state, config, deps)
    if not state.ctx then return false end

    local visible, open = reaper.ImGui_Begin(state.ctx, "Brush Envelope Editor", true)

    if visible then
        reaper.ImGui_Text(state.ctx, "Brush Envelope Editor")
        reaper.ImGui_Separator(state.ctx)

        local size_changed, new_size = reaper.ImGui_SliderInt(state.ctx, "Brush Size", state.brush_size, config.MIN_BRUSH_SIZE, config.MAX_BRUSH_SIZE)
        if size_changed then state.brush_size = new_size end

        local strength_changed, new_strength = reaper.ImGui_SliderDouble(state.ctx, "Falloff Strength", state.falloff_strength, config.MIN_FALLOFF_STRENGTH, config.MAX_FALLOFF_STRENGTH, "%.1f")
        if strength_changed then state.falloff_strength = new_strength end

        local falloff_names = table.concat(config.FALLOFF_TYPES, "\0") .. "\0"
        local sculpt_names = table.concat(config.SCULPT_MODES, "\0") .. "\0"
        if reaper.ImGui_BeginTable(state.ctx, "##falloff_sculpt", 2, reaper.ImGui_TableFlags_SizingStretchProp()) then
            reaper.ImGui_TableSetupColumn(state.ctx, "falloff_col", reaper.ImGui_TableColumnFlags_WidthStretch(), 1.0)
            reaper.ImGui_TableSetupColumn(state.ctx, "sculpt_col", reaper.ImGui_TableColumnFlags_WidthStretch(), 1.0)
            reaper.ImGui_TableNextRow(state.ctx)
            reaper.ImGui_TableNextColumn(state.ctx)
            reaper.ImGui_SetNextItemWidth(state.ctx, -1)
            local falloff_changed, new_falloff = reaper.ImGui_Combo(state.ctx, "Falloff Type", state.falloff_type - 1, falloff_names)
            if falloff_changed then state.falloff_type = new_falloff + 1 end
            reaper.ImGui_TableNextColumn(state.ctx)
            reaper.ImGui_SetNextItemWidth(state.ctx, -1)
            local sculpt_changed, new_sculpt = reaper.ImGui_Combo(state.ctx, "Sculpt mode", state.sculpt_mode - 1, sculpt_names)
            if sculpt_changed then state.sculpt_mode = new_sculpt + 1 end
            reaper.ImGui_EndTable(state.ctx)
        end

        local sm = config.SCULPT_MODES[state.sculpt_mode] or "grab"
        if sm == "smooth" then
            local sm_ch, sm_v = reaper.ImGui_SliderDouble(state.ctx, "Smooth strength", state.smooth_strength, config.MIN_SMOOTH_STRENGTH, config.MAX_SMOOTH_STRENGTH, "%.2f")
            if sm_ch then state.smooth_strength = sm_v end
        end

        local pow_ch, pow_v = reaper.ImGui_SliderDouble(state.ctx, "Sculpt power (Shift+scroll)", state.sculpt_power, config.MIN_SCULPT_POWER, config.MAX_SCULPT_POWER, "%.2f")
        if pow_ch then state.sculpt_power = pow_v end

        if reaper.ImGui_BeginTable(state.ctx, "##locks", 2, reaper.ImGui_TableFlags_SizingStretchProp()) then
            reaper.ImGui_TableSetupColumn(state.ctx, "lt", reaper.ImGui_TableColumnFlags_WidthStretch(), 1.0)
            reaper.ImGui_TableSetupColumn(state.ctx, "lv", reaper.ImGui_TableColumnFlags_WidthStretch(), 1.0)
            reaper.ImGui_TableNextRow(state.ctx)
            reaper.ImGui_TableNextColumn(state.ctx)
            _, state.lock_time_axis = reaper.ImGui_Checkbox(state.ctx, "Lock time", state.lock_time_axis)
            reaper.ImGui_TableNextColumn(state.ctx)
            _, state.lock_value_axis = reaper.ImGui_Checkbox(state.ctx, "Lock value", state.lock_value_axis)
            reaper.ImGui_EndTable(state.ctx)
        end

        reaper.ImGui_Separator(state.ctx)

        reaper.ImGui_Text(state.ctx, "Debug")
        _, state.debug_show_insert_panel = reaper.ImGui_Checkbox(state.ctx, "Show last insert attempt (debug window)", state.debug_show_insert_panel)
        _, state.debug_disable_js_eat = reaper.ImGui_Checkbox(state.ctx, "Disable JS arrange intercept + arrange HUD (circles)", state.debug_disable_js_eat)
        reaper.ImGui_Text(state.ctx, "When on: no arrange intercepts, no HUD circles. Button: one insert at synthetic")
        reaper.ImGui_Text(state.ctx, "coords (Y = button row center, X = button right + " .. tostring(config.DEBUG_SYNTHETIC_OFFSET_X) .. " px in window space → arrange client).")
        reaper.ImGui_Button(state.ctx, "Debug: insert brush points once (synthetic position)")
        if reaper.ImGui_IsItemClicked(state.ctx) and deps.debug_synthetic_insert_from_last_item then
            deps.debug_synthetic_insert_from_last_item(state.ctx)
        end

        reaper.ImGui_Separator(state.ctx)
        reaper.ImGui_Text(state.ctx, "Instructions:")
        reaper.ImGui_BulletText(state.ctx, "HUD shows only while SWS reports a live envelope lane hit")
        reaper.ImGui_BulletText(state.ctx, "Grab: LMB places points across the brush width once, then drag moves points under the brush (time + value)")
        reaper.ImGui_BulletText(state.ctx, "Escape: unlock lane / hide brush HUD")
        if not reaper.JS_Mouse_GetState then
            reaper.ImGui_BulletText(state.ctx, "Install js_ReaScriptAPI for LMB brush dragging")
        end
        reaper.ImGui_BulletText(state.ctx, "Wheel (lane locked or this window): brush size | Cmd/Ctrl+wheel: falloff | Shift+wheel: sculpt power (arrange zoom blocked only while adjusting)")
        reaper.ImGui_BulletText(state.ctx, "Tab: cycle falloff types (when this window has focus)")
        reaper.ImGui_BulletText(state.ctx, "Grab / Smooth: sculpt mode; inner ring follows falloff (Cmd/Ctrl+wheel)")
        reaper.ImGui_BulletText(state.ctx, "Axis locks: edit only time or only value")

        reaper.ImGui_Separator(state.ctx)

        local mouse_x, mouse_y = deps.get_mouse_client_xy()
        local mxs = mouse_x ~= nil and string.format("%.0f", mouse_x) or "nil"
        local mys = mouse_y ~= nil and string.format("%.0f", mouse_y) or "nil"
        reaper.ImGui_Text(state.ctx, "Mouse (client): " .. mxs .. ", " .. mys)
        reaper.ImGui_Text(state.ctx, string.format("Lane lock active: %s", tostring(state.target_envelope ~= nil)))
        reaper.ImGui_Text(state.ctx, string.format("Brush HUD currently shown: %s", tostring(deps.brush_hud_interactive())))
        reaper.ImGui_Text(state.ctx, string.format("SWS lane hit (raw BR; blocked by HUD area): %s", tostring(state.sws_hover_detected)))
        reaper.ImGui_Text(state.ctx, string.format("Mouse-point hover on locked envelope (size-independent): %s", tostring(state.envelope_detected)))

        if state.target_envelope then
            local _, env_name = reaper.GetEnvelopeName(state.target_envelope)
            reaper.ImGui_Text(state.ctx, "Locked lane: " .. (env_name or "Unknown"))
            reaper.ImGui_Text(state.ctx, "Escape clears the lock. LMB sculpt/add still uses the locked lane even when HUD is hidden.")

            if state.is_dragging then
                reaper.ImGui_Text(state.ctx, string.format("Drag: %s (%d pts in brush)", state.drag_mode, #state.captured_points))
            end
        else
            reaper.ImGui_Text(state.ctx, "Hover an envelope lane to lock the brush to it.")
        end

        reaper.ImGui_End(state.ctx)
    end

    return open
end

local function line(ctx, k, v)
    if v == nil then
        reaper.ImGui_Text(ctx, string.format("%s: (nil)", k))
    elseif type(v) == "boolean" then
        reaper.ImGui_Text(ctx, string.format("%s: %s", k, tostring(v)))
    elseif type(v) == "number" then
        reaper.ImGui_Text(ctx, string.format("%s: %.12g", k, v))
    elseif type(v) == "table" then
        reaper.ImGui_Text(ctx, k .. ":")
        for sk, sv in pairs(v) do
            line(ctx, "  " .. tostring(sk), sv)
        end
    else
        reaper.ImGui_Text(ctx, string.format("%s: %s", k, tostring(v)))
    end
end

--- Separate window: last single-point insert diagnostics (populated when checkbox is on).
function M.draw_insert_debug_panel(state, config)
    if not state.ctx or not state.debug_show_insert_panel then return end
    local last = state.debug_insert_last
    if not last then
        local visible, still_open = reaper.ImGui_Begin(state.ctx, "Insert debug (no attempts yet)", true)
        if visible then
            reaper.ImGui_TextWrapped(state.ctx, 'Enable "Show last insert attempt" and click or drag once on an envelope.')
            reaper.ImGui_End(state.ctx)
        end
        if still_open == false then
            state.debug_show_insert_panel = false
        end
        return
    end

    local visible, still_open = reaper.ImGui_Begin(state.ctx, "Insert debug (last attempt)", true)
    if visible then
        reaper.ImGui_TextWrapped(state.ctx, "Recorded immediately after each insert_one_point_at_arrange_client call (LMB / combined drag).")
        reaper.ImGui_Separator(state.ctx)

        line(state.ctx, "path", last.path)
        line(state.ctx, "success", last.success)
        if last.fail_reason then line(state.ctx, "fail_reason", last.fail_reason) end
        if last.cmd_id then line(state.ctx, "Main_OnCommand id", last.cmd_id) end
        line(state.ctx, "mouse_client_x", last.mx)
        line(state.ctx, "mouse_client_y", last.my)
        line(state.ctx, "frame_arrange_start", last.arrange_start)
        line(state.ctx, "frame_arrange_end", last.arrange_end)
        line(state.ctx, "cached_min_max (SWS BR)", last.cached_min_max)
        line(state.ctx, "envelope_bounds", last.bounds)
        line(state.ctx, "envelope_name", last.envelope_name)
        line(state.ctx, "ValidatePtr TrackEnvelope*", last.envelope_ptr_ok)
        line(state.ctx, "autoitem_idx", last.autoitem_idx)
        line(state.ctx, "INSERT_AT_MOUSE_ACTION_ID (0=API)", last.insert_action_id)
        line(state.ctx, "GetEnvelopeScalingMode", last.scaling_mode)
        line(state.ctx, "n_points_before", last.n_points_before)
        line(state.ctx, "n_points_after", last.n_points_after)
        line(state.ctx, "point_delta", last.point_delta)
        line(state.ctx, "sws_hover_detected", last.sws_hover)
        line(state.ctx, "envelope_detected (curve)", last.envelope_detected)
        line(state.ctx, "sws_before_prepare", last.sws_before_prepare)
        line(state.ctx, "sws_after_attempt", last.sws_after)

        if last.api_debug then
            reaper.ImGui_Separator(state.ctx)
            reaper.ImGui_Text(state.ctx, "API branch (insert_one_point_at_screen)")
            line(state.ctx, "insert_fn", last.api_debug.insert_fn)
            line(state.ctx, "InsertEnvelopePointEx available", last.api_debug.insert_ex_available)
        line(state.ctx, "t (project time)", last.api_debug.t)
        line(state.ctx, "v inserted (Envelope_Evaluate w/ PROJECT_SRATE, samples=1)", last.api_debug.v_insert)
        line(state.ctx, "v from screen Y only (unused for insert)", last.api_debug.v_from_screen_map)
            line(state.ctx, "insert_returned", last.api_debug.insert_returned)
            if last.api_debug.fail_reason then line(state.ctx, "api fail_reason", last.api_debug.fail_reason) end
        end

        reaper.ImGui_End(state.ctx)
    end
    if still_open == false then
        state.debug_show_insert_panel = false
    end
end

return M
