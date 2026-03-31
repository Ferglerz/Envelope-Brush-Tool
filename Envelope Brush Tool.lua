-- REAPER Brush Envelope Editor
-- Sculpt and create envelope points with brush-like controls.

local SCRIPT_PATH = debug.getinfo(1, "S").source:match("^@(.+)$") or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*[\\/])") or ""

local Core = dofile(SCRIPT_DIR .. "modules/BrushCore.lua")
local Envelope = dofile(SCRIPT_DIR .. "modules/BrushEnvelope.lua")
local Ops = dofile(SCRIPT_DIR .. "modules/BrushOps.lua")
local Render = dofile(SCRIPT_DIR .. "modules/BrushRender.lua")
local Input = dofile(SCRIPT_DIR .. "modules/BrushInput.lua")
local UI = dofile(SCRIPT_DIR .. "modules/BrushUI.lua")
local Deps = dofile(SCRIPT_DIR .. "modules/BrushDeps.lua")

local CONFIG = Core.CONFIG
local State = Core.new_state(CONFIG)
local D = Deps.new(State, CONFIG, {
    core = Core,
    envelope = Envelope,
    ops = Ops,
    render = Render,
    input = Input,
})

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
        or not reaper.JS_Window_GetRect or not reaper.ImGui_PointConvertNative
        or not reaper.JS_WindowMessage_Intercept or not reaper.JS_WindowMessage_Peek or not reaper.JS_WindowMessage_Release
        or not reaper.JS_WindowMessage_Send then
        reaper.ShowMessageBox(
            "This script requires js_ReaScriptAPI (FindChildByID/GetClientRect/ScreenToClient/GetRect, WindowMessage_Intercept/Peek/Release/Send) and ReaImGui ImGui_PointConvertNative.",
            "Missing API",
            0
        )
        return false
    end

    State.ctx = reaper.ImGui_CreateContext("Brush Envelope Editor")

    if not Core.get_arrange_hwnd() then
        reaper.ShowMessageBox("Could not locate REAPER arrange view window.", "Arrange View Not Found", 0)
        return false
    end
    if not D.setup_envelope_bounds() then
        reaper.ShowMessageBox("Could not read arrange view client bounds.", "Arrange Bounds Unavailable", 0)
        return false
    end

    if not Core.ensure_arrange_intercepts(State) then
        reaper.ShowMessageBox("Could not intercept arrange view input (wheel / mouse buttons) via js_ReaScriptAPI.", "Arrange Intercept Failed", 0)
        return false
    end

    return true
end

--- Runs at the start of a defer tick (after REAPER/ImGui yielded). Mouse is sampled again here.
local function run_pending_envelope_flush()
    if not State.envelope_flush_pending then
        return
    end
    State.envelope_flush_pending = false

    if not State.target_envelope or not Core.is_lmb_down_js() then
        return
    end

    if reaper.PreventUIRefresh then
        reaper.PreventUIRefresh(1)
    end

    local mx, my = D.get_mouse_client_xy()
    if mx and my then
        if CONFIG.DEFER_ENVELOPE_SUPPRESS_CONTROL_IMGUI then
            State.suppress_imgui_control_this_frame = true
        end
        if not State.is_dragging then
            Input.on_lmb_pressed(State, CONFIG, mx, my, {
                seed_brush_width_at_client = D.seed_brush_width_at_client,
                capture_points_in_radius = D.capture_points_in_radius,
            })
        elseif State.drag_mode == "sculpt" then
            Input.try_apply_sculpt_drag(State, CONFIG, mx, my, {
                capture_points_in_radius = D.capture_points_in_radius,
                sculpt_captured_points = D.sculpt_captured_points,
                refresh_captured_from_envelope = D.refresh_captured_from_envelope,
            })
        elseif State.drag_mode == "combined" then
            Input.try_combined_drag(State, CONFIG, mx, my, {
                capture_points_in_radius = D.capture_points_in_radius,
                sculpt_captured_points = D.sculpt_captured_points,
                refresh_captured_from_envelope = D.refresh_captured_from_envelope,
            })
        end
    end

    if reaper.PreventUIRefresh then
        reaper.PreventUIRefresh(-1)
    end
    reaper.UpdateArrange()
end

local function on_script_close()
    Core.release_arrange_intercepts(State)
    if State.undo_active then
        if State.sculpt_sort_pending and State.target_envelope then
            local ai = State.envelope_autoitem_idx or -1
            if ai >= 0 and reaper.Envelope_SortPointsEx then
                reaper.Envelope_SortPointsEx(State.target_envelope, ai)
            else
                reaper.Envelope_SortPoints(State.target_envelope)
            end
        end
        reaper.Undo_EndBlock(State.undo_operation_name, -1)
    end
end

