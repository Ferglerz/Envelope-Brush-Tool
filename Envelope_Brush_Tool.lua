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

--- Suppress the automatic "ReaScript: Run" undo point on script launch (must defer before project edits).
reaper.defer(function() end)

local Core = dofile(SCRIPT_DIR .. "modules/core.lua")
local Envelope = dofile(SCRIPT_DIR .. "modules/envelope/envelope.lua")
local Ops = dofile(SCRIPT_DIR .. "modules/ops.lua")
local Render = dofile(SCRIPT_DIR .. "modules/render/render.lua")
local Input = dofile(SCRIPT_DIR .. "modules/input.lua")
local UI = dofile(SCRIPT_DIR .. "modules/ui.lua")
local Brush = dofile(SCRIPT_DIR .. "modules/brush_session.lua")
local ProjExt = dofile(SCRIPT_DIR .. "modules/project_ext.lua")
local ActionShortcuts = dofile(SCRIPT_DIR .. "modules/action_shortcuts.lua")
local Util = dofile(SCRIPT_DIR .. "modules/util.lua")

local CONFIG = Core.CONFIG
local State = Core.new_state(CONFIG)

local DRAG_DEPS
local RENDER_DEPS

local function init()
    if not reaper.ImGui_CreateContext then
        reaper.ShowMessageBox("This script requires ReaImGui.", "Missing ReaImGui", 0)
        return false
    end
    if not reaper.BR_GetMouseCursorContext then
        reaper.ShowMessageBox("This script requires the SWS extension.", "Missing SWS Extension", 0)
        return false
    end
    if not reaper.CountEnvelopePointsEx or not reaper.GetEnvelopePointEx or not reaper.SetEnvelopePointEx or not reaper.InsertEnvelopePointEx or not reaper.Envelope_SortPointsEx then
        reaper.ShowMessageBox("This script requires REAPER v5.78+ (Envelope*Ex APIs for point access and automation item support).", "Old REAPER", 0)
        return false
    end
    if not reaper.Undo_OnStateChangeEx2 then
        reaper.ShowMessageBox("This script requires REAPER Undo_OnStateChangeEx2 for named brush undo points.", "Old REAPER", 0)
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

    if reaper.ImGui_Attach then
        reaper.ImGui_Attach(State.ctx, State.font_lock_closed)
        reaper.ImGui_Attach(State.ctx, State.font_lock_open)
    end

    if not Core.get_arrange_hwnd() then
        reaper.ShowMessageBox("Could not locate REAPER arrange view window.", "Arrange View Not Found", 0)
        return false
    end
    Core.refresh_frame_arrange(State)
    if not Envelope.setup_envelope_bounds(State, CONFIG, Core.get_arrange_hwnd) then
        reaper.ShowMessageBox("Could not read arrange view client bounds.", "Arrange Bounds Unavailable", 0)
        return false
    end

    if not Core.ensure_arrange_intercepts(State) then
        reaper.ShowMessageBox("Could not intercept arrange view input (wheel / mouse buttons) via js_ReaScriptAPI.", "Arrange Intercept Failed", 0)
        return false
    end

    DRAG_DEPS = Brush.drag_deps(State, CONFIG, Core, Envelope, Ops)
    RENDER_DEPS = Brush.render_deps(State, CONFIG, Core, Input)

    ProjExt.load_into_state(State, CONFIG)
    ProjExt.after_load_init(State)

    ActionShortcuts.refresh_main_passthrough_shortcuts(State)

    return true
end

local function apply_envelope_drag_tick(mx, my)
    if State.brush_settings_mode or not Core.brush_lmb_may_start_stroke(State) or mx == nil or my == nil then
        return
    end
    if not State.is_dragging then
        Input.on_lmb_pressed(State, CONFIG, mx, my, DRAG_DEPS)
    elseif State.drag_mode == "sculpt" then
        Input.try_apply_sculpt_drag(State, CONFIG, mx, my, DRAG_DEPS)
    elseif State.drag_mode == "combined" then
        Input.try_combined_drag(State, CONFIG, mx, my, DRAG_DEPS)
    end
end

