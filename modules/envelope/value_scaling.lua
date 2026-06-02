-- Linearize envelope point values for Get/Set/Insert/Evaluate (non-zero GetEnvelopeScalingMode).

local M = {}

local _mode_cache = {}

function M.invalidate(envelope)
    if envelope then
        _mode_cache[envelope] = nil
    end
end

function M.scaling_mode(envelope)
    if not envelope then return 0 end
    local mode = _mode_cache[envelope]
    if mode == nil then
        mode = reaper.GetEnvelopeScalingMode(envelope) or 0
        _mode_cache[envelope] = mode
    end
    return mode
end

function M.api_value_to_linear(envelope, value)
    if type(value) ~= "number" then return value end
    local mode = M.scaling_mode(envelope)
    if mode == 0 then return value end
    return reaper.ScaleFromEnvelopeMode(mode, value)
end

function M.linear_value_to_api(envelope, value)
    if type(value) ~= "number" then return value end
    local mode = M.scaling_mode(envelope)
    if mode == 0 then return value end
    return reaper.ScaleToEnvelopeMode(mode, value)
end

return M
