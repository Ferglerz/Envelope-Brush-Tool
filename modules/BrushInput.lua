local M = {}

local function imgui_mouse_wheel_sum(state)
    local w = 0
    if state.ctx then
        w = w + (reaper.ImGui_GetMouseWheel(state.ctx) or 0)
    end
    return w
end

--- VK scan: JS_VKeys_GetState string is 1-based; index vk+1 matches Windows VK (SWS/js).
local function vkey_down(vk)
    if not reaper.JS_VKeys_GetState then return false end
    local s = reaper.JS_VKeys_GetState(-1)
    if type(s) ~= "string" then return false end
    local i = vk + 1
    if i < 1 or i > #s then return false end
    return s:byte(i) ~= 0
end

local function imgui_shift_held_any(state)
    local k = reaper.ImGui_Key_LeftShift()
    if state.ctx and reaper.ImGui_IsKeyDown(state.ctx, k) then return true end
    if reaper.ImGui_Key_RightShift and state.ctx and reaper.ImGui_IsKeyDown(state.ctx, reaper.ImGui_Key_RightShift()) then return true end
    return false
end

local function key_mod_shift(state)
    if state.ctx and reaper.ImGui_GetKeyMods and reaper.ImGui_Mod_Shift then
        local m = reaper.ImGui_GetKeyMods(state.ctx)
        local shift = reaper.ImGui_Mod_Shift()
        if m ~= nil and shift ~= nil and (m & shift) ~= 0 then return true end
    end
    if state.ctx and imgui_shift_held_any(state) then return true end
    return vkey_down(0x10)
end

--- Cmd (Super) on macOS; Ctrl / Super bitmask for falloff scroll (matches ReaImGui Mod_* docs).
local function key_mod_cmd_or_falloff_scroll(state)
    if state.ctx and reaper.ImGui_GetKeyMods and reaper.ImGui_Mod_Super and reaper.ImGui_Mod_Ctrl then
        local m = reaper.ImGui_GetKeyMods(state.ctx)
        if m ~= nil then
            local ms, mc = reaper.ImGui_Mod_Super(), reaper.ImGui_Mod_Ctrl()
            if ms and (m & ms) ~= 0 then return true end
            if mc and (m & mc) ~= 0 then return true end
        end
    end
    if state.ctx then
        if reaper.ImGui_Key_LeftSuper and reaper.ImGui_IsKeyDown(state.ctx, reaper.ImGui_Key_LeftSuper()) then return true end
        if reaper.ImGui_Key_RightSuper and reaper.ImGui_IsKeyDown(state.ctx, reaper.ImGui_Key_RightSuper()) then return true end
        if reaper.ImGui_Key_LeftCtrl and reaper.ImGui_IsKeyDown(state.ctx, reaper.ImGui_Key_LeftCtrl()) then return true end
        if reaper.ImGui_Key_RightCtrl and reaper.ImGui_IsKeyDown(state.ctx, reaper.ImGui_Key_RightCtrl()) then return true end
    end
    if vkey_down(0x11) then return true end
    if vkey_down(0x5B) or vkey_down(0x5C) then return true end
    return false
end

local function brush_wheel_context_active(state)
    if state.sws_hover_detected and state.target_envelope then return true end
    if state.ctx and reaper.ImGui_IsWindowHovered then
        local hf = reaper.ImGui_HoveredFlags_AnyWindow
        local flag = hf and (type(hf) == "function" and hf() or hf) or 0
        local ok, h = pcall(reaper.ImGui_IsWindowHovered, state.ctx, flag)
        if ok and h then return true end
    end
    return false
end

local function imgui_key_pressed_any(state, key)
    if state.ctx and reaper.ImGui_IsKeyPressed(state.ctx, key) then return true end
    return false
end

local function begin_undo_once(state, name)
    if not state.undo_active then
        reaper.Undo_BeginBlock()
        state.undo_active = true
        state.undo_operation_name = name
    end
end

--- opts.focus_arrange: optional function() before Envelope_SortPoints (unused; focus steal was disruptive).
function M.end_drag_operation(state, opts)
    if not state.is_dragging then return end

    state.envelope_flush_pending = false
    state.is_dragging = false
    state.captured_points = {}
    state.last_create_client = nil
    state.sculpt_last_client = nil

    if state.sculpt_sort_pending and state.target_envelope then
        if opts and opts.focus_arrange then
            opts.focus_arrange()
        end
        local ai = state.envelope_autoitem_idx or -1
        if ai >= 0 and reaper.Envelope_SortPointsEx then
            reaper.Envelope_SortPointsEx(state.target_envelope, ai)
        else
            reaper.Envelope_SortPoints(state.target_envelope)
        end
        reaper.UpdateArrange()
        state.sculpt_sort_pending = false
    end

    if state.undo_active then
        reaper.Undo_EndBlock(state.undo_operation_name, -1)
        state.undo_active = false
        state.undo_operation_name = ""
    end
end

function M.clear_envelope_target(state, end_drag_operation)
    end_drag_operation()
    state.cached_envelope = nil
    state.target_envelope = nil
    state.envelope_autoitem_idx = -1
    state.envelope_flush_pending = false
    state.suppress_imgui_control_this_frame = false
    state.overlay_visible = false
    state.envelope_detected = false
    state.cached_envelope_properties.envelope = nil
end

