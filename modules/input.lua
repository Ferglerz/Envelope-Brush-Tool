local M = {}

local _mod_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_mod_dir .. "path.lua")
local Util = Path.load_from_modules("util.lua")
local Mods = Path.load_from_modules("mods.lua")

local function imgui_mouse_wheel_sum(state)
    local w = 0
    if state.ctx then
        w = w + (reaper.ImGui_GetMouseWheel(state.ctx) or 0)
    end
    return w
end

--- Wheel modifiers: js_ReaScript JS_Mouse_GetState (global), not ImGui_GetKeyMods; WM wParam masks in mods.lua.
local VK_ESCAPE = 0x1B
local VK_X = 0x58
local VK_Y = 0x59

local function js_mod_down(bit)
    if not reaper.JS_Mouse_GetState then return false end
    return (reaper.JS_Mouse_GetState(bit) or 0) > 0
end

local function sculpt_modifier_down_js()
    return js_mod_down(Mods.JS_CTRL) or js_mod_down(Mods.JS_CMD)
end

--- Sculpt: Cmd or Ctrl. Smooth: Shift. Sculpt wins when combined with Shift.
function M.resolve_brush_drag_kind()
    if sculpt_modifier_down_js() then
        return "sculpt"
    end
    if js_mod_down(Mods.JS_SHIFT) then
        return "smooth"
    end
    return "nudge"
end

local function wheel_mod_alt()
    if not reaper.JS_Mouse_GetState then return false end
    return (reaper.JS_Mouse_GetState(Mods.VK_MENU) or 0) > 0
end

local function wheel_mod_shift(arrange_wparam_lo)
    local js = false
    if reaper.JS_Mouse_GetState then
        js = (reaper.JS_Mouse_GetState(Mods.JS_SHIFT) or 0) > 0
    end
    if arrange_wparam_lo then
        local lo = arrange_wparam_lo & 0xFFFF
        if (lo & Mods.MK_SHIFT) ~= 0 then return true end
    end
    return js
end

local function wheel_mod_power_cmd_ctrl(arrange_wparam_lo)
    local js = false
    if reaper.JS_Mouse_GetState then
        local a = reaper.JS_Mouse_GetState(Mods.JS_CTRL) or 0
        local b = reaper.JS_Mouse_GetState(Mods.JS_CMD) or 0
        js = a > 0 or b > 0
    end
    if arrange_wparam_lo then
        local lo = arrange_wparam_lo & 0xFFFF
        if (lo & Mods.MK_CONTROL) ~= 0 then return true end
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

local function imgui_key_pressed_any(state, key)
    if state.ctx and reaper.ImGui_IsKeyPressed(state.ctx, key) then return true end
    return false
end

--- js_ReaScript: JS_VKeys_GetState(0) returns a byte string indexed by VK (Escape = 27 / 0x1B).
local function js_vkeys_down(vk)
    if not reaper.JS_VKeys_GetState or type(vk) ~= "number" then
        return false
    end
    local s = reaper.JS_VKeys_GetState(0)
    if type(s) ~= "string" or vk < 1 or vk > #s then
        return false
    end
    return s:byte(vk) == 1
end

local function js_vkey_pressed_edge(state, vk, prev_field)
    local down = js_vkeys_down(vk)
    local prev = state[prev_field]
    state[prev_field] = down
    if prev == nil then return false end
    return down and not prev
end

local function key_pressed_edge(state, vk, prev_field, imgui_key_fn)
    if imgui_key_fn and imgui_key_pressed_any(state, imgui_key_fn()) then
        return true
    end
    return js_vkey_pressed_edge(state, vk, prev_field)
end

local function toggle_lock_time_axis(state)
    state.lock_time_axis = not state.lock_time_axis
    if state.lock_time_axis then
        state.lock_value_axis = false
    end
end

local function toggle_lock_value_axis(state)
    state.lock_value_axis = not state.lock_value_axis
    if state.lock_value_axis then
        state.lock_time_axis = false
    end
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
            sort_fn(state.target_envelope, Util.track_autoitem_idx(state))
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

