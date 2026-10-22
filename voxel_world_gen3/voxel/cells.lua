-- Gen 3 map cells for the heightfield, read-only.
--
-- Coordinates are the engine's: 16px cells in the current (primary) map's
-- space, with connected maps placed where src/core/game3/map.lua's
-- Map.world put them, and the primary map's border tiling beyond that.
-- Collision bytes are the engine's translated COLL_* values
-- (src/core/game3/scripting/collision_frlg.lua), which RSE shares.

local use = ...
local Engine = use("engine")
local Tiles = use("tiles")

local Cells = {}

-- map id -> header map type, learned while each map is the current one
-- (bridge.lua keeps it across restarts)
Cells.mapTypes = {}

local COLL_SOLID = { [0x07] = true, [0xff] = true, [0x82] = true, [0x90] = true, [0x93] = true }
local COLL_WATER = 0x29
local COLL_GRASS = { [0x18] = true, [0x14] = true }
local COLL_LEDGE = { [0xA0] = true, [0xA1] = true, [0xA2] = true, [0xA3] = true }
-- doors and keep-facing warps: walkable, but cut into a facade.  (0x2B is
-- the engine's "cave" class -- metatile behaviour MB_CAVE, a cave FLOOR --
-- not an opening: RSE uses that behaviour on the staggered lawn cells along
-- a forest's edge too, and as a "door" they glued the trees beside them
-- into long flat walls.  Cave mouths come from MB_CAVE_DOOR, caveDoor.)
local COLL_OPENING = { [0x71] = true, [0x72] = true }

-- pokefirered general-tileset tree metatiles (collision_frlg.lua TREE_MIDS):
-- solid ones are trunks, walkable ones are the canopy over the path behind
local FRLG_TREE = {
  [0x00A] = true, [0x00B] = true, [0x00C] = true, [0x00E] = true,
  [0x00F] = true, [0x013] = true,
}
for mid = 0x014, 0x01F do FRLG_TREE[mid] = true end
for mid = 0x024, 0x027 do FRLG_TREE[mid] = true end

local function familyName()
  local Family = Engine.get("src.import.gba.family")
  if not (Family and Family.active) then return nil end
  local okA, fam = pcall(Family.active)
  return okA and type(fam) == "table" and fam.name or nil
end

-- A provider bound to the map that is current right now.  Returns nil when
-- there is no field map (title, battle-only states, a map still streaming).
Cells.family = familyName

