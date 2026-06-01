-- Cubic Bézier least-squares fit (Schneider / Graphics Gems) in normalized (time, value) space.

local M = {}

local function dot(ax, ay, bx, by)
    return ax * bx + ay * by
end

local function len(ax, ay)
    return math.sqrt(ax * ax + ay * ay)
end

local function unit(ax, ay)
    local l = len(ax, ay)
    if l < 1e-18 then
        return 0, 0, 0
    end
    return ax / l, ay / l, l
end

local function bernstein3(i, t)
    local u = 1 - t
    if i == 0 then
        return u * u * u
    end
    if i == 1 then
        return 3 * u * u * t
    end
    if i == 2 then
        return 3 * u * t * t
    end
    return t * t * t
end

function M.cubic_eval(P0, P1, P2, P3, t)
    local b0 = bernstein3(0, t)
    local b1 = bernstein3(1, t)
    local b2 = bernstein3(2, t)
    local b3 = bernstein3(3, t)
    return {
        x = b0 * P0.x + b1 * P1.x + b2 * P2.x + b3 * P3.x,
        y = b0 * P0.y + b1 * P1.y + b2 * P2.y + b3 * P3.y,
    }
end

function M.cubic_deriv(P0, P1, P2, P3, t)
    local u = 1 - t
    return {
        x = 3 * u * u * (P1.x - P0.x) + 6 * u * t * (P2.x - P1.x) + 3 * t * t * (P3.x - P2.x),
        y = 3 * u * u * (P1.y - P0.y) + 6 * u * t * (P2.y - P1.y) + 3 * t * t * (P3.y - P2.y),
    }
end

function M.cubic_deriv2(P0, P1, P2, P3, t)
    local u = 1 - t
    return {
        x = 6 * u * (P2.x - 2 * P1.x + P0.x) + 6 * t * (P3.x - 2 * P2.x + P1.x),
        y = 6 * u * (P2.y - 2 * P1.y + P0.y) + 6 * t * (P3.y - 2 * P2.y + P1.y),
    }
end