--- LMB release: optional opts.cleanup_redundant_points_after_drag (smooth-only angle cleanup in deps).
function M.end_drag_operation(state, opts)
    if not state.is_dragging then
        return
    end
    if opts and opts.cleanup_redundant_points_after_drag then
        opts.cleanup_redundant_points_after_drag()
    end
    clear_drag_pointer_state(state)
    M.apply_envelope_undo_finalize(state, opts)
end

--- Script exit: same undo/sort rules as end_drag_operation, but also runs when not dragging (orphaned undo block).
function M.end_session_from_script_close(state, opts)
    if state.is_dragging then
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
    if not M.brush_wheel_context_active(state) then
        M.clear_wheel_momentum(state)
        return
    end
    local wcfg, bcfg = config.wheel, config.brush
    local v = state.wheel_momentum_vel or 0
    if math.abs(v) < (wcfg.WHEEL_MOMENTUM_STOP or 0.03) then
        M.clear_wheel_momentum(state)
        return
    end

    -- Stop coast if user holds a modifier (Alt / Cmd / Ctrl) used for other wheel bindings.
    if wheel_adjust_kind(nil) ~= "size" then
        M.clear_wheel_momentum(state)
        return
    end

    local maxv = wcfg.WHEEL_MOMENTUM_MAX_VEL or 32
    v = math.max(-maxv, math.min(maxv, v))
    v = v * (wcfg.WHEEL_MOMENTUM_FRICTION or 0.87)

    local bs = state.brush_size
    if bs >= bcfg.MAX_BRUSH_SIZE and v > 0 then
        v = 0
        state.wheel_mom_size_accum = 0
    elseif bs <= bcfg.MIN_BRUSH_SIZE and v < 0 then
        v = 0
        state.wheel_mom_size_accum = 0
    else
        local rate = wcfg.WHEEL_MOMENTUM_SIZE_RATE or 0.13
        state.wheel_mom_size_accum = (state.wheel_mom_size_accum or 0) + v * rate
        local acc = state.wheel_mom_size_accum
        local step_px = math.max(1, math.floor(bcfg.BRUSH_SIZE_STEP + 0.5))
        while acc >= 1 do
            state.brush_size = clamp(state.brush_size + step_px, bcfg.MIN_BRUSH_SIZE, bcfg.MAX_BRUSH_SIZE)
            acc = acc - 1
        end
        while acc <= -1 do
            state.brush_size = clamp(state.brush_size - step_px, bcfg.MIN_BRUSH_SIZE, bcfg.MAX_BRUSH_SIZE)
            acc = acc + 1
        end
        state.wheel_mom_size_accum = acc
    end

    state.wheel_momentum_vel = v
    if math.abs(v) < (wcfg.WHEEL_MOMENTUM_STOP or 0.03) then
        M.clear_wheel_momentum(state)
    end
end

