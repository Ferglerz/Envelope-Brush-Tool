-- REAPER envelope helpers: evaluate, insert times, SWS BR_Env*, target state clear.

local M = {}

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

--- Value for new points: Envelope_Evaluate at evaluate_time with device SRATE/BSIZE. Returns value, insert_time, evaluate_time (all nil on failure).
function M.envelope_value_for_insert(envelope, project_time, autoitem_idx)
    local insert_t, eval_t = M.envelope_insert_evaluate_times(envelope, project_time, autoitem_idx)
    if insert_t == nil or eval_t == nil then
        return nil, nil, nil
    end
    local sr, ns = M.envelope_evaluate_device_params()
    local _, val = reaper.Envelope_Evaluate(envelope, eval_t, sr, ns)
    if val == nil then
        return nil, insert_t, eval_t
    end
    return val, insert_t, eval_t
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

--- Arrange-client Y range [top, bottom) for this envelope's value lane (same space as JS arrange HWND + brush mouse map).
--- Track I_TCPY is relative to the top of the arrange view; envelope offsets are relative to that track.
--- Prefer I_TCPY_USED / I_TCPH_USED (drawable value area, no padding). Full I_TCPH includes padding; mapping 0..16
--- raw across padded height makes the visible curve occupy a thin band of normalized Y — e.g. "top" of the drawn
--- lane maps to a very low raw (-100+ dB on volume) instead of the lane trim max.
function M.envelope_value_axis_client_y(envelope)
    if not envelope or not reaper.GetEnvelopeInfo_Value or not reaper.GetMediaTrackInfo_Value then
        return nil, nil
    end
    local tr = reaper.GetEnvelopeInfo_Value(envelope, "P_TRACK")
    if not tr or tr == 0 then
        return nil, nil
    end
    local proj = reaper.EnumProjects and reaper.EnumProjects(-1) or 0
    if reaper.ValidatePtr2 and not reaper.ValidatePtr2(proj, tr, "MediaTrack*") then
        return nil, nil
    end
    local track_y = reaper.GetMediaTrackInfo_Value(tr, "I_TCPY")
    if type(track_y) ~= "number" then
        return nil, nil
    end
    local env_y = reaper.GetEnvelopeInfo_Value(envelope, "I_TCPY_USED")
    local env_h = reaper.GetEnvelopeInfo_Value(envelope, "I_TCPH_USED")
    if type(env_y) ~= "number" or type(env_h) ~= "number" or env_h < 1 then
        env_y = reaper.GetEnvelopeInfo_Value(envelope, "I_TCPY")
        env_h = reaper.GetEnvelopeInfo_Value(envelope, "I_TCPH")
    end
    if type(env_y) ~= "number" or type(env_h) ~= "number" or env_h < 1 then
        return nil, nil
    end
    local top = track_y + env_y
    return top, top + env_h
end

--- Top/bottom for value↔pixel mapping: real envelope lane when API succeeds, else `state.envelope_bounds` (arrange fallback).
function M.envelope_value_axis_screen_for_mapping(state, envelope)
    local vt, vb = M.envelope_value_axis_client_y(envelope)
    local b = state and state.envelope_bounds
    if not b then
        return nil, nil
    end
    if vt == nil or vb == nil or vb <= vt then
        return b.top, b.bottom
    end
    return vt, vb
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

--- Raw min/max for ScaleFromEnvelopeMode + GetEnvelopePoint (REAPER: point APIs use one raw storage space).
--- SWS BR_EnvGetProperties returns LaneMinValue/LaneMaxValue: the raw range that spans the drawable lane for the
--- current volenvrange / trim. That range must pair with I_TCP*_USED pixel height — not padded I_TCPH nor fixed 0..16.
function M.get_envelope_properties(state, envelope)
    if not envelope then return nil, nil end

    if state.cached_envelope_properties.envelope == envelope then
        return state.cached_envelope_properties.min_val, state.cached_envelope_properties.max_val
    end

    local br_env = reaper.BR_EnvAlloc(envelope, M.envelope_is_take_envelope(envelope))
    if not br_env then return nil, nil end
    -- Return order per SWS BR_ReaScript.cpp: ... centerValue, type, faderScaling, AIoptions
    local _, _, _, _, _, _, min_val, max_val = reaper.BR_EnvGetProperties(br_env)
    reaper.BR_EnvFree(br_env, false)
    if min_val == nil or max_val == nil then
        return nil, nil
    end

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

function M.clear_target_envelope_state_only(state)
    state.target_envelope = nil
    state.envelope_autoitem_idx = -1
    state.cached_envelope = nil
    state.cached_envelope_properties.envelope = nil
    state.cached_defshape_envelope = nil
    state.envelope_flush_pending = false
    state.suppress_imgui_control_this_frame = false
    state.last_envelope_sort_os = nil
    state.envelope_points_dirty_sort = false
end

return M
