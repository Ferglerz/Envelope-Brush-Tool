-- js_ReaScript: WM_MOUSEWHEEL / WM_LBUTTON* intercept on arrange HWND (blocked until Peek + forward or drop).

local M = {}

local ARRANGE_INTERCEPT_MSGS = {
    "WM_MOUSEWHEEL",
    "WM_LBUTTONDOWN",
    "WM_LBUTTONUP",
    "WM_RBUTTONDOWN",
    "WM_RBUTTONUP",
    "WM_CONTEXTMENU",
}

local function suppress_arrange_context_menu(state)
    if state.brush_settings_mode or state.brush_ate_arrange_rmb then
        return true
    end
    if state.target_envelope and state.sws_hover_detected then
        return true
    end
    return false
end

local function wparam_wheel_delta_hiword(wph)
    if wph == nil or wph == 0 then return 0 end
    if math.abs(wph) <= 2000 then
        return wph
    end
    local hi = math.floor(wph / 65536) % 65536
    if hi >= 32768 then hi = hi - 65536 end
    return hi
end

local function forward_wm(hwnd, msg, wpl, wph, lpl, lph)
    if not hwnd or not reaper.JS_WindowMessage_Send or not msg then return end
    if reaper.JS_WindowMessage_PassThrough then
        pcall(reaper.JS_WindowMessage_PassThrough, hwnd, msg, true)
    end
    pcall(reaper.JS_WindowMessage_Send, hwnd, msg, wpl or 0, wph or 0, lpl or 0, lph or 0)
    if reaper.JS_WindowMessage_PassThrough then
        pcall(reaper.JS_WindowMessage_PassThrough, hwnd, msg, false)
    end
end

local function release_one_message(hwnd, msg)
    if not hwnd or not msg then return end
    if reaper.JS_WindowMessage_PassThrough then
        pcall(reaper.JS_WindowMessage_PassThrough, hwnd, msg, true)
    end
    if reaper.JS_WindowMessage_Release then
        pcall(reaper.JS_WindowMessage_Release, hwnd, msg)
    end
    if reaper.JS_WindowMessage_PassThrough then
        pcall(reaper.JS_WindowMessage_PassThrough, hwnd, msg, false)
    end
end

--- Unhook wheel / buttons / move on a concrete HWND (safe to call even if this script never intercepted).
local function release_all_known_messages_on_hwnd(hwnd)
    if not hwnd then return end
    for i = 1, #ARRANGE_INTERCEPT_MSGS do
        release_one_message(hwnd, ARRANGE_INTERCEPT_MSGS[i])
    end
    release_one_message(hwnd, "WM_MOUSEMOVE")
end

local function ensure_arrange_move_intercept(state)
    if state.arrange_move_intercept_active or not state.arrange_intercept_hwnd then return end
    if not reaper.JS_WindowMessage_Intercept then return end
    local ok = pcall(reaper.JS_WindowMessage_Intercept, state.arrange_intercept_hwnd, "WM_MOUSEMOVE", false)
    if ok then
        state.arrange_move_intercept_active = true
    end
end

local function release_arrange_move_intercept(state)
    if not state.arrange_move_intercept_active then return end
    state.arrange_move_intercept_active = false
    state.wm_mousemove_last_time = 0
    local hwnd = state.arrange_intercept_hwnd
    if hwnd then
        release_one_message(hwnd, "WM_MOUSEMOVE")
    end
end

--- Drop queued intercept messages (peek + consume timestamp, no forward).
local function discard_intercept_queue(state, hwnd, msg, last_key, max_iter)
    if not hwnd or not reaper.JS_WindowMessage_Peek or not msg or not last_key then return end
    max_iter = max_iter or 128
    for _ = 1, max_iter do
        local ret, _, time = reaper.JS_WindowMessage_Peek(hwnd, msg)
        if not ret or not time or time == 0 then
            break
        end
        if time == state[last_key] then
            break
        end
        state[last_key] = time
    end
end

--- Forward any messages still sitting in the intercept queue (blocked until Peek) so nothing is lost before Release.
local function drain_intercept_queue(state, hwnd, msg, last_key, max_iter)
    if not hwnd or not reaper.JS_WindowMessage_Peek or not msg or not last_key then return end
    max_iter = max_iter or 128
    for _ = 1, max_iter do
        local ret, _, time, wpl, wph, lpl, lph = reaper.JS_WindowMessage_Peek(hwnd, msg)
        if not ret or not time or time == 0 then
            break
        end
        if time == state[last_key] then
            break
        end
        state[last_key] = time
        forward_wm(hwnd, msg, wpl, wph, lpl, lph)
    end
end