--- Scroll: brush size | Alt+scroll: falloff | Cmd/Ctrl+scroll: power (Alt wins if both) | Shift: 25% finer steps.
--- Arrange wheel: intercepted (blocked); eaten for brush when context active, else forwarded to arrange.
function M.handle_wheel_input(state, config, clamp, core)
    if not state.ctx then return false end
    local brush_ctx = M.brush_wheel_context_active(state)
    local wm, arrange_wparam_lo = 0, nil
    if core and core.take_arrange_wheel_or_forward then
        wm, arrange_wparam_lo = core.take_arrange_wheel_or_forward(state, brush_ctx)
    end
    if not brush_ctx then return false end

    local ig = (wm == 0) and imgui_mouse_wheel_sum(state) or 0
    local wheel_delta = (wm ~= 0) and wm or ig
    if wheel_delta == 0 then return false end

    local alt = wheel_mod_alt()
    local fine = wheel_mod_shift(arrange_wparam_lo) and 0.25 or 1.0
    local d = wheel_delta > 0 and 1 or -1
    --- Default scroll→size mapping is inverted vs raw wheel delta; optional checkbox restores the legacy direction.
    local d_size = state.invert_brush_size_scroll and d or -d

    local fcfg, scfg, bcfg, wcfg = config.falloff, config.sculpt, config.brush, config.wheel
    if alt then
        M.clear_wheel_momentum(state)
        local step = core.falloff_wheel_step(config, fine)
        state.falloff_strength = core.clamp_falloff_strength(
            state.falloff_strength + d * step, config)
    elseif wheel_mod_power_cmd_ctrl(arrange_wparam_lo) then
        M.clear_wheel_momentum(state)
        local step = core.sculpt_wheel_step(config, fine)
        state.sculpt_power = core.clamp_sculpt_power(state.sculpt_power + d * step, config)
    else
        local step = math.max(1, math.floor(bcfg.BRUSH_SIZE_STEP * fine + 0.5))
        state.brush_size = clamp(state.brush_size + d_size * step,
            bcfg.MIN_BRUSH_SIZE, bcfg.MAX_BRUSH_SIZE)
        local imp = wcfg.WHEEL_MOMENTUM_IMPULSE or 2.5
        local mag = math.min(math.abs(wheel_delta), 4)
        local sign = wheel_delta > 0 and 1 or -1
        local mul = state.invert_brush_size_scroll and 1 or -1
        local add = sign * mag * imp * fine * mul
        state.wheel_momentum_vel = math.max(-(wcfg.WHEEL_MOMENTUM_MAX_VEL or 32),
            math.min(wcfg.WHEEL_MOMENTUM_MAX_VEL or 32, (state.wheel_momentum_vel or 0) + add))
    end

    return true
end

local function sync_escape_key_prev(state)
    local down = js_vkeys_down(VK_ESCAPE)
    state._brush_settings_esc_prev = down
    state._vk_prev_esc = down
end

function M.close_brush_settings(state)
    if not state.brush_settings_mode then
        return
    end
    state.brush_settings_mode = false
    state.brush_settings_freeze_client = nil
    state._brush_settings_panel_rect_imgui = nil
    state._brush_settings_js_lmb_prev = nil
    if state.ctx and reaper.ImGui_CloseCurrentPopup then
        pcall(reaper.ImGui_CloseCurrentPopup, state.ctx)
    end
    sync_escape_key_prev(state)
end

--- JS LMB press edge + `GetMousePosition`→ImGui (same space as `##BrushHudPanel` rect). Arrange clicks often never reach `ImGui_IsMouseClicked`.
function M.tick_brush_settings_lmb_dismiss(state, deps)
    if not state.brush_settings_mode or not state.ctx then
        return
    end
    if not deps or not deps.get_mouse_imgui_xy or not deps.is_lmb_down_js then
        return
    end
    local down = deps.is_lmb_down_js()
    if state._brush_settings_js_lmb_prev == nil then
        state._brush_settings_js_lmb_prev = down
        return
    end
    local prev = state._brush_settings_js_lmb_prev
    state._brush_settings_js_lmb_prev = down
    if not (down and not prev) then
        return
    end
    local rect = state._brush_settings_panel_rect_imgui
    if not rect then
        return
    end
    local mx, my = deps.get_mouse_imgui_xy()
    if type(mx) ~= "number" or type(my) ~= "number" then
        return
    end
    local x1, y1, x2, y2 = rect[1], rect[2], rect[3], rect[4]
    if mx >= x1 and mx <= x2 and my >= y1 and my <= y2 then
        return
    end
    M.close_brush_settings(state)
end