local function run_pending_envelope_flush()
    if not State.envelope_flush_pending then
        return
    end
    State.envelope_flush_pending = false

    if State.brush_settings_mode or not Core.brush_lmb_may_start_stroke(State) or not Core.is_lmb_down_js() then
        return
    end

    if reaper.PreventUIRefresh then
        reaper.PreventUIRefresh(1)
    end

    local mx, my = Brush.get_mouse_client_xy(State, Core)
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
        config = CONFIG,
        sort_envelope_points_for_autoitem = Ops.sort_envelope_points_for_autoitem,
        cleanup_redundant_points_after_drag = function()
            Brush.run_smooth_angle_cleanup_on_lmb_up(State, CONFIG, Core, Envelope, Ops, Input)
        end,
    })
    if State.ctx and reaper.ImGui_DestroyContext then
        pcall(reaper.ImGui_DestroyContext, State.ctx)
        State.ctx = nil
    end
    _G[SINGLETON_GKEY] = nil
    set_toolbar_toggle_state(0)
end

local function main_loop()
    if not State.ctx then
        return
    end

    Core.refresh_frame_arrange(State)
    if not Envelope.setup_envelope_bounds(State, CONFIG, Core.get_arrange_hwnd) then
        reaper.defer(main_loop)
        return
    end

    if ProjExt.tick_project_switch(State, CONFIG) then
        Input.clear_wheel_momentum(State)
        State.seed_hover_cache = nil
        State.seed_hover_last_client = nil
        State.envelope_ai_lane_cache = nil
    end

    State._brush_center_time = Util.mouse_cursor_time()

    local mouse_x, mouse_y = Brush.get_mouse_client_xy(State, Core)
    if mouse_x == nil or mouse_y == nil then
        reaper.defer(main_loop)
        return
    end
    State.mouse_pos = { x = mouse_x, y = mouse_y }

    local lmb_down = Core.is_lmb_down_js()
    local lmb_edge_down = lmb_down and not State._lmb_was_down_prev
    State._lmb_was_down_prev = lmb_down

    Envelope.detect_envelope(State, Core, CONFIG)

    if not lmb_down and not State.is_dragging and not State.brush_settings_mode and State.envelope_lane_hover then
        Brush.warm_seed_cache_for_hover(State, CONFIG, Core, Envelope, Ops, mouse_x, mouse_y)
    end

    run_pending_envelope_flush()

    if lmb_edge_down and State.envelope_lane_hover and State.target_envelope and not State.brush_settings_mode then
        State.brush_lmb_press_armed = true
    elseif not lmb_down then
        State.brush_lmb_press_armed = false
    end

    local brush_active = Core.brush_tool_active(State)
    local stroke_lmb = Core.brush_lmb_may_start_stroke(State)
    local eat_rmb = State.target_envelope and (brush_active or State.brush_settings_mode)
    Core.process_arrange_lmb_or_forward(State, stroke_lmb, eat_rmb)

    Core.sync_arrange_mouse_eat_with_os(State, lmb_down, Core.is_rmb_down_js())
    if lmb_down and stroke_lmb and not State.brush_settings_mode then
        State.envelope_flush_pending = true
    elseif not lmb_down and State.is_dragging then
        Brush.end_drag_operation(State, CONFIG, Core, Envelope, Ops, Input)
    elseif not lmb_down and (State.envelope_stroke_dirty or State.pending_undo_label) then
        Input.apply_envelope_undo_finalize(State, {
            config = CONFIG,
            sort_envelope_points_for_autoitem = Ops.sort_envelope_points_for_autoitem,
        })
    end

    Input.tick_rmb_brush_settings(State, Render.brush_hud_interactive(State), mouse_x, mouse_y)
    if State.brush_settings_mode and State.is_dragging then
        Brush.end_drag_operation(State, CONFIG, Core, Envelope, Ops, Input)
    end

    if State.suppress_imgui_control_this_frame then
        State.suppress_imgui_control_this_frame = false
    end

    local hud_rings = Render.brush_hud_visible(State)
    if not hud_rings then
        UI.pump_imgui_frame(State)
    end

    local open = true

    local hud_show = Render.brush_hud_visible(State)
    Render.update_brush_hud_text_fade(State, CONFIG, lmb_down, hud_show or brush_active)

    Input.tick_brush_settings_lmb_dismiss(State, {
        get_mouse_imgui_xy = function() return Core.get_mouse_imgui_xy(State.ctx) end,
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
        Render.render_brush_hud(State, CONFIG, RENDER_DEPS)
        Render.render_brush_hud_panel(State, CONFIG, RENDER_DEPS)
    end

    if State.script_close_requested then
        State.script_close_requested = false
        open = false
    end

    if State.is_dragging and State.brush_stroke_committed and State.sculpt_sort_pending and State.target_envelope then
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
