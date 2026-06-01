-- REAPER envelope helpers: evaluate, insert times, SWS BR_Env*, target state clear.

local M = {}

local _env_dir = (((debug.getinfo(1, "S").source or ""):match("^@(.+)$")) or ""):match("^(.*[\\/])") or ""
local Path = dofile(_env_dir .. "../path.lua")
local ValueScaling = Path.load("value_scaling.lua")

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
    if val ~= nil then return ValueScaling.api_value_to_linear(envelope, val) end
    return nil
end

--- Insert path: device SRATE + BSIZE (as samplesRequested), matching common Insert-at-mouse scripts. Caps BSIZE to avoid huge Evaluate requests.
local ENVELOPE_INSERT_EVAL_MAX_SAMPLES = 8192

function M.envelope_evaluate_device_params()
    local sr = 44100
    local n = 512
    if reaper.GetAudioDeviceInfo then
        local _, srate_str = reaper.GetAudioDeviceInfo("SRATE")
        if type(srate_str) == "string" then
            local x = tonumber(srate_str)
            if x and x > 0 and x == x then
                sr = x
            end
        end
        local _, bsize_str = reaper.GetAudioDeviceInfo("BSIZE")
        if type(bsize_str) == "string" then
            local x = tonumber(bsize_str)
            if x and x >= 1 and x == x then
                n = math.floor(x)
            end
        end
    end
    if n < 1 then
        n = 1
    end
    if n > ENVELOPE_INSERT_EVAL_MAX_SAMPLES then
        n = ENVELOPE_INSERT_EVAL_MAX_SAMPLES
    end
    return sr, n
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

--- Cached for script lifetime per envelope pointer (invalidated on target clear / project switch).
--- While the brush tool is open, automation items are not created on a lane without re-running the script context.
function M.envelope_has_automation_items(envelope, state)
    if not envelope or not state then
        return false
    end
    if not reaper.CountAutomationItems then
        return false
    end
    local cache = state.envelope_ai_lane_cache
    if cache == nil then
        cache = {}
        state.envelope_ai_lane_cache = cache
    end
    local known = cache[envelope]
    if known ~= nil then
        return known
    end
    local has = reaper.CountAutomationItems(envelope) > 0
    cache[envelope] = has
    return has
end

--- Returns insert_time, evaluate_time for Envelope_Evaluate / InsertEnvelopePoint*.
--- Track + automation item: project timeline for both. Take envelope (parent lane only): evaluate at project_time - item position; insert time multiplies by take playrate (ReaScript insert pattern).
function M.envelope_insert_evaluate_times(envelope, project_time, autoitem_idx)
    if not envelope or project_time == nil then
        return nil, nil
    end
    if type(autoitem_idx) == "number" and autoitem_idx >= 0 then
        return project_time, project_time
    end
    if M.envelope_is_take_envelope(envelope) then
        local proj = reaper.EnumProjects and reaper.EnumProjects(-1) or 0
        local take = reaper.GetEnvelopeInfo_Value(envelope, "P_TAKE")
        if take and take ~= 0 and reaper.ValidatePtr2 and reaper.ValidatePtr2(proj, take, "MediaItem_Take*") then
            local item = reaper.GetMediaItemTake_Item(take)
            if item and reaper.ValidatePtr2 and reaper.ValidatePtr2(proj, item, "MediaItem*") then
                local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
                if type(pos) == "number" and type(playrate) == "number" and playrate ~= 0 and playrate == playrate then
                    local eval_t = project_time - pos
                    local ins_t = eval_t * playrate
                    return ins_t, eval_t
                end
            end
        end
    end
    return project_time, project_time
end

