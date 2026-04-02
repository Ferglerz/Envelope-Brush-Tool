local M = {}

function M.draw_control_window(state, config, deps)
    if not state.ctx then return false end

    local visible, open = reaper.ImGui_Begin(state.ctx, "Brush Envelope Editor", true)

    if visible then
        reaper.ImGui_Text(state.ctx, "Brush Envelope Editor")
        reaper.ImGui_Separator(state.ctx)

        local size_changed, new_size = reaper.ImGui_SliderInt(state.ctx, "Brush Size", state.brush_size, config.MIN_BRUSH_SIZE, config.MAX_BRUSH_SIZE)
        if size_changed then
            state.brush_size = new_size
            if deps and deps.clear_wheel_momentum then deps.clear_wheel_momentum(state) end
        end

        local sp_min, sp_max = config.MIN_MIN_POINT_SPACING_PX, config.MAX_MIN_POINT_SPACING_PX
        local sp_changed, new_sp = reaper.ImGui_SliderInt(state.ctx, "Min point spacing (px)", state.min_point_spacing_px, sp_min, sp_max)
        if sp_changed then
            state.min_point_spacing_px = math.max(sp_min, math.min(sp_max, new_sp))
        end
        reaper.ImGui_TextWrapped(state.ctx, "Minimum screen distance (time + value) between points; pairs closer than this are culled after seeding new points or when you release the mouse after a sculpt drag (not while dragging). 0 = off.")

        local strength_changed, new_strength = reaper.ImGui_SliderDouble(state.ctx, "Falloff Strength", state.falloff_strength, config.MIN_FALLOFF_STRENGTH, config.MAX_FALLOFF_STRENGTH, "%.1f")
        if strength_changed then
            state.falloff_strength = new_strength
            if deps and deps.clear_wheel_momentum then deps.clear_wheel_momentum(state) end
        end

        local falloff_display = {}
        for i = 1, #config.FALLOFF_TYPES do
            local k = config.FALLOFF_TYPES[i]
            falloff_display[i] = (config.FALLOFF_TYPE_LABELS and config.FALLOFF_TYPE_LABELS[k]) or k
        end
        local falloff_names = table.concat(falloff_display, "\0") .. "\0"
        reaper.ImGui_SetNextItemWidth(state.ctx, -1)
        local falloff_changed, new_falloff = reaper.ImGui_Combo(state.ctx, "Falloff Type", state.falloff_type - 1, falloff_names)
        if falloff_changed then state.falloff_type = new_falloff + 1 end

        reaper.ImGui_Separator(state.ctx)
        local mod = (deps and deps.primary_modifier_short_name and deps.primary_modifier_short_name()) or "Ctrl"
        reaper.ImGui_TextWrapped(state.ctx, "Brush mode (hold while dragging): Nudge — plain LMB | Sculpt — " .. mod .. " | Smooth — Shift+LMB. Sculpt + Shift while dragging: Fine (half strength).")

        local sm_ch, sm_v = reaper.ImGui_SliderDouble(state.ctx, "Smooth strength (Shift drag)", state.smooth_strength, config.MIN_SMOOTH_STRENGTH, config.MAX_SMOOTH_STRENGTH, "%.2f")
        if sm_ch then state.smooth_strength = sm_v end

        local pow_ch, pow_v = reaper.ImGui_SliderDouble(state.ctx, "Strength / power (" .. mod .. "+scroll)", state.sculpt_power, config.MIN_SCULPT_POWER, config.MAX_SCULPT_POWER, "%.2f")
        if pow_ch then
            state.sculpt_power = pow_v
            if deps and deps.clear_wheel_momentum then deps.clear_wheel_momentum(state) end
        end

        _, state.sculpt_seed_blend_to_cursor = reaper.ImGui_Checkbox(
            state.ctx,
            "Sculpt seed: blend new points toward cursor (falloff)",
            state.sculpt_seed_blend_to_cursor
        )
        reaper.ImGui_TextWrapped(state.ctx, "When off, the first " .. mod .. "+LMB click only adds points along the existing envelope shape (spacing still applies); drag still sculpts as usual.")

        if deps and deps.brush_drag_kind_display then
            reaper.ImGui_Text(state.ctx, "Next drag: " .. deps.brush_drag_kind_display())
        end

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
        _, state.debug_disable_js_eat = reaper.ImGui_Checkbox(state.ctx, "Disable JS arrange intercept + arrange HUD (circles)", state.debug_disable_js_eat)
        _, state.debug_show_point_client_coords = reaper.ImGui_Checkbox(
            state.ctx,
            "Show arrange-client (x,y) next to each envelope point (HUD)",
            state.debug_show_point_client_coords
        )
        reaper.ImGui_TextWrapped(state.ctx, "Labels use arrange-client (x,y) from envelope_to_screen (index #n from GetEnvelopePoint*). Shown whenever a lane is locked and this is on — you do not need to hover the lane each frame (unlike the brush circles).")

        reaper.ImGui_Separator(state.ctx)
        reaper.ImGui_Text(state.ctx, "Instructions:")
        reaper.ImGui_BulletText(state.ctx, "HUD shows only while SWS reports a live envelope lane hit")
        reaper.ImGui_BulletText(state.ctx, "Sculpt: " .. mod .. "+LMB seeds points across the brush width once (optional blend toward cursor); drag moves those points (min spacing when you release)")
        reaper.ImGui_BulletText(state.ctx, "Nudge: plain LMB — move existing points in the brush only")
        reaper.ImGui_BulletText(state.ctx, "Smooth: Shift+LMB — gently pull values toward one level and times toward even spacing across the brush (per mouse move)")
        reaper.ImGui_BulletText(state.ctx, "Escape: close script (with this window focused)")
        if not reaper.JS_Mouse_GetState then
            reaper.ImGui_BulletText(state.ctx, "Install js_ReaScriptAPI for LMB brush dragging")
        end
        reaper.ImGui_BulletText(state.ctx, "Wheel: scroll = size | Alt+scroll = falloff | " .. mod .. "+scroll = strength | Shift+scroll = finer steps")
        reaper.ImGui_BulletText(state.ctx, "Tab: cycle falloff type (while brush context is active: envelope hover or this UI)")
        reaper.ImGui_BulletText(state.ctx, "Inner ring follows falloff; Shift while dragging Sculpt: Fine (half strength)")
        reaper.ImGui_BulletText(state.ctx, "Axis locks: edit only time or only value")

        reaper.ImGui_Separator(state.ctx)

        local mouse_x, mouse_y = deps.get_mouse_client_xy()
        local mxs = mouse_x ~= nil and string.format("%.0f", mouse_x) or "nil"
        local mys = mouse_y ~= nil and string.format("%.0f", mouse_y) or "nil"
        local lane = "—"
        if state.target_envelope then
            local _, env_name = reaper.GetEnvelopeName(state.target_envelope)
            lane = env_name or "Unknown"
        end
        reaper.ImGui_Text(state.ctx, string.format("Mouse (client) %s, %s  ·  Locked lane: %s", mxs, mys, lane))
        reaper.ImGui_TextWrapped(state.ctx, string.format(
            "On locked envelope curve at cursor X (±%d px vertically; not used for brush logic): %s",
            config.ENVELOPE_HOVER_TOLERANCE_PIXELS,
            tostring(state.envelope_detected)
        ))

        if state.target_envelope then
            reaper.ImGui_TextWrapped(state.ctx, "LMB brush uses the locked lane even when the HUD is hidden.")

            if state.is_dragging and state.active_sculpt_kind then
                local labels = config.BRUSH_DRAG_KIND_LABELS
                local lab = (labels and labels[state.active_sculpt_kind]) or state.active_sculpt_kind
                reaper.ImGui_Text(state.ctx, string.format("Drag: %s (%d pts in brush)", lab, #state.captured_points))
            end
        else
            reaper.ImGui_Text(state.ctx, "Hover an envelope lane to lock the brush to it.")
        end

        reaper.ImGui_End(state.ctx)
    end

    return open
end

return M
