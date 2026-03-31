local M = {}

M.CONFIG = {
    -- After deferred envelope flush, skip drawing the editor ImGui window for that tick (visible flicker; can help APIs stick).
    DEFER_ENVELOPE_SUPPRESS_CONTROL_IMGUI = false,
    -- Debug synthetic insert: horizontal offset from debug button's right edge, in ImGui window space (px).
    DEBUG_SYNTHETIC_OFFSET_X = 400,
    -- >0: Main_OnCommand(id,0). 0: InsertEnvelopePoint* after prepare_envelope_for_point_insert (track select + SWS arm).
    INSERT_AT_MOUSE_ACTION_ID = 0,
    MIN_POINT_SPACING_PIXELS = 10,
    DEFAULT_BRUSH_SIZE = 50,
    MIN_BRUSH_SIZE = 10,
    MAX_BRUSH_SIZE = 200,
    BRUSH_SIZE_STEP = 1,
    FALLOFF_TYPES = {"exponential", "linear", "inverse_exponential"},
    SCULPT_MODES = {"grab", "smooth"},
    DEFAULT_FALLOFF_STRENGTH = 1.0,
    MIN_FALLOFF_STRENGTH = 0.1,
    MAX_FALLOFF_STRENGTH = 3.0,
    FALLOFF_STRENGTH_STEP = 0.1,
    -- Inner dashed radius as fraction of brush radius: scales with falloff strength.
    FALLOFF_INNER_RATIO_AT_MIN_STRENGTH = 0.88,
    FALLOFF_INNER_RATIO_AT_MAX_STRENGTH = 0.12,
    -- HUD: vertical pad around brush; horizontal extra for labels to the right of the brush.
    BRUSH_HUD_PAD_V = 36,
    BRUSH_HUD_LABEL_EXTRA_W = 240,
    -- Pixels to skip at top of arrange view (time ruler inside 0x3E8 child). Tune if value axis is offset.
    ARRANGE_RULER_INSET = 28,
    -- Point-based hover test against the locked envelope curve; independent of brush radius/HUD size.
    ENVELOPE_HOVER_TOLERANCE_PIXELS = 8,
    OUTER_CIRCLE_COLOR = 0xFFFFFFCC,
    INNER_CIRCLE_COLOR = 0xFFFFFF66,
    CIRCLE_THICKNESS = 2.0,
    -- Min mouse delta (arrange client px) per defer tick to apply sculpt; smaller deltas accumulate until exceeded.
    SCULPT_DRAG_MIN_MOVEMENT_PX = 0.02,
    -- Smooth sculpt: blend per step toward Envelope_Evaluate at each point's time
    DEFAULT_SMOOTH_STRENGTH = 0.2,
    MIN_SMOOTH_STRENGTH = 0.02,
    MAX_SMOOTH_STRENGTH = 1.0,
    -- Shift+scroll: multiplies grab/smooth point movement (delta time/value).
    DEFAULT_SCULPT_POWER = 1.0,
    MIN_SCULPT_POWER = 0.25,
    MAX_SCULPT_POWER = 4.0,
    SCULPT_POWER_STEP = 0.05,
}

