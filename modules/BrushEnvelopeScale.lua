-- Shared raw vs display scaling for arrange mapping (BrushEnvelope + BrushOps).

local M = {}

function M.scaling_mode(envelope)
    if not envelope or not reaper.GetEnvelopeScalingMode then
        return 0
    end
    local m = reaper.GetEnvelopeScalingMode(envelope)
    if type(m) ~= "number" or m < 0 then
        return 0
    end
    return math.floor(m)
end

function M.raw_to_display(mode, raw)
    if mode == 0 or not reaper.ScaleFromEnvelopeMode then
        return raw
    end
    return reaper.ScaleFromEnvelopeMode(mode, raw)
end

function M.display_to_raw(mode, disp)
    if mode == 0 or not reaper.ScaleToEnvelopeMode then
        return disp
    end
    return reaper.ScaleToEnvelopeMode(mode, disp)
end

return M
