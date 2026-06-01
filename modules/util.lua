local M = {}

function M.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

--- Track envelope parent lane: REAPER uses autoitem_idx -1 (product scope: track-only).
function M.track_autoitem_idx(state)
    return state.envelope_autoitem_idx or -1
end

return M