function M.new_state(config)
    return {
        -- Brush settings
        brush_size = config.DEFAULT_BRUSH_SIZE,
        falloff_type = 1,
        falloff_strength = config.DEFAULT_FALLOFF_STRENGTH,
        sculpt_mode = 1,
        smooth_strength = config.DEFAULT_SMOOTH_STRENGTH,
        sculpt_power = config.DEFAULT_SCULPT_POWER,
        lock_time_axis = false,
        lock_value_axis = false,

        -- Mouse and interaction
        mouse_pos = {x = 0, y = 0},
        is_dragging = false,
        drag_mode = "sculpt",
        drag_start_pos = {x = 0, y = 0},
        captured_points = {},
        last_create_client = nil,

        -- Envelope context (REAPER: autoitem_idx -1 = parent lane; >=0 = automation item on that envelope)
        target_envelope = nil,
        envelope_autoitem_idx = -1,
        envelope_bounds = {top = 150, bottom = 600, left = 200, right = 1200},
        overlay_visible = false,
        cached_envelope = nil,
        envelope_detected = false,
        sws_hover_detected = false,

        -- Cached envelope properties
        cached_envelope_properties = {envelope = nil, min_val = 0, max_val = 1},

        -- Per-frame cache (arrange view)
        frame_arrange_start = 0,
        frame_arrange_end = 0,

        -- Main window client size for overlay
        client_w = 2000,
        client_h = 2000,

        -- Undo system
        undo_active = false,
        undo_operation_name = "",
        sculpt_sort_pending = false,
        sculpt_last_client = nil,

        -- ImGui: editor window + separate HUD for brush.
        ctx = nil,
        ctx_brush = nil,

        -- Arrange: JS_WindowMessage_Intercept/Peek (wheel + LMB + optional MOVE while eating LMB).
        arrange_intercept_active = false,
        arrange_intercept_hwnd = nil,
        wm_wheel_last_time = 0,
        wm_lmb_down_last_time = 0,
        wm_lmb_up_last_time = 0,
        wm_mousemove_last_time = 0,
        brush_ate_arrange_lmb = false,
        arrange_move_intercept_active = false,

        -- Deferred envelope ops: run Insert/Set at start of next main_loop (after defer), not same pass as ImGui.
        envelope_flush_pending = false,
        suppress_imgui_control_this_frame = false,

        -- Debug: release JS message intercepts, hide arrange HUD; test insert via button only.
        debug_disable_js_eat = false,
        _debug_js_eat_prev = false,

        -- Insert debug: checkbox in main window; last attempt details in separate ImGui window.
        debug_show_insert_panel = false,
        debug_insert_last = nil,
    }
end

function M.get_distance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

function M.clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
end

--- ReaScript: Envelope_Evaluate(env, time, samplerate, samplesRequested). (time, 0, 0) is not valid (sr=0).
function M.envelope_value_at_time(envelope, time_pos)
    if not envelope or time_pos == nil then return nil end
    local sr = 44100
    if reaper.GetSetProjectInfo then
        local proj = reaper.EnumProjects and reaper.EnumProjects(-1) or 0
        local r = reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", -1, false)
        if type(r) == "number" and r > 0 and r == r then
            sr = r
        end
    end
    local _, val = reaper.Envelope_Evaluate(envelope, time_pos, sr, 1)
    if val ~= nil then return val end
    return nil
end

function M.calc_inner_brush_radius(state, config, outer_radius)
    local span = config.MAX_FALLOFF_STRENGTH - config.MIN_FALLOFF_STRENGTH
    local t = span > 1e-9 and (state.falloff_strength - config.MIN_FALLOFF_STRENGTH) / span or 0.5
    t = M.clamp(t, 0, 1)
    local rmin = config.FALLOFF_INNER_RATIO_AT_MAX_STRENGTH
    local rmax = config.FALLOFF_INNER_RATIO_AT_MIN_STRENGTH
    local ratio = rmax - t * (rmax - rmin)
    return outer_radius * ratio
end

function M.refresh_frame_arrange(state)
    local a_start, a_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    state.frame_arrange_start = a_start
    state.frame_arrange_end = a_end
end

function M.get_arrange_hwnd()
    if not reaper.JS_Window_FindChildByID then return nil end
    local main = reaper.GetMainHwnd()
    if not main then return nil end
    return reaper.JS_Window_FindChildByID(main, 0x3E8)
end

--- JS_Window_SetFocus(main + arrange). Not called by the brush anymore — it pulled OS focus every defer tick and blocked the Action list etc. Kept for optional local experiments.
function M.focus_arrange_for_envelope_api()
    if not reaper.JS_Window_SetFocus then return end
    local main = reaper.GetMainHwnd()
    if main then
        pcall(reaper.JS_Window_SetFocus, main)
    end
    local arrange = M.get_arrange_hwnd()
    if arrange then
        pcall(reaper.JS_Window_SetFocus, arrange)
    end
end

--- js API expects integer screen coordinates on some platforms / Lua builds.
local function screen_to_arrange_client_int(arrange, sx, sy)
    if not arrange or not reaper.JS_Window_ScreenToClient or sx == nil or sy == nil then return nil, nil end
    return reaper.JS_Window_ScreenToClient(arrange, math.floor(sx + 0.5), math.floor(sy + 0.5))
end

