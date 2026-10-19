-- Day and night for the outdoor diorama.
--
-- The hour comes from the game's own clock in Ruby/Sapphire/Emerald (the
-- real-time clock the player set, the one berries and tides follow) and
-- from the device's clock in FireRed/LeafGreen, which have none.
--
-- From it: where the sun is (which way and how far shadows fall), whether
-- there is sun at all, a colour the whole scene is lit with, and the sky.
-- Everything is a smooth blend between a few keyframes, so a sunset fades
-- in over an hour rather than switching.

local DayNight = {}

local floor = math.floor

-- keyframes: hour -> scene tint, how much colour is taken out first
-- (desat: moonlight washes colours out, it does not paint them blue --
-- blue over brown rock read as purple), sky top, sky bottom
local NIGHT = { tint = { 0.50, 0.58, 0.80 }, desat = 0.65, top = { 0.03, 0.05, 0.14 }, bottom = { 0.09, 0.12, 0.24 } }
local DAWN = { tint = { 1.00, 0.84, 0.74 }, desat = 0.10, top = { 0.42, 0.52, 0.84 }, bottom = { 1.00, 0.80, 0.68 } }
local DAY = { tint = { 1.00, 1.00, 1.00 }, desat = 0.00, top = { 0.52, 0.76, 0.96 }, bottom = { 0.86, 0.93, 0.99 } }
local DUSK = { tint = { 1.00, 0.76, 0.58 }, desat = 0.10, top = { 0.34, 0.40, 0.70 }, bottom = { 1.00, 0.66, 0.46 } }

local KEYS = {
  { 0, NIGHT }, { 4.5, NIGHT }, { 6, DAWN }, { 8, DAY },
  { 16.5, DAY }, { 18.5, DUSK }, { 20, NIGHT }, { 24, NIGHT },
}
DayNight.KEYS = KEYS

-- the sun is up (and casts shadows) between these hours
DayNight.SUNRISE, DayNight.SUNSET = 5.5, 19.5

local function lerp3(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

-- hour: 0..24 (fractional)
function DayNight.at(hour)
  hour = (tonumber(hour) or 12) % 24
  local a, b = KEYS[1], KEYS[#KEYS]
  for i = 1, #KEYS - 1 do
    if hour >= KEYS[i][1] and hour <= KEYS[i + 1][1] then
      a, b = KEYS[i], KEYS[i + 1]
      break
    end
  end
  local span = b[1] - a[1]
  local t = span > 0 and (hour - a[1]) / span or 0
  -- ease in and out, so a blend does not start or stop with a jolt
  t = t * t * (3 - 2 * t)
  local out = {
    hour = hour,
    tint = lerp3(a[2].tint, b[2].tint, t),
    desat = a[2].desat + (b[2].desat - a[2].desat) * t,
    skyTop = lerp3(a[2].top, b[2].top, t),
    skyBottom = lerp3(a[2].bottom, b[2].bottom, t),
  }
  -- the sun: rises in the east, sets in the west, always a little to the
  -- south of overhead so shadows lean toward the camera where they show.
  -- Shadows point away from it and grow long at the ends of the day.
  local up = hour > DayNight.SUNRISE and hour < DayNight.SUNSET
  out.sun = up
  if up then
    local mid = (DayNight.SUNRISE + DayNight.SUNSET) / 2
    local half = (DayNight.SUNSET - DayNight.SUNRISE) / 2
    local a2 = (hour - mid) / half -- -1 sunrise .. 0 noon .. 1 sunset
    local long = 1 + 0.9 * a2 * a2
    -- morning: sun in the east, shadows fall west (negative x)
    out.sunX = 0.85 * a2 * long
    out.sunY = 0.42 * long
    -- keep a ray step finite: the bake marches along x
    if math.abs(out.sunX) < 0.18 then out.sunX = out.sunX < 0 and -0.18 or 0.18 end
  end
  return out
end

-- The sun moves in steps (each one is a new light bake, done in the
-- background): every half hour while it is up, and one "night" step.
function DayNight.sunKey(hour)
  local s = DayNight.at(hour)
  if not s.sun then return "night" end
  return tostring(floor(((tonumber(hour) or 12) % 24) * 2))
end

-- The sun direction of a step (its middle), so the bake is the same for
-- every frame within it.
function DayNight.sunOf(key)
  if key == "night" then return nil end
  local s = DayNight.at((tonumber(key) or 24) / 2 + 0.25)
  return s.sun and s or nil
end

-- The current hour.
--   mode "game":   the game clock (RSE), the device clock where there is none
--   mode "device": the device clock
--   mode "noon" / a number: fixed (tests, OFF)
function DayNight.hour(mode, Engine)
  if type(mode) == "number" then return mode end
  if mode == "noon" then return 12 end
  if mode == "game" and Engine then
    local Rtc = Engine.get and Engine.get("src.core.game3.rtc")
    local Runtime = Engine.get and Engine.get("src.core.game3.runtime")
    local Family = Engine.get and Engine.get("src.import.gba.family")
    local fam
    if Family and Family.active then
      local ok, f = pcall(Family.active)
      fam = ok and type(f) == "table" and f.name or nil
    end
    if fam ~= "frlg" and Rtc and Rtc.calcLocalTime then
      local session = Runtime and Runtime.getSession and Runtime.getSession()
      local ok, t = pcall(Rtc.calcLocalTime, session)
      if ok and type(t) == "table" and t.hours then
        return ((t.hours or 0) + (t.minutes or 0) / 60) % 24
      end
    end
  end
  local d = os.date("*t")
  return (d.hour + d.min / 60) % 24
end

return DayNight