local function main_loop()
    Core.refresh_frame_arrange(State)
    if not D.setup_envelope_bounds() then
        reaper.defer(main_loop)
        return
    end

    local mouse_x, mouse_y = D.get_mouse_client_xy()
    if mouse_x == nil or mouse_y == nil then
        reaper.defer(main_loop)
        return
    end
    State.mouse_pos = { x = mouse_x, y = mouse_y }

    Envelope.detect_envelope(State, {
        is_envelope_lane_visible = Core.is_envelope_lane_visible,
        clear_target_envelope_state_only = D.clear_target_envelope_state_only,
        setup_envelope_bounds = D.setup_envelope_bounds,
        get_mouse_client_xy = D.get_mouse_client_xy,
        point_hits_envelope_curve = D.point_hits_envelope_curve,
    })

    -- After SWS/bounds update: flush uses a stable target_envelope for the whole LMB-down stroke.
    if not State.debug_disable_js_eat then
        run_pending_envelope_flush()
    end

    -- Eat arrange LMB/MOVE only on envelope lane (SWS hover) or while finishing a brush drag off the lane.
    if not State.debug_disable_js_eat then
        Core.process_arrange_lmb_or_forward(State, State.overlay_visible or State.is_dragging)
    end

    -- Schedule envelope work for the *next* defer tick (see run_pending_envelope_flush): same-tick-as-ImGui was unreliable.
    local lmb_down = Core.is_lmb_down_js()
    if not State.debug_disable_js_eat then
        Core.sync_arrange_mouse_eat_with_os(State, lmb_down)
        if lmb_down and State.target_envelope then
            State.envelope_flush_pending = true
        elseif not lmb_down and State.is_dragging then
            D.end_drag_operation()
        end
    else
        -- No deferred flush / intercepts: run insert + sculpt same frame (debug “no eat” mode).
        if lmb_down and State.target_envelope then
            if reaper.PreventUIRefresh then
                reaper.PreventUIRefresh(1)
            end
            if not State.is_dragging then
                Input.on_lmb_pressed(State, CONFIG, mouse_x, mouse_y, {
                    seed_brush_width_at_client = D.seed_brush_width_at_client,
                    capture_points_in_radius = D.capture_points_in_radius,
                })
            elseif State.drag_mode == "sculpt" then
                Input.try_apply_sculpt_drag(State, CONFIG, mouse_x, mouse_y, {
                    capture_points_in_radius = D.capture_points_in_radius,
                    sculpt_captured_points = D.sculpt_captured_points,
                    refresh_captured_from_envelope = D.refresh_captured_from_envelope,
                })
            elseif State.drag_mode == "combined" then
                Input.try_combined_drag(State, CONFIG, mouse_x, mouse_y, {
                    capture_points_in_radius = D.capture_points_in_radius,
                    sculpt_captured_points = D.sculpt_captured_points,
                    refresh_captured_from_envelope = D.refresh_captured_from_envelope,
                })
            end
            if reaper.PreventUIRefresh then
                reaper.PreventUIRefresh(-1)
            end
            reaper.UpdateArrange()
        elseif not lmb_down and State.is_dragging then
            D.end_drag_operation()
        end
    end

    local open
    if State.suppress_imgui_control_this_frame then
        State.suppress_imgui_control_this_frame = false
        open = true
    else
        open = UI.draw_control_window(State, CONFIG, {
            get_mouse_client_xy = D.get_mouse_client_xy,
            brush_hud_interactive = D.brush_hud_interactive,
            debug_synthetic_insert_from_last_item = D.debug_synthetic_insert_from_last_item,
        })
    end

    if State.debug_show_insert_panel then
        UI.draw_insert_debug_panel(State, CONFIG)
    end

    if State.debug_disable_js_eat ~= State._debug_js_eat_prev then
        State._debug_js_eat_prev = State.debug_disable_js_eat
        if State.debug_disable_js_eat then
            State.envelope_flush_pending = false
            Core.release_arrange_intercepts(State)
        else
            Core.ensure_arrange_intercepts(State)
        end
    end

    Render.render_brush_hud(State, CONFIG, {
        calc_inner_brush_radius = D.calc_inner_brush_radius,
        get_arrange_imgui_overlay_geometry = D.get_arrange_imgui_overlay_geometry,
        get_mouse_imgui_xy = D.get_mouse_imgui_xy,
    })

    Input.handle_wheel_input(State, CONFIG, Core.clamp, Core)
    Input.handle_keyboard_input(State, {
        clear_envelope_target = D.clear_envelope_target,
        falloff_types = CONFIG.FALLOFF_TYPES,
    })

    if open then
        reaper.defer(main_loop)
    else
        on_script_close()
    end
end

if init() then
    reaper.defer(main_loop)
end
