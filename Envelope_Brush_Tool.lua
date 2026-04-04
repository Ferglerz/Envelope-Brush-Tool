-- REAPER Brush Envelope Editor
-- Sculpt and create envelope points with brush-like controls.

local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""

--- Toolbar toggle: capture on this action run (not from defer).
--- get_action_context returns: is_new_value, filename, section_id, cmd_id, ...
local _, _, ACTION_SECTION, ACTION_CMD = reaper.get_action_context()
local function set_toolbar_toggle_state(state)
    if ACTION_CMD == nil or ACTION_CMD < 0 then
        return
    end
    reaper.SetToggleCommandState(ACTION_SECTION, ACTION_CMD, state)
    reaper.RefreshToolbar2(ACTION_SECTION, ACTION_CMD)
end

--- Toggle: REAPER keeps one Lua state per script path. A second run invokes the previous instance's
--- `close()` (same idea as Advanced Toolbars' graceful shutdown when the defer loop stops), then exits
--- before registering a new defer — so the action behaves like an on/off switch.
local SINGLETON_GKEY = "Fergler_EnvelopeBrush_Singleton"
local prev_singleton = _G[SINGLETON_GKEY]
if type(prev_singleton) == "table" and type(prev_singleton.close) == "function" then
    prev_singleton.close()
    return
end

local Core = dofile(SCRIPT_DIR .. "modules/core.lua")
local Envelope = dofile(SCRIPT_DIR .. "modules/envelope/envelope.lua")
local Ops = dofile(SCRIPT_DIR .. "modules/ops.lua")
local Render = dofile(SCRIPT_DIR .. "modules/render/render.lua")
local Input = dofile(SCRIPT_DIR .. "modules/input.lua")
local UI = dofile(SCRIPT_DIR .. "modules/ui.lua")
local Deps = dofile(SCRIPT_DIR .. "modules/deps.lua")
local ProjExt = dofile(SCRIPT_DIR .. "modules/project_ext.lua")

local CONFIG = Core.CONFIG
local State = Core.new_state(CONFIG)
local D = Deps.new(State, CONFIG, {
    core = Core,
    envelope = Envelope,
    ops = Ops,
    input = Input,
})

--- Must be declared before init(): init assigns deps used by apply_envelope_drag_tick (same local, not global).
local DRAG_INPUT_DEPS

local function init()
    if not reaper.ImGui_CreateContext then
        reaper.ShowMessageBox("This script requires ReaImGui.", "Missing ReaImGui", 0)
        return false
    end
    if not reaper.BR_GetMouseCursorContext then
        reaper.ShowMessageBox("This script requires the SWS extension.", "Missing SWS Extension", 0)
        return false
    end
    if not reaper.JS_Window_FindChildByID or not reaper.JS_Window_GetClientRect or not reaper.JS_Window_ScreenToClient
        or not reaper.JS_Window_ClientToScreen or not reaper.JS_Window_GetRect or not reaper.ImGui_PointConvertNative
        or not reaper.JS_Window_GetForeground or not reaper.JS_Window_GetParent
        or not reaper.JS_WindowMessage_Intercept or not reaper.JS_WindowMessage_Peek or not reaper.JS_WindowMessage_Release
        or not reaper.JS_WindowMessage_Send or not reaper.JS_VKeys_GetState then
        reaper.ShowMessageBox(
            "This script requires js_ReaScriptAPI (FindChildByID/GetClientRect/ScreenToClient/ClientToScreen/GetRect/GetForeground/GetParent, WindowMessage_Intercept/Peek/Release/Send, VKeys_GetState) and ReaImGui ImGui_PointConvertNative.",
            "Missing API",
            0
        )
        return false
    end

    State.ctx = reaper.ImGui_CreateContext("Brush Envelope Editor")

    local lock_closed_path = SCRIPT_DIR .. "Lock Closed.ttf"
    local lock_open_path = SCRIPT_DIR .. "Lock Open.ttf"
    State.font_lock_closed = reaper.ImGui_CreateFontFromFile(lock_closed_path)
    State.font_lock_open = reaper.ImGui_CreateFontFromFile(lock_open_path)
    if not State.font_lock_closed or not State.font_lock_open then
        reaper.ShowMessageBox(
            "Could not load lock icon fonts (glyph A):\n" .. lock_closed_path .. "\n" .. lock_open_path,
            "Envelope Brush Tool",
            0
        )
        if State.ctx and reaper.ImGui_DestroyContext then
            reaper.ImGui_DestroyContext(State.ctx)
            State.ctx = nil
        end
        return false
    end

    --- Fonts are Resource objects; without Attach they expire after a few idle timer ticks (before first HUD use).
    if reaper.ImGui_Attach then
        reaper.ImGui_Attach(State.ctx, State.font_lock_closed)
        reaper.ImGui_Attach(State.ctx, State.font_lock_open)
    end

    if not Core.get_arrange_hwnd() then
        reaper.ShowMessageBox("Could not locate REAPER arrange view window.", "Arrange View Not Found", 0)
        return false
    end
    Core.refresh_frame_arrange(State)
    if not D.setup_envelope_bounds() then
        reaper.ShowMessageBox("Could not read arrange view client bounds.", "Arrange Bounds Unavailable", 0)
        return false
    end

    if not Core.ensure_arrange_intercepts(State) then
        reaper.ShowMessageBox("Could not intercept arrange view input (wheel / mouse buttons) via js_ReaScriptAPI.", "Arrange Intercept Failed", 0)
        return false
    end

    DRAG_INPUT_DEPS = {
        seed_brush_width_at_client = D.seed_brush_width_at_client,
        capture_points_in_radius = D.capture_points_in_radius,
        sculpt_captured_points = D.sculpt_captured_points,
        refresh_captured_from_envelope = D.refresh_captured_from_envelope,
        sync_brush_point_selection = D.sync_brush_point_selection,
        get_distance = Core.get_distance,
    }

    ProjExt.load_into_state(State, CONFIG)
    ProjExt.after_load_init(State)

    return true
end

--- LMB-down envelope work for one sampled client position.
local function apply_envelope_drag_tick(mx, my)
    if State.brush_settings_mode or not State.target_envelope or mx == nil or my == nil then
        return
    end
    local deps_drag = DRAG_INPUT_DEPS
    if not State.is_dragging then
        Input.on_lmb_pressed(State, CONFIG, mx, my, deps_drag)
    elseif State.drag_mode == "sculpt" then
        Input.try_apply_sculpt_drag(State, CONFIG, mx, my, deps_drag)
    elseif State.drag_mode == "combined" then
        Input.try_combined_drag(State, CONFIG, mx, my, deps_drag)
    end
end

--- Runs at the start of a defer tick (after REAPER/ImGui yielded). Mouse is sampled again here.
local function run_pending_envelope_flush()
    if not State.envelope_flush_pending then
        return
    end
    State.envelope_flush_pending = false

    if State.brush_settings_mode or not State.target_envelope or not Core.is_lmb_down_js() then
        return
    end

    if reaper.PreventUIRefresh then
        reaper.PreventUIRefresh(1)
    end

    local mx, my = D.get_mouse_client_xy()
    if mx and my then
        if CONFIG.arrange.DEFER_ENVELOPE_SUPPRESS_CONTROL_IMGUI then
            State.suppress_imgui_control_this_frame = true
        end
        apply_envelope_drag_tick(mx, my)
    end

    if reaper.PreventUIRefresh then
        reaper.PreventUIRefresh(-1)
    end
    reaper.UpdateArrange()
end

local function on_script_close()
    if State._shutdown_complete then
        return
    end
    State._shutdown_complete = true

    pcall(Input.close_brush_settings, State)
    State.brush_ate_arrange_rmb = false
    pcall(Core.release_arrange_intercepts, State)

    if State.ctx then
        pcall(UI.pump_imgui_frame, State)
    end
    pcall(ProjExt.save_now, State, CONFIG)
    pcall(Input.end_session_from_script_close, State, {
        sort_envelope_points_for_autoitem = Ops.sort_envelope_points_for_autoitem,
    })
    if State.ctx and reaper.ImGui_DestroyContext then
        pcall(reaper.ImGui_DestroyContext, State.ctx)
        State.ctx = nil
    end
    _G[SINGLETON_GKEY] = nil
    set_toolbar_toggle_state(0)
end

local function main_loop()
    --- After synchronous `close()` from a newer run, defer may still fire once; do not reschedule.
    if not State.ctx then
        return
    end

    Core.refresh_frame_arrange(State)
    if not D.setup_envelope_bounds() then
        reaper.defer(main_loop)
        return
    end

    if ProjExt.tick_project_switch(State, CONFIG) then
        Input.clear_wheel_momentum(State)
        State.prepared_insert_envelope = nil
        State.seed_hover_cache = nil
        State.seed_hover_last_client = nil
    end

    local mouse_x, mouse_y = D.get_mouse_client_xy()
    if mouse_x == nil or mouse_y == nil then
        reaper.defer(main_loop)
        return
    end
    State.mouse_pos = { x = mouse_x, y = mouse_y }

    local lmb_down = Core.is_lmb_down_js()

    Envelope.detect_envelope(State, {
        is_envelope_lane_visible = Core.is_envelope_lane_visible,
        clear_target_envelope_state_only = D.clear_target_envelope_state_only,
        setup_envelope_bounds = D.setup_envelope_bounds,
        get_mouse_client_xy = D.get_mouse_client_xy,
        point_hits_envelope_curve = D.point_hits_envelope_curve,
    })

    if not lmb_down and not State.is_dragging and not State.brush_settings_mode and State.target_envelope and State.overlay_visible then
        D.warm_seed_cache_for_hover(mouse_x, mouse_y)
    end

    -- After SWS/bounds update: flush uses a stable target_envelope for the whole LMB-down stroke.
    run_pending_envelope_flush()

    -- Eat arrange LMB/MOVE only on envelope lane (SWS hover) or while finishing a brush drag off the lane.
    local eat_rmb = State.target_envelope and (State.sws_hover_detected or State.brush_settings_mode)
    Core.process_arrange_lmb_or_forward(State, State.overlay_visible or State.is_dragging, eat_rmb)

    -- Schedule envelope work for the *next* defer tick (see run_pending_envelope_flush): same-tick-as-ImGui was unreliable.
    Core.sync_arrange_mouse_eat_with_os(State, lmb_down, Core.is_rmb_down_js())
    if lmb_down and State.target_envelope and State.overlay_visible and not State.brush_settings_mode then
        State.envelope_flush_pending = true
    elseif not lmb_down and State.is_dragging then
        D.end_drag_operation()
    end

    Input.tick_rmb_brush_settings(State, Render.brush_hud_interactive(State), mouse_x, mouse_y)
    if State.brush_settings_mode and State.is_dragging then
        D.end_drag_operation()
    end

    if State.suppress_imgui_control_this_frame then
        State.suppress_imgui_control_this_frame = false
    end
    UI.pump_imgui_frame(State)

    local open = true

    Render.update_brush_hud_text_fade(State, CONFIG, lmb_down, Render.brush_hud_visible(State))

    local render_deps = {
        calc_inner_brush_radius = D.calc_inner_brush_radius,
        get_arrange_imgui_overlay_geometry = D.get_arrange_imgui_overlay_geometry,
        brush_center_client_xy = D.brush_center_client_xy,
        get_mouse_client_xy = D.get_mouse_client_xy,
        get_mouse_imgui_xy = D.get_mouse_imgui_xy,
        envelope_to_screen = D.envelope_to_screen,
        arrange_client_to_imgui = D.arrange_client_to_imgui,
        brush_drag_kind_display = D.brush_drag_kind_display,
        primary_modifier_short_name = D.primary_modifier_short_name,
        calculate_falloff = Core.calculate_falloff,
        clear_wheel_momentum = Input.clear_wheel_momentum,
    }
    Input.tick_brush_settings_lmb_dismiss(State, {
        get_mouse_imgui_xy = D.get_mouse_imgui_xy,
        is_lmb_down_js = Core.is_lmb_down_js,
    })

    Input.tick_wheel_momentum(State, CONFIG, Core.clamp)
    Input.handle_wheel_input(State, CONFIG, Core.clamp, Core)
    Input.handle_keyboard_input(State, {
        request_script_close = function()
            State.script_close_requested = true
        end,
    })

    if State.script_close_requested then
        Input.close_brush_settings(State)
    end

    if Core.is_reaper_foreground() and not State._shutdown_complete then
        Render.render_brush_hud(State, CONFIG, render_deps)
        Render.render_brush_hud_panel(State, CONFIG, render_deps)
    end

    if State.script_close_requested then
        State.script_close_requested = false
        open = false
    end

    if State.is_dragging and State.sculpt_sort_pending and State.target_envelope then
        Core.tick_throttled_envelope_sort_if_due(State, CONFIG, Ops)
    end

    ProjExt.save_if_changed(State, CONFIG)

    if open then
        reaper.defer(main_loop)
    else
        on_script_close()
        return
    end
end

if not init() then
    Core.release_arrange_intercepts(State)
    if State.ctx and reaper.ImGui_DestroyContext then
        reaper.ImGui_DestroyContext(State.ctx)
        State.ctx = nil
    end
    set_toolbar_toggle_state(0)
    return
end

set_toolbar_toggle_state(1)
_G[SINGLETON_GKEY] = { close = on_script_close }

if reaper.atexit then
    reaper.atexit(on_script_close)
end

reaper.defer(main_loop)
