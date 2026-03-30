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

    if not Core.ensure_wheel_intercept(State) then
        reaper.ShowMessageBox("Could not intercept mouse wheel on the arrange view (js_ReaScriptAPI).", "Wheel Intercept Failed", 0)
        return false
    end

    return true
end

local function on_script_close()
    Core.release_wheel_intercept(State)
    if State.undo_active then
        if State.sculpt_sort_pending and State.target_envelope then
            reaper.Envelope_SortPoints(State.target_envelope)
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

    local open = UI.draw_control_window(State, CONFIG, {
        create_points_in_brush_area = D.create_points_in_brush_area,
        get_mouse_client_xy = D.get_mouse_client_xy,
        brush_hud_interactive = D.brush_hud_interactive,
    })

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

    local mx, my = D.get_mouse_client_xy()
    if mx == nil or my == nil then
        if open then
            reaper.defer(main_loop)
        else
            on_script_close()
        end
        return
    end
    State.mouse_pos = { x = mx, y = my }

    local lmb_down = Core.is_lmb_down_js()
    if lmb_down and State.target_envelope then
        if not State.is_dragging then
            Input.on_lmb_pressed(State, CONFIG, mx, my, {
                create_points_in_brush_area = D.create_points_in_brush_area,
                capture_points_in_radius = D.capture_points_in_radius,
            })
        elseif State.drag_mode == "combined" then
            Input.try_combined_drag(State, CONFIG, mx, my, {
                get_distance = Core.get_distance,
                create_points_in_brush_area = D.create_points_in_brush_area,
                capture_points_in_radius = D.capture_points_in_radius,
                sculpt_captured_points = D.sculpt_captured_points,
                refresh_captured_from_envelope = D.refresh_captured_from_envelope,
            })
        end
    elseif not lmb_down and State.is_dragging then
        D.end_drag_operation()
    end

    if open then
        reaper.defer(main_loop)
    else
        on_script_close()
    end
end

if init() then
    reaper.defer(main_loop)
end
