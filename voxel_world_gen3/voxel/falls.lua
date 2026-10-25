-- Waterfalls: mist and spray where the water lands.
--
-- The falls themselves are geometry (heightfield.lua grid.falls, a sloping
-- sheet the mesher builds and the shader streams).  Here, at each one's
-- foot: soft white mist billowing up and drifting off, bright drops of
-- spray thrown out and falling back, and froth spreading on the pool.
-- Drawn through scene.lua's glow pass, blended over the scene (like the
-- cave dust).  Positions are in the mesh's coordinates; drawing adds the
-- current shift (bridge.lua).

local Falls = {}

local random, sin, cos, floor, min, max = math.random, math.sin, math.cos, math.floor, math.min, math.max

local state = { list = {}, mist = {}, spray = {}, froth = {}, t = 0 }
Falls._state = state

function Falls.reset()
  state.list, state.mist, state.spray, state.froth = {}, {}, {}, {}
end

-- the falls of a freshly built grid (a rebuild while walking keeps what is
-- in the air; a different map starts afresh)
function Falls.setFalls(grid, sameMap)
  local list = {}
  for _, f in ipairs(grid and grid.falls or {}) do
    list[#list + 1] = { x1 = f.x1, x2 = f.x2, y = f.y1, z = f.z1, top = f.z0, y0 = f.y0,
      acc = 0 }
  end
  state.list = list
  if not sameMap then state.mist, state.spray, state.froth = {}, {}, {} end
end

function Falls.active()
  return #state.list > 0 or #state.mist > 0 or #state.spray > 0 or #state.froth > 0
end

-- rect: what the camera sees (world px); sx, sy: the mesh's shift;
-- wind: px/s sideways (bridge.lua's); budget: 1 normal, 0.5 lowest quality
function Falls.update(dt, rect, sx, sy, wind, budget)
  dt = min(dt or 1 / 60, 0.1)
  state.t = state.t + dt
  budget = budget or 1
  sx, sy = sx or 0, sy or 0
  local mist, spray, froth = state.mist, state.spray, state.froth
  for _, f in ipairs(state.list) do
    local seen = not rect or (f.x2 + sx >= rect[1] - 32 and f.x1 + sx <= rect[3] + 32
      and f.y + sy >= rect[2] - 32 and f.y0 + sy <= rect[4] + 48)
    if seen then
      -- more of it from a wider and a higher fall
      local w = (f.x2 - f.x1) / 16
      local power = min(1.5, (f.top - f.z) / 40)
      f.acc = f.acc + dt * w * (3 + 3 * power) * budget
      while f.acc >= 1 do
        f.acc = f.acc - 1
        local x = f.x1 + 2 + random() * (f.x2 - f.x1 - 4)
        if #mist < 90 * budget then
          -- (standing in the pool a little in front of the falls: lower,
          -- half of each puff was under the water and the sheet hid the rest)
          mist[#mist + 1] = { x = x, y = f.y + 3 + random() * 8, z = f.z + 6 + random() * 6,
            vx = (random() - 0.5) * 6, vz = 4 + random() * 6 * power, age = 0,
            life = 1.8 + random() * 1.6, size = 6 + random() * 5, ph = random() * 6.283 }
        end
        if random() < 0.8 and #spray < 70 * budget then
          spray[#spray + 1] = { x = x, y = f.y + random() * 3, z = f.z + 2,
            vx = (random() - 0.5) * 18, vy = 4 + random() * 14, vz = 14 + random() * 26 * power,
            age = 0, gz = f.z }
        end
        if random() < 0.35 and #froth < 40 * budget then
          froth[#froth + 1] = { x = x, y = f.y + 2 + random() * 4, z = f.z + 0.6, age = 0,
            life = 1.2 + random() * 1.0, size = 3 + random() * 3 }
        end
      end
    end
  end
  local drift = (wind or 0.9) * 3
  for i = #mist, 1, -1 do
    local m = mist[i]
    m.age = m.age + dt
    -- billows up, slows, spreads and drifts south off the pool and with the wind
    m.z = m.z + m.vz * dt
    m.vz = m.vz * (1 - 0.8 * dt)
    m.x = m.x + (m.vx + drift + sin(state.t * 1.4 + m.ph) * 2) * dt
    m.y = m.y + 3 * dt
    if m.age >= m.life then table.remove(mist, i) end
  end
  for i = #spray, 1, -1 do
    local d = spray[i]
    d.age = d.age + dt
    d.vz = d.vz - 120 * dt
    d.x, d.y, d.z = d.x + d.vx * dt, d.y + d.vy * dt, d.z + d.vz * dt
    if d.z <= d.gz or d.age > 2 then table.remove(spray, i) end
  end
  for i = #froth, 1, -1 do
    local r = froth[i]
    r.age = r.age + dt
    r.y = r.y + 4 * dt
    if r.age >= r.life then table.remove(froth, i) end
  end
end

-- One glow list (scene.lua's 16x16 round glow), in the mesher's vertex
-- layout: mist and spray upright, facing the camera; froth flat on the
-- water.  tint: the time of day's light colour (mist is not white at night).
function Falls.build(sx, sy, tint)
  sx, sy = sx or 0, sy or 0
  local tr, tg, tb = 1, 1, 1
  if tint then tr, tg, tb = tint[1], tint[2], tint[3] end
  local v, idx, n, ni = {}, {}, 0, 0
  local function upright(x, y, z, w, h, r, g, b, a)
    x, y = x + sx, y + sy
    v[n + 1] = { x - w, y, z, 0, 16, 0, 0, r, g, b, a }
    v[n + 2] = { x + w, y, z, 16, 16, 0, 0, r, g, b, a }
    v[n + 3] = { x + w, y, z + h, 16, 0, 0, 0, r, g, b, a }
    v[n + 4] = { x - w, y, z + h, 0, 0, 0, 0, r, g, b, a }
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = n + 1, n + 2, n + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = n + 1, n + 3, n + 4
    n, ni = n + 4, ni + 6
  end
  local function flat(x, y, z, s, r, g, b, a)
    x, y = x + sx, y + sy
    v[n + 1] = { x - s, y - s * 0.6, z, 0, 0, 0, 0, r, g, b, a }
    v[n + 2] = { x + s, y - s * 0.6, z, 16, 0, 0, 0, r, g, b, a }
    v[n + 3] = { x + s, y + s * 0.6, z, 16, 16, 0, 0, r, g, b, a }
    v[n + 4] = { x - s, y + s * 0.6, z, 0, 16, 0, 0, r, g, b, a }
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = n + 1, n + 2, n + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = n + 1, n + 3, n + 4
    n, ni = n + 4, ni + 6
  end
  for _, r in ipairs(state.froth) do
    local k = r.age / r.life
    flat(r.x, r.y, r.z, r.size * (1 + k), 0.96 * tr, 0.99 * tg, 1.0 * tb, (1 - k) * 0.75)
  end
  for _, m in ipairs(state.mist) do
    local k = m.age / m.life
    local a = (k < 0.15 and k / 0.15 or (1 - k) / 0.85) * 0.6
    local s = m.size * (1 + k * 1.6)
    upright(m.x, m.y, m.z - s, s, s * 2, 0.95 * tr, 0.98 * tg, 1.0 * tb, a)
  end
  for _, d in ipairs(state.spray) do
    upright(d.x, d.y, d.z - 2, 2.2, 4.4, 0.98 * tr, 1.0 * tg, 1.0 * tb, 1.0)
  end
  return v, n, idx, ni
end

return Falls
