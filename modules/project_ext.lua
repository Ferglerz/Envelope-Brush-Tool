-- Persist brush tool settings in the REAPER project via GetProjExtState / SetProjExtState (P_EXT / project extension data).

local M = {}

--- Section name in the project file (one section, multiple keys).
M.EXT_SECTION = "Fergler_EnvelopeBrush"

local VERSION = "1"

--- Fingerprint for the active project (directory path, or placeholder when unsaved).
function M.current_project_fingerprint()
    local a, b = reaper.GetProjectPath("")
    local p = (type(b) == "string" and b ~= "") and b or (type(a) == "string" and a or "")
    if p ~= "" then return p end
    return "__unsaved__"
end

local function get_ext(key)
    if not reaper.GetProjExtState then return "" end
    local a, b = reaper.GetProjExtState(0, M.EXT_SECTION, key)
    if a == false then return "" end
    if type(b) == "string" then return b end
    if type(a) == "string" then return a end
    return ""
end

local function set_ext(key, value)
    if not reaper.SetProjExtState then return end
    reaper.SetProjExtState(0, M.EXT_SECTION, key, tostring(value))
end

function M.serialize_snapshot(state)
    return table.concat({
        tostring(state.brush_size or 0),
        tostring(state.falloff_type or 1),
        string.format("%.8g", state.falloff_strength or 0),
        string.format("%.8g", state.sculpt_power or 0),
        state.invert_brush_size_scroll and "1" or "0",
        tostring(state.min_point_spacing_px or 1),
        state.lock_time_axis and "1" or "0",
        state.lock_value_axis and "1" or "0",
    }, "\1")
end

--- Apply project extension keys into `state`; clamp using `config`. No-op if no saved version.
function M.load_into_state(state, config)
    if not reaper.GetProjExtState then return end
    local ver = get_ext("version")
    if ver == "" then return end

    local fcfg, bcfg, spcfg, scfg = config.falloff, config.brush, config.spacing, config.sculpt
    local ntypes = #(fcfg.FALLOFF_TYPES or {})

    local function ti(key, default)
        local s = get_ext(key)
        if s == "" then return default end
        local v = tonumber(s)
        return (v ~= nil) and v or default
    end

    local function tb(key, default)
        local s = get_ext(key)
        if s == "" then return default end
        return s == "1" or s == "true"
    end

    state.brush_size = math.floor(
        math.max(bcfg.MIN_BRUSH_SIZE, math.min(bcfg.MAX_BRUSH_SIZE, ti("brush_size", state.brush_size)))
        + 0.5
    )
    local ft = math.floor(ti("falloff_type", state.falloff_type) + 0.5)
    if ntypes > 0 then
        state.falloff_type = math.max(1, math.min(ntypes, ft))
    end
    state.falloff_strength = math.max(
        fcfg.MIN_FALLOFF_STRENGTH,
        math.min(fcfg.MAX_FALLOFF_STRENGTH, ti("falloff_strength", state.falloff_strength))
    )
    state.sculpt_power = math.max(
        scfg.MIN_SCULPT_POWER,
        math.min(scfg.MAX_SCULPT_POWER, ti("sculpt_power", state.sculpt_power))
    )
    state.invert_brush_size_scroll = tb("invert_brush_size_scroll", state.invert_brush_size_scroll)
    local sp = math.floor(ti("min_point_spacing_px", state.min_point_spacing_px) + 0.5)
    state.min_point_spacing_px = math.max(spcfg.MIN_MIN_POINT_SPACING_PX, math.min(spcfg.MAX_MIN_POINT_SPACING_PX, sp))
    state.lock_time_axis = tb("lock_time", state.lock_time_axis)
    state.lock_value_axis = tb("lock_value", state.lock_value_axis)
    if state.lock_time_axis and state.lock_value_axis then
        state.lock_value_axis = false
    end
end

function M.write_from_state(state, config)
    if not reaper.SetProjExtState then return end
    set_ext("version", VERSION)
    set_ext("brush_size", state.brush_size)
    set_ext("falloff_type", state.falloff_type)
    set_ext("falloff_strength", string.format("%.10g", state.falloff_strength))
    set_ext("sculpt_power", string.format("%.10g", state.sculpt_power))
    set_ext("invert_brush_size_scroll", state.invert_brush_size_scroll and "1" or "0")
    set_ext("min_point_spacing_px", state.min_point_spacing_px)
    set_ext("lock_time", state.lock_time_axis and "1" or "0")
    set_ext("lock_value", state.lock_value_axis and "1" or "0")
    if reaper.MarkProjectDirty then
        pcall(reaper.MarkProjectDirty)
    end
end

local last_fp = nil
local last_blob = nil

--- Call after load_into_state in init to prime fingerprint tracking and avoid an immediate redundant save.
function M.after_load_init(state)
    last_fp = M.current_project_fingerprint()
    last_blob = M.serialize_snapshot(state)
end

--- Run at start of main loop: reload settings when switching projects. Returns true if the active project changed.
function M.tick_project_switch(state, config)
    local fp = M.current_project_fingerprint()
    if last_fp == nil then
        last_fp = fp
        return false
    end
    if fp ~= last_fp then
        M.load_into_state(state, config)
        last_fp = fp
        last_blob = M.serialize_snapshot(state)
        return true
    end
    return false
end

--- Persist when any tracked field changed (avoids redundant writes / dirty spam).
function M.save_if_changed(state, config)
    local blob = M.serialize_snapshot(state)
    if blob == last_blob then return end
    last_blob = blob
    M.write_from_state(state, config)
end

--- Force write (e.g. script exit).
function M.save_now(state, config)
    M.write_from_state(state, config)
    last_blob = M.serialize_snapshot(state)
end

return M