--- Value for new points from REAPER evaluator (linear domain, shape/scaling aware).
--- Returns linear_value_for_insert, insert_time, evaluate_time (all nil on failure).
function M.envelope_value_for_insert(envelope, project_time, autoitem_idx)
    local insert_t, eval_t = M.envelope_insert_evaluate_times(envelope, project_time, autoitem_idx)
    if insert_t == nil or eval_t == nil then
        return nil, nil, nil
    end
    local value_linear = M.envelope_value_at_time(envelope, eval_t)
    if value_linear == nil or type(value_linear) ~= "number" or value_linear ~= value_linear then
        return nil, insert_t, eval_t
    end
    return value_linear, insert_t, eval_t
end

--- Default point shape from envelope state chunk (DEFSHAPE <n> ...); fallback 0. Caches per `state` + envelope pointer.
function M.get_envelope_default_point_shape(envelope, state)
    if not envelope or not reaper.GetEnvelopeStateChunk then
        return 0
    end
    if state and state.cached_defshape_envelope == envelope then
        return state.cached_defshape_value
    end
    local ok_chunk, chunk = reaper.GetEnvelopeStateChunk(envelope, "", false)
    if not ok_chunk or type(chunk) ~= "string" then
        return 0
    end
    local digits = chunk:match("DEFSHAPE%s+(-?%d+)")
    local sh = digits and tonumber(digits)
    if sh == nil then
        sh = 0
    end
    if state then
        state.cached_defshape_envelope = envelope
        state.cached_defshape_value = sh
    end
    return sh
end

--- Arrange-client Y range [top, bottom) for this envelope's drawable value area.
--- Single-path rule: use I_TCPY_USED + I_TCPH_USED for all envelopes.
function M.envelope_value_axis_client_y(state, envelope)
    if not envelope or not reaper.GetEnvelopeInfo_Value or not reaper.GetMediaTrackInfo_Value then
        return nil, nil
    end
    local tr = reaper.GetEnvelopeInfo_Value(envelope, "P_TRACK")
    if not tr or tr == 0 then
        return nil, nil
    end
    local track_y = reaper.GetMediaTrackInfo_Value(tr, "I_TCPY")
    if type(track_y) ~= "number" then
        return nil, nil
    end
    local env_y = reaper.GetEnvelopeInfo_Value(envelope, "I_TCPY_USED")
    local env_h = reaper.GetEnvelopeInfo_Value(envelope, "I_TCPH_USED")
    if type(env_y) ~= "number" or type(env_h) ~= "number" or env_h < 1 then
        return nil, nil
    end
    local top = track_y + env_y
    return top, top + env_h
end

--- Top/bottom for value↔pixel mapping: strict lane mapping only (no fallback).
function M.envelope_value_axis_screen_for_mapping(state, envelope)
    local vt, vb = M.envelope_value_axis_client_y(state, envelope)
    if vt == nil or vb == nil or vb <= vt then
        return nil, nil
    end
    return vt, vb
end

--- Timeline time at arrange client X (sampled via GetSet_ArrangeView2 in native screen space).
local function arrange_time_at_client_x(arrange_hwnd, client_x)
    if not arrange_hwnd or type(client_x) ~= "number" then
        return nil
    end
    if not reaper.GetSet_ArrangeView2 then
        return nil
    end
    -- GetSet_ArrangeView2 uses arrange-view horizontal pixel space; feed arrange client X directly.
    local x0 = math.floor(client_x)
    local t0, t1 = reaper.GetSet_ArrangeView2(0, false, x0, x0 + 1)
    if type(t0) ~= "number" or t0 ~= t0 then
        return nil
    end
    if type(t1) == "number" and t1 == t1 then
        return 0.5 * (t0 + t1)
    end
    return t0
end

