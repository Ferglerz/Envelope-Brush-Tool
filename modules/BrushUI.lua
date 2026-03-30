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

        reaper.ImGui_Separator(state.ctx)
        reaper.ImGui_Text(state.ctx, "Instructions:")
        reaper.ImGui_BulletText(state.ctx, "HUD shows only while SWS reports a live envelope lane hit")
        reaper.ImGui_BulletText(state.ctx, "Brush overlay is non-blocking; LMB drag adds points (min spacing) and sculpts under the brush")
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
        reaper.ImGui_Text(state.ctx, string.format("Mouse (client): %d, %d", mouse_x, mouse_y))
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

return M