--- WM_MOUSEWHEEL + WM_LBUTTON* on arrange (blocked until Peek + forward or drop). MOVE added while LMB is eaten.
--- get_arrange_hwnd: function() -> hwnd (e.g. core.get_arrange_hwnd)
function M.ensure_arrange_intercepts(state, get_arrange_hwnd)
    if state.arrange_intercept_active then return true end
    if not reaper.JS_WindowMessage_Intercept or not reaper.JS_WindowMessage_Peek then return false end
    local hwnd = get_arrange_hwnd and get_arrange_hwnd() or nil
    if not hwnd then return false end
    for i = 1, #ARRANGE_INTERCEPT_MSGS do
        local msg = ARRANGE_INTERCEPT_MSGS[i]
        if not pcall(reaper.JS_WindowMessage_Intercept, hwnd, msg, false) then
            for j = 1, i - 1 do
                release_one_message(hwnd, ARRANGE_INTERCEPT_MSGS[j])
            end
            return false
        end
    end
    state.arrange_intercept_hwnd = hwnd
    state.arrange_intercept_active = true
    return true
end

--- get_arrange_hwnd: optional; when set, always unhooks the *current* arrange HWND after state-based cleanup
--- (covers atexit / second-run toggle if state and HWND diverged, or intercept_active was cleared incorrectly).
function M.release_arrange_intercepts(state, get_arrange_hwnd)
    if state.arrange_intercept_active then
        local hwnd = state.arrange_intercept_hwnd
        if not hwnd then
            state.arrange_intercept_active = false
            state.brush_ate_arrange_lmb = false
            state.brush_ate_arrange_rmb = false
            state.arrange_move_intercept_active = false
        else
            state.brush_ate_arrange_lmb = false
            state.brush_ate_arrange_rmb = false

            state.wm_mousemove_last_time = 0
            if state.arrange_move_intercept_active then
                drain_intercept_queue(state, hwnd, "WM_MOUSEMOVE", "wm_mousemove_last_time")
            end
            release_arrange_move_intercept(state)

            state.wm_wheel_last_time = 0
            state.wm_lmb_down_last_time = 0
            state.wm_lmb_up_last_time = 0
            state.wm_rmb_down_last_time = 0
            state.wm_rmb_up_last_time = 0
            state.wm_contextmenu_last_time = 0
            drain_intercept_queue(state, hwnd, "WM_MOUSEWHEEL", "wm_wheel_last_time")
            drain_intercept_queue(state, hwnd, "WM_LBUTTONDOWN", "wm_lmb_down_last_time")
            drain_intercept_queue(state, hwnd, "WM_LBUTTONUP", "wm_lmb_up_last_time")
            discard_intercept_queue(state, hwnd, "WM_RBUTTONDOWN", "wm_rmb_down_last_time")
            discard_intercept_queue(state, hwnd, "WM_RBUTTONUP", "wm_rmb_up_last_time")
            discard_intercept_queue(state, hwnd, "WM_CONTEXTMENU", "wm_contextmenu_last_time")

            state.arrange_intercept_hwnd = nil
            state.arrange_intercept_active = false
            state.wm_wheel_last_time = 0
            state.wm_lmb_down_last_time = 0
            state.wm_lmb_up_last_time = 0
            state.wm_rmb_down_last_time = 0
            state.wm_rmb_up_last_time = 0
            state.wm_contextmenu_last_time = 0
            state.wm_mousemove_last_time = 0

            release_all_known_messages_on_hwnd(hwnd)
        end
    end

    local live = get_arrange_hwnd and get_arrange_hwnd() or nil
    if live then
        release_all_known_messages_on_hwnd(live)
    end
end