--- Arrange HWND **client** mouse position, in the same ImGui/native space as the brush HUD
--- (GetRect + PointConvertNative → proportional map into GetClientRect). Not ScreenToClient(GetMouse).
function M.get_mouse_client_xy(ctx, get_arrange_hwnd_fn)
    if not ctx or not get_arrange_hwnd_fn or not reaper.GetMousePosition then return nil, nil end
    if not reaper.ImGui_PointConvertNative or not reaper.JS_Window_GetClientRect then return nil, nil end
    local mx, my = reaper.GetMousePosition()
    local imx, imy = reaper.ImGui_PointConvertNative(ctx, mx, my, false)
    if imx == nil or imy == nil then return nil, nil end
    local il, it, iw, ih = M.get_arrange_imgui_overlay_geometry(ctx, get_arrange_hwnd_fn)
    if not il or not it or not iw or not ih or iw <= 0 or ih <= 0 then return nil, nil end
    local hwnd = get_arrange_hwnd_fn()
    if not hwnd then return nil, nil end
    local ok, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
    if not ok then return nil, nil end
    local nl, nr = math.min(l, r), math.max(l, r)
    local nt, nb = math.min(t, b), math.max(t, b)
    local cw, ch = nr - nl, nb - nt
    if cw <= 0 or ch <= 0 then return nil, nil end
    local u = (imx - il) / iw
    local v = (imy - it) / ih
    u = M.clamp(u, 0, 1)
    v = M.clamp(v, 0, 1)
    return nl + u * cw, nt + v * ch
end

--- ImGui window-local point (e.g. from GetItemRect*) -> arrange 0x3E8 client coords. third arg to PointConvertNative: true = to screen native.
function M.imgui_window_local_to_arrange_client(ctx, local_x, local_y, get_arrange_hwnd_fn)
    if not ctx or not reaper.ImGui_GetWindowPos or not get_arrange_hwnd_fn then return nil, nil end
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    if wx == nil or wy == nil then return nil, nil end
    local gx, gy = wx + local_x, wy + local_y
    local sx, sy = gx, gy
    if reaper.ImGui_PointConvertNative then
        local nx, ny = reaper.ImGui_PointConvertNative(ctx, gx, gy, true)
        if nx ~= nil and ny ~= nil then
            sx, sy = nx, ny
        end
    end
    local arrange = get_arrange_hwnd_fn()
    return screen_to_arrange_client_int(arrange, sx, sy)
end

--- TK/Sexan: native arrange HWND rect -> ImGui coordinates (HiDPI / macOS safe).
function M.get_arrange_imgui_overlay_geometry(ctx, get_arrange_hwnd_fn)
    if not ctx or not reaper.JS_Window_GetRect or not reaper.ImGui_PointConvertNative then return nil end
    local hwnd = get_arrange_hwnd_fn()
    if not hwnd then return nil end
    local ok, left, top, right, bottom = reaper.JS_Window_GetRect(hwnd)
    if not ok then return nil end
    local il, it = reaper.ImGui_PointConvertNative(ctx, left, top, false)
    local ir, ib = reaper.ImGui_PointConvertNative(ctx, right, bottom, false)
    if il == nil or it == nil or ir == nil or ib == nil then return nil end
    local w = ir - il
    local h = ib - it
    if w <= 0 or h <= 0 then return nil end
    return il, it, w, h
end

--- Native screen mouse -> ImGui coordinates (same space as overlay + draw list).
function M.get_mouse_imgui_xy(ctx)
    if not ctx or not reaper.ImGui_PointConvertNative then return nil, nil end
    local mx, my = reaper.GetMousePosition()
    return reaper.ImGui_PointConvertNative(ctx, mx, my, false)
end

function M.native_to_hud_coords(ctx, x_native, y_native)
    local os_name = reaper.GetOS() or ""
    local is_mac = os_name:match("OSX") or os_name:match("macOS")
    if not is_mac then
        return x_native, y_native
    end

    local vp = reaper.ImGui_GetMainViewport(ctx)
    local _, vp_y = reaper.ImGui_Viewport_GetPos(vp)
    local _, vp_h = reaper.ImGui_Viewport_GetSize(vp)
    local y_hud = vp_y + vp_h - y_native
    return x_native, y_hud
end

function M.is_lmb_down_js()
    if not reaper.JS_Mouse_GetState then return false end
    local st = reaper.JS_Mouse_GetState(1) or 0
    if (st % 2) >= 1 then return true end
    local ok, st_all = pcall(reaper.JS_Mouse_GetState, -1)
    if ok and st_all and (st_all % 2) >= 1 then return true end
    return false
end

