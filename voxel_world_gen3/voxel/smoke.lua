-- Chimney smoke.  Houses get a small brick chimney on their roof, and soft
-- puffs rise from it, swell, drift with the wind and fade.
--
-- Chimneys come from the heightfield's sloped roofs (grid.roofs): homes,
-- not every building -- a roof no wider than seven cells (a Poke Center, a
-- Mart, a gym or a department store is wider or carries no house roof) and
-- picked by its position, so most houses have one and the same ones always
-- do.  The chimney stands on the front slope, toward one end, its foot on
-- the slope and its top above the ridge.  Positions are in the mesh's
-- coordinates; drawing adds the current shift (bridge.lua).

local HF -- set by Smoke.init (heightfield, for the roof's rise)

local Smoke = {}

local random, sin, floor, max, min, abs = math.random, math.sin, math.floor, math.max, math.min, math.abs

local state = { stacks = {}, puffs = {}, t = 0 }
Smoke._state = state

function Smoke.init(heightfield) HF = heightfield end

local function roofZ(r, x, y)
  local rise = HF and HF.roofRise and HF.roofRise(r) or 8
  if r.ridge == "ew" then
    local ym, half = (r.y0 + r.y1) / 2, max(1, (r.y1 - r.y0) / 2)
    return r.h + rise * (1 - min(1, abs(y - ym) / half)), r.h + rise
  end
  local xm, half = (r.x1 + r.x2) / 2, max(1, (r.x2 - r.x1) / 2)
  return r.h + rise * (1 - min(1, abs(x - xm) / half)), r.h + rise
end

-- chimneys of a freshly built grid
function Smoke.setStacks(grid)
  local stacks = {}
  for _, r in ipairs(grid.roofs or {}) do
    local w = r.x2 - r.x1
    local d = r.y1 - r.y0
    -- a home: two to seven cells wide, at least two deep
    if w >= 32 and w <= 7 * 16 and d >= 24 then
      local hsh = (floor(r.x1 / 16) * 73856093 + floor(r.y0 / 16) * 19349663) % 1000 / 1000
      if hsh < 0.8 then
        local side = hsh < 0.4 and 0.24 or 0.76
        local x, y
        if r.ridge == "ew" then
          x = r.x1 + w * side
          y = (r.y0 + r.y1) / 2 + d * 0.12
        else
          x = r.x1 + w * (side < 0.5 and 0.3 or 0.7)
          y = r.y0 + d * 0.4
        end
        local base, ridge = roofZ(r, x, y)
        stacks[#stacks + 1] = { x = floor(x) + 0.5, y = floor(y) + 0.5, z0 = base - 2, z1 = ridge + 7,
          ph = hsh * 37, next = hsh * 2 }
      end
    end
  end
  -- a rebuild while walking about (every few steps) keeps the smoke in the
  -- air and each chimney's rhythm: clearing them made the smoke stutter
  -- and rarely build up.  Only a different map starts afresh.
  local old = {}
  for _, s in ipairs(state.stacks) do old[s.x .. "," .. s.y] = s end
  local kept = 0
  for _, s in ipairs(stacks) do
    local o = old[s.x .. "," .. s.y]
    if o then s.next = o.next; kept = kept + 1 end
  end
  if kept == 0 and #state.stacks > 0 then state.puffs = {} end
  state.stacks = stacks
end

function Smoke.reset() state.stacks, state.puffs = {}, {} end

-- wind: px/s sideways at a tree top (bridge.lua's), wet: rain or snow
-- (more smoke: a fire is lit), rect: what the camera sees (world px)
function Smoke.update(dt, wind, wet, rect, sx, sy)
  dt = min(dt or 1 / 60, 0.1)
  state.t = state.t + dt
  sx, sy = sx or 0, sy or 0
  local puffs = state.puffs
  local every = wet and 0.3 or 0.5
  state.seen = 0
  for _, s in ipairs(state.stacks) do
    local x, y = s.x + sx, s.y + sy
    local seen = not rect or (x >= rect[1] - 16 and x <= rect[3] + 16 and y >= rect[2] - 16 and y <= rect[4] + 48)
    if seen then state.seen = state.seen + 1 end
    s.next = s.next - dt
    if seen and s.next <= 0 and #puffs < 160 then
      s.next = every * (0.7 + random() * 0.6)
      puffs[#puffs + 1] = { x = s.x + (random() - 0.5) * 1.5, y = s.y, z = s.z1 + 0.5,
        age = 0, life = 3.2 + random() * 1.6, ph = random() * 6.283 }
    end
  end
  local drift = (wind or 0.9) * 5
  for i = #puffs, 1, -1 do
    local p = puffs[i]
    p.age = p.age + dt
    -- rise, slowing as it cools; lean away with the wind, a little waver
    p.z = p.z + (9 - p.age * 1.4) * dt
    p.x = p.x + (drift * min(1, p.age / 1.5) + sin(state.t * 1.3 + p.ph) * 1.2) * dt
    if p.age >= p.life then table.remove(puffs, i) end
  end
end

-- Chimneys (opaque, brick) and puffs (soft round glows, grey), in the
-- mesher's vertex layout.
function Smoke.build(sx, sy)
  sx, sy = sx or 0, sy or 0
  local cv, ci, cn, cni = {}, {}, 0, 0
  local function face(a, b, c, d, s)
    local r, g, bl = 0.62 * s, 0.34 * s, 0.26 * s
    for _, v in ipairs({ a, b, c, d }) do
      cn = cn + 1
      cv[cn] = { v[1], v[2], v[3], 0.5, 0.5, 0, 0, r, g, bl, 1 }
    end
    ci[cni + 1], ci[cni + 2], ci[cni + 3] = cn - 3, cn - 2, cn - 1
    ci[cni + 4], ci[cni + 5], ci[cni + 6] = cn - 3, cn - 1, cn
    cni = cni + 6
  end
  for _, s in ipairs(state.stacks) do
    local x, y = s.x + sx, s.y + sy
    local hw, hd = 2.5, 2.5
    local x0, x1, y0, y1, z0, z1 = x - hw, x + hw, y - hd, y + hd, s.z0, s.z1
    face({ x0, y1, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x0, y1, z1 }, 1.0)  -- front
    face({ x1, y0, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x1, y0, z1 }, 0.78) -- east
    face({ x0, y1, z0 }, { x0, y0, z0 }, { x0, y0, z1 }, { x0, y1, z1 }, 0.9)  -- west
    face({ x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 }, 0.55) -- top (sooty)
  end
  local pv, pi, pn, pni = {}, {}, 0, 0
  for _, p in ipairs(state.puffs) do
    local k = p.age / p.life
    -- (a little darker than pale paving and roofs, or it vanished on them)
    local size = 4.5 + k * 12
    local a = (k < 0.08 and k / 0.08 or (1 - k) / 0.92) * 0.95
    local g = 0.66 + k * 0.2
    local x, y, z = p.x + sx, p.y + sy, p.z
    pv[pn + 1] = { x - size, y, z - size, 0, 16, 0, 0, g, g, g, a }
    pv[pn + 2] = { x + size, y, z - size, 16, 16, 0, 0, g, g, g, a }
    pv[pn + 3] = { x + size, y, z + size, 16, 0, 0, 0, g, g, g, a }
    pv[pn + 4] = { x - size, y, z + size, 0, 0, 0, 0, g, g, g, a }
    pi[pni + 1], pi[pni + 2], pi[pni + 3] = pn + 1, pn + 2, pn + 3
    pi[pni + 4], pi[pni + 5], pi[pni + 6] = pn + 1, pn + 3, pn + 4
    pn, pni = pn + 4, pni + 6
  end
  return cv, cn, ci, cni, pv, pn, pi, pni
end

return Smoke
