-- Small life in the diorama: fireflies over grass and woods at night, and
-- now and then by day a few birds flying up out of the trees.
--
-- Where they live comes from the heightfield: the swaying foliage
-- (grid.SW) -- tree tops for the birds to leave from, grass and canopy for
-- the fireflies to hover over.  Spots are gathered once per rebuild, in the
-- mesh's coordinates; drawing adds the current shift (bridge.lua), like the
-- terrain.  Quads stand upright facing the camera, in the mesher's vertex
-- layout, drawn through scene.lua's weather pass (fireflies glow additively).

local Critters = {}

local random, sin, cos, floor, max, min, sqrt = math.random, math.sin, math.cos, math.floor, math.max, math.min, math.sqrt

local state = {
  trees = {}, low = {}, -- spots: { x, y, z }
  flies = {}, birds = {},
  t = 0, nextFlock = 1.5, glow = 0,
}
Critters._state = state

-- gather spots from a freshly built grid (a sample: every few voxels)
function Critters.setSpots(grid, VOXEL)
  VOXEL = VOXEL or 4
  local trees, low = {}, {}
  local SW, H = grid.SW, grid.H
  if SW and H then
    local vc, vr = grid.vcols, grid.vrows
    for vy = 1, vr - 2, 3 do
      for vx = 1, vc - 2, 3 do
        local k = vy * vc + vx + 1
        if SW[k] then
          local h = H[k] or 0
          local x, y = grid.px + (vx + 0.5) * VOXEL, grid.py + (vy + 0.5) * VOXEL
          if h >= 10 then trees[#trees + 1] = { x, y, h } end
          low[#low + 1] = { x, y, h }
        end
      end
    end
  end
  state.trees, state.low = trees, low
  state.flies, state.birds = {}, {}
end

function Critters.reset()
  state.trees, state.low, state.flies, state.birds = {}, {}, {}, {}
end

local function inRect(s, rect, sx, sy)
  local x, y = s[1] + sx, s[2] + sy
  return x >= rect[1] and x <= rect[3] and y >= rect[2] and y <= rect[4]
end

-- a spot in view, preferably near the middle of it (around the player):
-- the far edge of the view is fogged, and much of it is off the top of the
-- screen once something rises above the trees
local function pick(list, rect, sx, sy, spread)
  local cx, cy = (rect[1] + rect[3]) / 2, rect[2] + (rect[4] - rect[2]) * 0.62
  local hw, hh = (rect[3] - rect[1]) * 0.3, (rect[4] - rect[2]) * 0.25
  local near = { cx - hw, cy - hh, cx + hw, cy + hh }
  local a, b = {}, {}
  for i = 1, #list do
    local s = list[i]
    if inRect(s, near, sx, sy) then a[#a + 1] = s
    elseif inRect(s, rect, sx, sy) then b[#b + 1] = s end
  end
  -- (spread: now and then anywhere in view, so fireflies fill the scene)
  if #b > 0 and (#a == 0 or (spread and random() < 0.5)) then return b[random(#b)] end
  if #a > 0 then return a[random(#a)] end
  return nil
end

-- night: 0..1 (fireflies), day: true when birds may fly (no rain),
-- rect: what the camera sees (world px), shift: mesh -> world
function Critters.update(dt, night, day, rect, sx, sy, budget)
  dt = min(dt or 1 / 60, 0.1)
  state.t = state.t + dt
  sx, sy = sx or 0, sy or 0
  budget = budget or 1
  -- fireflies: fade in with the night
  state.glow = state.glow + ((night > 0.5 and 1 or 0) - state.glow) * min(1, dt * 0.8)
  local want = floor(60 * budget * state.glow + 0.5)
  if #state.low == 0 or not rect then want = 0 end
  local flies = state.flies
  while #flies > want do flies[#flies] = nil end
  for _ = 1, 4 do
    if #flies >= want then break end
    local s = pick(state.low, rect, sx, sy, true)
    if not s then break end
    flies[#flies + 1] = { x = s[1] + (random() - 0.5) * 10, y = s[2] + (random() - 0.5) * 6,
      z = s[3] + 4 + random() * 14, ph = random() * 6.283, sp = 0.6 + random() * 0.8,
      life = 6 + random() * 10 }
  end
  for i = #flies, 1, -1 do
    local f = flies[i]
    f.life = f.life - dt
    -- a slow wander, bobbing up and down
    f.x = f.x + sin(state.t * 0.7 * f.sp + f.ph) * 6 * dt
    f.y = f.y + cos(state.t * 0.5 * f.sp + f.ph * 1.3) * 4 * dt
    f.z = f.z + sin(state.t * 1.1 * f.sp + f.ph) * 3 * dt
    if f.life <= 0 or (rect and not inRect({ f.x, f.y }, rect, sx, sy)) then table.remove(flies, i) end
  end

  -- birds: a small flock now and then, up out of a tree and away
  local birds = state.birds
  if day and #state.trees > 0 and rect then
    state.nextFlock = state.nextFlock - dt
    -- (flocks overlap: one need not have left the screen for the next)
    if state.nextFlock <= 0 and #birds < 12 then
      state.nextFlock = 3 + random() * 5
      local s = pick(state.trees, rect, sx, sy)
      if s then
        state.flocks = (state.flocks or 0) + 1
        local a = random() * 6.283
        local dx, dy = cos(a), sin(a) * 0.6
        local n = 3 + floor(random() * 3)
        for b = 1, n do
          birds[#birds + 1] = { x = s[1] + (random() - 0.5) * 12, y = s[2] + (random() - 0.5) * 8,
            z = s[3] + 2, vx = dx * (30 + random() * 8), vy = dy * (30 + random() * 8),
            vz = 9 + random() * 5, ph = random() * 6.283, delay = (b - 1) * 0.12, age = 0 }
        end
      end
    end
  end
  for i = #birds, 1, -1 do
    local b = birds[i]
    if b.delay > 0 then
      b.delay = b.delay - dt
    else
      b.age = b.age + dt
      b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
      b.z = b.z + b.vz * dt
      b.vz = max(1, b.vz - 3 * dt) -- the climb levels off
      -- gone once out of view (or after a while)
      local out = rect and (b.x + sx < rect[1] - 24 or b.x + sx > rect[3] + 24
        or b.y + sy < rect[2] - 24 or b.y + sy > rect[4] + 24)
      if b.age > 9 or b.z > 260 or out then table.remove(birds, i) end
    end
  end
end

function Critters.active() return #state.flies > 0 or #state.birds > 0 end

-- Fireflies (additive glow) and birds (dark), as two vertex lists.
-- Quads stand upright in the x-z plane, like the weather.
function Critters.build(sx, sy)
  sx, sy = sx or 0, sy or 0
  local gv, gi, gn, gni = {}, {}, 0, 0
  -- (texture coordinates over scene.lua's 16x16 round glow)
  local function quad(list, idx, n, ni, x, y, z, w, h, r, g, b, a)
    list[n + 1] = { x - w, y, z, 0, 16, 0, 0, r, g, b, a }
    list[n + 2] = { x + w, y, z, 16, 16, 0, 0, r, g, b, a }
    list[n + 3] = { x + w, y, z + h, 16, 0, 0, 0, r, g, b, a }
    list[n + 4] = { x - w, y, z + h, 0, 0, 0, 0, r, g, b, a }
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = n + 1, n + 2, n + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = n + 1, n + 3, n + 4
    return n + 4, ni + 6
  end
  for _, f in ipairs(state.flies) do
    -- a slow pulse, each on its own beat; a soft halo and a bright core
    local p = 0.5 + 0.5 * sin(state.t * 2.2 + f.ph * 3)
    local fade = min(1, f.life / 1.5) * state.glow
    local a = (0.25 + 0.75 * p) * fade
    local x, y = f.x + sx, f.y + sy
    -- (a wide soft halo and a small hot core: on a phone a single small
    -- glow vanished into the night)
    gn, gni = quad(gv, gi, gn, gni, x, y, f.z - 8, 8, 16, 0.85, 1.0, 0.3, a)
    gn, gni = quad(gv, gi, gn, gni, x, y, f.z - 3, 3, 6, 1.0, 1.0, 0.6, 1.0 * fade)
  end
  local bv, bi, bn, bni = {}, {}, 0, 0
  for _, b in ipairs(state.birds) do
    if b.delay <= 0 then
      -- a "v": two thin wings, their tips flapping up and down
      local flap = sin(state.t * 12 + b.ph) * 5
      local x, y, z = b.x + sx, b.y + sy, b.z
      local c = 0.16
      for side = -1, 1, 2 do
        bv[bn + 1] = { x, y, z, 0.5, 0.5, 0, 0, c, c, c, 1 }
        bv[bn + 2] = { x + side * 9, y, z + flap, 0.5, 0.5, 0, 0, c, c, c, 1 }
        bv[bn + 3] = { x + side * 9, y, z + flap + 2.2, 0.5, 0.5, 0, 0, c, c, c, 1 }
        bv[bn + 4] = { x, y, z + 3, 0.5, 0.5, 0, 0, c, c, c, 1 }
        bi[bni + 1], bi[bni + 2], bi[bni + 3] = bn + 1, bn + 2, bn + 3
        bi[bni + 4], bi[bni + 5], bi[bni + 6] = bn + 1, bn + 3, bn + 4
        bn, bni = bn + 4, bni + 6
      end
    end
  end
  return gv, gn, gi, gni, bv, bn, bi, bni
end

return Critters
