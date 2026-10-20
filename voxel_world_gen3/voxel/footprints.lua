-- Footprints.  Characters leave prints where the ground is soft:
--   sand    -- NPCs, followers and wild Pokemon on the move.  (The player's
--              own prints in sand the game already draws into the map.)
--   ash     -- on a map under falling volcanic ash (Route 113): everyone,
--              the player too, on any open ground.
--   wet     -- anyone just out of a puddle or shallow water leaves a few
--              dark wet prints on dry ground, drying fast.
-- Ground comes from the metatile behaviour (cells.lua: info.beh) -- the
-- same SAND / DEEP_SAND / FOOTPRINTS / PUDDLE / SHALLOW_WATER values the
-- game's own field effects test.
--
-- Characters have no identity from one frame to the next, only feet
-- positions; each is matched to the nearest one of the last frame (they
-- move a pixel or two per frame).  A print pair is laid every 8 px walked,
-- left and right foot in turn, across the direction of travel.

local Footprints = {}

local floor, sqrt, min, max, abs = math.floor, math.sqrt, math.min, math.max, math.abs

local state = { prints = {}, walkers = {}, map = nil, t = 0 }
Footprints._state = state

local LIFE = { sand = 14, ash = 18, wet = 3.5 }
local COL = {
  sand = { 0.38, 0.26, 0.15, 0.65 },
  ash = { 0.22, 0.22, 0.25, 0.72 },
  wet = { 0.16, 0.20, 0.30, 0.6 },
}
local MAXP = 360
-- feet this far from their anchor have really moved: a quarter of a cell.
-- (An NPC on Route 113, standing, read as walking 300 px a second: its
-- position flicked back and forth a pixel or three, frame after frame --
-- a step begun and taken back, over and over.  A real step goes on.)
local STEP = 4
local SPEED = 240 -- px/s: a Mach Bike
local MINGAP = 1 / 16 -- s between one character's prints (16 a second)

function Footprints.reset()
  state.prints, state.walkers = {}, {}
end