function Cells.provider()
  local Map = Engine.get("src.core.game3.map")
  if not (Map and Map.currentDef) then return nil end
  local def = Map.currentDef()
  local cmt = def and tonumber(def.mapType)
  if cmt and Map.current ~= nil and Cells.mapTypes[tostring(Map.current)] ~= cmt then
    Cells.mapTypes[tostring(Map.current)] = cmt
    Cells.typesDirty = true
  end
  local layout = def and def.midLayout
  if not (layout and layout.midAt and layout.width) then return nil end
  local frlg = familyName() == "frlg"
  -- metatile behaviours tell a cave mouth (MB_CAVE_DOOR, non-animated) from
  -- a house door (MB_WARP_DOOR); collision maps both to the same door byte
  local Coll = Engine.get("src.core.game3.collision")
  local MBm = Engine.get("src.core.game3.mb")
  local CAVE_DOOR = 0x60
  if MBm and MBm.require then
    local ok, v = pcall(MBm.require, "CAVE_DOOR")
    if ok and type(v) == "number" then CAVE_DOOR = v end
  end
  -- real doors (houses, the Poke Center, gyms): the animated door
  -- behaviour, the same value in both families; Petalburg Gym's own
  local WARP_DOOR, GYM_DOOR = 0x69, nil
  if MBm and MBm.require then
    local ok, v = pcall(MBm.require, "WARP_DOOR")
    if ok and type(v) == "number" then WARP_DOOR = v end
  end
  if MBm and MBm.id then
    local ok, v = pcall(MBm.id, "PETALBURG_GYM_DOOR")
    if ok and type(v) == "number" then GYM_DOOR = v end
  end
  local world = Map.world or {}

  local function locate(cx, cy)
    local w, h = layout.trueWidth or layout.width, layout.trueHeight or layout.height
    if cx >= 0 and cy >= 0 and cx < w and cy < h then
      return layout, cx, cy, def, Map.current
    end
    for _, entry in ipairs(world) do
      local d = entry.def
      local L = d and d ~= def and d.midLayout
      if L and L.midAt then
        local nx, ny = cx - (entry.ox or 0), cy - (entry.oy or 0)
        local lw = L.trueWidth or L.width or 0
        local lh = L.trueHeight or L.height or 0
        if nx >= 0 and ny >= 0 and nx < lw and ny < lh then
          return L, nx, ny, d, entry.id
        end
      end
    end
    return nil
  end

  local function cell(cx, cy)
    local L, nx, ny, d, did = locate(cx, cy)
    local mid, coll, border
    if L then
      mid = L:midAt(nx, ny)
      coll = L.collAt and L:collAt(nx, ny) or 0
    else
      -- beyond every loaded map: the primary map's border (a wall of trees
      -- outdoors, the black surround indoors).  Solid either way.
      mid = layout:midAt(cx, cy)
      coll = 0xff
      d = def
      border = true
    end
    local kind = "ground"
    if COLL_SOLID[coll] then
      kind = "solid"
    elseif coll == COLL_WATER then
      kind = "water"
    elseif COLL_GRASS[coll] then
      kind = "grass"
    elseif COLL_LEDGE[coll] then
      kind = "ledge"
    elseif COLL_OPENING[coll] then
      kind = "door"
    end
    -- the map this cell belongs to is a town or a city (header map type
    -- 1 / 2, both families): a neighbouring town seen from a route keeps
    -- its street lamps, a route seen from a town gets none
    -- (a neighbour's def may not carry its header's map type yet: then the
    -- type remembered from when it was the current map (Cells.mapTypes),
    -- else not a town -- the engine's own "kind" calls routes towns too)
    local dd = d or def
    local mt = dd and tonumber(dd.mapType)
    if not mt then mt = Cells.mapTypes[tostring(did or (d == nil and Map.current) or "?")] end
    local town = mt ~= nil and (mt == 1 or mt == 2)
    local info = { kind = kind, mid = mid, coll = coll, border = border, town = town,
      map = tostring(did or Map.current),
      pair = (L and L.pair) or (d and (d.pair or (d.midLayout and d.midLayout.pair))) }
    -- the map's elevation (caves: 3 the floor, 4 and up the raised levels;
    -- 0 and 15 are stairs and bridges that belong to either)
    if L and L.elevAt then
      local ok, e = pcall(L.elevAt, L, nx, ny)
      if ok then info.elev = e end
    end
    -- any cell: a cave mouth may not carry a door collision at all
    if kind ~= "solid" and L and Coll and Coll.behaviorOn then
      local ok, beh = pcall(Coll.behaviorOn, d, nx, ny)
      if ok and beh ~= nil then info.behKnown = true; info.beh = beh end
      if ok and beh == CAVE_DOOR then info.caveDoor = true end
      if ok and beh ~= nil and (beh == WARP_DOOR or beh == GYM_DOOR) then info.warpDoor = true end
    end
    if frlg and (d and d.kind) ~= "indoor" and mid and mid < 640 and FRLG_TREE[mid] then
      if kind == "solid" then info.tree = true else info.canopy = true end
    end
    return info
  end

  return {
    def = def,
    layout = layout,
    mapId = Map.current,
    revision = layout._revision or 0,
    kind = def.kind,
    cell = cell,
    -- the object outline in a cell's tile (tiles.lua): nil / false when
    -- the tileset cannot tell
    shape = function(info) return info and Tiles.shape(info.pair, info.mid) end,
    over = function(info) return info and Tiles.overCount(info.pair, info.mid) end,
    family = frlg and "frlg" or "rse",
  }
end

return Cells
