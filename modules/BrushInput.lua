local M = {}

local function imgui_mouse_wheel_sum(state)
    local w = 0
    if state.ctx then
        w = w + (reaper.ImGui_GetMouseWheel(state.ctx) or 0)
    end
    return w
end

--- Wheel modifiers: js_ReaScript JS_Mouse_GetState (global), not ImGui_GetKeyMods.
--- Same function uses button ids (1 = LMB) and, for Alt only, VK_MENU (0x12) — not bit 32 (that is VK_SPACE).
--- WM_MOUSEWHEEL wParam LOWORD: MK_SHIFT 0x0004, MK_CONTROL 0x0008.
--- Masks (js extension convention): 8 = Shift, 4 = Ctrl, 16 = Command (macOS), 32 used elsewhere — not Alt.
local MK_SHIFT = 0x0004
local MK_CONTROL = 0x0008
local JS_SHIFT = 8
local VK_MENU = 0x12 -- Alt / Option: use with JS_Mouse_GetState for wheel falloff only

local function js_mod_down(bit)
    if not reaper.JS_Mouse_GetState then return false end
    return (reaper.JS_Mouse_GetState(bit) or 0) > 0
end

--- Sculpt: Cmd (16) or Ctrl (4). Smooth: Shift (8). Sculpt wins when combined with Shift.
function M.resolve_brush_drag_kind()
    if js_mod_down(16) or js_mod_down(4) then
        return "sculpt"
    end
    if js_mod_down(JS_SHIFT) then
        return "smooth"
    end
    return "nudge"
end

--- Alt/Option for wheel: VK_MENU (0x12). Bitmask 32 maps to VK_SPACE, not Menu.
local function wheel_mod_alt()
    if not reaper.JS_Mouse_GetState then return false end
    return (reaper.JS_Mouse_GetState(VK_MENU) or 0) > 0
end

local function wheel_mod_shift(arrange_wparam_lo)
    local js = false
    if reaper.JS_Mouse_GetState then
        js = (reaper.JS_Mouse_GetState(8) or 0) > 0
    end
    if arrange_wparam_lo then
        local lo = arrange_wparam_lo & 0xFFFF
        if (lo & MK_SHIFT) ~= 0 then return true end
    end
    return js
end

local function wheel_mod_power_cmd_ctrl(arrange_wparam_lo)
    local js = false
    if reaper.JS_Mouse_GetState then
        local a = reaper.JS_Mouse_GetState(4) or 0
        local b = reaper.JS_Mouse_GetState(16) or 0
        js = a > 0 or b > 0
    end
    if arrange_wparam_lo then
        local lo = arrange_wparam_lo & 0xFFFF
        if (lo & MK_CONTROL) ~= 0 then return true end
    end
    return js
end

--- Same priority as handle_wheel: Alt → falloff, Cmd/Ctrl → power, else size.
local function wheel_adjust_kind(arrange_wparam_lo)
    if wheel_mod_alt() then return "falloff" end
    if wheel_mod_power_cmd_ctrl(arrange_wparam_lo) then return "power" end
    return "size"
end

function M.brush_wheel_context_active(state)
    if state.sws_hover_detected and state.target_envelope then return true end
    if state.ctx and reaper.ImGui_IsWindowHovered then
        local hf = reaper.ImGui_HoveredFlags_AnyWindow
        local flag = hf and (type(hf) == "function" and hf() or hf) or 0
        local ok, h = pcall(reaper.ImGui_IsWindowHovered, state.ctx, flag)
        if ok and h then return true end
    end
    return false
end

local function brush_wheel_context_active(state)
    return M.brush_wheel_context_active(state)
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

local function clear_drag_pointer_state(state)
    state.envelope_flush_pending = false
    state.is_dragging = false
    state.captured_points = {}
    state.last_create_client = nil
    state.sculpt_last_client = nil
    state.active_sculpt_kind = nil
end

--- Shared: pending Envelope_SortPoints* after sculpt + Undo_EndBlock when a block was opened.
--- opts.sort_envelope_points_for_autoitem: required for sort when sculpt_sort_pending.
function M.apply_envelope_undo_finalize(state, opts)
    if state.sculpt_sort_pending and state.target_envelope then
        if opts and opts.focus_arrange then
            opts.focus_arrange()
        end
        local sort_fn = opts and opts.sort_envelope_points_for_autoitem
        if sort_fn then
            sort_fn(state.target_envelope, state.envelope_autoitem_idx or -1)
        end
        reaper.UpdateArrange()
        state.sculpt_sort_pending = false
        state.last_envelope_sort_os = reaper.time_precise and reaper.time_precise() or 0
        state.envelope_points_dirty_sort = false
    end

    if state.undo_active then
        reaper.Undo_EndBlock(state.undo_operation_name, -1)
        state.undo_active = false
        state.undo_operation_name = ""
    end