--- Arrange client X span where timeline time actually advances.
--- Returns timeline_left, timeline_right (inclusive client X) or nil,nil.
function M.arrange_timeline_client_bounds_x(state, arrange_hwnd, client_left, client_right)
    if not state or not arrange_hwnd then
        return nil, nil
    end
    if type(client_left) ~= "number" or type(client_right) ~= "number" then
        return nil, nil
    end
    local x0 = math.floor(math.min(client_left, client_right))
    local x1 = math.floor(math.max(client_left, client_right))
    if x1 <= x0 then
        return x0, x1
    end

    local arrange_start = state.frame_arrange_start
    local arrange_end = state.frame_arrange_end
    if type(arrange_start) ~= "number" or type(arrange_end) ~= "number" or arrange_end <= arrange_start then
        return nil, nil
    end

    local left_time = arrange_time_at_client_x(arrange_hwnd, x0)
    if left_time == nil then
        return nil, nil
    end

    local right_time = arrange_time_at_client_x(arrange_hwnd, x1)
    if right_time == nil then
        return nil, nil
    end
    local span = arrange_end - arrange_start
    local start_threshold = arrange_start + math.max(1e-9, span * 1e-6)
    local end_threshold = arrange_end - math.max(1e-9, span * 1e-6)

    local timeline_left = x0
    if left_time <= start_threshold then
        if right_time <= start_threshold then
            return nil, nil
        end
        local lo, hi = x0, x1
        while (hi - lo) > 1 do
            local mid = math.floor((lo + hi) * 0.5)
            local tm = arrange_time_at_client_x(arrange_hwnd, mid)
            if tm == nil then
                return nil, nil
            end
            if tm > start_threshold then
                hi = mid
            else
                lo = mid
            end
        end
        timeline_left = hi
    end

    local timeline_right = x1
    if right_time >= end_threshold then
        if left_time >= end_threshold then
            return nil, nil
        end
        local lo, hi = x0, x1
        while (hi - lo) > 1 do
            local mid = math.floor((lo + hi) * 0.5)
            local tm = arrange_time_at_client_x(arrange_hwnd, mid)
            if tm == nil then
                return nil, nil
            end
            if tm >= end_threshold then
                hi = mid
            else
                lo = mid
            end
        end
        timeline_right = lo
    end

    if timeline_right <= timeline_left then
        return nil, nil
    end
    return timeline_left, timeline_right
end

--- Set envelope_bounds.left/right from arrange-time span, not TCP/client width.
--- Returns true on success; leaves bounds unchanged on failure.
function M.apply_timeline_x_to_envelope_bounds(state, arrange_hwnd, client_left_fallback, client_right_bound)
    local b = state and state.envelope_bounds
    if not b then return false end
    local tl, tr = M.arrange_timeline_client_bounds_x(state, arrange_hwnd, client_left_fallback, client_right_bound)
    if type(tl) == "number" and type(tr) == "number" and tr > tl then
        b.left = tl
        b.right = tr
        return true
    end
    return false
end

--- Brush center for radial screen capture and HUD rings (ScreenToClient + lane Y).
function M.brush_center_client_xy(state, envelope, mouse_x, mouse_y)
    if type(mouse_x) ~= "number" then
        return nil, M.clamp_client_y_to_value_axis(state, envelope, mouse_y)
    end
    return mouse_x, M.clamp_client_y_to_value_axis(state, envelope, mouse_y)
end

--- Clamp arrange-client Y into the envelope value lane so ruler / dead space above the lane do not skew value mapping.
function M.clamp_client_y_to_value_axis(state, envelope, y)
    if type(y) ~= "number" then
        return y
    end
    local v_top, v_bottom = M.envelope_value_axis_screen_for_mapping(state, envelope)
    if v_top == nil or v_bottom == nil or v_bottom <= v_top then
        return y
    end
    if y < v_top then
        return v_top
    end
    if y > v_bottom then
        return v_bottom
    end
    return y
end

