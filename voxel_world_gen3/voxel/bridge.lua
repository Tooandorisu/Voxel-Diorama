-- Engine side: where the voxel world plugs into the Gen 3 field draw.
--
-- Gen 3 does not composite render_pipelines' drawWorld (the registry has no
-- Gen 3 target, src/mods/Schemas.lua GEN3), so this does by hand what
-- src/world/OverworldController.lua does for Gen 1, at the two seams the
-- Gen 3 frame already has:
--
--   1. FieldView.draw, called by display.lua's drawFieldPlane while the
--      Renderer's world canvas is the target.  Instead of drawing the flat
--      field there, the field is drawn twice into our own canvases: once
--      without characters (the texture every voxel samples) and once with
--      characters only, each one moved into its own slot of an atlas by
--      borrowing the billboard hook Tilt mode already uses
--      (FieldView's pushBillboard -> Tilt.groundPoint).  The world canvas
--      itself is left transparent, so the OAM field sprites drawFieldPlane
--      flushes after us land on it alone.
--   2. Renderer:endWorldPass, right after those OAM sprites.  The scene is
--      rendered at window resolution and handed to Renderer:setWorldOverride,
--      the exact seam the Gen 1 pipeline uses, so the UI plane, fades and
--      ShaderFX all composite on top unchanged.
--
-- Anything that goes wrong falls back to the vanilla flat frame for that
-- frame; three failures in a row switch the mode off for the session.

local use = ...
local HF = use("heightfield")
local Mesher = use("mesher")
local Camera = use("camera")
local Scene = use("scene")
local Cells = use("cells")
local Engine = use("engine")
local Lighting = use("lighting")
local DayNight = use("daynight")
local Weather3D = use("weather3d")
local Critters = use("critters")
local Smoke = use("smoke")
local Footprints = use("footprints")
Smoke.init(HF)

local Bridge = {}

local CELL = 16
-- what a fully shadowed top is multiplied by: a cool, sky-lit shade
local SHADOW_TINT = { 0.58, 0.62, 0.76 }
-- indoors a room's shadows are its own colour dimmed, not sky-blue
local ROOM_SHADOW = { 0.72, 0.68, 0.66 }
-- slots are wide enough for the biggest field sprites (the S.S. Anne is
-- drawn from its left end, so it needs 96px+ to the right of its anchor)
local SLOT_W, SLOT_H, FOOT_X, FOOT_Y = 160, 96, 48, 80
local SLOT_COLS, SLOT_ROWS = 12, 4
-- feet anchor 4px north of the cell's south edge: in front of a facade the
-- character's cell touches, behind one it is standing inside (a doorway)
local FOOT_INSET = 4
-- how far north of the player is ever meshed comes from the quality preset
local REBUILD_SLACK = 5 -- cells of margin around what the camera needs

Bridge.PITCH = { 0, 30, 45, 55 } -- OFF, LOW, MID, HIGH

local settings = {
  level = 2, -- index into PITCH minus one: 0 = OFF
  heightScale = 1,
  lumps = true,
  shadows = true,
  indoorZoom = "fit",
  zoom = 1,
  xray = true,
  rate = "auto", -- auto | full | half: how often the 3D scene is redrawn
  perf = false,
  resolution = "auto", -- auto | full | half | pixel
  quality = "auto", -- auto | high | balanced | potato
  sunShadows = true, -- baked sun shadows + ambient occlusion on the terrain
  blur = true, -- soften the far distance (top of the screen)
  roundTrees = true, -- rounded crowns instead of flat-topped tree blocks
  roofs = true, -- gable roofs on buildings (outdoors)
  solid = 3, -- character body depth in px (0 = flat cards)
  daynight = "game", -- game (RSE clock, device clock in FRLG) | device | off
  weather3d = true, -- rain, snow and ash fall through the 3D scene
  breath = "subtle", -- off | subtle | normal: characters breathe
  blink = true, -- characters blink
  nightlights = true, -- lamps, doorways and windows light up at night
  reflect = true, -- water mirrors what stands beside it
  sway = true, -- trees and tall grass move in the wind
  critters = true, -- fireflies at night, birds by day
  smoke = true, -- chimneys on houses, smoke rising from them
  footprints = true, -- prints in sand and ash, wet prints out of puddles
  clouds = true, -- cloud shadows drifting over the ground, clouds and stars in the sky
  waves = true, -- foam along shores, waves rolling in, a wake behind swimmers
  yaw = 0, -- camera turn in degrees (+ = swing east / RIGHT, - = west / LEFT)
  fov = 30,
}

local state = {
  installed = false,
  failures = 0,
  disabled = false,
  pitch = 0,
  fz = nil,
  lastMap = nil,
  bigW = 0, bigH = 0,
  ground = nil, atlas = nil, lowres = nil, final = nil,
  grid = nil, built = nil,
  pending = nil,
  focusX = nil, focusY = nil,
}

local log = function() end

-- ------- quality presets
--
--   budget  pixels the 3D pass renders at under VOXEL RES AUTO (upscaled)
--   blk     voxels that share one leaf/rock bump (2 = 8px, 4 = a whole cell)
--   step    px the bumps snap to (4 = three heights): fine relief costs
--           ~100x the vertices of none, coarse relief ~6x
--   view    px north of the player that is meshed and captured
--   half    redraw the 3D scene every other frame (the game runs every frame)
local PRESETS = {
  high = { name = "HIGH", budget = 2.0e6, blk = 2, step = 2, view = 560, round = "full" },
  balanced = { name = "BAL", budget = 1.0e6, blk = 2, step = 4, view = 560, round = "soft" },
  potato = { name = "POTATO", budget = 0.35e6, blk = 4, step = 4, view = 420, half = true, blur = false },
}
-- AUTO starts balanced and steps down while the frame rate stays low
local AUTO_TIERS = {
  [0] = { name = "AUTO", budget = 1.0e6, blk = 2, step = 4, view = 560, round = "soft" },
  { name = "AUTO-1", budget = 0.7e6, blk = 2, step = 4, view = 560, round = "soft" },
  { name = "AUTO-2", budget = 0.5e6, blk = 2, step = 4, view = 500, half = true, round = "ridge" },
  { name = "AUTO-3", budget = 0.35e6, blk = 4, step = 4, view = 420, half = true, blur = false },
}
Bridge.PRESETS, Bridge.AUTO_TIERS = PRESETS, AUTO_TIERS

local function preset()
  if settings.quality == "auto" then
    return AUTO_TIERS[state.autoTier or 0] or AUTO_TIERS[0]
  end
  return PRESETS[settings.quality] or PRESETS.balanced
end
Bridge.preset = preset

local function roundOf(q)
  return settings.roundTrees and q.round or nil
end

local function reliefKey(q)
  local r = tostring(roundOf(q))
  if not settings.lumps then return "off:" .. r end
  return q.blk .. ":" .. q.step .. ":" .. r
end

function Bridge.setLogger(fn) log = fn or log end

function Bridge.configure(opts)
  for k, v in pairs(opts or {}) do settings[k] = v end
end

function Bridge.settings() return settings end

function Bridge.level() return settings.level end

function Bridge.setLevel(level)
  level = math.floor(tonumber(level) or 0)
  if level < 0 then level = 0 end
  if level > #Bridge.PITCH - 1 then level = #Bridge.PITCH - 1 end
  if level ~= settings.level then state.announced = false end
  settings.level = level
  if level > 0 then
    state.disabled = false
    state.failures = 0
  end
  return level
end

function Bridge.cycle()
  return Bridge.setLevel((settings.level + 1) % #Bridge.PITCH)
end

local function targetPitch()
  return Bridge.PITCH[settings.level + 1] or 0
end

-- ------- small helpers

local function canvas(w, h, filter)
  local c = love.graphics.newCanvas(w, h, { dpiscale = 1 })
  c:setFilter(filter or "nearest", filter or "nearest")
  return c
end

local function ensure(key, w, h, filter)
  local c = state[key]
  if c and c:getWidth() == w and c:getHeight() == h then return c end
  if c then c:release() end
  c = canvas(w, h, filter)
  state[key] = c
  return c
end

local function roundUp(v, step) return math.ceil(v / step) * step end

-- Outdoors gets a sky, everything else (houses, caves, gyms) a black void.
-- mapType is the cart's own answer (pret map_types.h: 1 town, 2 city,
-- 3 route, 5 underwater, 6 ocean route); `kind` defaults to "town" whenever
-- the importer did not derive it, so it is only the fallback.
local OUTDOOR_TYPES = { [1] = true, [2] = true, [3] = true, [5] = true, [6] = true }

-- Never outdoors: underground (caves, however big their lakes) and secret
-- bases.  "Indoor" (8) is what the cart calls the S.S. Anne harbour too, so
-- an indoor map can still be promoted -- but only when most of it is open
-- water or grass.
local INDOOR_TYPES = { [4] = true, [9] = true }

-- Maps whose type says neither (0 none, 7 unknown -- the S.S. Anne harbour
-- is one) are judged by their own ground: a map with a fair share of sea or
-- tall grass is outdoors.  Counted once per map.
local wetCache = setmetatable({}, { __mode = "k" })
local function looksOutdoor(def)
  local L = def and def.midLayout
  if not (L and L.collAt and L.width and L.height) then return nil end
  local hit = wetCache[def]
  if hit ~= nil then return hit end
  local w, h = L.trueWidth or L.width, L.trueHeight or L.height
  local n, wet = 0, 0
  for y = 0, h - 1, 2 do
    for x = 0, w - 1, 2 do
      local ok, c = pcall(L.collAt, L, x, y)
      if ok and c then
        n = n + 1
        if c == 0x29 or c == 0x18 or c == 0x14 then wet = wet + 1 end
      end
    end
  end
  hit = n > 0 and wet / n or 0
  wetCache[def] = hit
  return hit
end
Bridge._looksOutdoor = looksOutdoor

local function isOutdoor(def)
  if not def then return true end
  local t = tonumber(def.mapType)
  if t and OUTDOOR_TYPES[t] then return true end
  if t and INDOOR_TYPES[t] then return false end
  -- the ground can only promote a map to outdoors, never demote one; a map
  -- that calls itself indoor needs to be at least half sea or grass (the
  -- Cerulean Gym pool is not)
  local wet = looksOutdoor(def) or 0
  if wet >= ((t == 8) and 0.5 or 0.08) then return true end
  if t and t > 0 then return false end
  if def.environment and def.environment ~= "TOWN" and def.environment ~= "ROUTE" then return false end
  return def.kind == "route" or def.kind == "town" or def.kind == nil
end
Bridge.isOutdoor = isOutdoor

-- the time of day outdoors (daynight.lua), read at most once a second;
-- nil indoors and with DAY/NIGHT off (plain noon)
local dnCache = { t = -1 }
local function dayNight(def)
  if not isOutdoor(def) or settings.daynight == "off" then return nil end
  local t = love.timer and love.timer.getTime() or os.clock()
  if t - dnCache.t >= 1 or dnCache.mode ~= settings.daynight then
    dnCache.t, dnCache.mode = t, settings.daynight
    local ok, h = pcall(DayNight.hour, settings.daynight, Engine)
    dnCache.hour = ok and h or 12
    dnCache.at = DayNight.at(dnCache.hour)
    dnCache.key = DayNight.sunKey(dnCache.hour)
  end
  return dnCache.at, dnCache.key
end
Bridge.dayNight = dayNight

local function sunKeyFor(def)
  local _, key = dayNight(def)
  return key or "noon"
end

-- the game's current weather, as a kind weather3d.lua draws (nil: none, or
-- a weather the game's own overlay keeps drawing -- fog, sandstorm, shade)
local function weatherKind(def)
  if not settings.weather3d or not isOutdoor(def) then return nil end
  local FW = Engine.get("src.core.game3.field_weather")
  if not (FW and FW.getWeather) then return nil end
  local ok, id = pcall(FW.getWeather)
  return ok and Weather3D.kindOf(id) or nil
end
Bridge.weatherKind = weatherKind

-- Wind for the swaying foliage (scene.lua), in pixels at a tree's top: a
-- breeze on a fair day, more in rain, a gale in a storm.  Outdoors only.
local WIND = { rain = 1.5, storm = 2.4, downpour = 2.4, snow = 1.0, ash = 0.7 }
function Bridge.windFor(def)
  if settings.sway == false or not isOutdoor(def) then return 0 end
  local FW = Engine.get("src.core.game3.field_weather")
  local kind
  if FW and FW.getWeather then
    local ok, id = pcall(FW.getWeather)
    kind = ok and Weather3D.kindOf(id) or nil
  end
  return WIND[kind] or 0.9
end

local function skyFor(def)
  if isOutdoor(def) then
    local dn = dayNight(def)
    if dn then return dn.skyTop, dn.skyBottom end
    return { 0.52, 0.76, 0.96 }, { 0.86, 0.93, 0.99 }
  end
  return { 0, 0, 0 }, { 0, 0, 0 }
end

local function mods()
  return {
    FieldView = Engine.get("src.core.game3.field_view"),
    Renderer = Engine.get("src.render.Renderer"),
    Tilt = Engine.get("src.render.Tilt"),
    Zoom = Engine.get("src.render.Zoom"),
  }
end

-- ------- gating

-- A frame that cannot be drawn in 3D right after one that was (the frame a
-- route hands over to the next map, a map not loaded yet for a moment):
-- show the last 3D picture again instead of the flat map or an empty
-- world canvas -- the "blink" at every route border.
local HOLD_SECONDS = 0.5
local function canHold(R)
  return state.final ~= nil and state.lastShownT ~= nil
    and (love.timer.getTime() - state.lastShownT) < HOLD_SECONDS
    and R ~= nil and R.setWorldOverride ~= nil
end

local function blockingState()
  local T = Engine.get("src.core.game3.battle_transition")
  if T and T.isActive and T.isActive() then return "transition" end
  local Shop = Engine.get("src.ui.game3.shop_menu")
  if Shop and Shop.isShopCamera and Shop.isShopCamera() then return "shop" end
  local Sea = Engine.get("src.ui.game3.seagallop")
  if Sea and Sea.isActive and Sea.isActive() then return "seagallop" end
  return nil
end

function Bridge.active()
  if state.disabled then return false end
  return settings.level > 0 or state.pitch > 0.5
end

-- ------- status: why the view is or is not drawing, shown to the player
-- (a phone has no console) and filed in the mod manager's error feed

local toast = { text = nil, untilT = 0 }
local lastReason = nil
local reported = {}
local reporter = nil

function Bridge.setReporter(fn) reporter = fn end

local function now() return love.timer and love.timer.getTime() or os.clock() end

function Bridge.toast(text, seconds)
  toast.text = text
  toast.untilT = now() + (seconds or 4)
end

-- reasons that mean "cannot run on this device" rather than "not now"
local HARD = { shader = true, depth = true, mesh = true }

local function setReason(reason, detail)
  if reason == lastReason then return end
  lastReason = reason
  if reason and HARD[reason] then
    local msg = "VOXEL VIEW unavailable: " .. tostring(detail or reason)
    Bridge.toast(msg, 10)
    log("error", "%s", msg)
    if reporter and not reported[reason] then
      reported[reason] = true
      pcall(reporter, msg)
    end
  end
end

local function worldTarget(R)
  return (R and R.worldCanvas) or state.worldTarget
end

local function decide(opts)
  if not Bridge.active() then return false, "mode is OFF" end
  if opts and (opts.actorsOnly or opts.billboard) then return false, "second tilt pass" end
  local R = mods().Renderer
  if not R then return false, "renderer module not loaded" end
  -- only the call display.lua makes between beginWorldPass/endWorldPass is
  -- the world pass (the shop camera draws the field into the UI plane)
  if not state.inWorld then return false, "no world pass on this screen" end
  if not worldTarget(R) then return false, "renderer has no world canvas" end
  local block = blockingState()
  if block then return false, block end
  local ok, why, detail = Scene.available()
  if not ok then
    setReason(why or "shader", detail)
    return false, detail or why or "scene unavailable"
  end
  setReason(nil)
  return true
end

local function wantsFrame(opts)
  local ok, why = decide(opts)
  if not ok and not (opts and (opts.actorsOnly or opts.billboard)) then state.why = why end
  return ok
end

local function fail(where, err)
  state.failures = state.failures + 1
  state.pending = nil
  log("error", "%s failed: %s", where, tostring(err))
  local text = tostring(err):gsub("%s+", " ")
  if #text > 180 then text = text:sub(1, 180) .. "..." end
  state.lastError = where .. ": " .. text
  Bridge.toast("VOXEL VIEW error (" .. state.lastError .. ")", 10)
  if reporter then pcall(reporter, "VOXEL VIEW error (" .. state.lastError .. ")") end
  if state.failures >= 3 then
    state.disabled = true
    Bridge.toast("VOXEL VIEW stopped after 3 errors. Last: " .. state.lastError, 15)
    log("error", "voxel world switched off for this session after repeated errors")
  end
end

-- ------- frame capture (inside FieldView.draw)

-- the camera FieldView picks for a canvas this size, read off the first
-- module call that is handed it (both run every frame on the ground pass)
local function withCameraCapture(fn)
  local FE = Engine.get("src.core.game3.field_effects")
  local Doors = Engine.get("src.core.game3.doors")
  local cam = {}
  local restore = {}
  local function spy(mod, key)
    if type(mod) ~= "table" or type(mod[key]) ~= "function" then return end
    local orig = mod[key]
    restore[#restore + 1] = function() mod[key] = orig end
    mod[key] = function(camX, camY, ...)
      if cam.x == nil and type(camX) == "number" and type(camY) == "number" then
        cam.x, cam.y = camX, camY
      end
      return orig(camX, camY, ...)
    end
  end
  spy(FE, "drawBehind")
  spy(Doors, "draw")
  local ok, err = pcall(fn)
  for i = #restore, 1, -1 do restore[i]() end
  if not ok then error(err, 0) end
  return cam.x, cam.y
end

local function playerFocus()
  local P = Engine.get("src.core.game3.player")
  if P and type(P.px) == "number" then return P.px + CELL / 2, P.py + CELL / 2 end
  return nil
end

-- Indoors, a small room otherwise sits in the middle of a phone screen
-- the size of a stamp.  INDOOR ZOOM "fit" brings the camera in until the
-- room fills the width (or height), never past 3x and never out.
function Bridge.indoorZoom(pw, ph, scale)
  if settings.indoorZoom == "off" then return 1 end
  local Map = Engine.get("src.core.game3.map")
  local def = Map and Map.currentDef and Map.currentDef()
  if not def or isOutdoor(def) then return 1 end
  local L = def.midLayout
  local w = L and (L.trueWidth or L.width)
  local h = L and (L.trueHeight or L.height)
  if not (w and h and w > 0 and h > 0) then return 1 end
  local zw = (pw * 0.94) / (w * 16 * scale)
  -- the floor is foreshortened by the tilt, so it takes less height
  local zh = (ph * 0.85) / (h * 16 * scale * math.max(0.55, math.cos(math.rad(state.pitch))))
  local z = math.min(zw, zh)
  if z < 1 then z = 1 end
  if z > 3 then z = 3 end
  return z
end

-- Street lamps (heightfield.lua) are learned by metatile per map: every
-- lamp in a town is the same tile, and one seen clearly enough by its art
-- lights them all.  What is learned is kept in the mod's installation cache,
-- so a town's lamps are lit from the first frame next time, not only once
-- a rebuild happens to line its quarter-size art up with a thin post.
local LAMP_FILE = "lamps/v2.txt"
local lampCache, lampStore, lampDirty, lampCount = nil, nil, false, 0
local otherTypes = {}
function Bridge.setCache(cache) lampCache = cache end

local function lampKey(mapId)
  local fam = Cells.family and Cells.family() or "?"
  return tostring(fam) .. ":" .. tostring(mapId or "?")
end

local function loadLamps()
  if lampStore then return end
  lampStore = {}
  if not (lampCache and lampCache.read) then return end
  local ok, text = pcall(lampCache.read, lampCache, LAMP_FILE)
  if not ok or type(text) ~= "string" then return end
  local fam = tostring(Cells.family and Cells.family() or "?")
  for key, mid in text:gmatch("([^\t\n]+)\t(%d+)") do
    local tf, tid = key:match("^T:([^:]+):(.+)$")
    if tf then
      -- a map's header type (cells.lua), remembered for when it is only
      -- a neighbour
      if tf == fam then
        if Cells.mapTypes[tid] == nil then Cells.mapTypes[tid] = tonumber(mid) end
      else
        otherTypes[#otherTypes + 1] = key .. "\t" .. mid -- the other family's: kept
      end
    else
      lampStore[key] = lampStore[key] or {}
      lampStore[key][tonumber(mid)] = true
    end
  end
end

function Bridge.lampMemory(mapId)
  loadLamps()
  state.lampMemory = state.lampMemory or {}
  local key = lampKey(mapId)
  local m = state.lampMemory[key]
  if not m then
    m = { mids = {} }
    for mid in pairs(lampStore[key] or {}) do m.mids[mid] = true end
    state.lampMemory[key] = m
  end
  return m
end

-- write the learned lamp tiles back when a rebuild learned a new one
function Bridge.saveLamps()
  if not (lampCache and lampCache.write and state.lampMemory) then return end
  loadLamps()
  local n = 0
  for key, m in pairs(state.lampMemory) do
    for mid in pairs(m.mids or {}) do
      n = n + 1
      lampStore[key] = lampStore[key] or {}
      lampStore[key][mid] = true
    end
  end
  if n == lampCount and not Cells.typesDirty then return end
  lampCount = n
  Cells.typesDirty = false
  local lines = {}
  for key, mids in pairs(lampStore) do
    for mid in pairs(mids) do lines[#lines + 1] = key .. "\t" .. tostring(mid) end
  end
  local fam = tostring(Cells.family and Cells.family() or "?")
  for id, t in pairs(Cells.mapTypes) do
    lines[#lines + 1] = "T:" .. fam .. ":" .. tostring(id) .. "\t" .. tostring(t)
  end
  for _, l in ipairs(otherTypes) do lines[#lines + 1] = l end
  table.sort(lines)
  pcall(lampCache.write, lampCache, LAMP_FILE, table.concat(lines, "\n") .. "\n")
end

-- towns and cities (map types 1 and 2), where street lamps stand
function Bridge.isTown(def)
  if not def then return false end
  local t = tonumber(def.mapType)
  if t then return t == 1 or t == 2 end
  return def.kind == "town" or def.kind == "city"
end

-- How dark it is, 0 (day) .. 1 (night), from the hour's colour: lamps and
-- windows come on through dusk and go out through dawn.
function Bridge.nightLevel(dn)
  if not dn then return 0 end
  local t = dn.tint or { 1, 1, 1 }
  local l = 0.299 * t[1] + 0.587 * t[2] + 0.114 * t[3]
  local v = math.max((dn.desat or 0) / 0.65, (1 - l) / 0.43)
  if v < 0.01 then return 0 end
  return math.min(1, v)
end

local function frameCamera(R, focusX, focusY, fz)
  local pw, ph, scale
  local okR, rects = false, nil
  if R.frameRects and R.setWorldOverride then okR, rects = pcall(R.frameRects, R) end
  if okR and type(rects) == "table" and rects.pw then
    pw, ph = rects.pw, rects.ph
    local fit = R.fitScale and R:fitScale() or 1
    local Z = mods().Zoom
    scale = (Z and Z.scale) and Z.scale(fit) or fit
    if scale < 1 then scale = 1 end
    -- the player's own camera distance (mod option), then indoor fit on top
    scale = scale * (tonumber(settings.zoom) or 1)
    local z = Bridge.indoorZoom(pw, ph, scale)
    scale = scale * z
    if z > 1 then
      -- zoomed in on a room: keep the room in frame rather than the player
      -- dead centre, so walking to a wall does not push half the room off
      local Map = Engine.get("src.core.game3.map")
      local def = Map and Map.currentDef and Map.currentDef()
      local L = def and def.midLayout
      local roomW = L and (L.trueWidth or L.width) * 16
      if roomW then
        local half = pw / (2 * scale)
        if roomW <= 2 * half then
          focusX = roomW / 2
        else
          focusX = math.max(half, math.min(roomW - half, focusX))
        end
      end
    end
  else
    -- inline mode: the world canvas itself, one texel per world pixel
    local wc = worldTarget(R)
    pw, ph = wc and wc:getWidth() or 240, wc and wc:getHeight() or 160
    scale = 1
  end
  return Camera.solve({
    fx = focusX, fy = focusY, fz = fz or 0,
    pitch = state.pitch, yaw = state.yaw or 0, fov = settings.fov,
    scale = scale, width = pw, height = ph,
  }), scale
end

function Bridge.captureFrame(orig, game, canvasW, canvasH, opts)
  local M = mods()
  local R, Tilt = M.Renderer, M.Tilt
  local worldCanvas = love.graphics.getCanvas() or worldTarget(R)

  -- tilt and this are two answers to the same question
  if Tilt and Tilt.level and Tilt.level > 0 and Tilt.setLevel then Tilt.setLevel(0) end

  -- ease toward the selected angle on real frame time, like Tilt does
  local dt = love.timer and love.timer.getDelta() or 1 / 60
  local goal = targetPitch()
  -- indoors a flatter view (when tilted at all): a room's walls and the
  -- fronts of its furniture face the camera more
  if goal > 0 then
    local MapP = Engine.get("src.core.game3.map")
    local defP = MapP and MapP.currentDef and MapP.currentDef()
    if defP and not isOutdoor(defP) then goal = math.min(65, goal + 10) end
  end
  local step = 90 * math.min(dt, 0.1)
  if state.pitch < goal then state.pitch = math.min(goal, state.pitch + step)
  elseif state.pitch > goal then state.pitch = math.max(goal, state.pitch - step) end
  -- the turn eases toward CAMERA TURN the same way
  -- Indoors the camera stays straight: a room is a box seen from its open
  -- south side, with nothing behind its walls to look at, and turned it only
  -- showed the cut-off ends of the side walls and the black around them.
  -- (rooms used to keep the camera straight: turned, they showed the cut
  -- ends of the walls and the black around them.  Their open sides are
  -- walled now (heightfield.lua, the room pass), so they turn too.)
  local yGoal = (settings.level > 0) and (tonumber(settings.yaw) or 0) or 0
  local yaw = state.yaw or 0
  local yStep = math.max(0.4, math.abs(yGoal - yaw) * 0.12)
  if yaw < yGoal then yaw = math.min(yGoal, yaw + yStep)
  elseif yaw > yGoal then yaw = math.max(yGoal, yaw - yStep) end
  state.yaw = yaw

  -- how much map the camera can see decides how much flat map to draw
  local fx, fy = state.focusX, state.focusY
  if not fx then fx, fy = playerFocus() end
  fx, fy = fx or 0, fy or 0
  local cam = frameCamera(R, fx, fy, state.fz or 0)
  local x1, y1, x2, y2 = Camera.visibleRect(cam, 40 * settings.heightScale, preset().view)
  local margin = (REBUILD_SLACK + 2) * CELL
  local halfW = math.max(fx - x1, x2 - fx) + margin
  local north = (fy - y1) + margin + 48 -- 48: tall things lean into view
  local south = (y2 - fy) + margin
  -- The camera looks north, so the view reaches much further north than
  -- south.  Rather than a canvas centred on the player (half of it never
  -- seen), the flat field is drawn off-centre through FieldView's own
  -- camera pan.  Not in a dark cave: the Flash circle is drawn around the
  -- canvas centre and has to stay on the player.
  local FV = mods().FieldView
  local dark = FV and FV.flashRadius and tonumber(FV.flashRadius())
  local asym = FV ~= nil and not (dark and dark > 0)
  local wantW = roundUp(2 * halfW, 64)
  local wantH = asym and roundUp(north + south, 64) or roundUp(2 * math.max(north, south), 64)
  -- grow at once, shrink only when well oversized (a pitch tween would
  -- otherwise reallocate every frame)
  local limits = love.graphics.getSystemLimits and love.graphics.getSystemLimits()
  local maxTex = math.min(limits and limits.texturesize or 2048, 4096)
  wantW, wantH = math.min(wantW, maxTex), math.min(wantH, maxTex - SLOT_ROWS * SLOT_H)
  if wantW > state.bigW or wantW < state.bigW * 0.6 then state.bigW = wantW end
  if wantH > state.bigH or wantH < state.bigH * 0.6 then state.bigH = wantH end
  local W, H = state.bigW, state.bigH
  -- pan (world px, negative = north) that puts the player `south` px above
  -- the canvas bottom instead of at its centre
  local pan = 0
  if asym then pan = math.floor(H / 2 - math.min(south, H / 2)) * -1 end
  local basePan = FV and FV.cameraPanY or 0

  local Map = Engine.get("src.core.game3.map")
  local def = Map and Map.currentDef and Map.currentDef()
  local sky, skyLow = skyFor(def)
  local ground = ensure("ground", W, H)

  -- 1. the map without characters
  love.graphics.push("all")
  love.graphics.setCanvas(ground)
  love.graphics.origin()
  love.graphics.setScissor()
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  if love.graphics.setColorMask then love.graphics.setColorMask() end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.clear(skyLow[1], skyLow[2], skyLow[3], 1)
  if FV and pan ~= 0 then FV.cameraPanY = basePan + pan end
  -- the Flash darkness is not painted into the ground: the 3D pass cuts
  -- the lit circle itself (Scene, uDark).  Painted in, it followed the art
  -- up every wall and left the circle's edge ragged, walls sticking out.
  local flashFn = FV and FV.flashRadius
  if flashFn then FV.flashRadius = function() return nil end end
  -- nor the game's rain, snow and ash sprites: painted into the map they
  -- ran down every wall; the 3D view lets its own fall (weather3d.lua)
  local FW = weatherKind(def) and Engine.get("src.core.game3.field_weather")
  local fwDraw, fwBelow
  if FW then
    fwDraw, fwBelow = FW.draw, FW.drawBelow
    FW.draw, FW.drawBelow = function() end, function() end
  end
  local okG, camX, camY = pcall(withCameraCapture, function()
    orig(game, W, H, { skipActors = true })
  end)
  if flashFn then FV.flashRadius = flashFn end
  if FW then FW.draw, FW.drawBelow = fwDraw, fwBelow end
  state.dark = dark and dark > 0 and dark or nil
  if FV and pan ~= 0 then FV.cameraPanY = basePan end
  love.graphics.pop()
  if not okG then error(camX, 0) end
  if not camX then
    local px, py = playerFocus()
    if not px then error("no field camera this frame", 0) end
    camX, camY = math.floor(px - W / 2), math.floor(py - H / 2) + pan
  end
  state.focusX, state.focusY = camX + W / 2, camY + H / 2 - pan

  -- 2. characters only, each in its own atlas slot.  The atlas is the flat
  -- view plus a strip of slots underneath it: anything drawn at its flat
  -- position (the Flash darkness, stray FX) lands in the flat part and is
  -- ignored, and only the billboard hook moves a character down into its
  -- slot.  No transform of our own is involved, so nothing the field code
  -- does to the transform stack can push characters off the atlas.
  local actors = {}
  local slotY0 = H
  local atlas = ensure("atlas", math.max(W, SLOT_COLS * SLOT_W), H + SLOT_ROWS * SLOT_H)
  state.slotY0 = slotY0
  love.graphics.push("all")
  love.graphics.setCanvas(atlas)
  love.graphics.origin()
  love.graphics.setScissor()
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  if love.graphics.setColorMask then love.graphics.setColorMask() end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.clear(0, 0, 0, 0)
  local groundPoint = Tilt and Tilt.groundPoint
  if Tilt then
    Tilt.groundPoint = function(gx, gy)
      local n = #actors + 1
      if n > SLOT_COLS * SLOT_ROWS then return -8192, -8192 end
      local sx = ((n - 1) % SLOT_COLS) * SLOT_W
      local sy = slotY0 + math.floor((n - 1) / SLOT_COLS) * SLOT_H
      actors[n] = { x = gx + camX, y = gy + camY - FOOT_INSET, sx = sx, sy = sy }
      return sx + FOOT_X, sy + FOOT_Y
    end
  end
  -- Field effects (grass at the feet, ash puffs, splashes, sparkles...)
  -- are drawn as actors too.  They are marked, so footprints only follow
  -- characters: an effect's sprite is placed (groundPoint) just before its
  -- own draw function runs, so that draw marks the slot just taken.
  local FXm = Engine.get("src.core.game3.field_effects")
  local fxCollect = FXm and FXm.collectActors
  if fxCollect then
    FXm.collectActors = function(list, ...)
      local n0 = list and #list or 0
      local r = fxCollect(list, ...)
      if list then
        for i = n0 + 1, #list do
          local e = list[i]
          local d = type(e) == "table" and e.draw
          if d then
            e.draw = function(...)
              local last = actors[#actors]
              if last then last.fx = true end
              return d(...)
            end
          end
        end
      end
      return r
    end
  end
  if FV and pan ~= 0 then FV.cameraPanY = basePan + pan end
  local okA, errA = pcall(orig, game, W, H, { actorsOnly = true, billboard = true })
  if FV and pan ~= 0 then FV.cameraPanY = basePan end
  if fxCollect then FXm.collectActors = fxCollect end
  if Tilt then Tilt.groundPoint = groundPoint end
  love.graphics.pop()
  if not okA then error(errA, 0) end
  state.atlasCanvas = atlas

  -- 3. leave the engine's world canvas empty for the OAM layer
  love.graphics.setCanvas(worldCanvas)
  love.graphics.clear(0, 0, 0, 0)

  state.pending = {
    game = game, camX = camX, camY = camY, W = W, H = H,
    actors = actors, sky = sky, skyLow = skyLow,
    overlayW = canvasW, overlayH = canvasH,
  }
end

-- ------- render (inside Renderer:endWorldPass)

local function needsRebuild(provider, world, x0, y0, x1, y1)
  local b = state.built
  if not b or not state.grid then return true end
  if b.mapId ~= provider.mapId or b.def ~= provider.def then return true end
  if b.revision ~= provider.revision or b.world ~= world then return true end
  if b.heightScale ~= settings.heightScale or b.lumps ~= settings.lumps then return true end
  if b.relief ~= reliefKey(preset()) then return true end -- AUTO stepped: rebuild in the background
  if b.sun ~= settings.sunShadows then return true end
  if b.roofs ~= settings.roofs then return true end
  -- the sun moved on (every half hour of the day): bake its light anew
  if settings.sunShadows and b.sunKey ~= sunKeyFor(provider.def) then return true end
  if x0 < b.x0 or y0 < b.y0 or x1 > b.x1 or y1 > b.y1 then return true end
  return false
end

-- Rebuilding the voxel mesh is the expensive part (hundreds of ms on a
-- phone).  Only the first build on a map is done in one go -- it happens
-- behind the warp fade.  Every later one runs as a background job: a
-- coroutine given a few milliseconds per frame, started while the player is
-- still well inside the old mesh, which keeps drawing until the new one is
-- uploaded and swapped in.
local JOB_BUDGET = 0.003 -- seconds of rebuild work per frame
local JOB_BUDGET_GAP = 0.009 -- while part of the view has no mesh yet
local rebuildInner

local function rebuild(...)
  local t0 = love.timer.getTime()
  rebuildInner(nil, ...)
  state.tMesh = (love.timer.getTime() - t0) * 1000
end

local function startJob(...)
  local args = { ... }
  local job = { started = love.timer.getTime(), work = 0 }
  local function tick()
    if love.timer.getTime() > job.deadline then coroutine.yield() end
  end
  job.co = coroutine.create(function() rebuildInner(tick, unpack(args)) end)
  state.job = job
end

local function stepJob()
  local job = state.job
  if not job then return end
  local t0 = love.timer.getTime()
  -- part of the view is uncovered (just crossed into a new area): finish
  -- faster; otherwise trickle along at the normal budget
  job.deadline = t0 + (state.gap and JOB_BUDGET_GAP or JOB_BUDGET)
  local ok, err = coroutine.resume(job.co)
  local spent = love.timer.getTime() - t0
  job.work = job.work + spent
  state.tJobFrame = (state.tJobFrame or 0) + spent * 1000
  if not ok then
    state.job = nil
    error(err, 0)
  end
  if coroutine.status(job.co) == "dead" then
    state.job = nil
    state.tMesh = job.work * 1000 -- total work, spread over many frames
  end
end

rebuildInner = function(tick, provider, p, x0, y0, x1, y1)
  -- read the flat map back once so foliage and grass can take relief from
  -- their own art; only the cells that need it are ever sampled
  -- The art is read back at quarter size: one texel per 4px voxel is all
  -- the relief and the foliage/rock tests look at, and it is 1/16th of the
  -- GPU->CPU copy (a full-size read stalled phones on every rebuild).
  local data
  local W, H = p.W, p.H
  local qw, qh = math.ceil(W / 4), math.ceil(H / 4)
  local okD, d = pcall(function()
    local probe = ensure("probe", qw, qh)
    love.graphics.push("all")
    love.graphics.setCanvas(probe)
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setBlendMode("replace")
    love.graphics.setColor(1, 1, 1, 1)
    -- nearest filter: each probe texel centre lands on its 4x4 block's centre
    love.graphics.draw(state.ground, 0, 0, 0, 0.25, 0.25)
    love.graphics.pop()
    return probe:newImageData()
  end)
  if okD then data = d end
  local gx, gy = p.camX, p.camY
  local color = nil
  if data then
    color = function(wx, wy)
      local ix, iy = math.floor((wx - gx) / 4), math.floor((wy - gy) / 4)
      if ix < 0 or iy < 0 or ix >= qw or iy >= qh then return nil end
      local r, g, b = data:getPixel(ix, iy)
      return r, g, b
    end
  end
  local q = preset()
  local grid = HF.build({ cell = provider.cell, color = color, shape = provider.shape },
    x0, y0, x1 - x0 + 1, y1 - y0 + 1,
    { heightScale = settings.heightScale, lumps = settings.lumps, tick = tick,
      -- street lamps found before stay lamps (the quarter-size art a thin
      -- post is judged from shifts with the camera, so one rebuild saw a
      -- post that the next did not)
      lampMemory = Bridge.lampMemory(provider.mapId),
      town = Bridge.isTown(provider.def),
      reliefBlock = q.blk, reliefStep = q.step, round = roundOf(q),
      roofs = settings.roofs and isOutdoor(provider.def),
      -- RSE draws its roofs ridged east-west (gable trim down the sides)
      ridge = (function() local f = Cells.family and Cells.family() return (f and f ~= "frlg") and "ew" or "ns" end)(),
      indoor = not isOutdoor(provider.def),
      -- mountains outdoors and in caves; never in houses, whose walls are
      -- the same warm beige
      rock = isOutdoor(provider.def) or tonumber(provider.def and provider.def.mapType) == 4
        or (tonumber(provider.def and provider.def.cave) or 0) > 0,
      cave = tonumber(provider.def and provider.def.mapType) == 4
        or (tonumber(provider.def and provider.def.cave) or 0) > 0 })
  if data then data:release() end
  Bridge.saveLamps()
  local verts, idx, nv, ni = Mesher.build(grid, HF.VOXEL, tick)
  state.meshVerts, state.meshTris = nv, ni / 3
  -- light: sun outdoors, ambient occlusion everywhere; swapped in together
  -- with the mesh it belongs to
  local lightImage
  state.bakedSunKey = nil
  if settings.sunShadows then
    local key = sunKeyFor(provider.def)
    local s = (key ~= "noon") and DayNight.sunOf(key) or nil
    local indoor = not isOutdoor(provider.def)
    Lighting.bake(grid, HF.VOXEL, { tick = tick,
      -- no sun at night: ambient occlusion only.  Indoors the room's own
      -- light, high up toward the back wall: furniture throws a soft
      -- shadow forward onto the floor, the back wall a band along its foot.
      sun = indoor or key ~= "night",
      sunX = indoor and 0.1 or (s and s.sunX), sunY = indoor and 0.38 or (s and s.sunY),
      room = indoor and grid.room ~= nil })
    state.bakedSunKey = key
    local okL, img = pcall(function()
      local d = Lighting.imageData(grid, tick)
      local im = love.graphics.newImage(d)
      d:release()
      im:setFilter("linear", "linear")
      im:setWrap("clamp", "clamp")
      return im
    end)
    if okL then lightImage = img end
    if tick then tick() end
  end
  Scene.setTerrain(verts, idx, nv, ni, tick)
  Critters.setSpots(grid, HF.VOXEL)
  Smoke.setStacks(grid)
  Scene.setLight(lightImage, grid.px, grid.py, grid.vcols * HF.VOXEL, grid.vrows * HF.VOXEL)
  local Map = Engine.get("src.core.game3.map")
  state.grid = grid
  state.shiftX, state.shiftY = 0, 0
  state.built = {
    mapId = provider.mapId, def = provider.def, revision = provider.revision,
    world = Map and Map.world, heightScale = settings.heightScale, lumps = settings.lumps,
    relief = reliefKey(q), sun = settings.sunShadows, roofs = settings.roofs,
    sunKey = state.bakedSunKey or sunKeyFor(provider.def),
    x0 = x0, y0 = y0, x1 = x1, y1 = y1,
  }
end

function Bridge.renderPending(R)
  local p = state.pending
  state.pending = nil
  if not p then return end
  local provider = Cells.provider()
  if not provider then
    -- the map is between two loads: keep the last picture up
    if canHold(R) then pcall(R.setWorldOverride, R, state.final) end
    return
  end

  if state.lastMap ~= provider.mapId then
    state.lastMap = provider.mapId
    state.fz = nil
  end

  local fx, fy = state.focusX, state.focusY
  -- feet height under the focus, smoothed so surfing does not bob the camera
  local floorZ = state.grid and HF.floorAt(state.grid, fx - (state.shiftX or 0), fy - (state.shiftY or 0)) or 0
  state.fz = state.fz and (state.fz + (floorZ - state.fz) * 0.2) or floorZ

  local cam, scale = frameCamera(R, fx, fy, state.fz)
  local x1, y1, x2, y2 = Camera.visibleRect(cam, 40 * settings.heightScale, preset().view)
  local cx0 = math.floor(x1 / CELL) - 1
  local cy0 = math.floor(y1 / CELL) - 3 -- tall things north of the view lean in
  local cx1 = math.ceil(x2 / CELL) + 1
  local cy1 = math.ceil(y2 / CELL) + 1
  local world = (Engine.get("src.core.game3.map") or {}).world
  -- Walking across a seamless connection (route -> town) changes the map
  -- whose coordinates everything is in, but the old mesh is still the right
  -- shape: shift it into the new map's space and rebuild in the background
  -- instead of freezing at every border.
  do
    local b0 = state.built
    if b0 and state.grid and b0.mapId ~= provider.mapId
        and b0.heightScale == settings.heightScale and b0.lumps == settings.lumps then
      local entry
      for _, e in ipairs(world or {}) do
        if e.id == b0.mapId then entry = e break end
      end
      if entry then
        state.job = nil -- a half-built mesh is in the old map's coordinates
        local ox, oy = (entry.ox or 0), (entry.oy or 0)
        state.shiftX = (state.shiftX or 0) + ox * CELL
        state.shiftY = (state.shiftY or 0) + oy * CELL
        b0.x0, b0.x1, b0.y0, b0.y1 = b0.x0 + ox, b0.x1 + ox, b0.y0 + oy, b0.y1 + oy
        b0.mapId, b0.def = provider.mapId, provider.def
        b0.world = nil -- different world list: rebuild soon, in the background
      end
    end
  end

  -- a different map (a warp), a changed setting or no mesh at all: build now
  local b = state.built
  local hard = not b or not state.grid or b.mapId ~= provider.mapId or b.def ~= provider.def
    or b.heightScale ~= settings.heightScale or b.lumps ~= settings.lumps
  if hard then
    state.job = nil
  elseif not state.job then
    -- start the next mesh in the background before it is needed: when the
    -- view comes within 3 cells of the old mesh's edge, or a tile changed
    local soon = needsRebuild(provider, world, cx0 - 3, cy0 - 3, cx1 + 3, cy1 + 3)
    if soon then
      startJob(provider, p, cx0 - REBUILD_SLACK, cy0 - REBUILD_SLACK,
        cx1 + REBUILD_SLACK, cy1 + REBUILD_SLACK)
    end
  end
  state.gap = state.job ~= nil and needsRebuild(provider, world, cx0, cy0, cx1, cy1)
  if state.job then stepJob() end
  if hard then
    state.settleUntil = now() + 1.5 -- a warp's one-off build is not "slow"
    -- (behind the warp's fade the game waits for it: build what the camera
    -- sees and two cells more (a couple of steps), not the usual margin --
    -- a quarter less to do in a dense forest.  The background job grows it
    -- from there, starting on the very next frame.)
    rebuild(provider, p, cx0 - 2, cy0 - 2, cx1 + 2, cy1 + 2)
  end

  -- a character whose feet are inside a building's footprint has walked
  -- through its door: the facade hides it, so do not let its head poke
  -- out over the roof
  -- and in a dark cave, one outside the Flash circle stays in the dark the
  -- ground texture already painted there
  local FV = Engine.get("src.core.game3.field_view")
  local dark = FV and FV.flashRadius and FV.flashRadius()
  dark = tonumber(dark)
  local shown = {}
  -- the player's feet without any jump: the camera follows the cell
  -- position, so the focus is the ground under the player even mid-hop
  local groundY = fy + CELL / 2 - FOOT_INSET
  -- Only the player hops.  When someone already stands on the player's
  -- spot (the player, on the ground), nothing is mid-hop -- an NPC one cell
  -- north at the same x (walking UP to talk to it) used to be taken for a
  -- hopping player: pulled onto the player's spot and lifted 16px, it was
  -- drawn over the player.
  local grounded = false
  for _, a in ipairs(p.actors) do
    if math.abs(a.x - fx) <= 1 and math.abs(a.y - groundY) <= 0.5 then grounded = true break end
  end
  local hopper = nil
  if not grounded then
    for _, a in ipairs(p.actors) do
      if math.abs(a.x - fx) <= 1 and a.y < groundY - 0.5 and a.y >= groundY - 28
          and (hopper == nil or a.y > hopper.y) then
        hopper = a
      end
    end
  end
  for _, a in ipairs(p.actors) do
    -- a ledge hop draws the sprite higher up the flat screen, which would
    -- read as walking north (into a tree block, a fence...).  Put the
    -- player's feet back on the ground and lift the sprite into the air.
    local lift = 0
    if a == hopper then
      lift = groundY - a.y
      a.y = groundY
    end
    -- mid-hop over a ledge the feet are on the ledge's own cell, inside its
    -- low block: the block's top, in front of the sprite's upright plane,
    -- cut a band across the body.  Stand the sprite at the ledge's front
    -- edge instead, so the whole lip is behind it.
    do
      local c = provider.cell(math.floor(a.x / CELL), math.floor(a.y / CELL))
      if c and c.kind == "ledge" then
        a.y = (math.floor(a.y / CELL) + 1) * CELL + 0.5
      end
    end
    local lit = true
    if dark and dark > 0 then
      local dx, dy = a.x - fx, a.y - 8 - fy
      lit = dx * dx + dy * dy <= dark * dark
    end
    -- past the north/south edge of the built terrain there is only sky:
    -- a character standing there would float in it
    local inMesh = true
    local b = state.built
    if b then
      -- state.built's bounds are kept in the current map's coordinates (they
      -- move with it when a route hands over to a town), and so are the
      -- characters: no shift here.  Shifted, every character -- the player
      -- too -- fell outside the bounds after crossing a map border and
      -- vanished until the background rebuild finished.
      local cy = math.floor(a.y / CELL)
      inMesh = cy >= b.y0 + 1 and cy <= b.y1 - 1
    end
    if lit and inMesh and not HF.insideAt(state.grid, a.x - (state.shiftX or 0), a.y - (state.shiftY or 0)) then
      a.ground = HF.floorAt(state.grid, a.x - (state.shiftX or 0), a.y - (state.shiftY or 0))
      a.z = a.ground + lift
      if settings.sunShadows then
        local sun, ao = Lighting.at(state.grid, a.x - (state.shiftX or 0), a.y - 2 - (state.shiftY or 0), HF.VOXEL)
        local k = 0.5 + 0.5 * ao -- characters stand up out of the corner darkness
        a.lr = (SHADOW_TINT[1] + (1 - SHADOW_TINT[1]) * sun) * k
        a.lg = (SHADOW_TINT[2] + (1 - SHADOW_TINT[2]) * sun) * k
        a.lb = (SHADOW_TINT[3] + (1 - SHADOW_TINT[3]) * sun) * k
      end
      shown[#shown + 1] = a
    end
  end
  -- footprints: the ground under each character by its behaviour
  if settings.footprints ~= false and isOutdoor(provider.def) then
    local MBm = Engine.get("src.core.game3.mb")
    state.mbIds = state.mbIds or (function()
      local ids = {}
      for _, name in ipairs({ "SAND", "DEEP_SAND", "FOOTPRINTS", "PUDDLE", "SHALLOW_WATER" }) do
        local ok, v = pcall(MBm and MBm.id or function() end, name)
        if ok and v ~= nil then ids[v] = name end
      end
      return ids
    end)()
    local ids = state.mbIds
    local function groundAt(x, y)
      local c = provider.cell(math.floor(x / CELL), math.floor(y / CELL))
      if not c then return nil end
      local n = c.beh ~= nil and ids[c.beh]
      if n == "PUDDLE" or n == "SHALLOW_WATER" then return "wet" end
      if c.kind == "water" then return settings.waves ~= false and "water" or nil end
      if n == "SAND" or n == "DEEP_SAND" or n == "FOOTPRINTS" then return "sand" end
      if c.kind == "ground" and not c.canopy then return "open" end
      if c.kind == "door" or c.kind == "ledge" then return "open" end
      return nil
    end
    -- real time since the last footprint update, from the clock: the
    -- frame delta read here ran some three times slower than real time on
    -- the phone (prints lived ~50 s instead of 18 and the per-second
    -- counters ran long, which read as everyone walking at a sprint)
    local nowT = love.timer and love.timer.getTime and love.timer.getTime() or 0
    local dtp = math.max(0, math.min(0.1, nowT - (state.printClock or nowT)))
    state.printClock = nowT
    local nfx = 0
    for _, a in ipairs(shown) do if a.fx then nfx = nfx + 1 end end
    state.printFx = nfx
    -- The walkers come straight from the game: its objects, the player and
    -- the follower, each by its own name and at its own position -- not
    -- from the sprites placed on the flat view.  On Route 113 the sprites'
    -- positions hopped a pixel or two from frame to frame, and a few
    -- people standing in the ash laid some hundred prints a second.
    local walkers, wp, nmv = {}, nil, 0
    local sxm, sym = state.shiftX or 0, state.shiftY or 0
    -- (only one actually drawn this frame: the game keeps objects moving
    -- that are not on screen -- one paced Route 113 at some 300 px/s)
    local drawn = {}
    for _, a in ipairs(shown) do if not a.fx then drawn[#drawn + 1] = a end end
    local function onScreen(x, y)
      for _, a in ipairs(drawn) do
        if math.abs(a.x - x) <= 5 and math.abs(a.y - y) <= 5 then return true end
      end
      return false
    end
    local seenId = {}
    local function walker(id, px, py, moving, isPlayer, bike)
      if not (px and py) or seenId[id] then return end
      seenId[id] = true
      local x, y = px + CELL / 2, py + CELL - FOOT_INSET
      if not isPlayer and not onScreen(x, y) then return end
      if HF.insideAt(state.grid, x - sxm, y - sym) then return end
      walkers[#walkers + 1] = { id = id, x = x, y = y, moving = moving and true or false, bike = bike or nil,
        ground = HF.floorAt(state.grid, x - sxm, y - sym) }
      if moving then nmv = nmv + 1 end
      if isPlayer then wp = #walkers end
    end
    local Obj = Engine.get("src.core.game3.objects")
    if Obj and Obj.forDraw then
      local okL, list = pcall(Obj.forDraw)
      if okL and type(list) == "table" then
        for _, eo in ipairs(list) do
          if not eo.foreignMap and eo.px and eo.py then
            walker(eo, eo.px, eo.py, eo.moving)
          end
        end
      end
    end
    local Pl = Engine.get("src.core.game3.player")
    if Pl and Pl.px and (not Pl.isVisible or Pl.isVisible()) then
      walker("player", Pl.px, Pl.py, Pl.moving, true, Pl.biking == true)
    end
    local Fo = Engine.get("src.world.game3.Follower")
    local fa = Fo and Fo.actor and Fo.actor()
    if fa then walker("follower", fa.x, fa.y, fa.walkPhase == 1) end
    state.printMv = nmv
    Footprints.update(dtp, provider.mapId, walkers, groundAt, wp, weatherKind(provider.def) == "ash")
    Scene.setPrints(Footprints.build())
  else
    Scene.setPrints({}, 0, {}, 0)
  end
  local BREATH = { off = 0, subtle = 0.022, normal = 0.04 }
  Scene.setActors(shown, SLOT_W, SLOT_H, FOOT_X, FOOT_Y, tonumber(settings.solid) or 0,
    BREATH[settings.breath or "subtle"] or 0, love.timer and love.timer.getTime() or 0,
    settings.blink ~= false)
  Scene.setBackdrop(p.camX, p.camY, p.W, p.H)

  -- OAM field sprites, as drawn by display.lua into the world canvas around
  -- the same focus, laid on the ground under the player
  local wc = worldTarget(R)
  local ow, oh = wc:getWidth(), wc:getHeight()
  Scene.setOverlay(fx - ow / 2, fy - oh / 2, ow, oh, state.fz)

  -- Two ways to hand the picture over.  With Renderer:setWorldOverride the
  -- scene is rendered at window resolution and composited 1:1.  A build
  -- without that seam gets the scene painted into the world canvas itself,
  -- at world-pixel resolution, which every Renderer composites as usual.
  local inline = not R.setWorldOverride or not R.frameRects
  local pw, ph
  if inline then
    pw, ph = ow, oh
  else
    local rects = R:frameRects()
    pw, ph = math.max(1, math.floor(rects.pw)), math.max(1, math.floor(rects.ph))
  end
  local overlay = wc
  if inline then
    overlay = ensure("overlayCopy", ow, oh)
    love.graphics.push("all")
    love.graphics.setCanvas(overlay)
    love.graphics.origin()
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setShader()
    love.graphics.setBlendMode("replace")
    love.graphics.draw(wc, 0, 0)
    love.graphics.pop()
  end
  local rw, rh = pw, ph
  if settings.resolution == "auto" then
    -- keep the 3D pass near the preset's pixel budget (1 million balanced):
    -- a phone panel renders below native and is upscaled
    local budget = preset().budget
    local f = math.sqrt((pw * ph) / budget)
    if f > 1.15 then rw, rh = math.ceil(pw / f), math.ceil(ph / f) end
  elseif settings.resolution == "half" then
    rw, rh = math.ceil(pw / 2), math.ceil(ph / 2)
  elseif settings.resolution == "pixel" then
    local s = math.max(1, scale)
    rw, rh = math.ceil(pw / s), math.ceil(ph / s)
  end
  state.rw, state.rh = rw, rh
  local final = ensure("final", pw, ph)
  local target = final
  if rw ~= pw or rh ~= ph then target = ensure("lowres", rw, rh) end
  -- distance blur happens in the copy to `final`, so a full-size render
  -- needs a canvas of its own to be copied from
  local blur = settings.blur and preset().blur ~= false and Scene.blurShader() ~= nil
  if blur and target == final then target = ensure("sceneFull", pw, ph) end
  -- a reduced target keeps the same framing: fewer pixels per world pixel
  cam.width, cam.height = rw, rh
  cam.scale = cam.scale * rh / ph
  Camera.solve(cam)

  local skyTop, skyBottom = skyFor(provider.def)
  -- weather: particles around what the camera sees, and its gloom
  local tint = (dayNight(provider.def) or {}).tint
  do
    local kind = weatherKind(provider.def)
    local vx1, vy1, vx2, vy2 = Camera.visibleRect(cam, 40 * settings.heightScale, preset().view)
    local fy0 = state.focusY or 0
    local rect = { vx1, math.max(vy1, fy0 - 320), vx2, math.min(vy2, fy0 + 160) }
    local q = preset()
    local budget = (q.name == "POTATO" or q.name == "AUTO-3") and 0.5 or 1
    local dt = love.timer and love.timer.getDelta and love.timer.getDelta() or 1 / 60
    Weather3D.update(dt, kind, rect, budget)
    Scene.setWeather(Weather3D.build())
    -- chimney smoke: drifting with the wind, more of it on a wet day
    if settings.smoke ~= false and isOutdoor(provider.def) then
      local sxs, sys = state.shiftX or 0, state.shiftY or 0
      Smoke.update(dt, state.wind or Bridge.windFor(provider.def), kind ~= nil, rect, sxs, sys)
      Scene.setSmoke(Smoke.build(sxs, sys))
    else
      Scene.setSmoke({}, 0, {}, 0, {}, 0, {}, 0)
    end
    -- critters: outdoors, not in rain (fireflies hide, birds stay put)
    if settings.critters ~= false and isOutdoor(provider.def) then
      local dn = dayNight(provider.def)
      local night = Bridge.nightLevel(dn)
      if kind then night = 0 end
      local sxs, sys = state.shiftX or 0, state.shiftY or 0
      Critters.update(dt, night, kind == nil and night < 0.3, rect, sxs, sys, budget)
      Scene.setCritters(Critters.build(sxs, sys))
    else
      Scene.setCritters({}, 0, {}, 0, {}, 0, {}, 0)
    end
    local wt = Weather3D.tint()
    if wt then
      local base = tint or { 1, 1, 1 }
      tint = { base[1] * wt[1], base[2] * wt[2], base[3] * wt[3] }
      skyTop = { skyTop[1] * wt[1], skyTop[2] * wt[2], skyTop[3] * wt[3] }
      skyBottom = { skyBottom[1] * wt[1], skyBottom[2] * wt[2], skyBottom[3] * wt[3] }
    end
  end
  -- clouds: their shadows drift over the land by day, with the wind; the
  -- sky has clouds by day and stars by night.  Outdoors, under an open sky
  -- (rain, snow and ash bring their own grey).
  local clouds, sky
  if settings.clouds ~= false and isOutdoor(provider.def) and not weatherKind(provider.def) then
    local now = love.timer and love.timer.getTime() or 0
    local cdt = math.max(0, math.min(0.1, now - (state.cloudClock or now)))
    state.cloudClock = now
    local spd = 7 * (state.wind or 0.9)
    state.cloudX = ((state.cloudX or 0) - spd * cdt) % 4096
    state.cloudY = ((state.cloudY or 0) - spd * 0.35 * cdt) % 4096
    local night = Bridge.nightLevel(dayNight(provider.def))
    local day = 1 - night
    -- (by night the moon's: fainter, still drifting)
    clouds = { x = state.cloudX, y = state.cloudY, size = 560, strength = 0.2 * day + 0.12 * night }
    local t = tint or { 1, 1, 1 }
    sky = { clouds = day, stars = night > 0.4 and (night - 0.4) / 0.6 or 0, time = now,
      speed = spd, color = { math.min(1, 0.55 + 0.5 * t[1]), math.min(1, 0.55 + 0.5 * t[2]), math.min(1, 0.55 + 0.5 * t[3]) } }
  end
  local okR = Scene.render({
    clouds = clouds, sky = sky,
    foam = settings.waves ~= false and state.grid ~= nil and state.grid.hasWater == true,
    target = target, cam = cam,
    view = Camera.view(cam), proj = Camera.projection(cam, true),
    shiftX = state.shiftX, shiftY = state.shiftY,
    ground = state.ground, groundX = p.camX, groundY = p.camY,
    atlas = state.atlas, overlay = overlay,
    slot = { state.slotY0 or 0, SLOT_H, FOOT_Y },
    skyTop = skyTop, skyBottom = skyBottom, fog = skyBottom,
    fogStart = cam.dist * 1.25, fogEnd = cam.dist * 2.8,
    shadows = settings.shadows,
    xray = settings.xray,
    light = settings.sunShadows, shadowTint = (isOutdoor(provider.def) and SHADOW_TINT) or ROOM_SHADOW,
    tint = tint,
    desat = (dayNight(provider.def) or {}).desat,
    night = settings.nightlights ~= false and Bridge.nightLevel(dayNight(provider.def)) or 0,
    -- the wind eases to the weather's over a few seconds
    wind = (function()
      local goal = Bridge.windFor(provider.def)
      local cur = state.wind or goal
      cur = cur + (goal - cur) * 0.02
      state.wind = cur
      return cur
    end)(),
    -- only when there is water to show it (a second, half-size pass)
    reflect = settings.reflect ~= false and state.grid ~= nil and state.grid.hasWater == true,
    waterZ = HF.WATER,
    dark = state.dark and { state.focusX - (state.shiftX or 0), state.focusY - (state.shiftY or 0), state.dark } or nil,
  })
  if not okR then error("no depth buffer", 0) end
  if target ~= final then
    love.graphics.push("all")
    love.graphics.setCanvas(final)
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setBlendMode("replace")
    love.graphics.setColor(1, 1, 1, 1)
    if blur then
      local sh = Scene.blurShader()
      love.graphics.setShader(sh)
      sh:send("uTexel", { 1 / rw, 1 / rh })
      -- ~0.6% of the screen height at the top edge, the same look at any
      -- render resolution; LOW looks further away, so a little more
      local k = ({ 0, 1.25, 1.0, 0.8 })[settings.level + 1] or 1
      sh:send("uRadius", 0.006 * rh * k)
      sh:send("uStart", 0.42)
    end
    love.graphics.draw(target, 0, 0, 0, pw / rw, ph / rh)
    love.graphics.pop()
  end
  if inline then
    love.graphics.push("all")
    love.graphics.setCanvas(wc)
    love.graphics.origin()
    love.graphics.setShader()
    love.graphics.setBlendMode("replace")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(final, 0, 0)
    love.graphics.pop()
  else
    R:setWorldOverride(final)
  end
  Bridge.checkAtlas(shown)
  state.failures = 0
  if not state.announced then
    state.announced = true
    Bridge.toast("VOXEL VIEW: " .. (({ "OFF", "LOW", "MID", "HIGH" })[settings.level + 1] or "?"), 3)
  end
end

-- One-time self-check on the first frame with characters: were their
-- sprites actually captured into their atlas slots?  Reported on screen,
-- because the answer is only knowable on the player's device.
function Bridge.checkAtlas(shown)
  if state.atlasChecked or not shown or #shown == 0 or not state.atlasCanvas then return end
  state.atlasChecked = true
  local ok, data = pcall(function() return state.atlasCanvas:newImageData() end)
  if not ok or not data then return end
  local a = shown[1]
  local inSlot = 0
  for y = a.sy, a.sy + SLOT_H - 1, 2 do
    for x = a.sx, a.sx + SLOT_W - 1, 2 do
      local _, _, _, al = data:getPixel(x, y)
      if al > 0.5 then inSlot = inSlot + 1 end
    end
  end
  local stray = 0
  local w, h = data:getWidth(), state.slotY0 or 0
  for y = 0, h - 1, 4 do
    for x = 0, w - 1, 4 do
      local _, _, _, al = data:getPixel(x, y)
      if al > 0.5 then stray = stray + 1 end
    end
  end
  data:release()
  local msg = ("VOXEL check: %d chars, slot px %d, stray px %d"):format(#shown, inSlot, stray)
  log("info", "%s", msg)
  if inSlot == 0 then
    Bridge.toast(msg .. " (sprites not captured)", 12)
    if reporter then pcall(reporter, msg) end
  end
end

-- ------- AUTO quality
--
-- The frame time is watched while the view is on.  A sustained drop below
-- ~48 fps steps AUTO down one tier (fewer pixels, then half-rate 3D, then
-- coarse relief and a shorter view).  It only climbs back after a long run
-- at full speed, and stops climbing once a climb has had to be undone.
local SLOW_DT, FAST_DT = 1 / 48, 1 / 57

function Bridge.adapt(dt, t)
  if settings.quality ~= "auto" then return end
  dt = dt or (love.timer and love.timer.getDelta() or 1 / 60)
  t = t or now()
  if dt > 0.25 then return end -- a load hitch, not a frame rate
  state.emaDt = state.emaDt and (state.emaDt * 0.93 + dt * 0.07) or dt
  if state.settleUntil and t < state.settleUntil then
    state.slowSince, state.fastSince = nil, nil
    return
  end
  local tier = state.autoTier or 0
  if state.emaDt > SLOW_DT then
    state.fastSince = nil
    state.slowSince = state.slowSince or t
    if t - state.slowSince > 1.5 and tier < #AUTO_TIERS then
      state.autoTier = tier + 1
      state.slowSince = nil
      state.settleUntil = t + 3
      if state.climbedAt and t - state.climbedAt < 15 then state.noClimb = true end
      log("info", "voxel quality AUTO -> tier %d (%.0f fps)", state.autoTier, 1 / state.emaDt)
    end
  elseif state.emaDt < FAST_DT then
    state.slowSince = nil
    state.fastSince = state.fastSince or t
    if tier > 0 and not state.noClimb and t - state.fastSince > 30 then
      state.autoTier = tier - 1
      state.fastSince = nil
      state.climbedAt = t
      state.settleUntil = t + 3
      log("info", "voxel quality AUTO -> tier %d", state.autoTier)
    end
  else
    state.slowSince, state.fastSince = nil, nil
  end
end

-- ------- install

function Bridge.install()
  if state.installed then return true end
  local FieldView = require("src.core.game3.field_view")
  local Renderer = require("src.render.Renderer")
  require("src.render.Tilt")
  if not (FieldView and FieldView.draw and Renderer and Renderer.endWorldPass) then
    return false, "Gen 3 field renderer not found"
  end

  local origDraw = FieldView.draw
  FieldView.draw = function(game, canvasW, canvasH, opts)
    if not wantsFrame(opts) then
      state.pending = nil
      -- Into a battle: the game freezes the overworld under the wipe, so
      -- hold the last 3D picture rather than flashing back to the flat map
      -- for the length of the transition.
      local R = mods().Renderer
      local why = state.why
      local hold = blockingState() == "transition"
        or (canHold(R) and why ~= "mode is OFF" and why ~= "shop" and why ~= "seagallop")
      if Bridge.active() and state.inWorld and state.final and state.lastShown
          and R and R.setWorldOverride and hold
          and not (opts and (opts.actorsOnly or opts.billboard)) then
        love.graphics.clear(0, 0, 0, 0)
        state.reuse = true
        return
      end
      -- the mode is on but the field keeps drawing flat: say so once
      if Bridge.active() and not (opts and (opts.actorsOnly or opts.billboard)) then
        local t = now()
        state.idleSince = state.idleSince or t
        if not state.warnedIdle and t - state.idleSince > 6 and not blockingState() then
          state.warnedIdle = true
          local why = state.why or lastReason or "unknown"
          local v = love.getVersion and table.concat({ love.getVersion() }, ".", 1, 3) or "?"
          why = tostring(why) .. " [LOVE " .. v .. ", override "
            .. tostring(mods().Renderer and mods().Renderer.setWorldOverride ~= nil) .. "]"
          Bridge.toast("VOXEL VIEW is on but not drawing: " .. why, 12)
          log("warn", "voxel view on but not drawing: %s", tostring(why))
        end
      end
      return origDraw(game, canvasW, canvasH, opts)
    end
    state.idleSince = nil
    Bridge.adapt()
    local target = love.graphics.getCanvas()
    -- Half-rate 3D: on a 120 Hz phone panel the scene is redrawn every
    -- other frame and the last picture is shown in between.  The game
    -- itself still runs every frame; only the 3D redraw is skipped.
    state.frameNo = (state.frameNo or 0) + 1
    local half = settings.rate == "half"
    if settings.rate == "auto" then
      local fps = love.timer and love.timer.getFPS and love.timer.getFPS() or 60
      half = fps > 75 or (state.avgMs or 0) > 12 or preset().half == true
    end
    local R = mods().Renderer
    state.halfNow = half
    if half and state.final and state.lastShown and state.frameNo % 2 == 0
        and R and R.setWorldOverride then
      love.graphics.clear(0, 0, 0, 0)
      state.pending = nil
      state.reuse = true
      return
    end
    state.reuse = false
    local t0 = love.timer.getTime()
    local ok, err = pcall(Bridge.captureFrame, origDraw, game, canvasW, canvasH, opts)
    state.tCapture = (love.timer.getTime() - t0) * 1000
    if ok then return end
    love.graphics.setCanvas(target)
    fail("capture", err)
    if canHold(R) then
      love.graphics.clear(0, 0, 0, 0)
      state.pending = nil
      state.reuse = true
      return
    end
    return origDraw(game, canvasW, canvasH, opts)
  end

  local origBegin = Renderer.beginWorldPass
  Renderer.beginWorldPass = function(self, ...)
    local r = { origBegin(self, ...) }
    state.inWorld = true
    state.worldTarget = love.graphics.getCanvas()
    return unpack(r)
  end

  local origFrame = Renderer.endFrame
  Renderer.endFrame = function(self, ...)
    state.inWorld = false
    local r = { origFrame(self, ...) }
    -- endFrame can run more than once a frame on some screens; draw the
    -- stats line once, or two passes with different numbers overlap
    local frameId = love.timer.getTime()
    local hudOnce = state.hudAt ~= frameId and (frameId - (state.hudAt or 0)) > 0.002
    if hudOnce then state.hudAt = frameId end
    if settings.perf and Bridge.active() and hudOnce then
      pcall(function()
        love.graphics.push("all")
        love.graphics.setCanvas()
        love.graphics.origin()
        love.graphics.setShader()
        local w = love.graphics.getWidth()
        local k = math.max(1, math.floor(w / 360))
        local fps = love.timer.getFPS and love.timer.getFPS() or 0
        local text = ("FPS %d  cap %.1f  3d %.1f  bg %.1f  avg %.1f ms  %s %dx%d%s"):format(
          fps, state.tCapture or 0, state.tRender or 0,
          state.job and (state.tBg or 0) or 0, state.avgMs or 0,
          preset().name, state.rw or 0, state.rh or 0, state.halfNow and " 1/2" or "")
        -- what the map says it is and what the view made of it (sky or not)
        local Map = Engine.get("src.core.game3.map")
        local def = Map and Map.currentDef and Map.currentDef()
        if def then
          local wet = looksOutdoor(def)
          text = text .. ("\nmap type %s  kind %s  env %s  water/grass %s  outdoor %s"):format(
            tostring(def.mapType), tostring(def.kind), tostring(def.environment),
            wet and (math.floor(wet * 100 + 0.5) .. "%") or "?", tostring(isOutdoor(def)))
          local g = state.grid
          local rf = g and g.roofs or {}
          text = text .. ("  cave %d/%d  roofs %d %s  gaps %d  ptree %d/%d/%d"):format(g and g.caveMounds or 0,
            g and g.caveFlat or 0, #rf, rf[1] and rf[1].ridge or "-", g and g.gapFills or 0, g and g.patternTrees or 0,
            g and g.patternCand or 0, g and g.crownCells or 0)
          text = text .. "  blink " .. tostring(Scene.blinkFrames or 0)
          do
            local cs = Critters._state
            text = text .. ("  crit %d/%d f%d"):format(#cs.flies, #cs.birds, cs.flocks or 0)
            local fs = Footprints._state
            local nwk = 0
            for _, pr in ipairs(fs.prints) do if pr.kind == "wake" then nwk = nwk + 1 end end
            text = text .. ("  prints %d +%d w%d mv%d fx%d wk%d"):format(#fs.prints, fs.rate or 0, #fs.walkers, state.printMv or 0, state.printFx or 0, nwk)
            local tp = fs.top
            if tp and tp.path > 0 then
              local who = type(tp.id) == "table" and ("o" .. tostring(tp.id.localId or tp.id.virtualId or "?")) or tostring(tp.id)
              text = text .. ("  top %s %dpx %s @%d,%d"):format(who, math.floor(tp.path + 0.5), tp.moving and "mv" or "st",
                math.floor(tp.x), math.floor(tp.y))
            end
            local ss = Smoke._state
            text = text .. ("  smoke %d/%d%s"):format(#ss.stacks, #ss.puffs, ss.seen and (" v" .. ss.seen) or "")
          end
          if state.grid and state.grid.hasWater then
            text = text .. "  refl " .. tostring(Scene.reflFrames or 0)
          end
          if g and g.lights then
            local nl, nd = 0, 0
            for _, l in ipairs(g.lights) do if l.kind == "lamp" then nl = nl + 1 else nd = nd + 1 end end
            -- lamps (by tile + by art) / doorways
            text = text .. ("  lights %d(t%d a%d)/%d"):format(nl, g.lampsByTile or 0, g.lampsByArt or 0, nd)
          end
          if g and g.exitNote then
            text = text .. ("  exit %d (%s) void %d"):format(g.exitFloors or 0, g.exitNote, g.voidFlat or 0)
          end
          if g and g.room then
            local r = g.room
            text = text .. ("  room h%d d%d w%d s%d f%d e%d"):format(r.wallH, r.depth, r.walls, r.sides, r.things, r.edges or 0)
          end
          local wk = weatherKind(def)
          if wk then text = text .. "  wx " .. wk end
          local dn = dayNight(def)
          if dn then
            local h = dn.hour
            text = text .. ("  time %02d:%02d %s"):format(math.floor(h), math.floor((h % 1) * 60),
              dn.sun and "sun" or "night")
          end
        end
        love.graphics.setColor(0, 0, 0, 0.7)
        local font = love.graphics.getFont()
        local widest, lines = 0, 0
        for line in (text .. "\n"):gmatch("(.-)\n") do
          widest, lines = math.max(widest, font:getWidth(line)), lines + 1
        end
        -- shrink to fit a narrow phone screen
        if widest * k > w - 24 then k = (w - 24) / widest end
        love.graphics.rectangle("fill", 4, 4, widest * k + 12, font:getHeight() * k * lines + 8)
        love.graphics.setColor(1, 1, 0.4, 1)
        love.graphics.print(text, 10, 8, 0, k, k)
        love.graphics.pop()
      end)
    end
    if toast.text and now() < toast.untilT then
      pcall(function()
        love.graphics.push("all")
        love.graphics.setCanvas()
        love.graphics.origin()
        love.graphics.setShader()
        local w, h = love.graphics.getDimensions()
        local k = math.max(1, math.floor(math.min(w, h) / 360))
        local font = love.graphics.getFont()
        local tw = font:getWidth(toast.text) * k
        local maxW = w - 16
        local lines = math.ceil(tw / maxW)
        local bw = math.min(tw, maxW) + 16
        local bh = (font:getHeight() * k) * lines + 12
        local x, y = math.floor((w - bw) / 2), math.floor(h * 0.06)
        love.graphics.setColor(0, 0, 0, 0.75)
        love.graphics.rectangle("fill", x, y, bw, bh, 6, 6)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(toast.text, x + 8, y + 6, (bw - 16) / k, "center", 0, k, k)
        love.graphics.pop()
      end)
    end
    return unpack(r)
  end

  local origEnd = Renderer.endWorldPass
  Renderer.endWorldPass = function(self, ...)
    if state.reuse and state.final and self.setWorldOverride then
      state.reuse = false
      pcall(self.setWorldOverride, self, state.final)
      return origEnd(self, ...)
    end
    if state.pending then
      local target = love.graphics.getCanvas()
      local t0 = love.timer.getTime()
      state.tJobFrame = 0
      local ok, err = pcall(Bridge.renderPending, self)
      -- background rebuild time is shown separately ("bg"), not as drawing
      state.tBg = state.tJobFrame or 0
      state.tRender = (love.timer.getTime() - t0) * 1000 - state.tBg
      local total = (state.tCapture or 0) + state.tRender
      state.avgMs = state.avgMs and (state.avgMs * 0.9 + total * 0.1) or total
      state.lastShown = ok
      if ok then state.lastShownT = love.timer.getTime() end
      if not ok then
        love.graphics.setCanvas(target)
        if self.setWorldOverride then
          pcall(self.setWorldOverride, self, canHold(self) and state.final or nil)
        end
        fail("render", err)
      end
    end
    return origEnd(self, ...)
  end

  state.installed = true
  return true
end

function Bridge.release()
  Scene.release()
  for _, key in ipairs({ "ground", "atlas", "lowres", "final", "probe", "overlayCopy", "sceneFull" }) do
    if state[key] then state[key]:release() end
    state[key] = nil
  end
  state.grid, state.built = nil, nil
end

Bridge._state = state
return Bridge
