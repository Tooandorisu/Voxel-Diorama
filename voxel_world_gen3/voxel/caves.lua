-- Cave atmosphere: dust drifting in the air, now and then a drop of water
-- falling from the dark above and splashing on the floor.
--
-- Drawn through scene.lua's critter pass as soft additive glows (like the
-- fireflies): faint motes of dust catching the light, a bright streak for
-- a falling drop and a ring spreading where it lands.  In a dark cave the
-- Flash circle's darkness falls on them like on everything else, so only
-- what is near the player shows.  Positions are in the world's
-- coordinates (the mesh's plus the current shift, bridge.lua).

local Caves = {}

local random, sin, cos, floor, min, max = math.random, math.sin, math.cos, math.floor, math.min, math.max

local state = { motes = {}, drops = {}, rings = {}, t = 0, nextDrop = 1.2 }
Caves._state = state

function Caves.reset()
  state.motes, state.drops, state.rings = {}, {}, {}
  state.nextDrop = 1.2
end

-- rect: what the camera sees (world px); focus: the player's feet (world
-- px), where most of it happens (a dark cave shows nothing further out);
-- floorAt(x, y) -> floor height there, water(x, y) -> true on cave water;
-- budget: 1 normal, 0.5 on the lowest quality
function Caves.update(dt, rect, fx, fy, floorAt, water, budget)
  dt = min(dt or 1 / 60, 0.1)
  state.t = state.t + dt
  budget = budget or 1
  if not rect then return end
  local function spot(spread)
    -- near the player most of the time, anywhere in view now and then
    if random() < 0.7 then
      return fx + (random() - 0.5) * spread * 2, fy - 8 + (random() - 0.5) * spread * 1.2
    end
    return rect[1] + random() * (rect[3] - rect[1]), rect[2] + random() * (rect[4] - rect[2])
  end
  -- dust: slow motes hanging in the air, drifting and fading in and out
  local want = floor(44 * budget)
  local motes = state.motes
  for _ = 1, 3 do
    if #motes >= want then break end
    local x, y = spot(90)
    local g = floorAt and floorAt(x, y) or 0
    motes[#motes + 1] = { x = x, y = y, z = g + 4 + random() * 30, ph = random() * 6.283,
      life = 5 + random() * 6, age = 0, sp = 0.5 + random() * 0.8 }
  end
  for i = #motes, 1, -1 do
    local m = motes[i]
    m.age = m.age + dt
    m.x = m.x + (sin(state.t * 0.3 * m.sp + m.ph) * 2.2 + 0.6) * dt
    m.y = m.y + cos(state.t * 0.25 * m.sp + m.ph * 1.7) * 1.4 * dt
    m.z = m.z + (sin(state.t * 0.5 * m.sp + m.ph) * 1.2 - 0.4) * dt
    if m.age >= m.life then table.remove(motes, i) end
  end
  -- drips: a drop every couple of seconds, from high up straight down
  state.nextDrop = state.nextDrop - dt
  if state.nextDrop <= 0 then
    state.nextDrop = (1.2 + random() * 2.4) / budget
    local x, y = spot(70)
    local g = floorAt and floorAt(x, y) or 0
    state.drops[#state.drops + 1] = { x = x, y = y, z = g + 70 + random() * 30, g = g, vz = 0,
      wet = water and water(x, y) or false }
  end
  local drops = state.drops
  for i = #drops, 1, -1 do
    local d = drops[i]
    d.vz = d.vz - 260 * dt
    d.z = d.z + d.vz * dt
    if d.z <= d.g + 0.5 then
      -- a ring where it lands: wider and slower on water
      state.rings[#state.rings + 1] = { x = d.x, y = d.y, z = d.g + 0.6, age = 0,
        life = d.wet and 1.1 or 0.45, size = d.wet and 9 or 4 }
      table.remove(drops, i)
    end
  end
  local rings = state.rings
  for i = #rings, 1, -1 do
    local r = rings[i]
    r.age = r.age + dt
    if r.age >= r.life then table.remove(rings, i) end
  end
end

function Caves.active()
  return #state.motes > 0 or #state.drops > 0 or #state.rings > 0
end

-- One additive glow list (scene.lua's 16x16 round glow), in the mesher's
-- vertex layout.  Motes and drops stand upright facing the camera; a ring
-- lies flat on the floor.
function Caves.build()
  local v, idx, n, ni = {}, {}, 0, 0
  local function upright(x, y, z, w, h, r, g, b, a)
    v[n + 1] = { x - w, y, z, 0, 16, 0, 0, r, g, b, a }
    v[n + 2] = { x + w, y, z, 16, 16, 0, 0, r, g, b, a }
    v[n + 3] = { x + w, y, z + h, 16, 0, 0, 0, r, g, b, a }
    v[n + 4] = { x - w, y, z + h, 0, 0, 0, 0, r, g, b, a }
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = n + 1, n + 2, n + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = n + 1, n + 3, n + 4
    n, ni = n + 4, ni + 6
  end
  local function flat(x, y, z, s, r, g, b, a)
    v[n + 1] = { x - s, y - s * 0.6, z, 0, 0, 0, 0, r, g, b, a }
    v[n + 2] = { x + s, y - s * 0.6, z, 16, 0, 0, 0, r, g, b, a }
    v[n + 3] = { x + s, y + s * 0.6, z, 16, 16, 0, 0, r, g, b, a }
    v[n + 4] = { x - s, y + s * 0.6, z, 0, 16, 0, 0, r, g, b, a }
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = n + 1, n + 2, n + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = n + 1, n + 3, n + 4
    n, ni = n + 4, ni + 6
  end
  for _, m in ipairs(state.motes) do
    local k = m.age / m.life
    local a = (k < 0.2 and k / 0.2 or (k > 0.75 and (1 - k) / 0.25 or 1))
    a = a * (0.6 + 0.4 * sin(state.t * 1.7 + m.ph * 3))
    -- (drawn over the scene, not added to it: added, pale motes vanished
    -- on a pale cave floor.  A soft halo and a small bright core.)
    -- (big enough to read on a phone: at 1-2 px they were lost specks)
    -- (on a phone, at half resolution, over a pale floor, 4 px motes at
    -- half strength read as nothing: larger and fuller)
    upright(m.x, m.y, m.z - 7, 7, 14, 1.0, 0.93, 0.78, a * 0.6)
    upright(m.x, m.y, m.z - 3, 3, 6, 1.0, 1.0, 0.92, math.min(1, a * 1.3))
  end
  for _, d in ipairs(state.drops) do
    -- a short bright streak, longer as it speeds up
    local len = min(10, 2 + -d.vz * 0.03)
    upright(d.x, d.y, d.z, 2.2, len + 4, 0.85, 0.95, 1.0, 1.0)
  end
  for _, r in ipairs(state.rings) do
    local k = r.age / r.life
    local s = 4 + k * r.size * 2
    -- (a soft disc, brighter at first; on water its spreading is the ripple)
    flat(r.x, r.y, r.z, s, 0.85, 0.95, 1.0, (1 - k) * 0.8)
  end
  return v, n, idx, ni
end

return Caves