-- actors: { x, y, ground } (world px, feet); ground(x, y) -> "sand" /
-- "wet" (a wet cell: puddle, shallow water) / "ash" / "open" / nil;
-- player: the index in actors of the player (nil when unknown); ashMap:
-- volcanic ash is falling here
function Footprints.update(dt, map, actors, groundAt, player, ashMap)
  dt = min(dt or 1 / 60, 0.1)
  state.t = state.t + dt
  if map ~= state.map then
    state.map = map
    Footprints.reset()
  end
  -- match each character to last frame's nearest one
  local old = state.walkers
  local used = {}
  local walkers = {}
  local byId = {}
  for j, w in ipairs(old) do if w.id ~= nil then byId[w.id] = j end end
  for i, a in ipairs(actors) do
    local best, bd
    -- a character the game names (its object) is followed by that name
    if a.id ~= nil then best = byId[a.id]; if best and used[best] then best = nil end end
    for j, w in ipairs(a.id == nil and old or {}) do
      if not used[j] and w.id == nil then
        local dx, dy = a.x - w.x, a.y - w.y
        local d = dx * dx + dy * dy
        if d <= 36 and (not bd or d < bd) then best, bd = j, d end
      end
    end
    local w
    if best then
      used[best] = true
      local o = old[best]
      w = { id = a.id, x = a.x, y = a.y, ax = o.ax, ay = o.ay, dist = o.dist, foot = o.foot, wet = o.wet,
        at = o.at, path = o.path, moving = a.moving, lastPrint = o.lastPrint }
      -- Distance is counted from an anchor, only once the feet are a whole
      -- step away from it.  While the camera glides, everyone's position
      -- wobbles by a fraction of a pixel from frame to frame (the flat view
      -- is drawn at whole pixels); summed frame by frame, that wobble walked
      -- every NPC standing on Route 113's ash a print pair every second or
      -- two and filled the 360 at once.
      local dx, dy = a.x - o.ax, a.y - o.ay
      local step = sqrt(dx * dx + dy * dy)
      if step >= 12 then
        w.ax, w.ay = a.x, a.y -- teleported (or a mismatch): start over
      elseif step >= STEP and a.moving == false then
        w.ax, w.ay = a.x, a.y -- standing (the game says so): no steps
      elseif step >= STEP then
        w.ax, w.ay = a.x, a.y
        -- nobody walks faster than a Mach Bike (4 px a game frame): a jump
        -- in position beyond that since the last count is not walking
        local since = state.t - (o.at or state.t)
        w.at = state.t
        local counted = min(step, SPEED * since + STEP)
        w.dist = w.dist + counted
        w.path = (w.path or 0) + counted
        local g = groundAt(a.x, a.y)
        if g == "wet" then w.wet = 1.6 end
        -- (and at most 16 prints a second, a fast bike's pace)
        -- (on a bike: one tire track, a dash every 4 px, not a pair of feet)
        local every = a.bike and 4 or 8
        if w.dist >= every and state.t - (o.lastPrint or -1) >= (a.bike and 1 / 60 or MINGAP) then
          w.dist = min(w.dist - every, every)
          w.lastPrint = state.t
          local kind
          if g == "sand" and i ~= player then kind = "sand"
          elseif ashMap and (g == "open" or g == "sand") then kind = "ash"
          elseif w.wet and w.wet > 0 and g ~= "wet" and g ~= nil then kind = "wet" end
          if kind then
            -- across the direction of travel, a foot to each side
            local nx, ny = -dy / step, dx / step
            local side = a.bike and 0 or (w.foot and 1 or -1)
            w.foot = not w.foot
            state.laid = (state.laid or 0) + 1
            state.prints[#state.prints + 1] = { x = a.x + nx * side * 2.2, y = a.y - 1 + ny * side * 2.2,
              z = a.ground or 0, ax = dx / step, ay = dy / step, kind = kind, age = 0, life = LIFE[kind],
              tire = a.bike or nil }
          end
        end
      end
    else
      w = { id = a.id, x = a.x, y = a.y, ax = a.x, ay = a.y, dist = 0, foot = false, at = state.t, path = 0,
        moving = a.moving }
    end
    if w.wet then
      w.wet = w.wet - dt
      if w.wet <= 0 then w.wet = nil end
    end
    walkers[#walkers + 1] = w
  end
  state.walkers = walkers
  -- prints laid in the last second (PERF STATS)
  state.acc = (state.acc or 0) + dt
  if state.acc >= 1 then
    state.rate, state.acc, state.laid = state.laid or 0, 0, 0
    -- (PERF STATS) who walked furthest in that second
    local top
    for _, w in ipairs(walkers) do
      if not top or (w.path or 0) > (top.path or 0) then top = w end
    end
    state.top = top and { id = top.id, path = top.path or 0, moving = top.moving, x = top.x, y = top.y } or nil
    for _, w in ipairs(walkers) do w.path = 0 end
  end
  local prints = state.prints
  for i = #prints, 1, -1 do
    local p = prints[i]
    p.age = p.age + dt
    if p.age >= p.life then table.remove(prints, i) end
  end
  while #prints > MAXP do table.remove(prints, 1) end
end

-- flat quads on the ground, each a small oval along the direction of
-- travel (texture coordinates over scene.lua's 8x8 print texture)
function Footprints.build()
  local v, idx, n, ni = {}, {}, 0, 0
  for _, p in ipairs(state.prints) do
    local c = COL[p.kind]
    local k = p.age / p.life
    local a = c[4] * (k < 0.6 and 1 or (1 - k) / 0.4)
    -- 4.4 px long, 2.8 wide, along (ax, ay) (smaller vanished on a phone)
    -- (a tire track: 5.6 px dashes, 1.8 wide, end to end)
    local hl, hw = p.tire and 2.8 or 2.2, p.tire and 0.9 or 1.4
    local lx, ly = p.ax * hl, p.ay * hl
    local wx, wy = -p.ay * hw, p.ax * hw
    local z = p.z + 0.3
    v[n + 1] = { p.x - lx - wx, p.y - ly - wy, z, 0, 0, 0, 0, c[1], c[2], c[3], a }
    v[n + 2] = { p.x - lx + wx, p.y - ly + wy, z, 8, 0, 0, 0, c[1], c[2], c[3], a }
    v[n + 3] = { p.x + lx + wx, p.y + ly + wy, z, 8, 8, 0, 0, c[1], c[2], c[3], a }
    v[n + 4] = { p.x + lx - wx, p.y + ly - wy, z, 0, 8, 0, 0, c[1], c[2], c[3], a }
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = n + 1, n + 2, n + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = n + 1, n + 3, n + 4
    n, ni = n + 4, ni + 6
  end
  return v, n, idx, ni
end

return Footprints