--- SWS BR_EnvAlloc: pass true for take (item) envelopes so min/max and flags match the lane.
function M.envelope_is_take_envelope(envelope)
    if not envelope then return false end
    local proj = reaper.EnumProjects and reaper.EnumProjects(-1) or 0
    local take = reaper.GetEnvelopeInfo_Value(envelope, "P_TAKE")
    if take and take ~= 0 and reaper.ValidatePtr2 and reaper.ValidatePtr2(proj, take, "MediaItem_Take*") then
        return true
    end
    return false
end

function M.get_envelope_properties(state, envelope)
    if not envelope then return nil, nil end

    if state.cached_envelope_properties.envelope == envelope then
        return state.cached_envelope_properties.min_val, state.cached_envelope_properties.max_val
    end

    local br_env = reaper.BR_EnvAlloc(envelope, M.envelope_is_take_envelope(envelope))
    if not br_env then return nil, nil end
    local _, _, _, _, _, _, min_val, max_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)

    state.cached_envelope_properties.envelope = envelope
    state.cached_envelope_properties.min_val = min_val
    state.cached_envelope_properties.max_val = max_val

    return min_val, max_val
end

function M.is_envelope_lane_visible(envelope)
    if not envelope then return false end
    local br_env = reaper.BR_EnvAlloc(envelope, M.envelope_is_take_envelope(envelope))
    if not br_env then return false end
    -- BR_EnvGetProperties returns: active, visible, armed, ...
    -- Use the 2nd value (visible), not armed.
    local _, visible = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)
    return visible == true
end

--- Common ReaScript pattern before InsertEnvelopePoint*: isolate parent track + arm envelope (SWS), commit, then insert.
--- See SWS BR_EnvGetProperties / BR_EnvSetProperties (armed=true) / BR_EnvFree(true).
function M.prepare_envelope_for_point_insert(envelope)
    if not envelope then return end
    local proj = reaper.EnumProjects and reaper.EnumProjects(-1) or 0
    local tr = reaper.GetEnvelopeInfo_Value(envelope, "P_TRACK")
    if tr and tr ~= 0 then
        if reaper.ValidatePtr2 then
            if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then
                reaper.SetOnlyTrackSelected(tr)
            end
        else
            reaper.SetOnlyTrackSelected(tr)
        end
    end
    if not reaper.BR_EnvAlloc or not reaper.BR_EnvGetProperties or not reaper.BR_EnvSetProperties or not reaper.BR_EnvFree then
        return
    end
    local br = reaper.BR_EnvAlloc(envelope, M.envelope_is_take_envelope(envelope))
    if not br then return end
    local a, vis, armed, inLane, lh, dsh, minv, maxv, cval, etype, fsc, aiopt = reaper.BR_EnvGetProperties(br)
    if a == nil then a = true end
    if vis == nil then vis = true end
    if inLane == nil then inLane = true end
    if lh == nil then lh = 0 end
    if dsh == nil then dsh = 0 end
    if fsc == nil then fsc = false end
    local ok = pcall(function()
        reaper.BR_EnvSetProperties(br, a, vis, true, inLane, lh, dsh, fsc, aiopt or 0)
        reaper.BR_EnvFree(br, true)
    end)
    if not ok then
        pcall(reaper.BR_EnvFree, br, false)
    end
end

--- Lightweight SWS snapshot for debug UI (is_take-aware BR_EnvAlloc).
function M.get_envelope_sws_snapshot(envelope)
    if not envelope or not reaper.BR_EnvAlloc or not reaper.BR_EnvGetProperties or not reaper.BR_EnvFree then
        return nil
    end
    local is_take = M.envelope_is_take_envelope(envelope)
    local br = reaper.BR_EnvAlloc(envelope, is_take)
    if not br then
        return { br_alloc_failed = true, is_take = is_take }
    end
    local active, visible, armed, in_lane, lane_h, dotted, min_v, max_v, cur_v, env_type, fader_sc, ai_opt =
        reaper.BR_EnvGetProperties(br)
    reaper.BR_EnvFree(br, false)
    return {
        is_take = is_take,
        active = active,
        visible = visible,
        armed = armed,
        in_lane = in_lane,
        lane_height = lane_h,
        min_value = min_v,
        max_value = max_v,
        current_value = cur_v,
        env_type = env_type,
        fader_scaling = fader_sc,
        autoitem_opt = ai_opt,
    }
end