end

function M.end_drag_operation(state, opts)
    if not state.is_dragging then
        return
    end
    if opts and opts.enforce_min_spacing_after_drag then
        opts.enforce_min_spacing_after_drag()
    end
    clear_drag_pointer_state(state)
    M.apply_envelope_undo_finalize(state, opts)
end

--- Script exit: same undo/sort rules as end_drag_operation, but also runs when not dragging (orphaned undo block).
function M.end_session_from_script_close(state, opts)
    if state.is_dragging then
        if opts and opts.enforce_min_spacing_after_drag then
            opts.enforce_min_spacing_after_drag()
        end
        clear_drag_pointer_state(state)
    end
    M.apply_envelope_undo_finalize(state, opts)
end

function M.clear_wheel_momentum(state)
    state.wheel_momentum_vel = 0
    state.wheel_mom_size_accum = 0
end

--- Integrate brush-size wheel coast (plain scroll only; call before handle_wheel_input each frame).
function M.tick_wheel_momentum(state, config, clamp)
    if not state.ctx then return end
    if not brush_wheel_context_active(state) then
        M.clear_wheel_momentum(state)
        return
    end
    local v = state.wheel_momentum_vel or 0
    if math.abs(v) < (config.WHEEL_MOMENTUM_STOP or 0.03) then
        M.clear_wheel_momentum(state)
        return
    end

    -- Stop coast if user holds a modifier (Alt / Cmd / Ctrl) used for other wheel bindings.
    if wheel_adjust_kind(nil) ~= "size" then
        M.clear_wheel_momentum(state)
        return
    end

    local maxv = config.WHEEL_MOMENTUM_MAX_VEL or 32
    v = math.max(-maxv, math.min(maxv, v))
    v = v * (config.WHEEL_MOMENTUM_FRICTION or 0.87)

    local bs = state.brush_size
    if bs >= config.MAX_BRUSH_SIZE and v > 0 then
        v = 0
        state.wheel_mom_size_accum = 0
    elseif bs <= config.MIN_BRUSH_SIZE and v < 0 then
        v = 0
        state.wheel_mom_size_accum = 0
    else
        local rate = config.WHEEL_MOMENTUM_SIZE_RATE or 0.13
        state.wheel_mom_size_accum = (state.wheel_mom_size_accum or 0) + v * rate
        local acc = state.wheel_mom_size_accum
        local step_px = math.max(1, math.floor(config.BRUSH_SIZE_STEP + 0.5))
        while acc >= 1 do
            state.brush_size = clamp(state.brush_size + step_px, config.MIN_BRUSH_SIZE, config.MAX_BRUSH_SIZE)
            acc = acc - 1
        end
        while acc <= -1 do
            state.brush_size = clamp(state.brush_size - step_px, config.MIN_BRUSH_SIZE, config.MAX_BRUSH_SIZE)
            acc = acc + 1
        end
        state.wheel_mom_size_accum = acc
    end

    state.wheel_momentum_vel = v
    if math.abs(v) < (config.WHEEL_MOMENTUM_STOP or 0.03) then
        M.clear_wheel_momentum(state)
    end
end

--- Scroll: brush size | Alt+scroll: falloff | Cmd/Ctrl+scroll: sculpt power (Alt wins if both) | Shift: finer steps.
--- Arrange wheel: intercepted (blocked); eaten for brush when context active, else forwarded to arrange.
function M.handle_wheel_input(state, config, clamp, core)
    if not state.ctx then return false end
    local brush_ctx = brush_wheel_context_active(state)
    local wm, arrange_wparam_lo = 0, nil
    if core and core.take_arrange_wheel_or_forward then
        wm, arrange_wparam_lo = core.take_arrange_wheel_or_forward(state, brush_ctx)
    end
    if not brush_ctx then return false end

    local ig = (wm == 0) and imgui_mouse_wheel_sum(state) or 0
    local wheel_delta = (wm ~= 0) and wm or ig
    if wheel_delta == 0 then return false end

    local alt = wheel_mod_alt()
    local fine = wheel_mod_shift(arrange_wparam_lo) and 0.5 or 1.0
    local d = wheel_delta > 0 and 1 or -1

    if alt then
        M.clear_wheel_momentum(state)
        local step = config.FALLOFF_STRENGTH_STEP * fine
        state.falloff_strength = clamp(state.falloff_strength + d * step,
            config.MIN_FALLOFF_STRENGTH, config.MAX_FALLOFF_STRENGTH)
    elseif wheel_mod_power_cmd_ctrl(arrange_wparam_lo) then
        M.clear_wheel_momentum(state)
        local step = config.SCULPT_POWER_STEP * fine
        state.sculpt_power = clamp(state.sculpt_power + d * step,
            config.MIN_SCULPT_POWER, config.MAX_SCULPT_POWER)
    else
        local step = math.max(1, math.floor(config.BRUSH_SIZE_STEP * fine + 0.5))
        state.brush_size = clamp(state.brush_size + d * step,
            config.MIN_BRUSH_SIZE, config.MAX_BRUSH_SIZE)
        local imp = config.WHEEL_MOMENTUM_IMPULSE or 2.5
        local mag = math.min(math.abs(wheel_delta), 4)
        local sign = wheel_delta > 0 and 1 or -1
        local add = sign * mag * imp * fine
        state.wheel_momentum_vel = math.max(-(config.WHEEL_MOMENTUM_MAX_VEL or 32),
            math.min(config.WHEEL_MOMENTUM_MAX_VEL or 32, (state.wheel_momentum_vel or 0) + add))
    end

    return true