--- Peek WM_LBUTTON* / WM_MOUSEMOVE / WM_RBUTTON*: eat when brushing (target envelope), else forward. MOVE intercepted only after an eaten down.
--- eat_rmb: when nil, defaults to eat_lmb (backward compatible).
function M.process_arrange_lmb_or_forward(state, eat_lmb, get_arrange_hwnd, eat_rmb)
    eat_rmb = (eat_rmb ~= nil) and eat_rmb or eat_lmb
    if not state.arrange_intercept_active or not reaper.JS_WindowMessage_Peek then return end
    local hwnd = state.arrange_intercept_hwnd or (get_arrange_hwnd and get_arrange_hwnd()) or nil
    if not hwnd then return end

    local function handle_lmb(msg, last_key)
        local ret, _, time, wpl, wph, lpl, lph = reaper.JS_WindowMessage_Peek(hwnd, msg)
        if not ret or not time or time == 0 then return end
        if time == state[last_key] then return end
        state[last_key] = time

        if msg == "WM_LBUTTONDOWN" then
            if eat_lmb then
                state.brush_ate_arrange_lmb = true
                ensure_arrange_move_intercept(state)
            else
                state.brush_ate_arrange_lmb = false
                forward_wm(hwnd, msg, wpl, wph, lpl, lph)
            end
        else
            if state.brush_ate_arrange_lmb then
                state.brush_ate_arrange_lmb = false
                release_arrange_move_intercept(state)
            else
                forward_wm(hwnd, msg, wpl, wph, lpl, lph)
            end
        end
    end

    handle_lmb("WM_LBUTTONDOWN", "wm_lmb_down_last_time")
    handle_lmb("WM_LBUTTONUP", "wm_lmb_up_last_time")

    local function handle_rmb(msg, last_key)
        local ret, _, time, wpl, wph, lpl, lph = reaper.JS_WindowMessage_Peek(hwnd, msg)
        if not ret or not time or time == 0 then return end
        if time == state[last_key] then return end
        state[last_key] = time

        if msg == "WM_RBUTTONDOWN" then
            if eat_rmb then
                state.brush_ate_arrange_rmb = true
            else
                state.brush_ate_arrange_rmb = false
                forward_wm(hwnd, msg, wpl, wph, lpl, lph)
            end
        else
            if state.brush_ate_arrange_rmb then
                state.brush_ate_arrange_rmb = false
            else
                forward_wm(hwnd, msg, wpl, wph, lpl, lph)
            end
        end
    end

    handle_rmb("WM_RBUTTONDOWN", "wm_rmb_down_last_time")
    handle_rmb("WM_RBUTTONUP", "wm_rmb_up_last_time")

    local ret_cm, _, time_cm, wpl_cm, wph_cm, lpl_cm, lph_cm = reaper.JS_WindowMessage_Peek(hwnd, "WM_CONTEXTMENU")
    if ret_cm and time_cm and time_cm ~= 0 and time_cm ~= state.wm_contextmenu_last_time then
        state.wm_contextmenu_last_time = time_cm
        if not suppress_arrange_context_menu(state) then
            forward_wm(hwnd, "WM_CONTEXTMENU", wpl_cm, wph_cm, lpl_cm, lph_cm)
        end
    end

    if state.arrange_move_intercept_active then
        while true do
            local ret, _, time = reaper.JS_WindowMessage_Peek(hwnd, "WM_MOUSEMOVE")
            if not ret or not time or time == 0 then break end
            if time == state.wm_mousemove_last_time then break end
            state.wm_mousemove_last_time = time
        end
    end
end

--- If OS says LMB is up but we still hold eat/MOVE intercept (e.g. release outside arrange), clear it.
--- If OS says RMB is up but we still hold RMB eat, clear it.
function M.sync_arrange_mouse_eat_with_os(state, lmb_down, rmb_down)
    if not lmb_down then
        if state.brush_ate_arrange_lmb or state.arrange_move_intercept_active then
            state.brush_ate_arrange_lmb = false
            release_arrange_move_intercept(state)
        end
    end
    if rmb_down == false and state.brush_ate_arrange_rmb then
        state.brush_ate_arrange_rmb = false
    end
end

--- Peek one WM_MOUSEWHEEL. If brush_eat and delta usable, return ImGui-scale delta, wParam low word (MK_*), and do not forward.
--- wParam LOWORD: MK_SHIFT 0x0004, MK_CONTROL 0x0008 (same tick as wheel; use with JS_Mouse_GetState for modifiers).
--- Otherwise re-inject so REAPER still zooms (PassThrough + Send + PassThrough).
function M.take_arrange_wheel_or_forward(state, brush_eat, get_arrange_hwnd)
    if not state.arrange_intercept_active or not reaper.JS_WindowMessage_Peek then return 0, nil end
    local hwnd = state.arrange_intercept_hwnd or (get_arrange_hwnd and get_arrange_hwnd()) or nil
    if not hwnd then return 0, nil end
    local ret, _, time, wpl, wph, lpl, lph = reaper.JS_WindowMessage_Peek(hwnd, "WM_MOUSEWHEEL")
    if not ret or not time or time == 0 then return 0, nil end
    if time == state.wm_wheel_last_time then return 0, nil end
    state.wm_wheel_last_time = time

    if not brush_eat then
        forward_wm(hwnd, "WM_MOUSEWHEEL", wpl, wph, lpl, lph)
        return 0, nil
    end

    local d = wparam_wheel_delta_hiword(wph)
    if d == 0 then
        forward_wm(hwnd, "WM_MOUSEWHEEL", wpl, wph, lpl, lph)
        return 0, nil
    end

    local ad = math.abs(d)
    if ad >= 120 then
        return d / 120.0, wpl
    end
    return d > 0 and 1 or -1, wpl
end

return M
