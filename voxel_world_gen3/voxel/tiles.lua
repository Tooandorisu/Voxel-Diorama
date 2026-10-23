-- What a map tile (metatile) holds, read once from the game's own tileset
-- at full resolution -- not from the quarter-size picture of the screen
-- the heightfield judges relief by.
--
-- The engine keeps every tileset pair's metatiles as image data in three
-- layers (src/core/game3/tileset_native.lua, built by
-- src/import/gba/metatile.lua after pret's DrawMetatile):
--   imageData     drawn under sprites
--   midImageData  NORMAL: the bottom layer;  COVERED: the top layer
--   overImageData drawn over sprites (NORMAL / SPLIT: the top layer)
-- Map designers draw ground in a metatile's bottom layer and the object
-- standing on it -- a lamp post, a sign, a fence -- in its top layer, so the
-- top layer's opaque pixels are the object's exact outline.
--
-- The answer depends only on (tileset pair, metatile id): every lamp built
-- from the same tile gets the same verdict, wherever it stands and however
-- the camera lines up -- in FireRed/LeafGreen and Ruby/Sapphire/Emerald
-- alike, with no per-map tables.

local use = ...
local Engine = use("engine")

local Tiles = {}

local floor = math.floor
local cache = {}
Tiles._cache = cache
local overCache = {}

-- for tests: a stand-in for tileset_native
local source
function Tiles.setSource(src)
  source = src
  for k in pairs(cache) do cache[k] = nil end
  for k in pairs(overCache) do overCache[k] = nil end
end

local function tileset(pair)
  local NT = source or Engine.get("src.core.game3.tileset_native")
  if not (NT and pair) then return nil end
  -- only a pair already resident: loading one streams and yields, which
  -- must not happen inside the background rebuild (the field view keeps
  -- the pairs on screen loaded anyway)
  return NT._pairs and NT._pairs[pair] or nil
end

local function opaque(data, x0, y0)
  local mask, n = {}, 0
  for y = 0, 15 do
    for x = 0, 15 do
      local _, _, _, a = data:getPixel(x0 + x, y0 + y)
      if a and a > 0.5 then
        mask[y * 16 + x] = true
        n = n + 1
      end
    end
  end
  return mask, n
end

-- The outline of the object in a metatile's top layer:
--   { n = opaque pixels, rows, cols, medW = median row width, minX, maxX,
--     minY, maxY, left/right/top/bottom = touches that edge }
-- false when the tileset has no layer split (nothing to tell by);
-- nil while the tileset is not loaded yet (asked again later).
function Tiles.shape(pair, mid)
  if not (pair and mid) then return nil end
  local key = tostring(pair) .. ":" .. tostring(mid)
  local s = cache[key]
  if s ~= nil then return s end
  local ts = tileset(pair)
  if not ts then return nil end
  if not (ts.overImageData and ts.midToSlot and ts.cols) then
    cache[key] = false
    return false
  end
  local slot = ts.midToSlot[mid]
  if slot == nil then
    cache[key] = false
    return false
  end
  local x0, y0 = (slot % ts.cols) * 16, floor(slot / ts.cols) * 16
  local mask, n = opaque(ts.overImageData, x0, y0)
  -- nothing over sprites: a COVERED metatile keeps its top layer in the
  -- middle image (a NORMAL one keeps its bottom layer there -- solid ground,
  -- which reads as a full block, not a post)
  if n == 0 and ts.midImageData then
    mask, n = opaque(ts.midImageData, x0, y0)
  end
  s = { n = n, rows = 0, cols = 0, medW = 0, minX = 16, maxX = -1, minY = 16, maxY = -1 }
  local widths = {}
  local colSeen = {}
  for y = 0, 15 do
    local w = 0
    for x = 0, 15 do
      if mask[y * 16 + x] then
        w = w + 1
        colSeen[x] = true
        if x < s.minX then s.minX = x end
        if x > s.maxX then s.maxX = x end
        if y < s.minY then s.minY = y end
        if y > s.maxY then s.maxY = y end
      end
    end
    if w > 0 then widths[#widths + 1] = w end
  end
  s.rows = #widths
  for _ in pairs(colSeen) do s.cols = s.cols + 1 end
  table.sort(widths)
  s.medW = #widths > 0 and widths[floor((#widths + 1) / 2)] or 0
  s.left, s.right = s.minX == 0, s.maxX == 15
  s.top, s.bottom = s.minY == 0, s.maxY == 15
  cache[key] = s
  return s
end

-- How many pixels of a metatile are drawn over sprites (its top layer in
-- the over image alone): FRLG draws a tree's crown there, so the player
-- walks behind it; rock, roofs and walls draw nothing there.
-- nil while the tileset is not loaded, 0 when it has no layer split.
function Tiles.overCount(pair, mid)
  if not (pair and mid) then return nil end
  local key = tostring(pair) .. ":" .. tostring(mid)
  local v = overCache[key]
  if v ~= nil then return v end
  local ts = tileset(pair)
  if not ts then return nil end
  local slot = ts.midToSlot and ts.midToSlot[mid]
  if not (ts.overImageData and ts.cols and slot) then
    overCache[key] = 0
    return 0
  end
  local _, n = opaque(ts.overImageData, (slot % ts.cols) * 16, floor(slot / ts.cols) * 16)
  overCache[key] = n
  return n
end

-- A metatile's art at a pixel (x, y in 0..15), as drawn: the layers under
-- sprites, then the top layer over them.  Read from the tileset itself, so
-- the same for every cell built from that tile, wherever the camera is --
-- the heightfield's tests on art (rock or house, trees, relief) gave a
-- different answer near the edge of the screen capture than in its
-- middle, and the scene changed shape as you walked.
-- nil when the tileset is not resident.
function Tiles.pixel(pair, mid, x, y)
  local ts = tileset(pair)
  if not ts then return nil end
  local slot = ts.midToSlot and ts.midToSlot[mid]
  local data = ts.imageData
  if slot == nil or not (data and ts.cols) then return nil end
  local px, py = (slot % ts.cols) * 16 + x, floor(slot / ts.cols) * 16 + y
  local r, g, b, a = data:getPixel(px, py)
  -- (a COVERED metatile keeps its top layer in the middle image: tree
  -- crowns over the teal ground between them in RSE forests)
  if ts.midImageData then
    local r1, g1, b1, a1 = ts.midImageData:getPixel(px, py)
    if a1 and a1 > 0.5 then r, g, b, a = r1, g1, b1, 1 end
  end
  if ts.overImageData then
    local r2, g2, b2, a2 = ts.overImageData:getPixel(px, py)
    if a2 and a2 > 0.5 then r, g, b, a = r2, g2, b2, 1 end
  end
  if not a or a < 0.5 then return nil end
  return r, g, b
end

return Tiles