--- Scroll: brush size | Cmd/Ctrl+scroll: falloff | Shift+scroll: sculpt power (when over lane or any ImGui window).
--- Arrange wheel: intercepted (blocked); eaten for brush when context active, else forwarded to arrange.
function M.handle_wheel_input(state, config, clamp, core)
    if not state.ctx then return false end
    local brush_ctx = brush_wheel_context_active(state)
    local wm = (core and core.take_arrange_wheel_or_forward) and core.take_arrange_wheel_or_forward(state, brush_ctx) or 0
    if not brush_ctx then return false end

    local ig = (wm == 0) and imgui_mouse_wheel_sum(state) or 0
    local wheel_delta = (wm ~= 0) and wm or ig
    if wheel_delta == 0 then return false end

    if key_mod_cmd_or_falloff_scroll(state) then
        state.falloff_strength = clamp(state.falloff_strength + (wheel_delta > 0 and config.FALLOFF_STRENGTH_STEP or -config.FALLOFF_STRENGTH_STEP),
            config.MIN_FALLOFF_STRENGTH, config.MAX_FALLOFF_STRENGTH)
    elseif key_mod_shift(state) then
        state.sculpt_power = clamp(state.sculpt_power + (wheel_delta > 0 and config.SCULPT_POWER_STEP or -config.SCULPT_POWER_STEP),
            config.MIN_SCULPT_POWER, config.MAX_SCULPT_POWER)
    else
        state.brush_size = clamp(state.brush_size + (wheel_delta > 0 and config.BRUSH_SIZE_STEP or -config.BRUSH_SIZE_STEP),
            config.MIN_BRUSH_SIZE, config.MAX_BRUSH_SIZE)
    end
    return true
end

function M.handle_keyboard_input(state, deps)
    if not state.ctx then return false end

    if imgui_key_pressed_any(state, reaper.ImGui_Key_Escape()) then
        deps.clear_envelope_target()
        return true
    end

    if imgui_key_pressed_any(state, reaper.ImGui_Key_Tab()) then
        state.falloff_type = state.falloff_type + 1
        if state.falloff_type > #deps.falloff_types then
            state.falloff_type = 1
        end
        return true
    end

    return false
end

local function sculpt_delta_below_threshold(dx, dy, config)
    local t = config.SCULPT_DRAG_MIN_MOVEMENT_PX or 0.02
    return (dx * dx + dy * dy) < (t * t)
end

function M.try_apply_sculpt_drag(state, config, mx, my, deps)
    if not state.target_envelope or state.drag_mode ~= "sculpt" then return end

    state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
    if #state.captured_points == 0 then
        state.sculpt_last_client = { x = mx, y = my }
        return
    end

    if not state.sculpt_last_client then
        state.sculpt_last_client = { x = state.drag_start_pos.x, y = state.drag_start_pos.y }
    end

    local dx = mx - state.sculpt_last_client.x
    local dy = my - state.sculpt_last_client.y
    if sculpt_delta_below_threshold(dx, dy, config) then
        return
    end

    local undo_name = (config.SCULPT_MODES[state.sculpt_mode] == "smooth") and "Brush Smooth Envelope" or "Brush Sculpt Envelope"
    begin_undo_once(state, undo_name)
    deps.sculpt_captured_points(state.captured_points, dx, dy, state.target_envelope, true)
    deps.refresh_captured_from_envelope(state.target_envelope)
    state.sculpt_last_client = { x = mx, y = my }
    state.sculpt_sort_pending = true
end

function M.try_apply_add_drag(state, config, mx, my, deps)
    if not state.target_envelope or state.drag_mode ~= "add" then return end

    if state.last_create_client then
        if deps.get_distance(mx, my, state.last_create_client.x, state.last_create_client.y) < config.MIN_POINT_SPACING_PIXELS then
            return
        end
    end

    begin_undo_once(state, "Brush Add Envelope Points")
    local n = deps.create_points_in_brush_area(mx, my, state.brush_size, state.target_envelope)
    if n > 0 then
        state.last_create_client = { x = mx, y = my }
    end
end

--- LMB drag (grab / combined): points are seeded on press only; drag only sculpts under the brush.
function M.try_combined_drag(state, config, mx, my, deps)
    if not state.target_envelope or state.drag_mode ~= "combined" then return end

    state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)

    if not state.sculpt_last_client then
        state.sculpt_last_client = { x = state.drag_start_pos.x, y = state.drag_start_pos.y }
    end

    local dx = mx - state.sculpt_last_client.x
    local dy = my - state.sculpt_last_client.y
    if sculpt_delta_below_threshold(dx, dy, config) then
        return
    end

    if #state.captured_points > 0 then
        begin_undo_once(state, "Brush Drag Envelope")
        deps.sculpt_captured_points(state.captured_points, dx, dy, state.target_envelope, true)
        deps.refresh_captured_from_envelope(state.target_envelope)
        state.sculpt_sort_pending = true
    end
    state.sculpt_last_client = { x = mx, y = my }
end

function M.on_lmb_pressed(state, config, mx, my, deps)
    if not state.target_envelope then return end

    state.is_dragging = true
    local smooth = (config.SCULPT_MODES[state.sculpt_mode] == "smooth")
    state.drag_mode = smooth and "sculpt" or "combined"
    state.drag_start_pos = { x = mx, y = my }
    state.last_create_client = nil
    state.sculpt_sort_pending = false
    state.sculpt_last_client = { x = mx, y = my }

    if smooth then
        state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
        return
    end

    local n = deps.seed_brush_width_at_client(mx, my)
    if n > 0 then
        reaper.Undo_BeginBlock()
        state.undo_active = true
        state.undo_operation_name = "Brush Drag Envelope"
    end
    state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
end

return M