--- Chord-length parameterization; returns t[1..#pts] in [0, 1].
function M.chord_length_params(pts)
    local m = #pts
    local tk = { 0 }
    if m < 2 then
        return tk
    end
    local total = 0
    local seg = {}
    for i = 2, m do
        local dx = pts[i].x - pts[i - 1].x
        local dy = pts[i].y - pts[i - 1].y
        local d = len(dx, dy)
        seg[i] = d
        total = total + d
    end
    if total < 1e-18 then
        for i = 2, m do
            tk[i] = (i - 1) / (m - 1)
        end
        return tk
    end
    local acc = 0
    for i = 2, m do
        acc = acc + seg[i]
        tk[i] = acc / total
    end
    return tk
end

local function solve_2x2(a11, a12, a21, a22, x1, x2)
    local det = a11 * a22 - a12 * a21
    if math.abs(det) < 1e-18 then
        return nil, nil
    end
    return (x1 * a22 - x2 * a12) / det, (a21 * x1 - a11 * x2) / det
end

--- Build normalized (x=time 0..1, y=value) points from envelope anchors + interior targets.
function M.window_points_normalized(left_t, left_v, right_t, right_v, targets)
    if left_t == nil or right_t == nil or left_v == nil or right_v == nil then
        return nil
    end
    local dt = right_t - left_t
    if dt <= 1e-18 then
        return nil
    end
    local pts = {
        { x = 0, y = left_v, t = left_t, v = left_v },
    }
    if targets then
        for i = 1, #targets do
            local s = targets[i]
            if s.t ~= nil and s.v ~= nil then
                pts[#pts + 1] = {
                    x = (s.t - left_t) / dt,
                    y = s.v,
                    t = s.t,
                    v = s.v,
                }
            end
        end
    end
    pts[#pts + 1] = { x = 1, y = right_v, t = right_t, v = right_v }
    if #pts < 2 then
        return nil
    end
    return pts, dt
end

--- Schneider single cubic with endpoints fixed; pts in normalized xy, endpoints at x=0 and x=1.
function M.schneider_cubic(pts, opts)
    opts = opts or {}
    local m = #pts
    if m < 2 then
        return nil
    end

    local P0 = { x = pts[1].x, y = pts[1].y }
    local P3 = { x = pts[m].x, y = pts[m].y }
    local tk = M.chord_length_params(pts)

    local function fit_once(t_params)
        local tlx, tly = unit(pts[2].x - pts[1].x, pts[2].y - pts[1].y)
        if m == 2 then
            tlx, tly = unit(P3.x - P0.x, P3.y - P0.y)
        end
        local trx, try = unit(pts[m].x - pts[m - 1].x, pts[m].y - pts[m - 1].y)
        if m == 2 then
            trx, try = tlx, tly
        end

        local A11, A12, A21, A22 = 0, 0, 0, 0
        local X1, X2 = 0, 0

        for k = 1, m do
            local t = t_params[k]
            local B0 = bernstein3(0, t)
            local B1 = bernstein3(1, t)
            local B2 = bernstein3(2, t)
            local B3 = bernstein3(3, t)
            local Qx, Qy = pts[k].x, pts[k].y
            local fix_x = (B0 + B1) * P0.x + (B2 + B3) * P3.x
            local fix_y = (B0 + B1) * P0.y + (B2 + B3) * P3.y
            local Rx, Ry = Qx - fix_x, Qy - fix_y

            local c1x, c1y = B1 * tlx, B1 * tly
            local c2x, c2y = -B2 * trx, -B2 * try

            A11 = A11 + dot(c1x, c1y, c1x, c1y)
            A12 = A12 + dot(c1x, c1y, c2x, c2y)
            A21 = A21 + dot(c2x, c2y, c1x, c1y)
            A22 = A22 + dot(c2x, c2y, c2x, c2y)
            X1 = X1 + dot(Rx, Ry, c1x, c1y)
            X2 = X2 + dot(Rx, Ry, c2x, c2y)
        end

        local a1, a2 = solve_2x2(A11, A12, A21, A22, X1, X2)
        if not a1 or not a2 then
            return nil
        end

        local P1 = { x = P0.x + a1 * tlx, y = P0.y + a1 * tly }
        local P2 = { x = P3.x - a2 * trx, y = P3.y - a2 * try }
        return P0, P1, P2, P3, a1, a2, t_params
    end

    local P0, P1, P2, P3, a1, a2
    local t_params = tk
    for _ = 1, (opts.newton_iters or 2) do
        local r0, r1, r2, r3, ra1, ra2, tp = fit_once(t_params)
        if not r0 then
            return nil
        end
        P0, P1, P2, P3, a1, a2 = r0, r1, r2, r3, ra1, ra2

        local changed = false
        for k = 2, m - 1 do
            local t = t_params[k]
            local B = M.cubic_eval(P0, P1, P2, P3, t)
            local d1 = M.cubic_deriv(P0, P1, P2, P3, t)
            local d2 = M.cubic_deriv2(P0, P1, P2, P3, t)
            local ex, ey = B.x - pts[k].x, B.y - pts[k].y
            local denom = dot(d1.x, d1.y, d1.x, d1.y) + dot(ex, ey, d2.x, d2.y)
            if math.abs(denom) > 1e-18 then
                local dt = dot(ex, ey, d1.x, d1.y) / denom
                local nt = t - dt
                if nt < 0 then nt = 0 elseif nt > 1 then nt = 1 end
                if math.abs(nt - t) > 1e-8 then
                    changed = true
                end
                t_params[k] = nt
            end
        end
        if not changed then
            break
        end
    end

    if not P0 then
        local r0, r1, r2, r3, ra1, ra2 = fit_once(t_params)
        if not r0 then
            return nil
        end
        P0, P1, P2, P3, a1, a2 = r0, r1, r2, r3, ra1, ra2
    end

    local max_err = 0
    local max_err_k = 1
    for k = 1, m do
        local B = M.cubic_eval(P0, P1, P2, P3, t_params[k])
        local ev = math.abs(B.y - pts[k].y)
        if ev > max_err then
            max_err = ev
            max_err_k = k
        end
    end

    local chord_xy = len(P3.x - P0.x, P3.y - P0.y)
    local hint = 0
    if chord_xy > 1e-12 then
        hint = (a1 - a2) / chord_xy
        if hint > 1 then hint = 1 elseif hint < -1 then hint = -1 end
    end

    return {
        P0 = P0,
        P1 = P1,
        P2 = P2,
        P3 = P3,
        alpha1 = a1,
        alpha2 = a2,
        t_params = t_params,
        max_value_err = max_err,
        max_err_index = max_err_k,
        tension_hint = hint,
    }
end

function M.golden_section_min(f, lo, hi, iters)
    iters = iters or 12
    if hi < lo then lo, hi = hi, lo end
    if hi - lo < 1e-9 then
        local v = f(lo)
        return lo, v
    end
    local gr = (math.sqrt(5) - 1) * 0.5
    local c = hi - gr * (hi - lo)
    local d = lo + gr * (hi - lo)
    local fc, fd = f(c), f(d)
    for _ = 1, iters do
        if fc < fd then
            hi, d, fd = d, c, fc
            c = hi - gr * (hi - lo)
            fc = f(c)
        else
            lo, c, fc = c, d, fd
            d = lo + gr * (hi - lo)
            fd = f(d)
        end
    end
    if fc < fd then
        return c, fc
    end
    return d, fd
end

--- Map Schneider fit to REAPER shape-5 tension by minimizing value error at targets.
function M.find_best_reaper_tension(set_segment, measure_err, hint, search_radius, iters)
    hint = hint or 0
    search_radius = search_radius or 0.35
    iters = iters or 10

    local function eval_tens(t)
        if t > 1 then t = 1 elseif t < -1 then t = -1 end
        set_segment(t)
        return measure_err()
    end

    local lo = math.max(-1, hint - search_radius)
    local hi = math.min(1, hint + search_radius)
    local best_t, best_err = M.golden_section_min(eval_tens, lo, hi, iters)

    if search_radius < 0.99 then
        local g_t, g_err = M.golden_section_min(eval_tens, -1, 1, iters + 4)
        if g_err < best_err then
            best_t, best_err = g_t, g_err
        end
    end

    return best_t, best_err
end

return M
