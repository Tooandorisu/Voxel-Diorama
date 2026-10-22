-- Standalone: luajit mods/voxel_world_gen3/tests/voxel_world_gen3_test.lua
-- (run from the repo root).  Loads the mod through the real loader on a
-- Gen 3 boot, then checks the heightfield's un-projection rules and the
-- mesher on small hand-built maps.  No ROM and no LOVE window needed; the
-- GPU half is exercised by eye, see README.md.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")

local MOD = "mods/voxel_world_gen3"

-- ------- loads clean through the real loader and sandbox

do
  local run = T.sdk.loadMod(MOD, { generation = 3 })
  T.eq(#run.errors, 0, "loads clean on Gen 3 (" .. tostring(run.errors[1]) .. ")")
  local exports = run.loader.exports.voxel_world_gen3
  T.check(type(exports) == "table" and exports.version == "1.26.0", "exports its version")
  T.check(Runtime.wantsHook("input.key"), "claims the hotkey through input.key")
  T.check(Runtime.wantsHook("input.step"), "re-reads its options through input.step")
  local schema = run.loader.optionSchemas.voxel_world_gen3
  T.check(type(schema) == "table" and #schema >= 4, "defines its option rows")

  -- the hotkey is consumed in free roam and passed through otherwise
  local passed = false
  local function vanilla() passed = true return "vanilla" end
  local game = { zoomGateOK = function() return true end }
  local r = Runtime.call("input.key", vanilla, game, { phase = "pressed", key = "6" })
  T.check(r == true and not passed, "6 cycles the view in free roam")
  T.eq(exports.level(), 3, "MID -> HIGH")
  passed = false
  Runtime.call("input.key", vanilla, { zoomGateOK = function() return false end },
    { phase = "pressed", key = "6" })
  T.check(passed, "6 reaches the game while a menu or script holds the field")
  passed = false
  Runtime.call("input.key", vanilla, game, { phase = "pressed", key = "x" })
  T.check(passed, "other keys pass straight through")
  run.release()
end

-- ------- pure modules

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
local cache = {}
local function use(name)
  if cache[name] == nil then
    cache[name] = assert(loadstring(read(MOD .. "/voxel/" .. name .. ".lua"), "@" .. name))(use)
  end
  return cache[name]
end
local HF, Mesher, Camera = use("heightfield"), use("mesher"), use("camera")

-- inside the mod sandbox `package` is a stand-in whose `loaded` is empty, so
-- every engine lookup must go through require (voxel/engine.lua)
for _, f in ipairs({ "main.lua", "voxel/bridge.lua", "voxel/cells.lua", "voxel/scene.lua",
                     "voxel/heightfield.lua", "voxel/mesher.lua", "voxel/camera.lua", "voxel/tiles.lua", "voxel/critters.lua", "voxel/smoke.lua", "voxel/footprints.lua", "voxel/caves.lua" }) do
  T.check(not read(MOD .. "/" .. f):find("package%.loaded"), f .. " never reads package.loaded")
end
do
  local Sandbox = require("src.mods.Sandbox")
  require("src.render.Tilt")
  local env = Sandbox.envFor({ modId = "voxel_world_gen3", permissions = { engine_internals = true } })
  local Engine = assert(Sandbox.compile(read(MOD .. "/voxel/engine.lua"), "@engine", env))()
  T.check(Engine.get("src.render.Tilt") == require("src.render.Tilt"),
    "Engine.get returns the engine's own module from inside the sandbox")
end

local function mapProvider(rows, legend)
  return {
    cell = function(cx, cy)
      local row = rows[cy + 1]
      if not row or cx < 0 or cx >= #row then return { kind = "solid" } end
      local ch = row:sub(cx + 1, cx + 1)
      local k = legend[ch] or { kind = "ground" }
      return k
    end,
  }
end

local L = {
  ["."] = { kind = "ground" }, ["#"] = { kind = "solid" }, ["D"] = { kind = "door" },
  ["~"] = { kind = "water" }, ["T"] = { kind = "solid", tree = true },
  ["c"] = { kind = "ground", canopy = true }, ["="] = { kind = "ledge" },
}

local function at(grid, wx, wy)
  local vx = math.floor((wx - grid.px) / HF.VOXEL)
  local vy = math.floor((wy - grid.py) / HF.VOXEL)
  local k = vy * grid.vcols + vx + 1
  return grid.H[k], grid.S[k], grid.K[k], grid.C[k], grid.W and grid.W[k]
end

do
  -- a four-row house with a door in its bottom row, standing on grass
  local map = {
    "........",
    "..###...",
    "..###...",
    "..###...",
    "..#D#...",
    "........",
    "~~......",
  }
  local grid = HF.build(mapProvider(map, L), 0, 0, 8, 7, { lumps = false })
  -- run of 4 -> two storeys (32px) over the whole footprint
  local h, s, kk, cc = at(grid, 2 * 16 + 8, 1 * 16 + 2)
  T.eq(h, 32, "the whole footprint is raised (no ground strip behind it)")
  T.check(math.abs((kk * 16 + cc) - 16) < 1e-6, "...its top starts at the art's first row")
  T.check(math.abs((kk * 80 + cc) - 48) < 1e-6, "...and ends where the facade art begins")
  h, s = at(grid, 2 * 16 + 8, 3 * 16 + 8)
  T.eq(h, 32, "the southern rows are the footprint, two storeys tall")
  T.eq(s, 32, "...and sample their art 32px north (roof on top)")
  h = at(grid, 3 * 16 + 8, 4 * 16 + 8)
  T.eq(h, 32, "a door is part of the facade it is cut into")
  T.check(HF.insideAt(grid, 3 * 16 + 8, 4 * 16 + 12), "a character in the doorway is inside it")
  T.check(not HF.insideAt(grid, 3 * 16 + 8, 5 * 16 + 12), "one on the step in front is not")
  h = at(grid, 0 * 16 + 8, 6 * 16 + 8)
  T.eq(h, HF.WATER, "water sits below the bank")
  T.eq(HF.floorAt(grid, 8, 6 * 16 + 8), HF.WATER, "a surfer rides on the water")
  T.eq(HF.floorAt(grid, 3 * 16 + 8, 3 * 16 + 8), 0, "floorAt never puts feet on a roof")
end

do
  -- a lone FRLG tree: walkable canopy cell over a solid trunk
  local map = { "....", ".c..", ".T..", "...." }
  local grid = HF.build(mapProvider(map, L), 0, 0, 4, 4, { lumps = false })
  local h, s = at(grid, 16 + 8, 2 * 16 + 8)
  T.eq(h, 16, "the trunk cell carries a one-storey tree")
  T.eq(s, 16, "...whose top shows the canopy cell's art")
  local w
  h, s, _, _, w = at(grid, 16 + 8, 16 + 4)
  T.eq(h, 16, "the canopy cell is the top of the same tree")
  T.check(w == true, "...and stays walkable")
  T.check(not HF.insideAt(grid, 16 + 8, 16 + 8), "a player in the canopy row is not hidden like a doorway")
end

do
  -- one-cell things are knee high; ledges are a lip
  local map = { "......", ".#....", "......", "======", "......" }
  local grid = HF.build(mapProvider(map, L), 0, 0, 6, 5, { lumps = false })
  T.eq((at(grid, 16 + 8, 16 + 12)), 8, "a fence or sign is an 8px slab")
  T.eq((at(grid, 8, 3 * 16 + 12)), 4, "a ledge is a 4px lip")
  local _, _, kk, cc = at(grid, 8, 3 * 16 + 1)
  T.check(math.abs((kk * 48 + cc) - 48) < 1e-6 and math.abs((kk * 64 + cc) - 60) < 1e-6,
    "...whose top stretches its art over the whole cell")
end

do
  -- a window that runs off an all-solid border must terminate
  local grid = HF.build({ cell = function() return { kind = "solid" } end }, -5, -5, 6, 6, {})
  T.check(grid.vcols == 24, "all-solid surroundings build without running away")
  local verts, idx, nv, ni = Mesher.build(grid, HF.VOXEL)
  T.check(nv > 0 and ni % 3 == 0, "and still mesh")
end

do
  -- flat ground greedy-merges into one quad
  local grid = HF.build({ cell = function() return { kind = "ground" } end }, 0, 0, 10, 10, {})
  local verts, idx, nv, ni = Mesher.build(grid, HF.VOXEL)
  T.eq(nv, 4, "a flat field is a single quad")
  T.eq(ni, 6, "two triangles")
end

do
  -- the front wall follows the oblique rule (x, y - z); the top stretches
  -- the rest of the art over the footprint; the ground is flat
  local map = { "......", "..##..", "..##..", "..##..", "......" }
  local grid = HF.build(mapProvider(map, L), 0, 0, 6, 5, { lumps = false })
  local verts, _, nv = Mesher.build(grid, HF.VOXEL)
  local K, C = 16 / 48, 32 - 64 * 16 / 48
  local bad, front = 0, 0
  for i = 1, nv do
    local v = verts[i]
    local x, y, z, u, s = v[1], v[2], v[3], v[4], v[5]
    if math.abs(u - x) > 0.5 then bad = bad + 1 end
    local zc = math.max(0, math.min(z, 32))
    local struct = math.abs(s - (K * y + C + 32 - zc)) <= 0.6
    local flat = math.abs(s - y) <= 0.5
    if math.abs(y - 64) < 0.6 and z > 1 then
      front = front + 1
      if math.abs(s - (y - z)) > 0.6 then bad = bad + 1 end
    end
    if not (struct or flat) then bad = bad + 1 end
  end
  T.eq(bad, 0, "all samples follow the oblique un-projection / roof stretch")
  T.check(front > 0, "...the front wall was checked")
end

do
  -- camera: the focus lands mid-screen and north is up
  local cam = Camera.solve({ fx = 100, fy = 100, fz = 0, pitch = 45, fov = 30,
    scale = 4, width = 960, height = 640 })
  local sx, sy = Camera.project(cam, 100, 100, 0)
  T.check(math.abs(sx - 480) < 0.01 and math.abs(sy - 320) < 0.01, "focus projects to centre")
  local _, ny = Camera.project(cam, 100, 60, 0)
  T.check(ny < sy, "north of the player is up the screen")
  local _, uy = Camera.project(cam, 100, 100, 20)
  T.check(uy < sy, "up is up the screen")
  local gx, gy = Camera.groundHit(cam, 480, 320, 0)
  T.check(math.abs(gx - 100) < 0.01 and math.abs(gy - 100) < 0.01, "groundHit inverts project")
  -- at the focus, one world pixel is `scale` screen pixels tall when seen
  -- face-on, like the flat view
  local _, y1 = Camera.project(cam, 100, 100, 0)
  local a = math.rad(45)
  local _, y2 = Camera.project(cam, 100, 100 - 10 * math.cos(a), 10 * math.sin(a))
  T.check(math.abs((y1 - y2) - 40) < 0.5, "framing matches the flat view's scale")
end

do
  -- mountains: a deep run of rock-coloured cells stands taller than a
  -- building, and only when the caller allows rock (outdoors / caves)
  local rows = {}
  for y = 1, 14 do rows[y] = "###" end
  rows[15] = "..."
  local function colored(r, g, b)
    local cell = mapProvider(rows, L).cell
    return { cell = cell, color = function(wx, wy)
      local c = cell(math.floor(wx / 16), math.floor(wy / 16))
      if c and c.kind ~= "solid" then return 0.45, 0.75, 0.38 end -- the grass around it
      return r, g, b
    end }
  end
  local rockArt = colored(0.85, 0.72, 0.62)
  local roofArt = colored(0.30, 0.50, 0.85)
  local g1 = HF.build(rockArt, 0, 0, 3, 15, { rock = true, lumps = false })
  local g2 = HF.build(roofArt, 0, 0, 3, 15, { rock = true, lumps = false })
  local g3 = HF.build(rockArt, 0, 0, 3, 15, { rock = false, lumps = false })
  T.eq(select(2, at(g1, 16 + 8, 13 * 16 + 8)), 48, "a 14-cell rock mass stands 48px tall")
  T.eq(select(2, at(g2, 16 + 8, 13 * 16 + 8)), 32, "a blue-roofed run stays two storeys")
  T.eq(select(2, at(g3, 16 + 8, 13 * 16 + 8)), 32, "indoors (rock off) beige walls stay two storeys")
  T.eq(HF.rockHeight(5), nil, "small rock outcrops keep the ordinary run heights")
  local g4 = HF.build(rockArt, 0, 0, 3, 15, { rock = true, lumps = true })
  local bumps = {}
  for vx = 4, 7 do
    local k = (13 * 4 + 2) * g4.vcols + vx + 1
    bumps[g4.H[k]] = true
  end
  T.check(next(bumps) ~= nil, "rock tops get relief when LEAF RELIEF is on")
end

do
  -- sky vs black void: the cart's mapType decides, not the "town" default
  local Bridge = use("bridge")
  T.check(Bridge.isOutdoor({ mapType = 3, kind = "route" }), "a route has a sky")
  T.check(Bridge.isOutdoor({ mapType = 1, kind = "town" }), "a town has a sky")
  T.check(not Bridge.isOutdoor({ mapType = 8, kind = "town" }), "an indoor map is dark even when kind fell back to town")
  T.check(not Bridge.isOutdoor({ mapType = 4 }), "a cave is dark")
  T.check(not Bridge.isOutdoor({ kind = "indoor" }), "kind is the fallback without a mapType")
  local function layout(code)
    return { width = 10, height = 10, collAt = function(_, x, y) return (y < 6) and code or 0 end }
  end
  T.check(Bridge.isOutdoor({ mapType = 7, midLayout = layout(0x29) }), "an 'unknown' map that is mostly sea (the S.S. Anne harbour) has a sky")
  T.check(not Bridge.isOutdoor({ mapType = 7, midLayout = layout(0x07) }), "an 'unknown' map of floor and walls stays dark")
  local function pool(code)
    return { width = 10, height = 10, collAt = function(_, x, y) return (y < 2 and x < 4) and code or 0 end }
  end
  T.check(not Bridge.isOutdoor({ mapType = 8, midLayout = pool(0x29) }), "an indoor map with a pool is still indoors")
  T.check(Bridge.isOutdoor({ mapType = 8, midLayout = layout(0x29) }), "an 'indoor' map that is mostly open sea (the harbour) has a sky")
  T.check(not Bridge.isOutdoor({ mapType = 4, midLayout = layout(0x29) }), "a cave with a big lake stays dark")
end

do
  -- relief detail: coarse bumps keep forests and mountains cheap
  local function noisy(wx, wy)
    local h = math.sin(math.floor(wx / 4) * 12.9898 + math.floor(wy / 4) * 78.233) * 43758.5453
    h = h - math.floor(h)
    return 0.2 + 0.2 * h, 0.5 + 0.3 * h, 0.25
  end
  local forest = { cell = function(cx, cy) return { kind = "solid", tree = true } end, color = noisy }
  local function count(opts)
    local g = HF.build(forest, 0, 0, 16, 16, opts)
    local _, _, nv = Mesher.build(g, HF.VOXEL)
    return nv
  end
  local fine = count({ reliefBlock = 1, reliefStep = 1 })
  local bal = count({ reliefBlock = 2, reliefStep = 4 })
  local potato = count({ reliefBlock = 4, reliefStep = 4 })
  local flat = count({ lumps = false })
  T.check(bal * 5 < fine, ("balanced relief is >5x lighter than per-voxel (%d vs %d)"):format(bal, fine))
  T.check(potato < bal and flat <= potato, ("potato relief is lighter still (%d, flat %d)"):format(potato, flat))
end

do
  -- AUTO quality steps down after a sustained slow spell, not on a hitch
  local Bridge = use("bridge")
  local st = Bridge._state
  Bridge.configure({ quality = "auto" })
  st.autoTier, st.emaDt, st.settleUntil = 0, nil, nil
  local t = 100
  for _ = 1, 120 do t = t + 1 / 60; Bridge.adapt(1 / 60, t) end
  T.eq(st.autoTier, 0, "60 fps stays at the top tier")
  Bridge.adapt(0.5, t) -- a load hitch
  T.eq(st.autoTier, 0, "one long frame is ignored")
  for _ = 1, 150 do t = t + 1 / 30; Bridge.adapt(1 / 30, t) end
  T.eq(st.autoTier, 1, "30 fps for a few seconds steps down one tier")
  T.check(Bridge.preset().budget < Bridge.AUTO_TIERS[0].budget, "...to fewer pixels")
  for _ = 1, 3000 do t = t + 1 / 30; Bridge.adapt(1 / 30, t) end
  T.eq(st.autoTier, #Bridge.AUTO_TIERS, "and on down to the potato tier, never past it")
  T.check(Bridge.preset().half == true, "the last tiers redraw 3D at half rate")
  Bridge.configure({ quality = "potato" })
  T.eq(Bridge.preset().name, "POTATO", "a fixed preset ignores the AUTO tier")
  Bridge.configure({ quality = "auto" })
  st.autoTier = 0
end

do
  -- baked light: a block shadows the ground south-east of it, not north-west
  local Lighting = use("lighting")
  local map = { "........", "........", "...##...", "...##...", "........", "........", "........" }
  local grid = HF.build(mapProvider(map, L), 0, 0, 8, 7, { lumps = false })
  Lighting.bake(grid, HF.VOXEL, {})
  local function sunAt(wx, wy) return (Lighting.at(grid, wx, wy, HF.VOXEL)) end
  T.eq(sunAt(5 * 16 + 1, 4 * 16 + 1), 0, "the ground just south-east of a block is in its shadow")
  T.eq(sunAt(2 * 16 + 4, 1 * 16 + 4), 1, "the ground north-west of it is in the sun")
  T.eq(sunAt(3 * 16 + 8, 2 * 16 + 8), 1, "its own top is in the sun")
  local _, aoWall = Lighting.at(grid, 5 * 16 + 2, 3 * 16 + 8, HF.VOXEL)
  local _, aoOpen = Lighting.at(grid, 7 * 16 + 8, 6 * 16 + 8, HF.VOXEL)
  T.check(aoWall < aoOpen and aoOpen == 1, "ground hugging a wall is darker than open ground")
  Lighting.bake(grid, HF.VOXEL, { sun = false })
  T.eq(sunAt(5 * 16 + 1, 4 * 16 + 1), 1, "indoors there is no sun shadow, only corner darkening")
end

do
  -- a fence running north-south is one cell wide: knee-high, not a wall
  local map = { "........", "..#.##..", "..#.##..", "..#.##..", "..#.##..", "........" }
  local grid = HF.build(mapProvider(map, L), 0, 0, 8, 6, { lumps = false })
  T.eq((at(grid, 2 * 16 + 8, 4 * 16 + 8)), 8, "a long one-cell-wide fence stays 8px")
  T.eq((at(grid, 4 * 16 + 8, 4 * 16 + 8)), 32, "a two-cell-wide block of the same depth is two storeys")
end

do
  -- solid cells that are flat on screen stay flat: lawn that is only
  -- impassable, and the sea in the map's border
  local rows = { "........", ".###.##.", ".###.##.", ".###.##.", "........" }
  local base = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      if cy < 0 then return { kind = "solid", border = true, mid = 9 } end
      local c = base(cx, cy)
      if not c then return nil end
      local roof = cx >= 5 and cx <= 6 and cy >= 1 and cy <= 3
      -- lawn, walkable or not, is metatile 1; the roof has its own pieces,
      -- and the walkable row over it shares the roof's look but not its ids
      local out = { kind = c.kind, mid = roof and (40 + cx + cy * 8) or 1 }
      if cy == 0 and (cx == 5 or cx == 6) then out.mid = 60 end
      return out
    end,
    color = function(wx, wy)
      local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
      if cy < 0 then return 0.25, 0.45, 0.9 end            -- sea
      if cx >= 5 and cx <= 6 and cy >= 1 and cy <= 3 then  -- a roof
        return ((wy % 8) < 4) and 0.8 or 0.55, 0.3, 0.25
      end
      local tuft = ((wx + wy) % 12 == 0) and 0.05 or 0       -- grass, solid or not
      return 0.45 + tuft, 0.75 + tuft, 0.38
    end,
  }
  local grid = HF.build(provider, 0, -2, 8, 7, { lumps = false })
  T.eq((at(grid, 2 * 16 + 8, 2 * 16 + 8)), 0, "impassable lawn that looks like the grass beside it is ground")
  T.eq((at(grid, 5 * 16 + 8, 3 * 16 + 8)), 32, "a red-roofed building beside it still stands")
  T.eq((at(grid, 3 * 16 + 8, -1 * 16 + 8)), HF.WATER, "sea in the map border lies flat as water")
  T.eq((at(grid, 6 * 16 + 8, 1 * 16 + 8)), 32, "a roof whose colours match the walkable row behind it still stands")
end

do
  -- round trees: crowns lower toward their edges, and the lowered top
  -- still meets the facade under it
  local map = { "......", ".c.c..", ".T.T..", "......" }
  local provider = mapProvider(map, L)
  local flat = HF.build(provider, 0, 0, 6, 4, { lumps = false })
  local soft = HF.build(provider, 0, 0, 6, 4, { lumps = false, round = "soft" })
  local _, _, nvFlat = Mesher.build(flat, HF.VOXEL)
  local function hk(g, wx, wy)
    local k = math.floor((wy - g.py) / 4) * g.vcols + math.floor((wx - g.px) / 4) + 1
    return g.H[k], g.S[k], g.K[k], g.C[k]
  end
  local hc = hk(soft, 16 + 8, 2 * 16 + 4)
  local he = hk(soft, 16 + 1, 2 * 16 + 4)
  T.eq(hc, 16, "the middle of a crown keeps the tree's height")
  T.check(he < hc, ("its east/west edge is lower (%s < %s)"):format(tostring(he), tostring(hc)))
  local h, s2, kk, cc = hk(soft, 16 + 1, 2 * 16 + 14)
  local frontTop = kk * (3 * 16) + cc
  T.check(math.abs(frontTop - (3 * 16 - h)) < 1e-6, "a lowered top meets the oblique facade under it")
  T.eq((hk(flat, 16 + 1, 2 * 16 + 4)), 16, "ROUND TREES off keeps flat-topped trees")
  local _, _, nvSoft = Mesher.build(soft, HF.VOXEL)
  T.check(nvSoft > nvFlat, "rounding costs some vertices, as expected")
end

do
  -- sloped roofs: one gable per building, split where the roof colour
  -- changes; none on trees, fences or when switched off
  local rows = { "..........", ".######.#.", ".######.#.", ".######.#.", ".######.#.", ".........." }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      local cx = math.floor(wx / 16)
      local c = cell(cx, math.floor(wy / 16))
      if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
      if cx <= 3 then                            -- a blue roof, striped
        local k = (wx % 8 < 4) and 1 or 0.7
        return 0.25 * k, 0.4 * k, 0.85 * k
      end
      return 0.85, 0.3, 0.25                     -- a red roof next door
    end,
  }
  local grid = HF.build(provider, 0, 0, 10, 6, { lumps = false, roofs = true })
  T.eq(#grid.roofs, 2, "two buildings wall to wall get a roof each (the one-cell post gets none)")
  T.eq(grid.roofs[1].x1, 16, "the first roof starts at its building's west wall")
  T.eq(grid.roofs[1].x2, 4 * 16, "...spans its light and dark stripes, and ends where the roof colour changes")
  local off = HF.build(provider, 0, 0, 10, 6, { lumps = false })
  T.eq(#off.roofs, 0, "SLOPED ROOFS off: flat tops")
  local verts, _, nv = Mesher.build(grid, HF.VOXEL)
  local _, _, nvOff = Mesher.build(off, HF.VOXEL)
  local top = 0
  for i = 1, nv do top = math.max(top, verts[i][3]) end
  T.check(top > 32 and nv > nvOff, ("a ridge rises above the walls (%s px)"):format(top))
end

do
  -- a house built right up against a forest is its own building
  local rows = { ".cTcTc.", ".TcTcT.", ".#####.", ".#####.", ".#####.", "......." }
  local grid = HF.build(mapProvider(rows, L), 0, 0, 7, 6, { lumps = false, roofs = true })
  T.eq(#grid.roofs, 1, "one roof across the whole house, trunks behind it or not")
  T.eq((at(grid, 2 * 16 + 8, 4 * 16 + 8)), 32, "the house keeps its own two storeys")
end

do
  -- cut-outs: a rock in the sea stands in water, a fence is posts with gaps
  local rows = { "~~~~~~", "~~#~~~", "~~~~~~", "......", ".####.", "......" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy) local c = cell(cx, cy); if c then c.mid = c.kind == "solid" and 50 or 1 end return c end,
    color = function(wx, wy)
      local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
      local lx = wx - cx * 16
      if cy <= 2 then
        if cx == 2 and cy == 1 and lx >= 4 and lx < 12 and (wy % 16) >= 4 and (wy % 16) < 12 then
          return 0.8, 0.8, 0.82 -- the rock
        end
        if cx == 2 and cy == 1 then return 0.12, 0.25, 0.6 end -- its darker water ring
        -- sea with strong wave stripes: crest and trough far apart
        if (wx + wy) % 8 < 4 then return 0.55, 0.75, 0.98 end
        return 0.2, 0.38, 0.82
      end
      if cy == 4 and cx >= 1 and cx <= 4 and (lx < 4 or (wy % 16) >= 8 and (wy % 16) < 12) then
        return 0.85, 0.85, 0.8  -- fence posts and a rail
      end
      return 0.45, 0.75, 0.38   -- grass
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 6, { lumps = false })
  T.eq((at(grid, 2 * 16 + 8, 1 * 16 + 8)), 8, "the middle of a sea rock stands up")
  T.eq((at(grid, 2 * 16 + 1, 1 * 16 + 1)), HF.WATER, "the water around it in the same cell lies at sea level")
  T.eq((at(grid, 1 * 16 + 2, 4 * 16 + 2)), 8, "a fence post stands")
  T.eq((at(grid, 1 * 16 + 8, 4 * 16 + 2)), 0, "the grass between posts lies flat")
  T.eq((at(grid, 1 * 16 + 8, 4 * 16 + 10)), 8, "the rail stands")
  local whole = HF.build(provider, 0, 0, 6, 6, { lumps = false, cutouts = false })
  T.eq((at(whole, 2 * 16 + 1, 1 * 16 + 1)), 8, "cut-outs off: the whole cell is raised as before")
end

do
  -- the dips between crowns follow the art's dark gaps, not a fixed rhythm
  local rows = { "......", ".####.", ".####.", ".####.", ".####.", ".####.", ".####.", "......" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy) local c = cell(cx, cy); if c then c.mid = c.kind == "solid" and 70 or 1 end return c end,
    color = function(wx, wy)
      local c = cell(math.floor(wx / 16), math.floor(wy / 16))
      if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
      -- crowns every 20 art rows, with a dark band where one meets the next
      if wy % 20 < 4 then return 0.05, 0.25, 0.1 end
      return 0.3, 0.7, 0.3
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 8, { lumps = false, round = "soft" })
  -- for each dipped row of the column's middle, check the art it shows is dark
  local bad, dips = 0, 0
  for vy = 1 * 4 + 1, 7 * 4 - 2 do
    local k = vy * grid.vcols + 2 * 4 + 1 + 1
    if grid.H[k] < 32 then
      dips = dips + 1
      local v = grid.K[k] * (grid.py + vy * 4 + 2) + grid.C[k] - (32 - grid.H[k])
      if v % 20 >= 6 and v % 20 <= 18 then bad = bad + 1 end
    end
  end
  T.check(dips > 0 and bad == 0, ("dips land on the art's gaps (%d dips, %d off)"):format(dips, bad))
end

do
  -- far into a connected map west/north of the current one (negative cells)
  local provider = {
    cell = function(cx, cy) return { kind = "solid", mid = 70 } end,
    color = function(wx, wy)
      if wy % 20 < 4 then return 0.05, 0.25, 0.1 end
      return 0.3, 0.7, 0.3
    end,
  }
  local ok, err = pcall(HF.build, provider, -60, -40, 6, 8, { lumps = false, round = "soft" })
  T.check(ok, "round trees build at negative map coordinates (" .. tostring(err) .. ")")
end

do
  -- a chain of sea rocks three deep is rocks, not a building
  local rows = { "~~~~~~", "~~##~~", "~~##~~", "~~##~~", "~~~~~~" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy) local c = cell(cx, cy); if c then c.mid = c.kind == "solid" and 50 or 1 end return c end,
    color = function(wx, wy)
      local c = cell(math.floor(wx / 16), math.floor(wy / 16))
      if c and c.kind == "solid" and (wx % 16) >= 4 and (wx % 16) < 12 and (wy % 16) >= 4 and (wy % 16) < 12 then
        return 0.8, 0.8, 0.82
      end
      return 0.25, 0.45, 0.9
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 5, { lumps = false, roofs = true })
  T.eq(#grid.roofs, 0, "rocks in the sea get no roof")
  T.eq((at(grid, 2 * 16 + 8, 2 * 16 + 8)), 8, "a rock in the chain is knee-high")
  T.eq((at(grid, 2 * 16 + 1, 2 * 16 + 1)), HF.WATER, "the water around it lies flat")
end

do
  -- a rock mound with a dark cave mouth is rock, not a house: no roof, and
  -- its side walls slant the rock art instead of streaking one pixel column
  local rows = { "......", ".###..", ".###..", ".#D#..", "......" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy) local c = cell(cx, cy); if c then c.mid = c.kind == "ground" and 1 or (80 + cx + cy * 8) end return c end,
    color = function(wx, wy)
      local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
      local c = cell(cx, cy)
      if not c or c.kind == "ground" then return 0.45, 0.75, 0.38 end
      if cx == 2 and cy == 3 and (wy % 16) > 4 then return 0.08, 0.06, 0.05 end -- the cave mouth
      return 0.62, 0.47, 0.4 -- brown rock
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 5, { lumps = false, roofs = true, rock = true })
  T.eq(#grid.roofs, 0, "a rock mound with a cave mouth gets no house roof")
  local verts, _, nv = Mesher.build(grid, HF.VOXEL)
  local slanted = false
  for i = 1, nv do
    local v = verts[i]
    if v[3] > 20 and math.abs(v[4] - v[1]) > 4 then slanted = true end
  end
  T.check(slanted, "rock side walls slide the art as they rise")
end

do
  -- a mound with a cave mouth (collision 0x2B) never gets a house roof
  local rows = { "......", ".###..", ".###..", ".#C#..", "......" }
  local legend = setmetatable({ ["C"] = { kind = "door", coll = 0x71, caveDoor = true } }, { __index = L })
  local cell = mapProvider(rows, legend).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if not c then return nil end
      local out = { kind = c.kind, coll = c.coll, caveDoor = c.caveDoor, mid = c.kind == "ground" and 1 or (90 + cx + cy * 8) }
      return out
    end,
    color = function(wx, wy)
      local c = cell(math.floor(wx / 16), math.floor(wy / 16))
      if not c or c.kind == "ground" then return 0.45, 0.75, 0.38 end
      return 0.3, 0.35, 0.8 -- not rock-coloured: only the cave mouth can tell
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 5, { lumps = false, roofs = true })
  T.eq(#grid.roofs, 0, "a block with a cave mouth gets no roof")
  -- one height across a rock mass, however deep each column runs
  local rows2 = {}
  for y = 1, 14 do rows2[y] = (y <= 8) and "####" or ".###" end
  rows2[15] = "...."
  local cell2 = mapProvider(rows2, L).cell
  local g2 = HF.build({ cell = cell2, color = function(wx, wy)
    local c = cell2(math.floor(wx / 16), math.floor(wy / 16))
    if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
    return 0.85, 0.72, 0.62 end }, 0, 0, 4, 15, { rock = true, lumps = false })
  T.eq(select(2, at(g2, 0 * 16 + 8, 7 * 16 + 8)), select(2, at(g2, 2 * 16 + 8, 7 * 16 + 8)),
    "neighbouring rock columns of different depth stand equally tall")
end

do
  -- a brown rock mound with a cave mouth, its corners showing the forest
  -- around it, is neither rounded like trees nor roofed
  local rows = { "......", ".###..", ".###..", ".#C#..", "......" }
  local legend = setmetatable({ ["C"] = { kind = "door", coll = 0x71, caveDoor = true } }, { __index = L })
  local cell = mapProvider(rows, legend).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if not c then return nil end
      return { kind = c.kind, coll = c.coll, caveDoor = c.caveDoor, mid = c.kind == "ground" and 1 or (95 + cx + cy * 8) }
    end,
    color = function(wx, wy)
      local lx, ly = wx % 16, wy % 16
      local c = cell(math.floor(wx / 16), math.floor(wy / 16))
      if not c or c.kind == "ground" or ((lx < 4 or lx > 11) and (ly < 4 or ly > 11)) then
        return 0.2, 0.6, 0.25 -- forest green, also in the mound's corners
      end
      return 0.55, 0.38, 0.3 -- brown rock
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 5, { lumps = false, roofs = true, round = "soft" })
  local hs = {}
  for vx = 1 * 4, 4 * 4 - 1 do hs[grid.H[(2 * 4 + 2) * grid.vcols + vx + 1]] = true end
  local n = 0 for _ in pairs(hs) do n = n + 1 end
  T.check(n <= 2, "the mound's top is level rock (no tree rounding)")
  T.eq(#grid.roofs, 0, "and has no roof")
end

do
  -- a cave mound is one level block: no slivers
  -- the mouth is walkable ground (not a door): the column over it is
  -- a cell shorter than the rest of the mound
  local rows = { ".......", ".#####.", ".#####.", ".##C##.", "......." }
  local legend = setmetatable({ ["C"] = { kind = "ground", coll = 0, caveDoor = true } }, { __index = L })
  local cell = mapProvider(rows, legend).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if not c then return nil end
      return { kind = c.kind, coll = c.coll, caveDoor = c.caveDoor, mid = c.kind == "ground" and 1 or (95 + cx + cy * 8) }
    end,
    color = function(wx, wy)
      local half = 8 + (wy - 16) * 0.8
      if wy >= 16 and wy < 64 and math.abs(wx - 56) < half then return 0.55, 0.38, 0.3 end
      return 0.12, 0.38, 0.4
    end,
  }
  local grid = HF.build(provider, 0, 0, 7, 5, { lumps = false, roofs = true, round = "soft" })
  local hs = {}
  for vy = 1 * 4, 3 * 4 - 1 do
    for vx = 1 * 4, 6 * 4 - 1 do hs[grid.H[vy * grid.vcols + vx + 1]] = true end
  end
  local n = 0 for _ in pairs(hs) do n = n + 1 end
  T.eq(n, 1, "the whole mound top is one level (no slivers)")
end

do
  -- indoors, a room as a dollhouse: one back-wall height across the room
  -- (a cabinet's cell does not raise its column), side walls as tall,
  -- furniture as tall as its art reaches above its cell, the floor flat
  local rows = { "##########", "##########", "##########", "#.##.#...#", "#........#", "#.....##.#", "#.....##.#", "##########" }
  local cell = mapProvider(rows, L).cell
  local function color(wx, wy)
    local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
    if cy < 0 or cy > 7 or cx < 0 or cx > 9 then return nil end
    -- cabinet (2..3, 3), its art from 12 px up in the wall row
    if (cx == 2 or cx == 3) and wy >= 2 * 16 + 4 and wy < 3 * 16 + 14 then return 0.85, 0.5, 0.25 end
    -- a pot (5, 3), 4 px up
    if cx == 5 and wy >= 2 * 16 + 12 and wy < 3 * 16 + 12 then return 0.55, 0.35, 0.15 end
    -- a table (6..7, 5..6)
    if (cx == 6 or cx == 7) and (cy == 5 or cy == 6) then return 0.75, 0.7, 0.3 end
    if cy == 0 or cy == 7 then return 0, 0, 0 end
    if cx == 0 or cx == 9 then return 0.7, 0.55, 0.3 end
    if cy == 1 or cy == 2 then
      if wy % 16 == 6 then return 0.95, 0.95, 0.95 end
      return 0.78, 0.66, 0.35
    end
    return (wx % 2 == 0) and 0.55 or 0.62, 0.8, 0.4
  end
  -- walkable floor under the furniture rows (a door-less room)
  local L3 = {}
  for k, v in pairs(L) do L3[k] = v end
  local g = HF.build({ cell = cell, color = color }, 0, 0, 10, 8, { lumps = false, indoor = true })
  local function h(cx, cy) return g.H[(cy * 4 + 1) * g.vcols + cx * 4 + 1 + 1] end
  local wallH = g.room and g.room.wallH
  T.eq(wallH, 48, "a two-row back wall stands 48 px: its art and a plain storey above")
  T.eq(g.CAP[(1 * 4 + 1) * g.vcols + 4 * 4 + 1 + 1], 16, "the top 16 px hold the art's top row")
  local even = true
  for cx = 1, 8 do if h(cx, 1) ~= wallH or h(cx, 2) ~= wallH then even = false end end
  T.check(even, "the back wall is one height all along (cabinet columns too)")
  T.eq(h(0, 4), wallH, "the side wall is as tall as the back wall")
  local cab, pot, tab = h(2, 3), h(5, 3), h(6, 5)
  T.check(cab > pot and cab >= 20 and cab < wallH, "the cabinet stands tall against the wall (" .. tostring(cab) .. ")")
  T.check(pot >= 12 and pot <= 20, "a pot is knee-high (" .. tostring(pot) .. ")")
  T.check(tab >= 8 and tab <= 12, "a table is low (" .. tostring(tab) .. ")")
  T.eq(h(3, 4), 0, "the floor is flat")
  -- the same room with no side walls on the map: its floor runs to the
  -- black.  A thin wall stands in the void along each edge, as tall as the
  -- back wall, showing the back wall's art (read from a column of it)
  local g2 = HF.build({ cell = cell, color = function(wx, wy)
    local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
    if (cx == 0 or cx == 9) and cy >= 3 then return 0, 0, 0 end
    return color(wx, wy)
  end }, 0, 0, 10, 8, { lumps = false, indoor = true })
  local inner = (4 * 4 + 1) * g2.vcols + 0 * 4 + 3 + 1 -- (0, 4)'s east voxel
  local outer = (4 * 4 + 1) * g2.vcols + 0 * 4 + 0 + 1
  T.check(g2.room and g2.room.edges > 0, "open room edges are walled")
  T.eq(g2.H[inner], g2.room.wallH, "the edge wall is as tall as the back wall")
  T.eq(g2.H[outer], 0, "and one voxel thin")
  T.check(g2.U[inner] ~= nil and g2.K[inner] == 0, "it reads the back wall's art")
end

do
  -- indoors, a one-cell wall beside the void stays a whole, full wall
  local rows = { "#....#", "#....#", "#....#", "#....#", "......" }
  local cell = mapProvider(rows, L).cell
  local provider = { cell = cell, color = function(wx, wy)
    local c = cell(math.floor(wx / 16), math.floor(wy / 16))
    if c and c.kind == "solid" then return (wx % 16 < 8) and 0 or 0.9, 0.9, 0.9 end
    return 0.9, 0.75, 0.45 end }
  local g = HF.build(provider, 0, 0, 6, 5, { lumps = false, indoor = true })
  local tall = true
  for vx = 0, 3 do if g.H[(3 * 4 + 2) * g.vcols + vx + 1] ~= 48 then tall = false end end
  T.check(tall, "an indoor side wall is not cut out or shrunk")
end

do
  -- night lights: a thin grey post on its own is a lamp; a fence run is not
  local rows = { "......", ".#..##", "......", "......" }
  local cell = mapProvider(rows, L).cell
  local provider = { cell = cell, color = function(wx, wy)
    local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
    local c = cell(cx, cy)
    -- the post: a 4px grey column in the middle of the cell
    if c.kind == "solid" and wx % 16 >= 6 and wx % 16 < 10 then return 0.35, 0.36, 0.40 end
    return 0.86, 0.78, 0.55 end } -- town paving
  local g = HF.build(provider, 0, 0, 6, 4, { lumps = false })
  local lamps = 0
  for _, l in ipairs(g.lights) do if l.kind == "lamp" then lamps = lamps + 1 end end
  T.eq(lamps, 1, "one lone post is a lamp, the pair beside each other is not")
  -- a fence running north-south is not a row of lamps
  local rowsV = { "......", "...#..", "...#..", "...#..", "......" }
  local cellV = mapProvider(rowsV, L).cell
  local gV = HF.build({ cell = cellV, color = function(wx, wy)
    local c = cellV(math.floor(wx / 16), math.floor(wy / 16))
    if c.kind == "solid" and wx % 16 >= 6 and wx % 16 < 10 then return 0.35, 0.36, 0.40 end
    return 0.86, 0.78, 0.55 end }, 0, 0, 6, 5, { lumps = false })
  local lv = 0
  for _, l in ipairs(gV.lights) do if l.kind == "lamp" then lv = lv + 1 end end
  T.eq(lv, 0, "a north-south fence is not lamps")
  -- a lamp once found is remembered: a later rebuild that sees only one
  -- pixel of its post still lights it
  local mem = {}
  HF.build(provider, 0, 0, 6, 4, { lumps = false, lampMemory = mem })
  T.check(mem["1,1"], "the lamp is remembered")
  local faint = HF.build({ cell = cell, color = function(wx, wy)
    local c = cell(math.floor(wx / 16), math.floor(wy / 16))
    if c.kind == "solid" and wx % 16 >= 6 and wx % 16 < 7 and wy % 16 < 4 then return 0.35, 0.36, 0.40 end
    return 0.86, 0.78, 0.55 end }, 0, 0, 6, 4, { lumps = false, lampMemory = mem })
  local lf = 0
  for _, l in ipairs(faint.lights) do if l.kind == "lamp" then lf = lf + 1 end end
  T.eq(lf, 1, "a remembered lamp stays lit when the art shows less of it")
  -- one lamp found by its art lights its twins (same metatile) at once
  local rowsT = { "......", ".#..#.", "......", "......" }
  local cellT = function(cx, cy)
    local c = mapProvider(rowsT, L).cell(cx, cy)
    if c.kind == "solid" then return { kind = "solid", mid = 0x2A1 } end
    return c
  end
  local memT = {}
  local gT = HF.build({ cell = cellT, color = function(wx, wy)
    local cx = math.floor(wx / 16)
    local c = cellT(cx, math.floor(wy / 16))
    if c.kind == "solid" then
      if cx == 1 and wx % 16 >= 6 and wx % 16 < 10 then return 0.35, 0.36, 0.40 end
      if cx == 4 and wx % 16 == 6 and wy % 16 < 4 then return 0.35, 0.36, 0.40 end
    end
    return 0.86, 0.78, 0.55 end }, 0, 0, 6, 4, { lumps = false, lampMemory = memT })
  local lt = 0
  for _, l in ipairs(gT.lights) do if l.kind == "lamp" then lt = lt + 1 end end
  T.eq(lt, 2, "a faint lamp is lit by its twin's metatile")
  -- learned lamp tiles are written to the mod cache and read back
  local Bridge = use("bridge")
  local store = {}
  Bridge.setCache({ read = function(_, k) return store[k] end,
    write = function(_, k, v) store[k] = v return true end })
  local m = Bridge.lampMemory(77)
  m.mids[0x2A1] = true
  Bridge.saveLamps()
  T.check(store["lamps/v2.txt"] and store["lamps/v2.txt"]:find("77\t673"), "lamp tile saved")
  -- a fresh session reads it back (state cleared)
  Bridge._state.lampMemory = nil
  T.check(Bridge.lampMemory(77).mids[673], "lamp tile restored")
  local Lighting = use("lighting")
  Lighting.bake(g, 4, { sun = false })
  local k = (1 * 4 + 3) * g.vcols + 1 * 4 + 2 + 1
  T.check((g.glow[k] or 0) > 0.7, "lamplight is bright at the lamp's foot")
  T.check((g.glow[(3 * 4 + 3) * g.vcols + 5 * 4 + 3 + 1] or 0) == 0, "and none far away")
  local Bridge = use("bridge")
  T.eq(Bridge.nightLevel(nil), 0, "no lights without day/night")
  local DN = use("daynight")
  T.eq(Bridge.nightLevel(DN.at(12)), 0, "no lights at noon")
  T.eq(Bridge.nightLevel(DN.at(1)), 1, "full lights at night")
  local dusk = Bridge.nightLevel(DN.at(18.5))
  T.check(dusk > 0.2 and dusk < 1, "lights coming on at dusk")
end

do
  -- Night lights by TILE: the object outline in a metatile's top layer,
  -- from the tileset at full resolution (tiles.lua)
  local Tiles = use("tiles")
  -- a fake tileset: slots of 16x16 in a row; pixel(x, y) -> alpha
  local slots = {}
  local function img(layer)
    return { getPixel = function(_, x, y)
      local sl = slots[math.floor(x / 16)]
      local f = sl and sl[layer]
      return 0, 0, 0, (f and f(x % 16, y % 16)) and 1 or 0
    end }
  end
  local function post(x, y) return x >= 7 and x <= 9 and y >= 3 and y <= 14 end
  local function vfence(x, y) return x >= 6 and x <= 9 end
  local function hfence(x, y) return y >= 5 and y <= 9 end
  local function box(x, y) return x >= 3 and x <= 12 and y >= 4 and y <= 13 end
  slots[0] = {}                       -- mid 1: plain ground, nothing on top
  slots[1] = { over = post }          -- mid 2: a lamp post (NORMAL / SPLIT)
  slots[2] = { mid = post }           -- mid 3: the same post, COVERED
  slots[3] = { over = vfence }        -- mid 4: vertical fence
  slots[4] = { over = hfence }        -- mid 5: horizontal fence
  slots[5] = { over = box }           -- mid 6: a mailbox / sign
  Tiles.setSource({ _pairs = { town = {
    cols = 64, midToSlot = { [1] = 0, [2] = 1, [3] = 2, [4] = 3, [5] = 4, [6] = 5 },
    overImageData = img("over"), midImageData = img("mid") } } })
  T.check(HF.isPost(Tiles.shape("town", 2)), "a thin post in the top layer is a lamp post")
  T.check(HF.isPost(Tiles.shape("town", 3)), "a COVERED tile keeps its post in the middle layer")
  -- (a vertical fence is as thin as a post: the map tells them apart --
  -- it runs on through the cells above and below)
  T.check(HF.isPost(Tiles.shape("town", 4)), "a vertical fence piece is post-shaped on its own")
  T.check(not HF.isPost(Tiles.shape("town", 5)), "a horizontal fence touches the tile's sides")
  T.check(not HF.isPost(Tiles.shape("town", 6)), "a mailbox is a box")
  T.check(Tiles.shape("other", 2) == nil, "a tileset not loaded is asked again later")

  -- the map: P lamp, F vertical fence, B building, S fountain spout over basin
  local legend = {
    ["."] = { kind = "ground", mid = 1 }, ["P"] = { kind = "solid", mid = 2 },
    ["C"] = { kind = "solid", mid = 3 }, ["F"] = { kind = "solid", mid = 4 },
    ["H"] = { kind = "solid", mid = 5 }, ["M"] = { kind = "solid", mid = 6 },
    ["#"] = { kind = "solid", mid = 7 },
  }
  local rows = {
    "..........",
    ".P..P#..F.",   -- a lone lamp; a lamp beside a building; fence column
    ".....#..F.",
    ".C..M...F.",   -- covered lamp; mailbox
    "..P.......",   -- spout over its basin
    "..#..HHH..",
    "..........",
  }
  local function cell(cx, cy)
    local row = rows[cy + 1]
    if not row or cx < 0 or cx >= #row then return { kind = "solid", border = true, mid = 1, pair = "town" } end
    local c = legend[row:sub(cx + 1, cx + 1)]
    return { kind = c.kind, mid = c.mid, pair = "town" }
  end
  local provider = { cell = cell, shape = function(c) return Tiles.shape(c.pair, c.mid) end }
  local g = HF.build(provider, 0, 0, 10, 7, { lumps = false, town = true })
  local at = {}
  for _, l in ipairs(g.lights) do
    if l.kind == "lamp" then at[math.floor(l.x / 16) .. "," .. math.floor(l.y / 16)] = true end
  end
  T.check(at["1,1"], "a lone lamp is lit")
  T.check(at["4,1"], "a lamp beside a building is lit too (same tile, same verdict)")
  T.check(at["1,3"], "a covered lamp tile is lit")
  T.check(not at["8,1"] and not at["8,2"] and not at["8,3"], "a vertical fence is not a row of lamps")
  T.check(not at["4,3"], "a mailbox is not a lamp")
  T.check(not at["2,4"], "a post standing in something solid (a fountain's spout) is not a lamp")
  T.eq(g.lampsByTile, 3, "three lamps, all judged by their tile")
  local r = HF.build(provider, 0, 0, 10, 7, { lumps = false, town = false })
  local rl = 0
  for _, l in ipairs(r.lights) do if l.kind == "lamp" then rl = rl + 1 end end
  T.eq(rl, 0, "no street lamps on routes")
  -- each cell by its own map: a town's lamps seen from the route next to it
  local townCells = { cell = function(cx, cy) local c = cell(cx, cy); c.town = true; return c end,
    shape = provider.shape }
  local nb = HF.build(townCells, 0, 0, 10, 7, { lumps = false, town = false })
  local nl = 0
  for _, l in ipairs(nb.lights) do if l.kind == "lamp" then nl = nl + 1 end end
  T.eq(nl, 3, "a neighbouring town keeps its lamps while you stand on the route")
  -- a tile's art from the tileset (the same wherever the camera is): the
  -- layer under sprites, the top layer over it
  Tiles.setSource({ _pairs = { art = { cols = 4, midToSlot = { [9] = 1 },
    imageData = { getPixel = function(_, x, y) return 0.2, 0.6, 0.2, 1 end },
    overImageData = { getPixel = function(_, x, y)
      local lx = x % 16
      return 0.8, 0.5, 0.4, (lx >= 4 and lx < 8) and 1 or 0 end } } } })
  local r1, g1 = Tiles.pixel("art", 9, 1, 1)
  local r2 = Tiles.pixel("art", 9, 5, 1)
  T.check(g1 == 0.6 and r2 == 0.8, "a tile's art reads its bottom layer, the top layer over it")
  T.eq(Tiles.pixel("art", 99, 1, 1), nil, "an unknown tile has no art")
  Tiles.setSource(nil)

  -- doorways: only real doors
  local drows = { "###", "#D#", "...", "###", "#A#", "..." }
  local dcell = function(cx, cy)
    local row = drows[cy + 1]
    if not row or cx < 0 or cx >= #row then return { kind = "solid" } end
    local ch = row:sub(cx + 1, cx + 1)
    if ch == "D" then return { kind = "door", behKnown = true, warpDoor = true } end
    if ch == "A" then return { kind = "door", behKnown = true } end -- an arrow warp
    return { kind = ch == "#" and "solid" or "ground" }
  end
  local dg = HF.build({ cell = dcell }, 0, 0, 3, 6, { lumps = false })
  local doors = {}
  for _, l in ipairs(dg.lights) do if l.kind == "door" then doors[#doors + 1] = math.floor(l.y / 16) end end
  T.eq(#doors, 1, "one lit doorway: the house door, not the arrow warp")
end

do
  -- a uniform declared in both shader stages must match in precision; on a
  -- phone the vertex stage defaults to highp and the pixel stage to
  -- mediump, so such a shader does not link ("uMirror precision mismatch").
  -- Every uniform belongs to one stage only.
  local src = read(MOD .. "/voxel/scene.lua")
  local shaderText = src:match("local SHADER = %[%[(.-)%]%]")
  local vtx = shaderText:match("#ifdef VERTEX(.-)#endif")
  local pix = shaderText:match("#ifdef PIXEL(.-)#endif")
  local head = shaderText:match("^(.-)#ifdef VERTEX")
  T.check(not head:find("\nuniform"), "no uniform is shared by both stages")
  local vset = {}
  for name in vtx:gmatch("uniform%s+[%w_]+%s+([%w_]+)") do vset[name] = true end
  local both = {}
  for name in pix:gmatch("uniform%s+[%w_]+%s+([%w_]+)") do if vset[name] then both[#both + 1] = name end end
  T.eq(#both, 0, "no uniform declared in both stages (" .. table.concat(both, ",") .. ")")
end

do
  -- town or route, per cell, by its own map's header type; a neighbour
  -- whose def does not carry it yet is not taken for a town (the engine's
  -- "kind" calls routes towns too) unless its type was learned before
  local Cells = use("cells")
  local Map = require("src.core.game3.map")
  local saved = { currentDef = Map.currentDef, current = Map.current, world = Map.world }
  local function layout(w, h)
    return { width = w, height = h, midAt = function() return 1 end, collAt = function() return 0 end }
  end
  local routeDef = { mapType = 3, kind = "town", midLayout = layout(4, 4) }
  local townDef = { kind = "town", midLayout = layout(4, 4) }
  Map.currentDef = function() return routeDef end
  Map.current = "ROUTE_T"
  Map.world = { { id = "TOWN_T", def = townDef, ox = 4, oy = 0 } }
  local ok, err = pcall(function()
    Cells.mapTypes = {}
    local pv = Cells.provider()
    T.eq(pv.cell(1, 1).town, false, "a route cell is not a town")
    T.eq(pv.cell(5, 1).town, false, "an unknown neighbour is not taken for a town")
    T.eq(Cells.mapTypes["ROUTE_T"], 3, "the current map's type is remembered")
    Cells.mapTypes["TOWN_T"] = 2
    T.eq(Cells.provider().cell(5, 1).town, true, "a neighbour remembered as a city is one")
  end)
  Map.currentDef, Map.current, Map.world = saved.currentDef, saved.current, saved.world
  Cells.mapTypes = {}
  T.check(ok, "cells town test ran: " .. tostring(err))
end

do
  -- the sea closed off at a map's edge with the same water tile, collision
  -- set, lies flat as water instead of standing as a wall
  local rows = { "~~~#", "~~~#", "~~~#" }
  local leg = { ["~"] = { kind = "water", mid = 9 }, ["#"] = { kind = "solid", mid = 9 } }
  local g = HF.build(mapProvider(rows, leg), 0, 0, 4, 3, { lumps = false })
  T.eq(g.H[(1 * 4 + 1) * g.vcols + 3 * 4 + 1 + 1], HF.WATER, "edge water with collision is water")
  -- a sliver beyond every loaded map (the current map's border tile, trees)
  -- next to a neighbour's sea is sea
  local rows2 = { "~~BB..", "~~BB..", "~~BB.." }
  local leg2 = { ["~"] = { kind = "water", mid = 9, map = "R115" },
    ["B"] = { kind = "solid", border = true, mid = 3, map = "RUSTBORO" },
    ["."] = { kind = "ground", mid = 1, map = "RUSTBORO" } }
  local g2 = HF.build(mapProvider(rows2, leg2), 0, 0, 6, 3, { lumps = false })
  T.eq(g2.H[(1 * 4 + 1) * g2.vcols + 2 * 4 + 1 + 1], HF.WATER, "border sliver beside the sea is sea")
  T.eq(g2.H[(1 * 4 + 1) * g2.vcols + 3 * 4 + 1 + 1], HF.WATER, "both columns of it")
  -- the current map's own border forest beside its own pond stays forest
  local leg3 = { ["~"] = { kind = "water", mid = 9, map = "RUSTBORO" },
    ["B"] = { kind = "solid", border = true, mid = 3, map = "RUSTBORO" },
    ["."] = { kind = "ground", mid = 1, map = "RUSTBORO" } }
  local g3 = HF.build(mapProvider(rows2, leg3), 0, 0, 6, 3, { lumps = false })
  T.check(g3.H[(1 * 4 + 1) * g3.vcols + 2 * 4 + 1 + 1] > 0, "own border beside own pond stays solid")
end

do
  -- swaying foliage: trees and tall grass are flagged (grid.SW) and their
  -- faces carry the sway flags 0.7 (top) / 0.2 (wall); houses do not
  local rows = { "......", ".TT.##", ".TT.##", "\"\"\"...", "......" }
  local leg = { ["."] = { kind = "ground" }, ["T"] = { kind = "solid", tree = true },
    ["#"] = { kind = "solid" }, ['"'] = { kind = "grass" } }
  local g = HF.build(mapProvider(rows, leg), 0, 0, 6, 5, { lumps = false })
  local function k(cx, cy) return (cy * 4 + 1) * g.vcols + cx * 4 + 1 + 1 end
  T.check(g.SW[k(1, 1)], "a tree sways")
  T.check(g.SW[k(0, 3)], "tall grass sways")
  T.check(not g.SW[k(4, 1)], "a building does not")
  local verts, _, nv = Mesher.build(g, HF.VOXEL)
  local top, wall = false, false
  for i = 1, nv do
    local a = verts[i][11]
    if a == 0.7 then top = true elseif a == 0.2 then wall = true end
  end
  T.check(top and wall, "swaying faces are flagged for the shader")
  local ind = HF.build(mapProvider(rows, leg), 0, 0, 6, 5, { lumps = false, indoor = true })
  T.check(not ind.SW[k(1, 1)], "nothing sways indoors")
end

do
  -- critters: fireflies over foliage at night, birds out of trees by day
  local C = use("critters")
  local rows = { "TTTTTT", "TTTTTT", "\"\"\"\"\"\"", "......" }
  local leg = { ["."] = { kind = "ground" }, ["T"] = { kind = "solid", tree = true }, ['"'] = { kind = "grass" } }
  local g = HF.build(mapProvider(rows, leg), 0, 0, 6, 4, { lumps = false })
  C.setSpots(g, HF.VOXEL)
  T.check(#C._state.low > 0 and #C._state.trees > 0, "spots gathered from swaying foliage")
  local rect = { 0, 0, 96, 64 }
  for _ = 1, 120 do C.update(1 / 30, 1, false, rect, 0, 0, 1) end
  T.check(#C._state.flies > 10, "fireflies at night")
  T.eq(#C._state.birds, 0, "no birds at night")
  local gv, gn, gi, gni = C.build(0, 0)
  T.check(gn > 0 and gni == gn / 4 * 6, "fireflies become quads")
  C.setSpots(g, HF.VOXEL)
  for _ = 1, 600 do C.update(1 / 30, 0, true, rect, 0, 0, 1) end
  T.eq(#C._state.flies, 0, "no fireflies by day")
  T.check(C._state.t > 0, "time runs")
  C.setSpots(g, HF.VOXEL)
  C._state.nextFlock = 0
  C.update(1 / 30, 0, true, rect, 0, 0, 1)
  T.check(#C._state.birds >= 3, "a flock flies up out of a tree")
  C.reset()
end

do
  -- chimney smoke: homes get a chimney (most of them, the same ones every
  -- time), wide buildings none; puffs rise from it and fade
  local Smoke = use("smoke")
  Smoke.init(HF)
  local grid = { roofs = {
    { x1 = 0, x2 = 64, y0 = 0, y1 = 48, h = 32, maxRise = 20, ridge = "ew" },
    { x1 = 100, x2 = 100 + 10 * 16, y0 = 0, y1 = 48, h = 32, maxRise = 20, ridge = "ew" },
  } }
  local got = 0
  for i = 0, 19 do
    grid.roofs[1].x1, grid.roofs[1].x2 = i * 80, i * 80 + 64
    Smoke.setStacks(grid)
    got = got + #Smoke._state.stacks
  end
  T.check(got >= 10 and got <= 20, "most homes have a chimney (" .. got .. "/20)")
  grid.roofs[1].x1, grid.roofs[1].x2 = 0, 64
  Smoke.setStacks(grid)
  local s1 = Smoke._state.stacks[1]
  Smoke.setStacks(grid)
  T.check(s1 == nil or (Smoke._state.stacks[1] and Smoke._state.stacks[1].x == s1.x), "the same house, the same chimney")
  for _, st in ipairs(Smoke._state.stacks) do
    T.check(st.x < 100, "a wide building has no chimney")
    T.check(st.z1 > 32 + 8, "the chimney tops the ridge")
  end
  if #Smoke._state.stacks > 0 then
    for _ = 1, 90 do Smoke.update(1 / 30, 1, false, nil, 0, 0) end
    T.check(#Smoke._state.puffs > 2, "smoke rises")
    local cv, cn, ci, cni, pv, pn = Smoke.build(0, 0)
    T.check(cn == #Smoke._state.stacks * 16 and pn == #Smoke._state.puffs * 4, "chimneys and puffs become quads")
  end
  Smoke.reset()
end

do
  -- windows only on buildings: a block with a door in it; a fountain (a
  -- stone block three deep, no door) has no lit windows
  local rows = { "......", ".###..", ".###.F", ".#D#.F", "......" }
  local leg = { ["."] = { kind = "ground" }, ["#"] = { kind = "solid" },
    ["D"] = { kind = "door", behKnown = true, warpDoor = true }, ["F"] = { kind = "solid" } }
  local g = HF.build(mapProvider(rows, leg), 0, 0, 6, 5, { lumps = false, roofs = true })
  local function k(cx, cy) return (cy * 4 + 1) * g.vcols + cx * 4 + 1 + 1 end
  T.check(g.B[k(1, 2)] and g.B[k(3, 1)], "the house is a building")
  T.check(not g.B[k(5, 2)], "the doorless block (a fountain) is not")
  T.eq(g.buildings, 1, "one building")
end

do
  -- footprints: an NPC walking on sand leaves prints, the player does not
  -- (the game draws its own); on an ash map everyone does; out of a puddle
  -- a few wet prints, then none
  local FP = use("footprints")
  FP.reset()
  local function ground(kind) return function() return kind end end
  local npc, pl = { x = 0, y = 0 }, { x = 100, y = 0 }
  for _ = 1, 40 do
    npc.x, pl.x = npc.x + 1, pl.x + 1
    FP.update(1 / 60, "M", { pl, npc }, ground("sand"), 1, false)
  end
  local n = #FP._state.prints
  T.check(n >= 4 and n <= 5, "an NPC on sand leaves a print every 8 px (" .. n .. ")")
  for _, p in ipairs(FP._state.prints) do T.check(p.x < 60, "none from the player") end
  FP.update(1 / 60, "OTHER", {}, ground("sand"), nil, false)
  T.eq(#FP._state.prints, 0, "a new map starts clean")
  local a = { x = 0, y = 0 }
  for _ = 1, 40 do a.x = a.x + 1; FP.update(1 / 60, "R113", { a }, ground("open"), 1, true) end
  T.check(#FP._state.prints >= 4, "on an ash map even the player leaves prints")
  FP.reset()
  local w = { x = 0, y = 0 }
  local g = function(x) return x < 8 and "wet" or "open" end
  for _ = 1, 200 do w.x = w.x + 1; FP.update(1 / 60, "R", { w }, g, nil, false) end
  local wet = #FP._state.prints
  T.check(wet >= 2 and wet <= 14, "a few wet prints out of a puddle, then dry (" .. wet .. ")")
  local v, nv = FP.build()
  T.eq(nv, wet * 4, "prints become quads")
  FP.reset()
  -- standing still while the camera glides: positions wobble by a fraction
  -- of a pixel every frame, which must not count as walking
  local s = { x = 50, y = 50 }
  for i = 1, 600 do
    s.x, s.y = 50 + (i % 2) * 0.9, 50 + ((i % 3) == 0 and 0.7 or 0)
    FP.update(1 / 120, "R113", { s }, ground("open"), nil, true)
  end
  T.eq(#FP._state.prints, 0, "a character standing on ash leaves no prints (camera wobble)")
  -- a slow walker at a high frame rate (half a pixel a frame) still counts
  local h = { x = 0, y = 0 }
  for _ = 1, 80 do h.x = h.x + 0.5; FP.update(1 / 120, "R113", { s, h }, ground("open"), nil, true) end
  T.check(#FP._state.prints >= 4, "half-pixel steps add up (" .. #FP._state.prints .. ")")
  FP.reset()
  -- a character the game says is standing leaves nothing, however its
  -- position creeps; the same creep with moving = true does
  local c = { x = 0, y = 0, moving = false }
  for _ = 1, 200 do c.x = c.x + 1; FP.update(1 / 60, "R113", { c }, ground("open"), nil, true) end
  T.eq(#FP._state.prints, 0, "standing (moving = false): no prints")
  c.moving = true
  for _ = 1, 40 do c.x = c.x + 1; FP.update(1 / 60, "R113", { c }, ground("open"), nil, true) end
  T.check(#FP._state.prints >= 4, "walking (moving = true): prints")
  FP.reset()
  -- a step begun and taken back, frame after frame (moving = true, the
  -- position flicking 3 px forward and back): no prints
  local f = { id = "f", x = 100, y = 100, moving = true }
  for i = 1, 600 do
    f.y = 100 + (i % 2) * 3
    FP.update(1 / 120, "R113", { f }, ground("open"), nil, true)
  end
  T.eq(#FP._state.prints, 0, "a flickering step leaves no prints")
  FP.reset()
  -- characters named by the game are followed by name: two walking side by
  -- side, 3 px apart, each lay their own prints
  local p1, p2 = { id = "a", x = 0, y = 0, moving = true }, { id = "b", x = 0, y = 3, moving = true }
  for _ = 1, 40 do
    p1.x, p2.x = p1.x + 1, p2.x + 1
    FP.update(1 / 60, "R113", { p2, p1 }, ground("open"), nil, true)
  end
  local n2 = #FP._state.prints
  T.check(n2 >= 8 and n2 <= 10, "two named walkers, a print every 8 px each (" .. n2 .. ")")
  FP.reset()
  -- on a bike: one line of tire marks every 4 px, down the middle
  local b = { id = "player", x = 0, y = 50, moving = true, bike = true }
  for _ = 1, 40 do b.x = b.x + 1; FP.update(1 / 60, "R113", { b }, ground("open"), 1, true) end
  local nb = #FP._state.prints
  T.check(nb >= 8 and nb <= 10, "a bike leaves a mark every 4 px (" .. nb .. ")")
  local straight = true
  for _, p in ipairs(FP._state.prints) do
    if not p.tire or math.abs(p.y - 49) > 0.01 then straight = false end
  end
  T.check(straight, "tire marks run in one line, not left and right")
  FP.reset()
  -- surfing: a wake, a ripple every 5 px either side, gone in a moment
  local sw = { id = "player", x = 0, y = 50, moving = true }
  for _ = 1, 40 do sw.x = sw.x + 1; FP.update(1 / 60, "R", { sw }, ground("water"), 1, false) end
  local nw = #FP._state.prints
  T.check(nw >= 6 and nw <= 9, "a swimmer leaves a wake (" .. nw .. ")")
  T.eq(FP._state.prints[1].kind, "wake", "of foam")
  for _ = 1, 120 do FP.update(1 / 60, "R", { sw }, ground("water"), 1, false) end
  T.eq(#FP._state.prints, 0, "which fades within two seconds")
  FP.reset()
  -- shores: water voxels know how far out they are (0 at the edge)
  local gw = HF.build(mapProvider({ "....", "~~~~", "~~~~", "~~~~" }, L), 0, 0, 4, 4, { lumps = false })
  local edge = gw.shore[(1 * 4 + 0) * gw.vcols + 5 + 1]
  local out = gw.shore[(3 * 4 + 3) * gw.vcols + 5 + 1]
  T.check(edge and edge <= 0.25, "water at the shore is near it (" .. tostring(edge) .. ")")
  T.check(out == nil or out == 1, "water far out is open sea")
  T.eq(gw.shore[1], 0, "land reads as the shore")
end

do
  -- a forest by its tile pattern (Lavender Town's grey trees: not in the
  -- FRLG tree list, not green): tiles repeating every second cell across
  -- and down are trees, with or without art; a plain repeating wall is not
  local rows = {}
  for y = 0, 7 do
    local r = {}
    for x = 0, 9 do r[#r + 1] = "#" end
    rows[#rows + 1] = table.concat(r)
  end
  local function cell(cx, cy)
    if cx < 0 or cy < 0 or cx > 9 or cy > 7 then return nil end
    if cx < 5 then
      return { kind = "solid", mid = 900 + (cx % 2) + 2 * (cy % 2), pair = "L" } -- forest: a 2x2 tree tiled
    end
    return { kind = "solid", mid = 950 + (cy % 2), pair = "L" } -- a wall: rows of two tiles, every cell across alike
  end
  HF._tileRock = {}
  local g = HF.build({ cell = cell, family = "frlg" }, 0, 0, 10, 8, { lumps = false })
  local r = HF.build({ cell = cell, family = "rse" }, 0, 0, 10, 8, { lumps = false })
  T.eq(r.patternTrees, nil, "RSE forests are left to their art")
  T.check((g.patternTrees or 0) > 0, "a forest is found by its pattern (" .. tostring(g.patternTrees) .. ")")
  local kf = (4 * 4 + 1) * g.vcols + 2 * 4 + 1 + 1
  local kw = (4 * 4 + 1) * g.vcols + 7 * 4 + 1 + 1
  T.check(g.SW[kf] == true, "the forest is trees (it sways)")
  T.check(not g.SW[kw], "the wall is not")
end

do
  -- rock remembered per tile: a mountain judged once with its art on
  -- screen stays a mountain when built again without it (the picture is
  -- only there near the camera)
  local function cell(cx, cy)
    if cx < 0 or cy < 0 or cx > 7 or cy > 9 then return nil end
    if cy < 8 then return { kind = "solid", mid = 777, pair = "R" } end
    return { kind = "ground", mid = 1, pair = "R" }
  end
  HF._rockMem = {}
  local rocky = function(wx, wy) if wy < 8 * 16 then return 0.78, 0.62, 0.5 end return 0.4, 0.7, 0.35 end
  local a = HF.build({ cell = cell, color = rocky }, 0, 0, 8, 10, { lumps = false, rock = true, roofs = true })
  local b = HF.build({ cell = cell, color = function() return nil end }, 0, 0, 8, 10, { lumps = false, rock = true, roofs = true })
  local k = (7 * 4 + 1) * a.vcols + 3 * 4 + 1 + 1
  T.eq(b.H[k], a.H[k], "a mountain built without its art keeps its height (" .. tostring(a.H[k]) .. ")")
  T.eq(#b.roofs, #a.roofs, "and gets no house roofs")
end

do
  -- caves: dust hangs in the air near the player; a drop falls and leaves
  -- a ring where it lands, wider on water
  local CV = use("caves")
  CV.reset()
  local rect = { 0, 0, 320, 240 }
  for _ = 1, 600 do CV.update(1 / 60, rect, 160, 160, function() return 0 end, function() return true end, 1) end
  local st = CV._state
  T.check(#st.motes > 10, "dust motes drift in the air (" .. #st.motes .. ")")
  local near = 0
  for _, m in ipairs(st.motes) do if math.abs(m.x - 160) < 120 then near = near + 1 end end
  T.check(near * 2 > #st.motes, "most of them near the player")
  local landed = false
  for _ = 1, 600 do
    CV.update(1 / 60, rect, 160, 160, function() return 0 end, function() return true end, 1)
    for _, r in ipairs(st.rings) do if r.size == 9 then landed = true end end
  end
  T.check(landed, "a drop lands on water and spreads a ring")
  local v, n = CV.build()
  T.check(n > 0 and n % 4 == 0, "it all builds into quads")
  CV.reset()
end

do
  -- RSE indoors: the exit is a black walkable cell in the black row below
  -- the floor; it shows the floor tile above it, not the void
  local rows = { "#....#", "#....#", "#....#", "##.###", "######" }
  local cell = mapProvider(rows, L).cell
  local provider = { cell = cell, color = function(wx, wy)
    local cy = math.floor(wy / 16)
    if cy >= 3 then return 0.02, 0.02, 0.02 end
    return 0.9, 0.75, 0.45 end }
  local g = HF.build(provider, 0, 0, 6, 5, { lumps = false, indoor = true })
  local k = (3 * 4 + 1) * g.vcols + 2 * 4 + 1 + 1
  T.eq(g.exitFloors, 1, "one exit cell found")
  T.eq(g.H[k], 0, "the exit lies flat with the floor")
  T.eq(g.K[k] * (3 * 16 + 5) + g.C[k], 2 * 16 + 5, "the exit shows the floor tile above it")
  local o = HF.build(provider, 0, 0, 6, 5, { lumps = false })
  T.eq(o.exitFloors, 0, "outdoors nothing is changed")
  -- a dark-grey mat with a door collision, floor raised a pixel by relief
  local rows2 = { "#....#", "#....#", "#....#", "##D###", "######" }
  local L2 = {}
  for k, v in pairs(L) do L2[k] = v end
  L2["D"] = { kind = "door" }
  local cell2 = mapProvider(rows2, L2).cell
  local g2 = HF.build({ cell = cell2, color = function(wx, wy)
    local cy = math.floor(wy / 16)
    if cy == 3 and math.floor(wx / 16) == 2 then return 0.3, 0.24, 0.2 end
    if cy >= 3 then return 0, 0, 0 end
    return 0.9, 0.75, 0.45 end }, 0, 0, 6, 5, { lumps = false, indoor = true })
  T.eq(g2.exitFloors, 1, "a dark mat on a door cell becomes floor too")
  -- a light mat (RSE Poke Center): flat, in its own art
  local g3 = HF.build({ cell = cell2, color = function(wx, wy)
    local cy = math.floor(wy / 16)
    if cy == 3 and math.floor(wx / 16) == 2 then return 0.8, 0.65, 0.55 end
    if cy >= 3 then return 0, 0, 0 end
    return 0.9, 0.75, 0.45 end }, 0, 0, 6, 5, { lumps = false, indoor = true })
  local k3 = (3 * 4 + 1) * g3.vcols + 2 * 4 + 1 + 1
  T.eq(g3.exitFloors, 1, "a light mat on the exit becomes floor")
  T.eq(g3.H[k3], 0, "the light mat lies flat")
  T.eq(g3.K[k3] * 53 + g3.C[k3], 53, "the light mat keeps its own art")
  -- the black row beside the exit lies flat: it hid the floor and the exit
  local kv = (3 * 4 + 1) * g3.vcols + 4 * 4 + 1 + 1
  T.eq(g3.H[kv], 0, "the black void indoors does not stand as a wall")
  T.check(g3.voidFlat > 0, "void cells counted")
end

do
  -- solid characters: depth N adds N darkened layers, each 1px further back
  local Scene = use("scene")
  T.check(type(Scene.setActors) == "function", "scene builds actor bodies")
end

do
  -- cave walls are lower than mountains
  local rows = {}
  for y = 1, 8 do rows[y] = "####" end
  rows[9] = "...."
  local cell = mapProvider(rows, L).cell
  local g = HF.build({ cell = cell, color = function() return 0.6, 0.45, 0.35 end }, 0, 0, 4, 9,
    { rock = true, cave = true, lumps = false })
  T.eq((at(g, 24, 7 * 16 + 8)), 24, "a cave wall stands 24px, not mountain height")
end

do
  -- Emerald-style forest: no tree ids, trunk rows (solid) alternate with
  -- walkable canopy rows; the art tells them apart from plain lawn
  local rows = { "......", "#####.", "......", "#####.", "......", "......" }
  local legend = setmetatable({ ["#"] = { kind = "solid" } }, { __index = L })
  local cell = mapProvider(rows, legend).cell
  local provider = {
    cell = function(cx, cy) local c = cell(cx, cy); if c then c.mid = 1 end return c end,
    color = function(wx, wy)
      local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
      if cx <= 4 and cy >= 0 and cy <= 3 then -- leafy, with strong texture
        local k = ((math.floor(wx / 4) + math.floor(wy / 4)) % 2 == 0) and 1 or 0.55
        return 0.25 * k, 0.65 * k, 0.3 * k
      end
      return 0.45, 0.75, 0.38 -- plain lawn
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 6, { lumps = false })
  T.check((at(grid, 2 * 16 + 8, 2 * 16 + 8)) > 0, "a canopy row between trunk rows is raised with its tree")
  T.eq((at(grid, 5 * 16 + 8, 2 * 16 + 8)), 0, "plain lawn beside the forest stays flat")

  -- round trees: the forest is one canopy, rounded only where it ends
  local rg = HF.build(provider, 0, 0, 6, 6, { lumps = false, round = "soft" })
  local mid = at(rg, 2 * 16 + 8, 2 * 16 + 8)
  T.eq((at(rg, 2 * 16 + 2, 2 * 16 + 2)), mid, "no dip between two Emerald trees side by side")
  T.eq((at(rg, 2 * 16 + 8, 2 * 16 - 2)), mid, "no dip between one Emerald tree and the next to the south")
  T.check((at(rg, 4 * 16 + 14, 2 * 16 + 8)) < mid, "the forest's outer edge is still rounded")

  -- the canopy is flagged as leaf so the shader can green the teal in it
  local vk = (2 * 4 + 2) * rg.vcols + (2 * 4 + 2) + 1
  T.check(rg.F[vk] == true, "an Emerald canopy voxel is flagged as leaf")
  T.check(rg.F[(2 * 4 + 2) * rg.vcols + (5 * 4 + 2) + 1] == nil, "lawn is not leaf")
  local verts, _, nv = Mesher.build(rg, HF.VOXEL)
  local leafTop, plainTop = false, false
  for i = 1, nv do
    local a = verts[i][11]
    if a == 0.9 then leafTop = true elseif a == 1 then plainTop = true end
  end
  T.check(leafTop and plainTop, "leaf tops carry their own flag, other tops stay plain")
end

do
  -- RSE house: eave trim down both sides in yellow, orange roof between --
  -- one roof, not three (the trim columns used to get gables of their own)
  local rows = { "........", ".#####..", ".#####..", ".#####..", "........" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      local cx = math.floor(wx / 16)
      local c = cell(cx, math.floor(wy / 16))
      if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
      if cx == 1 or cx == 5 then return 0.9, 0.8, 0.3 end -- yellow trim
      return 0.85, 0.5, 0.3                               -- orange tiles
    end,
  }
  local grid = HF.build(provider, 0, 0, 8, 5, { lumps = false, roofs = true })
  T.eq(#grid.roofs, 1, "a house with trim down its sides gets one roof")
  T.check(grid.roofs[1] and grid.roofs[1].x1 == 16 and grid.roofs[1].x2 == 6 * 16, "...spanning the whole house")
end

do
  -- a wall of trees running off the bottom of the captured view (Oldale's
  -- border forest) is still trees: it votes with the rows that have art
  local rows = {}
  for y = 1, 12 do rows[y] = "######" end
  local provider = {
    cell = mapProvider(rows, L).cell,
    color = function(wx, wy)
      if wy >= 4 * 16 then return nil end -- past the capture
      local k = ((math.floor(wx / 4) + math.floor(wy / 4)) % 2 == 0) and 1 or 0.6
      return 0.25 * k, 0.65 * k, 0.3 * k
    end,
  }
  local grid = HF.build(provider, 0, 0, 6, 4, { lumps = false })
  T.check(grid.F[(1 * 4 + 1) * grid.vcols + (2 * 4 + 1) + 1] == true,
    "a forest whose last rows are past the capture is still leafy")
end

do
  -- RSE house: walkable top corners, east-west ridge
  local rows = { "........", "..###...", ".#####..", ".#####..", "........" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      -- the roof art covers the walkable corners too
      local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
      if cx >= 1 and cx <= 5 and cy >= 1 and cy <= 3 then return 0.85, 0.5, 0.3 end
      return 0.45, 0.75, 0.38
    end,
  }
  local grid = HF.build(provider, 0, 0, 8, 5, { lumps = false, roofs = true, ridge = "ew" })
  T.eq((at(grid, 1 * 16 + 8, 1 * 16 + 8)), (at(grid, 3 * 16 + 8, 1 * 16 + 8)),
    "a house's shorter corner column stands as tall as the rest")
  T.eq(#grid.roofs, 1, "...under one roof")
  local r = grid.roofs[1]
  T.check(r and r.ridge == "ew" and r.y0 == 16, "the roof is ridged east-west over the whole house")
  local verts, _, nv = Mesher.build(grid, HF.VOXEL)
  local ridgeZ = r.h + HF.roofRise(r)
  local found = false
  for i = 1, nv do
    local v = verts[i]
    if math.abs(v[3] - ridgeZ) < 0.01 and math.abs(v[2] - (r.y0 + r.y1) / 2) < 0.01 then found = true end
  end
  T.check(found, "the ridge line runs across the middle of the house")
end

do
  -- a lighter column in the middle of a roof does not split the house
  local rows = { "........", ".######.", ".######.", ".######.", "........" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      local cx = math.floor(wx / 16)
      local c = cell(cx, math.floor(wy / 16))
      if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
      if cx == 4 then return 1, 0.85, 0.5 end -- a lighter patch
      return 0.85, 0.5, 0.3
    end,
  }
  local grid = HF.build(provider, 0, 0, 8, 5, { lumps = false, roofs = true, ridge = "ew" })
  T.eq(#grid.roofs, 1, "a lighter column mid-roof leaves one roof, no gable down the middle")
end

do
  -- a house with lawn behind one column is not grown over the lawn, and a
  -- column cut short mid-roof (art still roof) joins the rest
  local rows = { "........", ".##.###.", ".######.", ".######.", "........" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
      if cx >= 1 and cx <= 6 and cy >= 1 and cy <= 3 then return 0.85, 0.5, 0.3 end
      return 0.45, 0.75, 0.38
    end,
  }
  local grid = HF.build(provider, 0, 0, 8, 5, { lumps = false, roofs = true, ridge = "ew" })
  T.eq((at(grid, 3 * 16 + 8, 1 * 16 + 8)), (at(grid, 2 * 16 + 8, 1 * 16 + 8)),
    "a roof column cut short mid-roof stands with the rest")
  local lawn = function(wx, wy)
    local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
    if cy >= 1 and cy <= 3 and cell(cx, cy) and cell(cx, cy).kind == "solid" then return 0.85, 0.5, 0.3 end
    return 0.45, 0.75, 0.38
  end
  local g2 = HF.build({ cell = provider.cell, color = lawn }, 0, 0, 8, 5, { lumps = false, roofs = true, ridge = "ew" })
  T.eq((at(g2, 3 * 16 + 8, 1 * 16 + 8)), 0, "...but lawn behind a shorter column stays lawn")
end

do
  -- RSE: a two-tone house (two trim columns one side) is still one roof
  local rows = { "........", ".######.", ".######.", ".######.", "........" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      local cx = math.floor(wx / 16)
      local c = cell(cx, math.floor(wy / 16))
      if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
      if cx <= 2 then return 0.9, 0.8, 0.3 end
      return 0.85, 0.5, 0.3
    end,
  }
  local g = HF.build(provider, 0, 0, 8, 5, { lumps = false, roofs = true, ridge = "ew" })
  T.eq(#g.roofs, 1, "RSE: a house two-tone across is one roof")
  local f = HF.build(provider, 0, 0, 8, 5, { lumps = false, roofs = true })
  T.eq(#f.roofs, 2, "FRLG still splits roofs by colour")
end

do
  -- RSE: part of a house reaching further back is still under one roof
  local rows = { "........", "....###.", ".######.", ".######.", ".######.", "........" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      local c = cell(math.floor(wx / 16), math.floor(wy / 16))
      if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
      return 0.85, 0.5, 0.3
    end,
  }
  local g = HF.build(provider, 0, 0, 8, 6, { lumps = false, roofs = true, ridge = "ew" })
  T.eq(#g.roofs, 1, "RSE: a house deeper on one side gets one roof")
  T.check(g.roofs[1] and g.roofs[1].x1 == 16 and g.roofs[1].x2 == 7 * 16 and g.roofs[1].y0 == 16,
    "...over the whole house, from its deepest point")
end

do
  -- a pale column mid-house (the light band) is not a cliff in the roof
  local rows = { "........", ".######.", ".######.", ".######.", "........" }
  local cell = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = cell(cx, cy)
      if c then c.mid = (c.kind == "solid") and (100 + cx) or 1 end
      return c
    end,
    color = function(wx, wy)
      local cx = math.floor(wx / 16)
      local c = cell(cx, math.floor(wy / 16))
      if not c or c.kind ~= "solid" then return 0.45, 0.75, 0.38 end
      if cx == 2 or cx == 3 then return 0.85, 0.78, 0.66 end -- pale band, rock-like
      return 0.85, 0.5, 0.3
    end,
  }
  for _, ridge in ipairs({ "ew", "ns" }) do
    local g = HF.build(provider, 0, 0, 8, 5, { lumps = false, roofs = true, rock = true, ridge = ridge })
    T.eq(#g.roofs, 1, "pale columns mid-house stay under the roof (" .. ridge .. ")")
    T.check(g.roofs[1] and g.roofs[1].x1 == 16 and g.roofs[1].x2 == 7 * 16, "...which spans the house (" .. ridge .. ")")
    T.check(not g.R[(1 * 4 + 1) * g.vcols + (2 * 4 + 1) + 1], "...and they lose their rock walls (" .. ridge .. ")")
  end
end

do
  -- cave levels: the floor above a cliff (elevation 4) stands one level up,
  -- the cliff is as tall as that floor, and a character up there stands on it
  local rows = { "......", "......", "######", "......", "......" }
  local base = mapProvider(rows, L).cell
  local provider = {
    cell = function(cx, cy)
      local c = base(cx, cy)
      if c then c.elev = (cy <= 1) and 4 or 3 end
      return c
    end,
    color = function() return 0.6, 0.45, 0.35 end,
  }
  local g = HF.build(provider, 0, 0, 6, 5, { rock = true, cave = true, indoor = true, lumps = false })
  T.eq((at(g, 40, 0 * 16 + 8)), 16, "a raised cave floor stands one level up")
  T.eq((at(g, 40, 2 * 16 + 8)), 16, "...its cliff is as tall as the floor on top")
  T.eq((at(g, 40, 4 * 16 + 8)), 0, "...and the floor below stays down")
  T.eq(HF.floorAt(g, 40, 8), 16, "a character up there stands on the raised floor")
  T.check(not HF.insideAt(g, 40, 8), "...and is not hidden as if inside a wall")
  local flat = HF.build(mapProvider(rows, L), 0, 0, 6, 5, { rock = true, lumps = false })
  T.eq((at(flat, 40, 0 * 16 + 8)), 0, "outside caves, floors stay flat")
end

do
  -- a fountain: 3x3 of pale stone on paving, round, its corners the paving
  local rows = { "......", ".###..", ".###..", ".###..", "......" }
  local cell = mapProvider(rows, L).cell
  local paving = { 0.92, 0.88, 0.74 }
  local provider = {
    cell = function(cx, cy) local c = cell(cx, cy); if c then c.mid = (c.kind == "solid") and 50 or 1 end return c end,
    color = function(wx, wy)
      local dx, dy = wx - 2.5 * 16, wy - 2.5 * 16
      if dx * dx + dy * dy < 20 * 20 then return 0.78, 0.74, 0.70 end -- stone basin
      return paving[1], paving[2], paving[3]
    end,
  }
  local g = HF.build(provider, 0, 0, 6, 5, { lumps = false, roofs = true, rock = true, ridge = "ew" })
  T.eq(#g.roofs, 0, "a fountain gets no roof")
  T.check((at(g, 2.5 * 16, 2.5 * 16)) > 0 and (at(g, 2.5 * 16, 2.5 * 16)) <= 16, "it stands low")
  T.check((at(g, 16 + 2, 16 + 2)) <= 0, "its paving corners lie flat")
end

do
  -- an impassable lawn cell between two trees is filled to the canopy
  local rows = { "......", ".T#T..", "......" }
  local legend = setmetatable({ ["#"] = { kind = "solid" } }, { __index = L })
  local base = mapProvider(rows, legend).cell
  local provider = {
    cell = function(cx, cy) local c = base(cx, cy); if c then c = { kind = c.kind, tree = c.tree, mid = (cx == 2 and cy == 1) and 7 or 1 } end return c end,
    color = function(wx, wy)
      local cx = math.floor(wx / 16)
      if cx == 2 then return 0.44, 0.75, 0.63 end -- teal lawn
      local k = ((math.floor(wx / 4) + math.floor(wy / 4)) % 2 == 0) and 1 or 0.6
      return 0.25 * k, 0.65 * k, 0.3 * k
    end,
  }
  local g = HF.build(provider, 0, 0, 6, 3, { lumps = false })
  T.check((at(g, 2 * 16 + 8, 16 + 8)) > 4, "a lawn gap between two trees is filled")
  T.check(g.F[(1 * 4 + 2) * g.vcols + (2 * 4 + 2) + 1] == true, "...as leaves")
end

do
  -- RSE forest edge: staggered "cave floor" (0x2B) lawn cells between trees
  -- neither make the trees a cave mound nor stay holes
  local rows = { "......", ".TcT..", ".TcT..", "......" }
  local legend = setmetatable({ ["c"] = { kind = "ground", coll = 0x2B } }, { __index = L })
  local base = mapProvider(rows, legend).cell
  local provider = {
    cell = function(cx, cy) local c = base(cx, cy); return c and { kind = c.kind, tree = c.tree, coll = c.coll, mid = 1 } end,
    color = function(wx, wy)
      if math.floor(wx / 16) == 2 then return 0.44, 0.75, 0.63 end
      local k = ((math.floor(wx / 4) + math.floor(wy / 4)) % 2 == 0) and 1 or 0.6
      return 0.25 * k, 0.65 * k, 0.3 * k
    end,
  }
  local g = HF.build(provider, 0, 0, 6, 4, { lumps = false, rock = true })
  T.eq(g.caveMounds or 0, 0, "cave-floor cells beside trees make no cave mound")
  T.check((at(g, 2 * 16 + 8, 16 + 8)) > 4, "...and are filled between the trees")
end

do
  -- staggered edge: a WALKABLE lawn cell between two trees north and south,
  -- closed in east and west, is filled; a lawn path running east-west
  -- between trees is not
  local rows = { "..T...T.", "..-...-.", "..T...T.", "........" }
  local legend = setmetatable({ ["-"] = { kind = "ground" } }, { __index = L })
  local base = mapProvider(rows, legend).cell
  local function provider(closed)
    return {
      cell = function(cx, cy)
        local c = base(cx, cy)
        if c and closed and cy == 1 and (cx == 1 or cx == 3) then return { kind = "solid", mid = 9 } end
        return c and { kind = c.kind, tree = c.tree, mid = 1 }
      end,
      color = function(wx, wy)
        local cx, cy = math.floor(wx / 16), math.floor(wy / 16)
        local c = base(cx, cy)
        if c and c.tree then
          local k = ((math.floor(wx / 4) + math.floor(wy / 4)) % 2 == 0) and 1 or 0.6
          return 0.25 * k, 0.65 * k, 0.3 * k
        end
        if closed and cy == 1 and (cx == 1 or cx == 3) then return 0.9, 0.85, 0.7 end -- fence
        return 0.44, 0.75, 0.63
      end,
    }
  end
  local g = HF.build(provider(true), 0, 0, 8, 4, { lumps = false })
  T.check((at(g, 2 * 16 + 8, 16 + 8)) > 4, "an enclosed lawn cell between staggered trees is filled")
  local p = HF.build(provider(false), 0, 0, 8, 4, { lumps = false })
  T.check((at(p, 2 * 16 + 8, 16 + 8)) <= 1, "a lawn path between trees stays open")
end

do
  -- day and night
  local DN = use("daynight")
  local noon, dusk, night, morning = DN.at(12), DN.at(18.5), DN.at(23), DN.at(8)
  T.check(noon.sun and noon.tint[1] == 1 and noon.tint[3] == 1, "noon: sun up, plain daylight")
  T.check(not night.sun, "night: no sun")
  T.check(night.tint[3] > night.tint[1] and night.tint[1] < 0.6, "night: dark and blue")
  T.check(dusk.tint[1] > dusk.tint[3] + 0.2, "dusk: warm")
  T.check(morning.sunX < 0 and DN.at(17).sunX > 0, "shadows fall west in the morning, east in the evening")
  T.check(DN.at(7).sunY > noon.sunY, "shadows are longer early in the day")
  T.eq(DN.sunKey(23), "night", "one light bake for the whole night")
  T.check(DN.sunKey(10.1) == DN.sunKey(10.4) and DN.sunKey(10.1) ~= DN.sunKey(10.6), "the sun moves in half-hour steps")
  T.eq(DN.hour(15), 15, "a fixed hour")
  -- the bake with a morning sun throws a block's shadow to the west
  local Lighting = use("lighting")
  local rows = { "........", "........", "...##...", "...##...", "........" }
  local g = HF.build(mapProvider(rows, L), 0, 0, 8, 5, { lumps = false })
  local s = DN.at(7)
  local SUN = Lighting.bake(g, HF.VOXEL, { sunX = s.sunX, sunY = s.sunY })
  local function sunAt(wx, wy)
    local k = math.floor(wy / HF.VOXEL) * g.vcols + math.floor(wx / HF.VOXEL) + 1
    return SUN[k]
  end
  T.eq(sunAt(2 * 16 + 8, 3 * 16 + 14), 0, "morning: the shadow lies west of the block")
  T.eq(sunAt(5 * 16 + 8, 3 * 16 + 14), 1, "...and not east of it")
end

do
  -- water: deep enough for a bank, its surface flagged for the ripple
  local rows = { "......", "......", "~~~~~~", "~~~~~~", "......" }
  local g = HF.build(mapProvider(rows, L), 0, 0, 6, 5, { lumps = false })
  T.check(HF.WATER <= -4, "water lies at least a voxel below the land")
  local verts, _, nv = Mesher.build(g, HF.VOXEL)
  local surface, bank = false, false
  for i = 1, nv do
    local v = verts[i]
    if v[11] == 0.97 and v[3] == HF.WATER then surface = true end
    if v[11] < 0.1 and v[3] <= HF.WATER + 0.1 and v[8] < 0.6 then bank = true end
  end
  T.check(surface, "the water surface is flagged as water")
  T.check(g.hasWater, "a map with water asks for reflections")
  local dry = HF.build(mapProvider({ "....", "...." }, L), 0, 0, 4, 2, { lumps = false })
  T.check(not dry.hasWater, "a dry map skips the reflection pass")
  T.check(bank, "the far shore shows a shaded bank down to the water")
end

do
  -- 3D weather
  local W3 = use("weather3d")
  W3.reset()
  T.eq(W3.kindOf(3), "rain", "game weather 3 is rain")
  T.eq(W3.kindOf(7), "ash", "...7 is volcanic ash")
  T.eq(W3.kindOf(6), nil, "fog stays the game's own overlay")
  local rect = { 0, 0, 320, 240 }
  for _ = 1, 150 do W3.update(1 / 60, "rain", rect, 1) end -- 2.5 s: fully in
  local n = #W3._state.parts
  T.check(n == W3.SPEC.rain.n, "rain fades in to its full count")
  local inside = true
  for _, p in ipairs(W3._state.parts) do
    if p.x < -8 or p.x > 328 or p.y < -8 or p.y > 248 or p.z < 0 or p.z > 200 then inside = false end
  end
  T.check(inside, "every drop stays in view, above the ground")
  local t = W3.tint()
  T.check(t and t[1] < 1 and t[3] > t[1], "rain darkens and cools the scene")
  local _, nv, _, ni = W3.build()
  T.eq(nv, n * 4, "one quad per drop")
  T.eq(ni, n * 6, "...two triangles each")
  local half = W3.reset() or nil
  for _ = 1, 150 do W3.update(1 / 60, "rain", rect, 0.5) end
  T.check(#W3._state.parts <= W3.SPEC.rain.n / 2 + 1, "a slow device gets half the drops")
  for _ = 1, 90 do W3.update(1 / 60, nil, rect, 0.5) end
  T.check(not W3.active() and W3.tint() == nil, "it stops when the game's rain stops")
end

do
  -- breathing
  local Scene = use("scene")
  T.eq(Scene.breathScale(100, 100, 0, 3), 1, "BREATH OFF: no movement")
  local lo, hi = 2, 0
  for i = 0, 400 do
    local s = Scene.breathScale(100, 100, 0.022, i * 0.02)
    lo, hi = math.min(lo, s), math.max(hi, s)
  end
  T.check(lo >= 1 and hi <= 1.0221 and hi - lo > 0.015, "SUBTLE: the body rises about 2% and settles")
  local same = 0
  for i = 0, 100 do
    if math.abs(Scene.breathScale(8, 8, 0.022, i * 0.05) - Scene.breathScale(40, 8, 0.022, i * 0.05)) < 1e-6 then same = same + 1 end
  end
  T.check(same < 10, "two characters side by side breathe out of step")
end

do
  -- blinking: short, rare, out of step
  local Scene = use("scene")
  local shut, total = 0, 0
  for i = 0, 6000 do
    total = total + 1
    if Scene.blinking(100, 100, i / 100) then shut = shut + 1 end
  end
  local frac = shut / total
  T.check(frac > 0.015 and frac < 0.04, "eyes are shut about 2-3% of the time (a blink every few seconds)")
  local both = 0
  for i = 0, 6000 do
    if Scene.blinking(8, 8, i / 100) and Scene.blinking(40, 8, i / 100) then both = both + 1 end
  end
  T.check(both < shut / 3, "neighbours do not blink together")
end

do
  -- camera turn
  local function cam(yaw)
    return Camera.solve({ fx = 200, fy = 300, fz = 0, pitch = 45, yaw = yaw, fov = 30, scale = 3, width = 900, height = 1600 })
  end
  local c0, c30 = cam(0), cam(30)
  T.check(math.abs(c0.ex - 200) < 1e-6 and c0.xa[1] == 1, "no turn: the camera sits straight south")
  local sx, sy = Camera.project(c30, 200, 300, 0)
  T.check(math.abs(sx - 450) < 0.01 and math.abs(sy - 800) < 0.01, "turned: the player stays in the middle of the screen")
  T.check(c30.ex > 200 and c30.ey > 300, "turned right: the camera swings round to the south-east")
  local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
  T.check(math.abs(dot(c30.xa, c30.ya)) < 1e-9 and math.abs(dot(c30.ya, c30.za)) < 1e-9
    and math.abs(dot(c30.xa, c30.za)) < 1e-9 and math.abs(dot(c30.ya, c30.ya) - 1) < 1e-9, "the turned view stays square")
  -- a north-facing wall still faces away (no hidden faces come into view)
  T.check(c30.za[2] > 0, "north faces stay hidden when turned")
  local a = { Camera.project(c30, 260, 300, 0) }
  local b = { Camera.project(c30, 200, 240, 0) }
  T.check(a[2] > 800 and b[1] > 450, "camera swung east: east sides come toward it, north leans right")
  local x1, y1, x2, y2 = Camera.visibleRect(c30, 40, 560)
  T.check(x1 < 200 and x2 > 200 and y1 < 300 and y2 > 300, "the visible ground still surrounds the player")
end

T.finish("voxel_world_gen3")