end

function M.handle_keyboard_input(state, deps)
    if not state.ctx then return false end

    if imgui_key_pressed_any(state, reaper.ImGui_Key_Escape()) then
        if deps.request_script_close then
            deps.request_script_close()
        end
        return true
    end

    return false
end

--- Tab: JS_VKeys (global), gated to brush_wheel_context_active — works over arrange without ImGui focus.
local VK_TAB = 0x09

function M.handle_tab_cycle_falloff(state, deps)
    if not reaper.JS_VKeys_GetState or not deps or not deps.falloff_types then return false end
    local down = (reaper.JS_VKeys_GetState(VK_TAB) or 0) ~= 0
    local pressed = down and not state._vk_tab_down_prev
    state._vk_tab_down_prev = down
    if not pressed or not M.brush_wheel_context_active(state) then
        return false
    end
    state.falloff_type = state.falloff_type + 1
    if state.falloff_type > #deps.falloff_types then
        state.falloff_type = 1
    end
    return true
end

local function sculpt_delta_below_threshold(dx, dy, config)
    local t = config.SCULPT_DRAG_MIN_MOVEMENT_PX or 0.02
    return (dx * dx + dy * dy) < (t * t)
end

function M.try_apply_sculpt_drag(state, config, mx, my, deps)
    if not state.target_envelope or state.drag_mode ~= "sculpt" then return end

    -- Capture is fixed at LMB (on_lmb_pressed); do not re-scan each frame or the brush "picks up" new points.
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

    local kind = state.active_sculpt_kind or "nudge"
    local undo_name = (kind == "smooth") and "Brush Smooth Envelope" or "Brush Nudge Envelope"
    begin_undo_once(state, undo_name)
    deps.sculpt_captured_points(state.captured_points, dx, dy, state.target_envelope)
    deps.refresh_captured_from_envelope(state.target_envelope)
    state.sculpt_last_client = { x = mx, y = my }
    state.sculpt_sort_pending = true
end

--- LMB drag (sculpt combined): capture at press only; falloff weights are from brush center at LMB, not current mouse.
function M.try_combined_drag(state, config, mx, my, deps)
    if not state.target_envelope or state.drag_mode ~= "combined" then return end

    if not state.sculpt_last_client then
        state.sculpt_last_client = { x = state.drag_start_pos.x, y = state.drag_start_pos.y }
    end

    local dx = mx - state.sculpt_last_client.x
    local dy = my - state.sculpt_last_client.y
    if sculpt_delta_below_threshold(dx, dy, config) then
        return
    end

    if #state.captured_points > 0 then
        begin_undo_once(state, "Brush Sculpt Envelope")
        deps.sculpt_captured_points(state.captured_points, dx, dy, state.target_envelope)
        deps.refresh_captured_from_envelope(state.target_envelope)
        state.sculpt_sort_pending = true
    end
    state.sculpt_last_client = { x = mx, y = my }
end

function M.on_lmb_pressed(state, config, mx, my, deps)
    if not state.target_envelope then return end

    state.is_dragging = true
    local kind = M.resolve_brush_drag_kind()
    state.active_sculpt_kind = kind
    state.drag_mode = (kind == "sculpt") and "combined" or "sculpt"
    state.drag_start_pos = { x = mx, y = my }
    state.sculpt_sort_pending = false
    state.last_envelope_sort_os = nil
    state.envelope_points_dirty_sort = false
    state.sculpt_last_client = { x = mx, y = my }

    if kind == "nudge" or kind == "smooth" then
        state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
        return
    end

    local n = deps.seed_brush_width_at_client(mx, my)
    if n > 0 then
        reaper.Undo_BeginBlock()
        state.undo_active = true
        state.undo_operation_name = "Brush Sculpt Envelope"
    end
    state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
end

return M