function M.handle_keyboard_input(state, deps)
    if not state.ctx then return false end

    -- Escape: JS edges only (arrange keeps focus). First Esc closes settings; second closes script.
    if state.brush_settings_mode then
        if js_vkey_pressed_edge(state, VK_ESCAPE, "_brush_settings_esc_prev") then
            M.close_brush_settings(state)
            return true
        end
    elseif js_vkey_pressed_edge(state, VK_ESCAPE, "_vk_prev_esc") then
        if deps.request_script_close then
            deps.request_script_close()
        end
        return true
    end

    if state.target_envelope then
        if key_pressed_edge(state, VK_X, "_vk_prev_x", reaper.ImGui_Key_X) then
            toggle_lock_time_axis(state)
            return true
        end
        if key_pressed_edge(state, VK_Y, "_vk_prev_y", reaper.ImGui_Key_Y) then
            toggle_lock_value_axis(state)
            return true
        end
    end

    return false
end

local RMB_DRAG_THRESH_PX = 8

--- RMB up without drag on brush lane: toggle frozen HUD settings mode (see render.render_brush_hud_panel).
function M.tick_rmb_brush_settings(state, brush_context_ok, mouse_x, mouse_y)
    if not reaper.JS_Mouse_GetState then return end
    local rmb_down = (reaper.JS_Mouse_GetState(2) or 0) > 0
    if rmb_down and not state._rmb_down_prev then
        state._rmb_press_client = (mouse_x and mouse_y) and { x = mouse_x, y = mouse_y } or nil
        state._rmb_dragged = false
    end
    if rmb_down and state._rmb_press_client and mouse_x and mouse_y then
        local dx = mouse_x - state._rmb_press_client.x
        local dy = mouse_y - state._rmb_press_client.y
        if (dx * dx + dy * dy) > (RMB_DRAG_THRESH_PX * RMB_DRAG_THRESH_PX) then
            state._rmb_dragged = true
        end
    end
    if not rmb_down and state._rmb_down_prev then
        if state._rmb_press_client and not state._rmb_dragged and brush_context_ok then
            if state.brush_settings_mode then
                M.close_brush_settings(state)
            else
                state.brush_settings_mode = true
                state.brush_settings_freeze_client = { x = state._rmb_press_client.x, y = state._rmb_press_client.y }
                sync_escape_key_prev(state)
                local lmb = (reaper.JS_Mouse_GetState(1) or 0) % 2 >= 1
                state._brush_settings_js_lmb_prev = lmb
            end
        end
        state._rmb_press_client = nil
    end
    state._rmb_down_prev = rmb_down
end

local function sculpt_delta_below_threshold(dx, dy, config)
    local t = config.sculpt.SCULPT_DRAG_MIN_MOVEMENT_PX or 0.02
    return (dx * dx + dy * dy) < (t * t)
end

function M.try_apply_sculpt_drag(state, config, mx, my, deps)
    if not state.target_envelope or state.drag_mode ~= "sculpt" then return end

    local kind = state.active_sculpt_kind or "nudge"
    local continuous_smooth = kind == "smooth"

    -- Fixed capture at LMB: nothing to sculpt — keep last_client in sync with the pointer.
    if #state.captured_points == 0 and not continuous_smooth then
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

    if continuous_smooth then
        state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
    end

    if #state.captured_points == 0 then
        state.sculpt_last_client = { x = mx, y = my }
        return
    end
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
    -- Non-nil: skip an immediate full sort on the first sculpt/nudge tick (see core.tick_throttled_envelope_sort_if_due).
    state.last_envelope_sort_os = (reaper.time_precise and reaper.time_precise()) or 0
    state.envelope_points_dirty_sort = false
    state.sculpt_last_client = { x = mx, y = my }

    if kind == "nudge" or kind == "smooth" then
        state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
        if deps.sync_brush_point_selection then
            deps.sync_brush_point_selection(state.target_envelope, state.captured_points)
        end
        return
    end

    local n = deps.seed_brush_width_at_client(mx, my)

    if n > 0 then
        reaper.Undo_BeginBlock()
        state.undo_active = true
        state.undo_operation_name = "Brush Sculpt Envelope"
    end
    state.captured_points = deps.capture_points_in_radius(mx, my, state.brush_size, state.target_envelope)
    if deps.sync_brush_point_selection then
        deps.sync_brush_point_selection(state.target_envelope, state.captured_points)
    end
end

return M
