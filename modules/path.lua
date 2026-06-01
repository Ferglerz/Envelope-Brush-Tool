-- Script directory resolution and dofile helpers for REAPER Lua modules.

local M = {}

local _path_src = debug.getinfo(1, "S").source or ""
local _path_file = _path_src:match("^@(.+)$") or ""
M.MODULES_DIR = _path_file:match("^(.*[\\/])") or ""

local _module_cache = {}

--- Directory of the first stack frame outside path.lua (the module that called Path.load).
function M.caller_dir()
    for level = 2, 15 do
        local info = debug.getinfo(level, "S")
        if not info or not info.source then
            break
        end
        local src = info.source
        if src:sub(1, 1) == "@" and not src:match("[/\\]path%.lua$") then
            local path = src:match("^@(.+)$") or ""
            local dir = path:match("^(.*[\\/])") or ""
            if #dir > 0 then
                return dir
            end
        end
    end
    error("Envelope Brush Tool: Path.caller_dir could not resolve caller")
end

local function cached_load(cache_key, filepath)
    local hit = _module_cache[cache_key]
    if hit ~= nil then
        return hit
    end
    local mod = dofile(filepath)
    _module_cache[cache_key] = mod
    return mod
end

--- Load relative to the caller's directory (sibling files in the same folder).
function M.load(relative_path)
    local dir = M.caller_dir()
    return cached_load(dir .. relative_path, dir .. relative_path)
end

--- Load relative to this `modules/` directory (shared files: util, config, envelope/…, render/…).
function M.load_from_modules(relative_path)
    return cached_load("modules:" .. relative_path, M.MODULES_DIR .. relative_path)
end

return M