function M.clear_target_envelope_state_only(state)
    state.target_envelope = nil
    state.envelope_autoitem_idx = -1
    state.cached_envelope = nil
    state.cached_envelope_properties.envelope = nil
    state.envelope_flush_pending = false
    state.suppress_imgui_control_this_frame = false
end

function M.calculate_falloff(distance, radius, falloff_type_name, strength)
    if distance >= radius then return 0 end
    local normalized = distance / radius

    if falloff_type_name == "exponential" then
        return math.exp(-strength * 3 * normalized)
    elseif falloff_type_name == "linear" then
        return (1 - normalized) * strength
    else -- inverse_exponential
        return (1 - math.exp(-strength * 3 * (1 - normalized)))
    end
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
    release_one_message(state.arrange_intercept_hwnd, "WM_MOUSEMOVE")
end

--- WM_MOUSEWHEEL + WM_LBUTTON* on arrange (blocked until Peek + forward or drop). MOVE added while LMB is eaten.
function M.ensure_arrange_intercepts(state)
    if state.arrange_intercept_active then return true end
    if not reaper.JS_WindowMessage_Intercept or not reaper.JS_WindowMessage_Peek then return false end
    local hwnd = M.get_arrange_hwnd()
    if not hwnd then return false end
    local msgs = { "WM_MOUSEWHEEL", "WM_LBUTTONDOWN", "WM_LBUTTONUP" }
    for i = 1, #msgs do
        if not pcall(reaper.JS_WindowMessage_Intercept, hwnd, msgs[i], false) then
            for j = 1, i - 1 do
                release_one_message(hwnd, msgs[j])
            end
            return false
        end
    end
    state.arrange_intercept_hwnd = hwnd
    state.arrange_intercept_active = true
    return true
end

function M.release_arrange_intercepts(state)
    if not state.arrange_intercept_active then return end
    release_arrange_move_intercept(state)
    local hwnd = state.arrange_intercept_hwnd
    state.arrange_intercept_hwnd = nil
    state.arrange_intercept_active = false
    state.wm_wheel_last_time = 0
    state.wm_lmb_down_last_time = 0
    state.wm_lmb_up_last_time = 0
    state.wm_mousemove_last_time = 0
    state.brush_ate_arrange_lmb = false
    if hwnd then
        release_one_message(hwnd, "WM_MOUSEWHEEL")
        release_one_message(hwnd, "WM_LBUTTONDOWN")
        release_one_message(hwnd, "WM_LBUTTONUP")
    end
end

--- Peek WM_LBUTTON* / WM_MOUSEMOVE: eat when brushing (target envelope), else forward. MOVE intercepted only after an eaten down.
function M.process_arrange_lmb_or_forward(state, eat_lmb)
    if not state.arrange_intercept_active or not reaper.JS_WindowMessage_Peek then return end
    local hwnd = state.arrange_intercept_hwnd or M.get_arrange_hwnd()
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
function M.sync_arrange_mouse_eat_with_os(state, lmb_down)
    if lmb_down then return end
    if state.brush_ate_arrange_lmb or state.arrange_move_intercept_active then
        state.brush_ate_arrange_lmb = false
        release_arrange_move_intercept(state)
    end
end

--- Peek one WM_MOUSEWHEEL. If brush_eat and delta usable, return ImGui-scale delta and do not forward.
--- Otherwise re-inject so REAPER still zooms (PassThrough + Send + PassThrough).
function M.take_arrange_wheel_or_forward(state, brush_eat)
    if not state.arrange_intercept_active or not reaper.JS_WindowMessage_Peek then return 0 end
    local hwnd = state.arrange_intercept_hwnd or M.get_arrange_hwnd()
    if not hwnd then return 0 end
    local ret, _, time, wpl, wph, lpl, lph = reaper.JS_WindowMessage_Peek(hwnd, "WM_MOUSEWHEEL")
    if not ret or not time or time == 0 then return 0 end
    if time == state.wm_wheel_last_time then return 0 end
    state.wm_wheel_last_time = time

    if not brush_eat then
        forward_wm(hwnd, "WM_MOUSEWHEEL", wpl, wph, lpl, lph)
        return 0
    end

    local d = wparam_wheel_delta_hiword(wph)
    if d == 0 then
        forward_wm(hwnd, "WM_MOUSEWHEEL", wpl, wph, lpl, lph)
        return 0
    end

    local ad = math.abs(d)
    if ad >= 120 then
        return d / 120.0
    end
    return d > 0 and 1 or -1
end

return M