--- Raw min/max for envelope scaling helpers + GetEnvelopePoint (REAPER: point APIs use one raw storage space).
--- SWS BR_EnvGetProperties returns LaneMinValue/LaneMaxValue: the raw range that spans the drawable lane for the
--- current volenvrange / trim. That range must pair with I_TCP*_USED pixel height — not padded I_TCPH nor fixed 0..16.
function M.get_envelope_properties(state, envelope)
    if not envelope then return nil, nil, nil, nil end

    if state.cached_envelope_properties.envelope == envelope then
        local c = state.cached_envelope_properties
        return c.min_val, c.max_val, c.center_val, c.scaling_mode
    end

    local br_env = reaper.BR_EnvAlloc(envelope, M.envelope_is_take_envelope(envelope))
    if not br_env then return nil, nil, nil, nil end
    -- Return order per SWS BR_ReaScript.cpp: ... centerValue, type, faderScaling, AIoptions
    local _, _, _, _, _, _, min_val, max_val, center_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)
    local scaling_mode = reaper.GetEnvelopeScalingMode(envelope)
    if min_val == nil or max_val == nil or center_val == nil or scaling_mode == nil then
        return nil, nil, nil, nil
    end

    state.cached_envelope_properties.envelope = envelope
    state.cached_envelope_properties.min_val = min_val
    state.cached_envelope_properties.max_val = max_val
    state.cached_envelope_properties.center_val = center_val
    state.cached_envelope_properties.scaling_mode = scaling_mode

    return min_val, max_val, center_val, scaling_mode
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

local function non_empty_string(s, fallback)
    s = (tostring(s or ""):match("^%s*(.-)%s*$")) or ""
    if s == "" then
        return fallback
    end
    return s
end

--- Track name for undo labels (master → "Master", else P_NAME or "Track N").
function M.track_display_name_for_envelope(envelope)
    if not envelope or not reaper.GetEnvelopeInfo_Value then
        return "Unknown track"
    end
    local tr = reaper.GetEnvelopeInfo_Value(envelope, "P_TRACK")
    if not tr then
        return "Unknown track"
    end
    local master = reaper.GetMasterTrack(0)
    if master and tr == master then
        return "Master"
    end
    if reaper.GetTrackName then
        local ok, name = reaper.GetTrackName(tr)
        if ok then
            name = non_empty_string(name, nil)
            if name then
                return name
            end
        end
    end
    local num = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
    if type(num) == "number" and num > 0 then
        return string.format("Track %d", math.floor(num))
    end
    return "Track"
end

--- Envelope lane label from GetEnvelopeName (Volume, Pan, FX param, …).
function M.envelope_lane_display_name(envelope)
    if not envelope or not reaper.GetEnvelopeName then
        return "Envelope"
    end
    local ok, name = reaper.GetEnvelopeName(envelope)
    if ok then
        name = non_empty_string(name, nil)
        if name then
            return name
        end
    end
    return "Envelope"
end

--- When ai_idx >= 0, suffix for automation-item lane (1-based index).
function M.automation_item_lane_suffix(_envelope, autoitem_idx)
    if type(autoitem_idx) ~= "number" or autoitem_idx < 0 then
        return nil
    end
    return string.format("Automation item %d", autoitem_idx + 1)
end

--- "Track / Lane" or "Track / Lane / Automation item N" for Undo_EndBlock descriptions.
function M.brush_target_location_label(_state, envelope, autoitem_idx)
    local track = M.track_display_name_for_envelope(envelope)
    local lane = M.envelope_lane_display_name(envelope)
    local ai = M.automation_item_lane_suffix(envelope, autoitem_idx)
    if ai then
        return string.format("%s / %s / %s", track, lane, ai)
    end
    return string.format("%s / %s", track, lane)
end

function M.clear_target_envelope_state_only(state)
    state.target_envelope = nil
    state.envelope_autoitem_idx = -1
    state.envelope_lane_hover = false
    state.envelope_curve_hover = false
    state.brush_stroke_committed = false
    state.brush_lmb_press_armed = false
    state.envelope_ai_lane_cache = nil
    state.cached_envelope_properties.envelope = nil
    state.cached_defshape_envelope = nil
    state.envelope_flush_pending = false
    state.suppress_imgui_control_this_frame = false
    state.last_envelope_sort_os = nil
    state.envelope_points_dirty_sort = false
end

return M
