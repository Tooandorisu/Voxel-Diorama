-- Weather that falls through the 3D scene.
--
-- The game draws rain, snow and ash as flat sprites over the screen.  Baked
-- into the map the 3D view is built from, they ran down walls and roofs like
-- paint.  Instead the 3D view hides them (bridge.lua) and lets its own
-- particles fall in the world: thin streaks for rain, slow flakes for snow,
-- grey flecks for Mt. Chimney's ash -- in front of and behind buildings,
-- hidden by what stands in front of them, lit by the time of day.
--
-- Particles live in world pixels around the camera's view; each frame they
-- move, and whatever reached the ground starts again at the top somewhere
-- else in view.

local W3 = {}

local random, sin, floor, max, min = math.random, math.sin, math.floor, math.max, math.min

-- game weather id (src/core/game3/weather.lua) -> kind
local KIND = {
  [3] = "rain",       -- RAIN
  [4] = "snow",       -- SNOW
  [5] = "storm",      -- RAIN_THUNDERSTORM
  [7] = "ash",        -- VOLCANIC_ASH
  [13] = "downpour",  -- DOWNPOUR
}
function W3.kindOf(id) return KIND[tonumber(id) or -1] end

-- per kind: particle count, fall speed (px/s), sideways drift, streak
-- length, width, colour, alpha, scene tint
local SPEC = {
  rain = { n = 480, fall = 300, drift = -50, len = 14, w = 1.2, col = { 0.80, 0.88, 1.0 }, a = 0.65,
           tint = { 0.80, 0.83, 0.92 } },
  storm = { n = 620, fall = 340, drift = -70, len = 16, w = 1.2, col = { 0.78, 0.86, 1.0 }, a = 0.6,
            tint = { 0.70, 0.73, 0.85 } },
  downpour = { n = 800, fall = 380, drift = -80, len = 18, w = 1.3, col = { 0.80, 0.88, 1.0 }, a = 0.6,
               tint = { 0.66, 0.70, 0.82 } },
  snow = { n = 260, fall = 26, drift = 6, len = 3.5, w = 3.5, col = { 1.0, 1.0, 1.0 }, a = 0.95,
           tint = { 0.96, 0.98, 1.04 }, sway = 10 },
  -- ash: big pale flakes, plenty of them -- small grey specks vanished
  -- against the ash-covered ground, above all at night
  ash = { n = 380, fall = 22, drift = 12, len = 4.0, w = 4.0, col = { 0.88, 0.86, 0.82 }, a = 1.0,
          tint = { 0.90, 0.88, 0.84 }, sway = 8 },
}
W3.SPEC = SPEC

local TOP = 150 -- px above the ground where particles start

local state = { kind = nil, parts = {}, level = 0, t = 0, flash = 0, nextFlash = 8 }
W3._state = state

local function spawn(p, rect, s, anywhere)
  p.x = rect[1] + random() * (rect[3] - rect[1])
  p.y = rect[2] + random() * (rect[4] - rect[2])
  p.z = anywhere and random() * TOP or (TOP * (0.8 + random() * 0.4))
  p.ph = random() * 6.283
  p.v = 0.85 + random() * 0.3
end

-- kind: nil for none.  rect: the visible ground {x1, y1, x2, y2}.
-- scale: 0..1 particle budget (lower on slow devices).
function W3.update(dt, kind, rect, scale)
  dt = min(dt or 1 / 60, 0.1)
  state.t = state.t + dt
  -- fade in over two seconds, out over one: the game's own rain starts and
  -- stops gradually too
  if kind then
    if kind ~= state.kind then
      state.kind, state.parts, state.level = kind, {}, (state.kind and state.level or 0)
    end
    state.level = min(1, state.level + dt / 2)
  else
    state.level = max(0, state.level - dt)
    if state.level == 0 then state.kind, state.parts = nil, {} end
  end
  local k = state.kind
  if not k or not rect then return end
  local s = SPEC[k]
  local want = floor(s.n * (scale or 1) * state.level + 0.5)
  local parts = state.parts
  while #parts < want do
    local p = {}
    spawn(p, rect, s, true)
    parts[#parts + 1] = p
  end
  while #parts > want do parts[#parts] = nil end
  local w = rect[3] - rect[1]
  local h = rect[4] - rect[2]
  for i = 1, #parts do
    local p = parts[i]
    p.z = p.z - s.fall * p.v * dt
    p.x = p.x + s.drift * dt
    if p.z <= 0 then
      spawn(p, rect, s, false)
    elseif p.x < rect[1] - 8 or p.x > rect[3] + 8 or p.y < rect[2] - 8 or p.y > rect[4] + 8 then
      -- the view moved on: wrap around into it
      p.x = rect[1] + (p.x - rect[1]) % max(1, w)
      p.y = rect[2] + (p.y - rect[2]) % max(1, h)
    end
  end
  -- thunderstorm: now and then a double flash of lightning
  if k == "storm" then
    state.nextFlash = state.nextFlash - dt
    if state.nextFlash <= 0 then
      state.flash, state.nextFlash = 0.35, 6 + random() * 9
    end
  end
  state.flash = max(0, state.flash - dt)
end

-- the colour the scene is lit with under this weather (times the day's)
function W3.tint()
  local k = state.kind
  if not k then return nil end
  local t = SPEC[k].tint
  local l = state.level
  local r, g, b = 1 + (t[1] - 1) * l, 1 + (t[2] - 1) * l, 1 + (t[3] - 1) * l
  -- lightning: two quick bright pulses
  local f = state.flash
  if f > 0 then
    local pulse = (f > 0.25 or (f > 0.08 and f < 0.15)) and 1.7 or 1
    r, g, b = r * pulse, g * pulse, b * pulse
  end
  return { r, g, b }
end

function W3.active() return state.kind ~= nil and #state.parts > 0 end

-- Quads in the x-z plane (they face the north-looking camera), in the
-- mesher's vertex layout; the texture is a plain white pixel.
function W3.build()
  local k = state.kind
  local verts, idx, nv, ni = {}, {}, 0, 0
  if not k then return verts, 0, idx, 0 end
  local s = SPEC[k]
  local c = s.col
  local a = s.a
  local hw = s.w / 2
  local len = s.len
  local slant = (s.drift / max(1, s.fall)) * len
  -- rain streaks fade toward their tail; flakes are solid
  local topA = s.sway and a or a * 0.4
  for i = 1, #state.parts do
    local p = state.parts[i]
    local x = p.x
    if s.sway then x = x + sin(state.t * 1.3 + p.ph) * s.sway * 0.3 end
    local z0, z1 = p.z, p.z + len
    local x0, x1 = x, x - slant
    local b = nv
    verts[b + 1] = { x0 - hw, p.y, z0, 0.5, 0.5, 0, 0, c[1], c[2], c[3], a }
    verts[b + 2] = { x0 + hw, p.y, z0, 0.5, 0.5, 0, 0, c[1], c[2], c[3], a }
    verts[b + 3] = { x1 + hw, p.y, z1, 0.5, 0.5, 0, 0, c[1], c[2], c[3], topA }
    verts[b + 4] = { x1 - hw, p.y, z1, 0.5, 0.5, 0, 0, c[1], c[2], c[3], topA }
    nv = nv + 4
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = b + 1, b + 2, b + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = b + 1, b + 3, b + 4
    ni = ni + 6
  end
  return verts, nv, idx, ni
end

function W3.reset()
  state.kind, state.parts, state.level, state.flash = nil, {}, 0, 0
end

return W3
