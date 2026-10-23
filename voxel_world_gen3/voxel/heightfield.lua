-- Voxel heightfield: turns a window of Gen 3 map cells into a grid of 4px
-- voxel columns.
--
-- The GBA overworld is drawn in an oblique projection: anything standing up
-- (a house, a tree, a fence) is painted shifted north by its own height, so
-- one screen pixel of art at (x, y) belongs to a 3D point (x, y + z, z).
-- Running that backwards gives every voxel a texture lookup of (x, y - z):
-- a building whose art spans N rows stands on its southern rows, its front
-- wall carries the bottom rows of art upright, and its roof carries the rest.
-- That one rule is why a fence, a forest and a Poke Center all come out
-- looking like their sprites instead of like a printed block.
--
-- Pure Lua: the cells come from a provider, so this file never touches the
-- engine and can be tested on its own.
--
--   provider.cell(cx, cy) -> info | nil
--     info.kind     "ground" | "solid" | "water" | "grass" | "ledge" | "door"
--     info.canopy   true when the cell is the walkable top half of a tree
--     info.tree     true when the cell is a tree trunk (FRLG knows this)
--     info.border   true beyond every loaded map (the map's border tiling)
--   provider.color(wx, wy) -> r, g, b (0..1) or nil   art at a world pixel

local HF = {}

HF.CELL = 16
HF.VOXEL = 4
-- Water lies a little over a voxel below the land: deep enough that every
-- shore shows a bank, shallow enough that a surfer still rides on top.
HF.WATER = -6
HF.PER = HF.CELL / HF.VOXEL -- voxels per cell edge

local CELL, VOXEL, PER = HF.CELL, HF.VOXEL, HF.PER
-- Runs are measured this many cells past the build window: what a run is
-- (rock, trees, a narrow wall, a tower) is judged over all of it, and a
-- run cut off nearer changed its verdict -- and its height -- as the
-- window slid over it.  (A dozen was too few: Rock Tunnel's walls and the
-- Safari Zone's tree lines are longer than the screen.)
local RUNX = 40
local RAMP = 12 * CELL

local floor, max, min = math.floor, math.max, math.min

local function snap(v)
  return floor(v / VOXEL + 0.5) * VOXEL
end

-- Height of a structure run of `n` cells, before the user's height scale.
-- One-cell things (fences, signs, rocks, lone shrubs) are knee-high slabs,
-- two-cell things are one storey, anything taller -- houses, the Poke Center,
-- a forest edge -- gets two storeys, which is where its art changes from wall
-- to roof on almost every FRLG/RSE building.
function HF.runHeight(n, foliage)
  if n >= 3 then return 32 end
  if n == 2 then return 16 end
  return foliage and 12 or 8
end

local function luminance(r, g, b)
  return 0.299 * r + 0.587 * g + 0.114 * b
end

-- FRLG/RSE rock: warm tan/pink/brown, desaturated.  Roofs fail it (blue,
-- saturated red, the Gyms' golden yellow) and so does grass.
local function isRockColor(r, g, b)
  local warm = r - b
  local l = 0.299 * r + 0.587 * g + 0.114 * b
  return r >= g * 0.98 and g >= b * 0.92 and warm > 0.06 and warm < 0.36
    and l > 0.3 and l < 0.92
end

-- Mountains: a big rock mass rises above the two-storey cap.  One height
-- for all of it: a height that grew with each column's depth left long
-- straight north-south cliff steps between neighbouring columns of what is
-- one rock mass (relief gives it its ruggedness instead).
function HF.rockHeight(n)
  if n >= 6 then return 48 end
  return nil
end

HF._tileRock = {} -- [pair:mid] = rock-coloured (forest pattern test)
HF._rockMem = {}  -- [pair:mid] = rock by its art (rockCell), once seen
HF._roomMem = {}  -- [map] = an interior's back wall depth, once seen
HF._borderWater = {} -- [pair:mid] = a border tile is sea, once seen
HF._leafMem = {}  -- [pair:mid] = foliage by its art, once seen

local function isFoliageColor(r, g, b)
  -- leafy greens and the dark blue-greens FRLG uses for tree shadow
  return g > r * 1.08 and g > b * 0.95 and g > 0.18
end

-- opts:
--   heightScale  multiplier on structure heights (1 = faithful to the art)
--   lumps        false turns off per-voxel foliage/grass relief
-- A street lamp's post, from a tile's object outline (tiles.lua): a thin
-- upright thing (no wider than 6 px over most of its height, at least 6 px
-- tall), clear of the tile's sides -- a fence's rails run to the left and
-- right edges, a sign or a mailbox is a box, a lamp is a stick.
function HF.isPost(s)
  return type(s) == "table" and s.n >= 6 and s.n <= 110 and s.medW <= 6 and s.rows >= 6
    and not s.left and not s.right
end

function HF.build(provider, x0, y0, cols, rows, opts)
  opts = opts or {}
  local scale = opts.heightScale or 1
  local tick = opts.tick or function() end
  local lumps = opts.lumps ~= false
  -- relief granularity: `blk` voxels share one bump (1 = every 4px voxel,
  -- 2 = 8px blocks) and bumps snap to `step` px, so neighbours agree and the
  -- mesher can merge them.  Fine relief costs ~100x the vertices of none.
  local blk = math.max(1, math.floor(opts.reliefBlock or 2))
  local step = math.max(1, opts.reliefStep or 2)
  local color = provider.color

  local vcols, vrows = cols * PER, rows * PER
  local grid = {
    x0 = x0, y0 = y0, cols = cols, rows = rows,
    vcols = vcols, vrows = vrows,
    px = x0 * CELL, py = y0 * CELL, -- world pixel of voxel (0,0)
    -- per voxel: H top height, S facade height, K/C texture row of the top
    -- (v = K*y + C), L shade, W walkable (a tree's canopy row)
    H = {}, S = {}, K = {}, C = {}, L = {}, W = {}, R = {}, F = {}, FL = {},
    -- light sources for the night (lighting.lua): lamps, lit doorways
    lights = {},
    B = {}, -- buildings (under a roof): only their walls have lit windows
    SW = {}, -- foliage that sways in the wind (trees, canopies, tall grass)
    -- indoors (the room pass): U shifts where a voxel's art is read from
    -- sideways (px), CAP is how much of a wall's top shows its art's top
    -- row held, instead of the art running on (a wall taller than its art)
    U = {}, CAP = {},
  }
  local H, S, K, C, L, W, R = grid.H, grid.S, grid.K, grid.C, grid.L, grid.W, grid.R
  local F = grid.F
  local FL = grid.FL

  -- cell infos, cached for anything a run or a ground test looks at
  local info = {}
  local function at(cx, cy)
    -- unique for any cell (runs and the ground test look well past the window)
    local key = (cy - y0 + 64) * 65536 + (cx - x0 + 64)
    local v = info[key]
    if v == nil then
      v = provider.cell(cx, cy) or false
      if v then
        -- our own copy: providers may hand out one shared table per kind,
        -- and the tree pass below marks cells individually
        local copy = {}
        for kk, vv in pairs(v) do copy[kk] = vv end
        v = copy
      end
      info[key] = v
    end
    return v or nil
  end

  -- ------- solid cells that are not things
  --
  -- Collision says "solid" for plenty that is flat on screen: impassable
  -- lawn around a copse, the sea in the map's border.  Raised, those stand
  -- as tall blocks of grass or water (and with sun shadows on, cast big
  -- shadows).  A solid cell built from the same metatile as walkable
  -- ground beside it is ground, and border whose art is water is water.
  local stats = {}
  local function cellStats(cx, cy)
    local key = cy * 65536 + cx
    local st = stats[key]
    if st ~= nil then return st or nil end
    st = false
    if color then
      local n, sr, sg, sb, sl, sl2 = 0, 0, 0, 0, 0, 0
      local samples = {}
      for j = 0, 3 do
        for i = 0, 3 do
          local r, g, b = color(cx * CELL + 2 + i * 4, cy * CELL + 2 + j * 4)
          if not r then n = -1 break end
          local l = luminance(r, g, b)
          n, sr, sg, sb, sl, sl2 = n + 1, sr + r, sg + g, sb + b, sl + l, sl2 + l * l
          -- (flat, three numbers a sample: a table per sample was a good
          -- share of a warp's build on a phone)
          local m = #samples
          samples[m + 1], samples[m + 2], samples[m + 3] = r, g, b
        end
        if n < 0 then break end
      end
      if n > 0 then
        local ml = sl / n
        st = { r = sr / n, g = sg / n, b = sb / n,
               sd = math.sqrt(math.max(0, sl2 / n - ml * ml)), samples = samples }
      end
    end
    stats[key] = st
    return st or nil
  end

  local function isWaterColor(st)
    return st.b > st.r * 1.4 and st.b > st.g * 1.08 and st.b > 0.45
  end

  local function walkable(c)
    return c and (c.kind == "ground" or c.kind == "grass") and not c.canopy
  end

  -- The tile ids standing on walkable ground or water near the view, for
  -- the impassable-lawn test below: a solid tile whose id is in neither set
  -- (a trunk, a wall, a roof -- most of them) can skip its 7x7 search.
  -- Gathered once, over the view and a margin wide enough that the search
  -- from anywhere inside it stays inside it.
  local RX0, RY0, RX1, RY1 = x0 - 8, y0 - 8, x0 + cols + 7, y0 + rows + 7
  local nearMids
  local function midsNear()
    if nearMids then return nearMids end
    nearMids = {}
    for yy = RY0, RY1 do
      for xx = RX0, RX1 do
        local n = at(xx, yy)
        if n and not n.border and n.mid ~= nil
            and (n.kind == "water" or ((n.kind == "ground" or n.kind == "grass") and not n.canopy)) then
          nearMids[n.mid] = true
        end
      end
    end
    return nearMids
  end

  local effective = {}
  local function kindOf(cx, cy)
    local c = at(cx, cy)
    if not c then return nil end
    if c.kind ~= "solid" or c.tree then return c.kind end
    local key = cy * 65536 + cx
    local k = effective[key]
    if k then return k end
    k = "solid"
    if c.border then
      -- (remembered per tile: the border's art is only there on screen,
      -- and an island's sea border was water or a wall around the island
      -- depending on where you stood)
      local st = cellStats(cx, cy)
      local mkey = c.mid ~= nil and (tostring(c.pair) .. ":" .. tostring(c.mid)) or nil
      if st then
        local w = isWaterColor(st) and true or false
        if mkey then HF._borderWater[mkey] = w end
        if w then k = "water" end
      elseif mkey and HF._borderWater[mkey] then
        k = "water"
      end
      -- a sliver between two maps' edges, beyond both: the current map's
      -- border tile fills it (a forest, for Rustboro) -- out in the sea
      -- west of Route 115 it stood as a tall dark wall until you crossed
      -- over.  Border beside a neighbouring map's water is that water.
      if k == "solid" then
        for d = 1, 3 do
          for _, o in ipairs({ { d, 0 }, { -d, 0 }, { 0, d }, { 0, -d } }) do
            local n = at(cx + o[1], cy + o[2])
            -- (another map's water: the current map's own border beside
            -- its own pond is its forest, and stays)
            if n and not n.border and n.kind == "water" and n.map ~= c.map then k = "water" end
          end
          if k ~= "solid" then break end
        end
      end
    elseif c.mid ~= nil and (cx < RX0 + 3 or cx > RX1 - 3 or cy < RY0 + 3 or cy > RY1 - 3
        or midsNear()[c.mid]) then
      -- Impassable lawn is the very same metatile as the walkable lawn
      -- beside it, with only the collision bit set.  Matching the tile id
      -- (never the colours: a roof can look like the walkable row behind
      -- it) keeps every building, sign and door standing.
      for d = 1, 3 do
        for dy = -d, d do
          for dx = -d, d do
            if k == "solid" and (math.abs(dx) == d or math.abs(dy) == d) then
              local n = at(cx + dx, cy + dy)
              if walkable(n) and not n.border and n.mid == c.mid then k = "ground" end
              -- likewise the sea: a map's edge often closes it off with the
              -- very water tile, collision set (Route 115's west shore) --
              -- raised, it stood as a dark wall out in the water
              if k == "solid" and n and n.kind == "water" and not n.border and n.mid == c.mid then
                k = "water"
              end
            end
          end
        end
        if k ~= "solid" then break end
      end
    end
    effective[key] = k
    return k
  end
  HF._kindOf = kindOf -- for tests

  local structMemo = {}
  local function struct(cx, cy)
    -- (asked again and again by the column runs below: remembered)
    local key = (cy - y0 + 64) * 65536 + (cx - x0 + 64)
    local r = structMemo[key]
    if r ~= nil then return r end
    local c = at(cx, cy)
    r = false
    if c then
      if c.kind == "solid" then
        r = kindOf(cx, cy) == "solid"
      elseif c.kind == "door" then
        -- a door is part of the facade it is cut into
        local n = at(cx, cy - 1)
        r = n ~= nil and n.kind == "solid"
      end
    end
    structMemo[key] = r
    return r
  end

  local function vindex(vx, vy) return vy * vcols + vx + 1 end

  -- foliage test over a cell's art (centre-ish samples)
  -- true / false, or nil when the cell's art is not available (outside
  -- the captured view) and it should not vote either way
  -- (remembered per tile, like rock below: Emerald's forests have no art
  -- past the screen, and judged only by what was on screen a forest stood
  -- as trees from one spot and as a four-storey block from the next)
  local leafMem = HF._leafMem
  local function foliageCell(cx, cy)
    if not color then return nil end
    local c0 = at(cx, cy)
    local mkey = c0 and c0.mid ~= nil and (tostring(c0.pair or c0.map) .. ":" .. tostring(c0.mid)) or nil
    local hits, seen = 0, 0
    for i = 0, 3 do
      local sx = cx * CELL + 2 + (i % 2) * 11
      local sy = cy * CELL + 2 + floor(i / 2) * 11
      local r, g, b = color(sx, sy)
      if r then
        seen = seen + 1
        if isFoliageColor(r, g, b) then hits = hits + 1 end
      end
    end
    if seen < 3 then
      if mkey then return leafMem[mkey] end
      return nil
    end
    -- the cell as a whole must lean green too: a brown rock mound whose
    -- corners show the grass or forest around it is not foliage
    local st = cellStats(cx, cy)
    local v = hits >= 3
    if st and not (st.g > st.r * 1.02) then v = false end
    if mkey then leafMem[mkey] = v end
    return v
  end

  -- Rock by its art -- remembered per tile.  The map's picture is only
  -- there near the camera, and a mountain's far columns, judged without
  -- it, came out as houses with roofs, then turned to rock once on screen:
  -- Lavender Town's rocky hills changed shape with every step (the
  -- "buildings glitching while moving").  A tile judged rock once, on
  -- screen, is rock everywhere and every time after.
  local tileRockMem = HF._rockMem
  -- (nil: no art for it on hand, and never judged)
  local function rockKnown(cx, cy)
    local c = at(cx, cy)
    if c and c.cliff then return true end
    local key = c and c.mid ~= nil and (tostring(c.pair) .. ":" .. tostring(c.mid)) or nil
    if color then
      local hits, seen = 0, 0
      for i = 0, 3 do
        local sx = cx * CELL + 3 + (i % 2) * 9
        local sy = cy * CELL + 3 + floor(i / 2) * 9
        local r, g, b = color(sx, sy)
        if r then
          seen = seen + 1
          if isRockColor(r, g, b) then hits = hits + 1 end
        end
      end
      if seen == 4 then
        local v = hits >= 3
        if key then tileRockMem[key] = v end
        return v
      end
    end
    if key and tileRockMem[key] ~= nil then return tileRockMem[key] end
    return nil
  end
  local function rockCell(cx, cy)
    return rockKnown(cx, cy) or false
  end

  local function relief(wx, wy, lo, hi)
    if not (lumps and color) then return 0, 1 end
    local r, g, b = color(wx, wy)
    if not r then return 0, 1 end
    local l = luminance(r, g, b)
    local t = max(0, min(1, (l - 0.15) / 0.6))
    local off = floor((lo + (hi - lo) * t) / step + 0.5) * step
    if off < lo then off = lo elseif off > hi then off = hi end
    -- the shade follows the snapped height, so equal bumps stay mergeable
    local q = (hi > lo) and (off - lo) / (hi - lo) or t
    return off, floor((0.86 + 0.14 * q) * 32 + 0.5) / 32
  end

  -- 1. ground everywhere
  for i = 1, vcols * vrows do
    H[i], S[i], K[i], C[i], L[i] = 0, 0, 1, 0, 1
  end
  for cy = y0, y0 + rows - 1 do
    tick()
    for cx = x0, x0 + cols - 1 do
      local kind = kindOf(cx, cy) or "ground"
      if kind == "water" or kind == "grass" then
        for j = 0, PER - 1 do
          for i = 0, PER - 1 do
            local vx = (cx - x0) * PER + i
            local vy = (cy - y0) * PER + j
            local k = vindex(vx, vy)
            if kind == "water" then
              H[k] = HF.WATER
              grid.hasWater = true
            else
              local bi, bj = i - i % blk, j - j % blk
              -- (taller than it was, 1..5: tall enough to part around
              -- whoever walks through it, still under a character's knees)
              local off, shade = relief(cx * CELL + bi * VOXEL + blk * 2,
                cy * CELL + bj * VOXEL + blk * 2, 3, 8)
              H[k], L[k] = max(3, off), shade
            end
          end
        end
      end
    end
  end

  -- 1b. cave levels.  A cave has floors at several heights (the map's
  -- elevation: 3 the cave floor, 4 and up the ledges above it).  Flat, the
  -- player walked "into" every cliff to reach the floor above it and the
  -- cliffs stood a storey above the floor they hold up, blocking the view.
  -- Each raised floor stands one level (16px) per elevation step, and a
  -- cliff is as tall as the floor on top of it (below).
  local LEVEL = snap(16 * scale)
  local floorCache = {}
  local function floorOf(cx, cy)
    if not opts.cave then return 0 end
    local key = (cy - y0 + 64) * 65536 + (cx - x0 + 64)
    local f = floorCache[key]
    if f ~= nil then return f or nil end
    local function walk(c)
      return c and (c.kind == "ground" or c.kind == "grass" or c.kind == "ledge" or c.kind == "door")
    end
    local c = at(cx, cy)
    f = false
    if walk(c) then
      local e = c.elev
      if e == 0 or e == 15 then
        -- stairs, bridges: the lowest level beside them
        e = nil
        for _, d in ipairs({ { 0, 1 }, { 0, -1 }, { -1, 0 }, { 1, 0 } }) do
          local n = at(cx + d[1], cy + d[2])
          local ne = n and walk(n) and n.elev
          if ne and ne ~= 0 and ne ~= 15 and (e == nil or ne < e) then e = ne end
        end
      end
      f = max(0, (e or 3) - 3) * LEVEL
    end
    floorCache[key] = f
    return f or nil
  end
  HF._floorOf = floorOf -- for tests
  if opts.cave then
    for cy = y0, y0 + rows - 1 do
      tick()
      for cx = x0, x0 + cols - 1 do
        local f = floorOf(cx, cy)
        if f and f > 0 then
          for j = 0, PER - 1 do
            for i = 0, PER - 1 do
              local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
              -- (S: a floor's open side shows the art below it, not a smear)
              H[k], S[k], FL[k] = H[k] + f, f, f
            end
          end
        end
      end
    end
  end

  -- 2. structure runs, one map column at a time
  --
  -- A run covers its whole footprint.  Its front wall carries the bottom
  -- h rows of its art upright (v = y - z); the top carries the rest of the
  -- art, stretched over the full depth of the run, so the strip of ground
  -- the flat art never showed (hidden behind the thing) is not smeared out
  -- of a single pixel row.
  -- Round trees: each tree column is lowered along its east and west
  -- edges, and each two-cell stretch north-south (one tree's height in the
  -- art) at its ends, so a forest reads as rows of rounded crowns rather
  -- than one flat slab.  Drops in px per voxel.
  -- opts.round picks how far: "full" (domes), "soft" (crown edges and a
  -- dip between trees), "ridge" (crown edges only); anything else is flat.
  -- Each step costs vertices: on a big forest ~1.5x, ~5x and ~9x flat.
  local ROUND = {
    full = { x = { 4, 0, 0, 4 }, y2 = { 6, 2, 0, 0, 0, 0, 2, 6 }, y1 = { 4, 0, 0, 4 }, gap = 6, near = 2 },
    soft = { x = { 4, 0, 0, 4 }, y2 = { 4, 0, 0, 0, 0, 0, 0, 4 }, y1 = { 4, 0, 0, 4 }, gap = 4, near = 0 },
    ridge = { x = { 4, 0, 0, 4 }, y2 = { 0, 0, 0, 0, 0, 0, 0, 0 }, y1 = { 0, 0, 0, 0 }, gap = 0, near = 0 },
  }
  local roundP = ROUND[opts.round or ""]
  local round = roundP ~= nil
  local ROUND_X = roundP and roundP.x
  local ROUND_Y2 = roundP and roundP.y2
  local ROUND_Y1 = roundP and roundP.y1

  -- Where a column of trees dips between one crown and the next, read from
  -- the art itself: the rows of the (stretched) top whose art is darkest --
  -- the shadow under each crown -- are the gaps.  A fixed two-cell rhythm
  -- drifts out of step with the art on long forest columns (the top art is
  -- squeezed to fit), putting a dip through the middle of a tree and one
  -- tree's tip on the next one's crown.  nil when the art is not on hand.
  local function crownGaps(cx, ytop, ybottom, kc)
    if not color or not roundP or roundP.gap == 0 then return nil end
    local ry0 = max(ytop, y0) * PER
    local ry1 = (min(ybottom, y0 + rows - 1) + 1) * PER - 1
    -- read a little past the screen rows too, and judge each row against
    -- the rows around it, not the whole stretch on screen: what is on
    -- screen changes as you walk, and the gaps moved with it
    local NEAR = 2 * PER
    local sr0, sr1 = max(ytop * PER, ry0 - 2 * NEAR), min((ybottom + 1) * PER - 1, ry1 + 2 * NEAR)
    local lum, n = {}, 0
    for ry = sr0, sr1 do
      local wy = ry * VOXEL + 2
      local k, c = kc(wy)
      local v = k * wy + c
      local acc, m = 0, 0
      for i = 0, PER - 1 do
        local r, g, b = color(cx * CELL + i * VOXEL + 2, v)
        if r then acc, m = acc + luminance(r, g, b), m + 1 end
      end
      if m > 0 then lum[ry] = acc / m; n = n + 1 end
    end
    if n < 3 then return nil end
    local function near(ry)
      local sum, m = 0, 0
      for r = ry - NEAR, ry + NEAR do
        local l = lum[r]
        if l then sum, m = sum + l, m + 1 end
      end
      return sum / m
    end
    -- a gap is a dark row, darker than the rows around it, and the darkest
    -- within two rows (ties: the upper one) -- decided by its neighbours
    -- alone, not by where the scan started (rows can be any number: maps
    -- west/north of the current one have negative coordinates)
    local cand = {}
    for ry = max(sr0 + 1, ry0 - 5), min(sr1 - 1, ry1 + 5) do
      local l, a, b = lum[ry], lum[ry - 1], lum[ry + 1]
      if l and a and b and l <= a and l <= b and l < near(ry) - 0.04 then cand[ry] = l end
    end
    local drop = {}
    for ry, l in pairs(cand) do
      local keep = true
      for r = ry - 2, ry + 2 do
        local o = cand[r]
        if r ~= ry and o and (o < l or (o == l and r < ry)) then keep = false break end
      end
      if keep then drop[ry] = roundP.gap end
    end
    -- soften either side, and round off the run's two ends
    local out = {}
    for ry, d in pairs(drop) do
      out[ry] = math.max(out[ry] or 0, d)
      if roundP.near > 0 then
        out[ry - 1] = math.max(out[ry - 1] or 0, roundP.near)
        out[ry + 1] = math.max(out[ry + 1] or 0, roundP.near)
      end
    end
    if ytop >= y0 then out[ytop * PER] = math.max(out[ytop * PER] or 0, roundP.gap) end
    if ybottom <= y0 + rows - 1 then
      local e = (ybottom + 1) * PER - 1
      out[e] = math.max(out[e] or 0, roundP.gap)
    end
    return out, drop
  end

  -- a tree or its canopy (a forest continues there)
  -- a cave mouth: the MB_CAVE_DOOR behaviour when the map knows behaviours
  -- (cells.lua); only without them the door collision 0x2B, which RSE also
  -- uses for plain building doors and warps (Rustboro's forest edge stood
  -- as 25 columns of flat "cave mound")
  local function isCaveMouth(c)
    return c ~= nil and c.caveDoor == true
  end

  local function isTreeAt(x, y)
    local c = at(x, y)
    return c ~= nil and c.tree == true
  end

  local function leafyAt(x, y)
    local c = at(x, y)
    return c ~= nil and (c.tree == true or c.canopy == true)
  end

  -- leafy: a tree or forest top (grid.F), where the shader turns the teal
  -- shadow drawn between tree crowns leaf green
  -- fill: one continuous canopy (Ruby/Sapphire/Emerald forests, whose art
  -- draws every tree as a round crown on teal -- domed one by one they read
  -- as a pegboard): rounded only where the forest ends, not between trees
  local function stamp(cx, ytop, ybottom, h, foliage, walk, lo, hi, dome, fill, leafy, clipT, clipB)
    lo, hi = lo or -4, hi or 4
    -- where the two-cell trees start: from the run's real end (a run cut
    -- off by the build window pairs from the end that is really there, so
    -- the pairing does not shift as you walk)
    local pbase = ytop
    if clipT and clipB then pbase = 0 elseif clipT then pbase = ybottom - 1 end
    local Y0, Y1 = ytop * CELL, (ybottom + 1) * CELL
    local len = Y1 - Y0
    -- The art is read lifted by the run's height: its top end maps to
    -- itself, everything from RAMP below it to h higher.  (Squashed over
    -- the whole run, a long forest read different art at every step: the
    -- run is cut off by the build window, and its length changed as you
    -- walked.  Within RAMP of the top a run's length is its own.)
    local R = min(len, RAMP)
    local kA = max(R - h, VOXEL) / R
    local cA = (Y0 + R - h) - kA * (Y0 + R)
    local YR = Y0 + R
    local function kc(wy)
      if wy < YR then return kA, cA end
      return 1, -h
    end
    local maxDrop = floor(h * 0.6 / 2) * 2
    -- (the gaps shape the crown only near a gap the art shows: a whole
    -- column switching between the two whenever a gap came into view
    -- reshaped Rock Tunnel's walls at every step)
    local gaps, gdrop
    if dome and not fill then gaps, gdrop = crownGaps(cx, ytop, ybottom, kc) end
    local function gapRow(cy)
      if not gdrop then return false end
      for r = cy * PER - 6, (cy + 1) * PER + 5 do
        if gdrop[r] then return true end
      end
      return false
    end
    local openN = fill and not leafyAt(cx, ytop - 1)
    local openS = fill and not leafyAt(cx, ybottom + 1)
    for cy = max(ytop, y0), min(ybottom, y0 + rows - 1) do
      local w = walk and walk[cy] or nil
      local kk, cc = kc(cy * CELL)
      local useGaps = gaps and gapRow(cy)
      -- where this cell sits in its two-cell tree (an odd last cell is a
      -- tree of its own)
      local p = (cy - pbase) % 2
      local single = p == 0 and cy == ybottom
      for j = 0, PER - 1 do
        local wy = cy * CELL + j * VOXEL
        for i = 0, PER - 1 do
          local vx = (cx - x0) * PER + i
          local vy = (cy - y0) * PER + j
          local k = vindex(vx, vy)
          local top, shade = h, 1
          if foliage then
            local off
            local bi, bj = i - i % blk, j - j % blk
            local by = cy * CELL + bj * VOXEL + blk * 2
            off, shade = relief(cx * CELL + bi * VOXEL + blk * 2, kk * by + cc, lo, hi)
            if dome then
              -- the crown's shape comes from the dome, not the art
              local dy, dx
              if fill then
                dy = 0
                if j == 0 and cy == ytop and openN then dy = ROUND_Y1[1] end
                if j == PER - 1 and cy == ybottom and openS then dy = ROUND_Y1[PER] end
                dx = 0
                if i == 0 and not leafyAt(cx - 1, cy) then dx = ROUND_X[1] end
                if i == PER - 1 and not leafyAt(cx + 1, cy) then dx = ROUND_X[PER] end
              elseif useGaps then
                dy = gaps[cy * PER + j] or 0
              else
                dy = single and ROUND_Y1[j + 1] or ROUND_Y2[p * PER + j + 1]
              end
              local drop = (dx or ROUND_X[i + 1]) + dy
              if drop > maxDrop then drop = maxDrop end
              off = -drop
              -- shaded by the dome alone: art-driven shades differ on every
              -- patch and would stop the mesher merging the crown
              shade = floor((1 - 0.025 * drop) * 32 + 0.5) / 32
            end
            top = h + off
          end
          -- A top below the facade height samples the art as the facade
          -- would continue down to it, so its edge meets the wall under it.
          F[k] = (fill or leafy) or nil
          if top < h then
            H[k], S[k], K[k], C[k], L[k], W[k] = top, top, kk, cc + (h - top), shade, w
          else
            H[k], S[k], K[k], C[k], L[k], W[k] = top, h, kk, cc, shade, w
          end
        end
      end
    end
  end

  -- Sloped roofs: a building (a solid run three or more cells deep that is
  -- not foliage, rock or a fence) gets a gable over its flat top.  The
  -- ridge runs north-south down the middle, so from the north-looking
  -- camera the roof folds left and right and a triangular gable stands over
  -- the front wall -- the shape that reads as "a house" from this angle.
  -- Adjacent columns with the same run share one roof.
  local roofs = opts.roofs == true
  grid.roofs = {}
  -- block columns judged cliff rather than house (by colour); a house's
  -- light band or pale tiles can tip a column that way mid-roof
  local rockyCols = {}
  local openRoof = {}
  -- buildings standing wall to wall (a house, the Poke Center, a house)
  -- have the same depth; a change of roof colour splits them
  -- Compared by hue (colour with the brightness divided out): light and
  -- dark stripes of one roof are the same building, orange beside red or
  -- blue is not.  The top two cells of the column are averaged.
  local function roofHue(cx, top)
    local a, b = cellStats(cx, top), cellStats(cx, top + 1)
    if not a then return b and roofHue(cx, top + 1) or nil end
    local r, g, bl = a.r, a.g, a.b
    if b then r, g, bl = (r + b.r) / 2, (g + b.g) / 2, (bl + b.b) / 2 end
    local sum = r + g + bl
    if sum < 0.05 then return nil end
    return { r = r / sum, g = g / sum, b = bl / sum }
  end

  local function sameRoof(a, b)
    if not (a and b) then return true end
    return math.abs(a.r - b.r) < 0.09 and math.abs(a.g - b.g) < 0.09 and math.abs(a.b - b.b) < 0.09
  end

  local function addRoof(cx, top, bottom, h)
    local key = top .. ":" .. bottom .. ":" .. h
    local r = openRoof[key]
    local st = roofHue(cx, top)
    local function addHue(rr)
      if st then
        local hs = rr.hsum
        hs[1], hs[2], hs[3], hs[4] = hs[1] + st.r, hs[2] + st.g, hs[3] + st.b, hs[4] + 1
      end
    end
    -- RSE (east-west ridge): one building is one depth; the colour check
    -- split houses at their trim and two-tone tiles, leaving a roof and a
    -- flat strip side by side.  Only FRLG's north-south ridges split by hue.
    if r and r.cx2 == cx - 1 and (opts.ridge == "ew" or sameRoof(st, r.st)) then
      r.cx2 = cx
      r.x2 = (cx + 1) * CELL
      r.st = st or r.st
      addHue(r)
      return
    end
    local Y0, Y1 = top * CELL, (bottom + 1) * CELL
    local len = Y1 - Y0
    local kk = max(len - h, VOXEL) / len
    r = { cx2 = cx, x1 = cx * CELL, x2 = (cx + 1) * CELL, y0 = Y0, y1 = Y1,
          h = h, k = kk, c = (Y1 - h) - kk * Y1, maxRise = 20 * scale, st = st,
          ridge = opts.ridge == "ew" and "ew" or "ns", hsum = { 0, 0, 0, 0 } }
    addHue(r)
    openRoof[key] = r
    grid.roofs[#grid.roofs + 1] = r
  end

  -- Cut-outs.  A fence, a sign or a rock in the sea is one solid cell, but
  -- its art covers only part of it: the rest is the grass or water it
  -- stands on.  Raised whole, the cell becomes a block of grass with a
  -- fence painted on top (or a blue box with a rock on it).  The art
  -- decides voxel by voxel: what looks like the walkable ground or water
  -- next to the cell lies flat with it, only the object itself stands.
  -- outdoors only: indoors a one-cell wall beside the black void is a wall,
  -- and cutting it out of the floor beside it left a few stray specks
  local cutouts = opts.cutouts ~= false and color ~= nil and opts.indoor ~= true
  -- the background's palette: every colour sampled in up to two walkable
  -- or water cells beside it -- wave crests and troughs, grass and its
  -- tufts -- rather than their average, which matches neither
  local function background(cx, cy)
    local order = { { 0, 1 }, { 0, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 1, 1 }, { -1, -1 }, { 1, -1 } }
    local palette, floorH, found = {}, nil, 0
    for _, d in ipairs(order) do
      local n = at(cx + d[1], cy + d[2])
      local k = n and kindOf(cx + d[1], cy + d[2])
      if k == "water" or (k == "ground" and not n.canopy) or k == "grass" then
        local h = (k == "water") and HF.WATER or 0
        if floorH == nil or floorH == h then
          local st = cellStats(cx + d[1], cy + d[2])
          if st then
            floorH = h
            local sm = st.samples
            for q = 1, #sm do palette[#palette + 1] = sm[q] end
            found = found + 1
            if found >= 2 then break end
          end
        end
      end
    end
    if found == 0 then return nil end
    return palette, floorH
  end

  local TOL = 0.09
  -- palette: flat, r, g, b, r, g, b, ...
  local abs = math.abs
  local function inPalette(palette, r, g, b)
    for i = 1, #palette, 3 do
      if abs(r - palette[i]) < TOL and abs(g - palette[i + 1]) < TOL and abs(b - palette[i + 2]) < TOL then
        return true
      end
    end
    return false
  end

  local cutInfo = {}
  local function cutOut(cx, cy)
    if cy < y0 or cy > y0 + rows - 1 then return end
    local palette, floorH = background(cx, cy)
    if not palette then return end
    local isObj, count, sat = {}, 0, 0
    local colSeen, rowSeen = {}, {}
    for j = 0, PER - 1 do
      for i = 0, PER - 1 do
        local r, g, b = color(cx * CELL + i * VOXEL + 2, cy * CELL + j * VOXEL + 2)
        local obj = not (r and inPalette(palette, r, g, b))
        -- the shaded ring of water around a sea rock, or a tuft of grass
        -- in a darker green, is still the background: in water anything
        -- clearly blue is water, on land anything clearly green is grass
        if obj and r then
          if floorH < 0 then
            if b > r * 1.3 and b > g * 1.05 then obj = false end
          elseif g > r * 1.15 and g > b * 1.15 then
            obj = false
          end
        end
        isObj[j * PER + i] = obj
        if obj then
          count = count + 1
          colSeen[i], rowSeen[j] = true, true
          if r then sat = sat + (max(r, g, b) - min(r, g, b)) end
        end
      end
    end
    -- all object (a solid stone block) or almost none (collision only):
    -- nothing to cut
    if count >= PER * PER - 1 then return end
    -- remembered for the lamp pass below
    if floorH == 0 then
      local nc, nr = 0, 0
      for q = 0, PER - 1 do
        if colSeen[q] then nc = nc + 1 end
        if rowSeen[q] then nr = nr + 1 end
      end
      cutInfo[cy * 65536 + cx] = { cx = cx, cy = cy, count = count, sat = sat / max(1, count),
        cols = nc, rows = nr }
    end
    for j = 0, PER - 1 do
      for i = 0, PER - 1 do
        local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
        if count < 2 or not isObj[j * PER + i] then
          H[k], S[k], K[k], C[k], L[k], W[k] = floorH, 0, 1, 0, 1, nil
        else
          -- the voxel shows the very pixel that made it part of the object,
          -- top and sides: solid extruded pixel art, not grass from a row
          -- the stretched mapping happened to land on
          K[k], C[k], S[k] = 1, 0, 0
        end
      end
    end
  end

  -- A mound's art is not a rectangle: its upper corners show the grass and
  -- trees around it.  Raised whole, those corners stretch into green spires.
  -- Every voxel of the top whose art (where the stretched top samples it) is
  -- clearly green lies flat, so the mound takes the shape it is drawn in.
  local function shapeByArt(cx, top, bottom)
    if not color then return end
    for cy = max(top, y0), min(bottom, y0 + rows - 1) do
      for j = 0, PER - 1 do
        for i = 0, PER - 1 do
          local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
          local wy = cy * CELL + j * VOXEL + 2
          local r, g, b = color(cx * CELL + i * VOXEL + 2, K[k] * wy + C[k])
          -- anything not rock-coloured: grass, and the dark teal forest
          -- shadow FRLG draws around trees (as blue as it is green)
          if r and not isRockColor(r, g, b) and g > r * 1.1 and g >= b * 0.8 then
            H[k], S[k], K[k], C[k], L[k], W[k], R[k] = 0, 0, 1, 0, 1, nil, nil
            grid.caveFlat = (grid.caveFlat or 0) + 1
          end
        end
      end
    end
  end

  -- rock voxels: their side walls slant the art down the face (mesher.lua)
  -- instead of smearing one column of pixels into long streaks
  local function markRock(cx, top, bottom)
    for cy = max(top, y0), min(bottom, y0 + rows - 1) do
      for j = 0, PER - 1 do
        for i = 0, PER - 1 do
          R[vindex((cx - x0) * PER + i, (cy - y0) * PER + j)] = true
        end
      end
    end
  end

  -- Forests by their tile pattern.  A tree is two cells wide and two tall,
  -- so a forest repeats its tiles every second cell across and down: the
  -- cell two below (and two across) is the same tile, the one right below
  -- (and right beside) is not.  Lavender Town's grey trees (its own
  -- tileset, not in the FRLG tree list, and too grey to pass for foliage
  -- by colour) stood as tall blocks -- judged by art that is only there
  -- near the camera, so they also changed shape as the view moved.  The
  -- pattern needs no art: the same verdict wherever the camera is.
  -- (A cliff face repeats every cell, a roof or a wall does not repeat
  -- that way at all.)
  -- (FireRed/LeafGreen only: Ruby/Sapphire/Emerald forests already come
  -- out right by their art -- marked here too, all of Petalburg Woods
  -- turned into one block of tree tops)
  if provider.family == "frlg" then
    local function sm(cx, cy)
      local c = at(cx, cy)
      if c and c.kind == "solid" and c.mid ~= nil and not (c.tree and not c.patternTree) then return c.mid end
      return nil
    end
    -- (mountains repeat their rock tiles too: a tile whose art is rock
    -- coloured is never a tree.  Judged once per tile, when its art is on
    -- screen, and remembered, so the verdict does not depend on where the
    -- camera is either)
    local function notRock(cx, cy, m)
      local c = at(cx, cy)
      local key = tostring(c and c.pair) .. ":" .. tostring(m)
      local v = HF._tileRock[key]
      if v == nil then
        local st = cellStats(cx, cy)
        if st then
          v = rockCell(cx, cy) or isRockColor(st.r, st.g, st.b)
          HF._tileRock[key] = v
        end
      end
      return v ~= true
    end
    -- a crown drawn over sprites (FRLG: the player walks behind a tree's
    -- top half) in this cell or the one above or below: a tree, whatever
    -- its colour (Lavender Town's trees are brown-grey enough to pass for
    -- rock)
    local overOf = provider.over
    local function crown(cx, cy)
      if not overOf then return false end
      for dy = -1, 1 do
        local c = at(cx, cy + dy)
        local n = c and overOf(c)
        if n and n >= 40 then return true end
      end
      return false
    end
    local function forestAt(cx, cy)
      local m = sm(cx, cy)
      if not m or not (crown(cx, cy) or notRock(cx, cy, m)) then return false end
      local votes, seen = 0, 0
      for _, d in ipairs({ { 0, 2 }, { 0, -2 }, { 2, 0 }, { -2, 0 } }) do
        local m2 = sm(cx + d[1], cy + d[2])
        if m2 ~= nil then
          seen = seen + 1
          -- (the cell between must be a different tile: not a plain
          -- repeating wall)
          local mid1 = sm(cx + d[1] / 2, cy + d[2] / 2)
          if m2 == m and mid1 ~= nil and mid1 ~= m then votes = votes + 1 end
        end
      end
      return seen >= 2 and votes >= 2 and votes * 4 >= seen * 3
    end
    local fmemo = {}
    local function forest(cx, cy)
      local key = (cy - y0 + 64) * 65536 + (cx - x0 + 64)
      local v = fmemo[key]
      if v == nil then v = forestAt(cx, cy); fmemo[key] = v end
      return v
    end
    local marks = {}
    local cand, crowns = 0, 0
    for cx = x0 - 1, x0 + cols do
      tick()
      for cy = y0 - 13, y0 + rows + 12 do
        if crown(cx, cy) then crowns = crowns + 1 end
        if forest(cx, cy) then
          cand = cand + 1
          -- (a forest needs a few such cells together: one stray match on
          -- a patterned roof is not a tree)
          local n = 0
          for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            if forest(cx + d[1], cy + d[2]) then n = n + 1 end
          end
          if n >= 2 then marks[#marks + 1] = at(cx, cy) end
        end
      end
    end
    local marked = 0
    for _, c in ipairs(marks) do
      if not c.tree then c.tree, c.patternTree = true, true; marked = marked + 1 end
    end
    grid.patternTrees = marked
    grid.patternCand, grid.crownCells = cand, crowns
  end

  -- Trees by their art.  FRLG trees are known by metatile id (cells.lua);
  -- Ruby/Sapphire/Emerald have no such list, and their forests alternate a
  -- solid trunk row with a walkable canopy row -- left alone every trunk
  -- became its own little block with a flat green strip between.  A solid
  -- cell that looks like foliage, under a walkable cell whose art is busy
  -- foliage too (tree tops, not plain lawn), is a tree and its canopy.
  if color and opts.artTrees ~= false then
    local function solidLeafy(cx, cy)
      local c = at(cx, cy)
      return c and c.kind == "solid" and not c.border and foliageCell(cx, cy) == true
    end
    for cx = x0 - 1, x0 + cols do
      tick()
      for cy = y0 - 13, y0 + rows + 12 do
        local c = at(cx, cy)
        if c and not c.tree and not c.canopy and (c.kind == "ground" or c.kind == "grass")
            and solidLeafy(cx, cy + 1) and foliageCell(cx, cy) == true then
          local st = cellStats(cx, cy)
          if st and st.sd >= 0.07 then
            c.canopy, c.artTree = true, true
            local t = at(cx, cy + 1)
            t.tree, t.artTree = true, true
          end
        end
      end
    end
  end

  for cx = x0, x0 + cols - 1 do
    tick()
    local cy = y0 - 1 -- the apron row lets a run start above the window
    while cy <= y0 + rows - 1 do
      if struct(cx, cy) then
        -- runs are only measured a few cells past the window: beyond a
        -- map's edge everything is solid border, and a run's height stops
        -- changing at three cells anyway
        local top = cy
        -- measured up to a dozen cells past the window so a mountain's
        -- height does not change as the window slides over it
        -- A run never mixes tree trunks with anything else: a house built
        -- right up against a forest is its own building, not the forest's
        -- southern edge (FRLG forests alternate trunk and canopy cells, so
        -- the house would come out roof / tree / roof / tree).
        local isTree = function(y) local c = at(cx, y) return c ~= nil and c.tree == true end
        local kindTree = isTree(cy)
        -- (the map and the border tiling past its edge stay one run: split,
        -- the sliver of border between two maps' edges -- Petalburg's and
        -- Route 104's -- stood on its own as a flat strip through the
        -- forest)
        local isBorder = function(y) local c = at(cx, y) return c ~= nil and c.border == true end
        local kindBorder = isBorder(cy)
        -- A building set into a hillside (Lavender Town's Poke Center) is
        -- not part of the hill: a run going down from rock into a
        -- building's facade -- not rock, with a door below it -- stops at
        -- the rock.  As one run, the Center took the hill's depth, and one
        -- of its columns stood up as a long strip of roof running back
        -- into the rock.
        local function doorBelow(y)
          for dy = 0, 7 do
            for dx = -3, 3 do
              local c = at(cx + dx, y + dy)
              -- (FRLG's house doors are walkable cells with the door
              -- behaviour, not the door collision; Pokemon Tower's door is
              -- the kind without animation, like a cave's)
              if c and (c.kind == "door" or c.warpDoor or c.caveDoor) then return true end
            end
          end
          return false
        end
        local function hillEdge(y) -- rock at y, the building's facade below it
          -- (or the forest behind it: Emerald's trees are known only by
          -- their art, and Route 104's flower shop and the trees behind it
          -- were one run -- trees from one spot, a green tower from another)
          if kindTree then return false end
          if rockCell(cx, y) and not rockCell(cx, y + 1) and doorBelow(y + 1) then return true end
          -- a forest standing on a cliff (Route 119): the trees are trees,
          -- the cliff rock -- as one run the whole of it was either
          if foliageCell(cx, y) == true and foliageCell(cx, y - 1) == true
              and foliageCell(cx, y + 1) ~= true and rockKnown(cx, y + 1) == true and rockKnown(cx, y + 2) == true then
            return true
          end
          return foliageCell(cx, y) == true and foliageCell(cx, y - 1) == true
            and foliageCell(cx, y + 1) == false and foliageCell(cx, y + 2) == false and doorBelow(y + 1)
        end
        while top - 1 >= y0 - RUNX and struct(cx, top - 1) and isTree(top - 1) == kindTree
            and not hillEdge(top - 1) do
          top = top - 1
        end
        local bottom = cy
        while bottom + 1 <= y0 + rows + RUNX and struct(cx, bottom + 1) and isTree(bottom + 1) == kindTree
            do
          if hillEdge(bottom) then break end
          bottom = bottom + 1
        end
        -- One building, one mapping.  RSE houses leave some top cells
        -- walkable (the corners under the gable trim, a cell here and there
        -- along the roof), so their columns came out of different depths:
        -- each stretched the roof art its own way, and the light band and
        -- trim jumped up and down from column to column.  Every column along
        -- the same front wall whose top is within two cells of its
        -- neighbour's takes the building's highest top -- as long as the
        -- cells it grows over show the building, not the lawn behind it.
        if not kindTree then
          local function sameFront(nx)
            return struct(nx, bottom) and not struct(nx, bottom + 1) and not isTreeAt(nx, bottom)
          end
          local function topOf(nx)
            local t = bottom
            while t - 1 >= y0 - RUNX and struct(nx, t - 1) and not isTreeAt(nx, t - 1) do t = t - 1 end
            return t
          end
          local best = top
          for dir = -1, 1, 2 do
            local prev, nx = top, cx + dir
            for _ = 1, 8 do
              if not sameFront(nx) then break end
              local t = topOf(nx)
              if math.abs(t - prev) > 2 then break end
              if t < best then best = t end
              prev, nx = t, nx + dir
            end
          end
          if best < top and top - best <= 2 then
            -- the lawn behind the building, as colours
            local behind = cellStats(cx, best - 1)
            local ok = true
            for y = best, top - 1 do
              local c = at(cx, y)
              if not c or c.canopy or c.tree or c.kind == "water" or c.kind == "door" then ok = false break end
              local st = cellStats(cx, y)
              if behind and st then
                local same = 0
                local sm = st.samples
                for q = 1, #sm, 3 do
                  if inPalette(behind.samples, sm[q], sm[q + 1], sm[q + 2]) then same = same + 1 end
                end
                if same * 4 >= (#sm / 3) * 3 then ok = false break end
              end
            end
            if ok then top = best end
          end
        end
        local tree = false
        for y = top, bottom do
          local c = at(cx, y)
          if c and c.tree then tree = true break end
        end
        -- FRLG trees: the walkable canopy cell above the trunk is the top of
        -- the same tree, so the run starts there
        local n = at(cx, top - 1)
        local walk = nil
        if tree and n and n.canopy then
          top = top - 1
          walk = { [top] = true }
        end
        local cells = bottom - top + 1
        -- a mountain running on into the border past the map's edge is as
        -- deep as both together
        local span = cells
        if not kindBorder then
          local y = top - 1
          while span < 6 and struct(cx, y) and isBorder(y) do span, y = span + 1, y - 1 end
          y = bottom + 1
          while span < 6 and struct(cx, y) and isBorder(y) do span, y = span + 1, y + 1 end
        end
        local foliage = tree
        if not foliage then
          -- judged by the cells nearest the front (on screen, like rock),
          -- and only those whose art is on hand: a forest running off the
          -- top of the view must not be outvoted by what lies past it
          -- (the southernmost six cells that have art: a forest running off
          -- the bottom of the view -- the wall of trees around a town -- has
          -- none in its last rows, and with no votes it stood as a plain
          -- block instead of trees)
          -- (the border tiling past the map's edge votes only when no map
          -- cell can: whether its art is on hand depends on where you stand)
          local mapVotes = false
          for y = top, bottom do
            local c = at(cx, y)
            if c and not c.border and foliageCell(cx, y) ~= nil then mapVotes = true break end
          end
          local hits, votes = 0, 0
          for y = bottom, top, -1 do
            local c = at(cx, y)
            local f = nil
            if not (mapVotes and c and c.border) then f = foliageCell(cx, y) end
            if f ~= nil then
              votes = votes + 1
              if f then hits = hits + 1 end
              if votes >= 6 then break end
            end
          end
          foliage = votes > 0 and hits * 2 > votes
        end
        -- A block with a cave mouth in it or right beside it is a rock mound
        -- (Diglett's Cave, Rock Tunnel): never trees, never a roof.
        -- The whole mound counts, not only the columns beside the mouth:
        -- walk sideways along the block (through solid cells) looking for it.
        local caveMound = false
        -- (a mouth with rock right above it: Pokemon Tower's door, the
        -- same kind without animation, has its slate facade above, and the
        -- cliffs beside the tower sank to a cave mound's 16 px)
        local function caveIn(x)
          for y = top, bottom + 1 do
            local c = at(x, y)
            if isCaveMouth(c) and (not color or rockCell(x, y - 1) or rockCell(x, y - 2)
                or not cellStats(x, y - 1)) then return true end
          end
          return false
        end
        -- the block's colour where its art is on hand: the southernmost cell
        -- with art (a forest running off the bottom of the view has none in
        -- its last rows, and must still count as green)
        local function frontStats(x)
          for y = bottom, top, -1 do
            local st = cellStats(x, y)
            if st then return st end
          end
          return nil
        end
        local mouthX = nil
        if caveIn(cx) then caveMound, mouthX = true, cx end
        for dir = -1, 1, 2 do
          local x = cx
          for _ = 1, 6 do
            if caveMound then break end
            x = x + dir
            if caveIn(x) then caveMound, mouthX = true, x break end
            -- only through the mound itself: stop at open ground and at
            -- the forest beside it (tree cells, or green art)
            local solidRow, leafy = false, false
            for y = top, bottom do
              if struct(x, y) then solidRow = true end
              local c = at(x, y)
              if c and (c.tree or c.canopy) then leafy = true end
            end
            local st = frontStats(x)
            if st and st.g > st.r * 1.02 then leafy = true end
            if not solidRow or leafy then break end
          end
        end
        -- a forest column beside the mound stays trees
        if caveMound and not caveIn(cx) then
          local st = frontStats(cx)
          if tree or (st and st.g > st.r * 1.02) then caveMound = false end
        end
        -- RSE uses the same "door without animation" behaviour for cave
        -- mouths and for some buildings' doors: a mound is rock-coloured
        if caveMound and color then
          local rocky, n = 0, 0
          -- judged over the column of the mouth itself (a mound's sides
          -- show the grass around it)
          local mx = mouthX or cx
          for y = top, bottom do
            local st = cellStats(mx, y)
            if st then
              n = n + 1
              -- (dark counts only at the mouth itself: Pokemon Tower's dark
              -- slate facade, a door without animation at its foot, passed
              -- for a cave mound and its door column sank to 16 px)
              if rockCell(mx, y) or isRockColor(st.r, st.g, st.b) or (y >= bottom - 1 and (st.r + st.g + st.b) < 0.6) then rocky = rocky + 1 end
            end
          end
          if n > 0 and rocky * 2 < n then caveMound = false end
        end
        -- (a forest known by its tile pattern is trees, cave or no cave)
        if caveMound then
          for y = top, bottom do
            local c = at(cx, y)
            if c and c.patternTree then caveMound = false break end
          end
        end
        if caveMound then
          foliage, tree = false, false
          grid.caveMounds = (grid.caveMounds or 0) + 1
        end
        -- A run one cell wide (nothing solid beside most of it) is a fence,
        -- a hedge or a row of posts running north-south, not a building
        -- seen end-on: it stays knee-high however long it is.  FRLG trees
        -- keep their own height.
        local narrow = false
        if cells >= 2 and not tree and opts.indoor ~= true then
          local beside = 0
          for y = top, bottom do
            if struct(cx - 1, y) or struct(cx + 1, y) then beside = beside + 1 end
          end
          narrow = beside * 2 < cells
        end
        -- A run standing in the sea (a chain of rocks, rocks touching one
        -- another) is never a building, however deep: knee-high, cut out of
        -- the water, no roof.
        local wet = false
        if not tree then
          local water, n = 0, 0
          for y = top, bottom do
            n = n + 2
            if kindOf(cx - 1, y) == "water" then water = water + 1 end
            if kindOf(cx + 1, y) == "water" then water = water + 1 end
          end
          n = n + 2
          if kindOf(cx, top - 1) == "water" then water = water + 1 end
          if kindOf(cx, bottom + 1) == "water" then water = water + 1 end
          wet = water * 2 >= n
        end
        local rock = false
        if opts.cave and not narrow and not wet and not foliage and cells >= 3 then
          -- in a cave every solid mass is the cave's rock wall
          rock = true
        elseif not narrow and not wet and not foliage and opts.rock and HF.rockHeight(span) then
          -- judge by the six southernmost cells that can be judged (a
          -- mountain running off the bottom of the view has no art in its
          -- last rows: judged by those, Cape Brink's cliffs were rock or
          -- houses depending on where you stood)
          -- (the border tiling past the map's edge votes only when nothing
          -- else can: it is the same wall wherever you stand, and its
          -- verdict flipped the mountain it runs into)
          local hits, n = 0, 0
          local anyMap = false
          for y = top, bottom do
            local c = at(cx, y)
            if c and not c.border and rockKnown(cx, y) ~= nil then anyMap = true break end
          end
          for y = bottom, top, -1 do
            local c = at(cx, y)
            local v = nil
            if not (anyMap and c and c.border) then v = rockKnown(cx, y) end
            if v ~= nil then
              n = n + 1
              if v then hits = hits + 1 end
              if n >= 6 then break end
            end
          end
          rock = hits * 2 > n
        end
        -- cave walls stand one storey and a half: the art already draws the
        -- cliff face, and at mountain height it stretched into long teeth
        local base = rock and (opts.cave and 24 or (HF.rockHeight(span) or HF.rockHeight(6))) or HF.runHeight((narrow or wet) and 1 or cells, foliage)
        -- every column of a cave mound stands equally tall and low (16px, so
        -- its art is barely stretched and reads like the flat game): the column
        -- over the mouth is a cell shorter (the mouth is walkable), which
        -- left it a storey lower than its neighbours
        if caveMound then base = 16 end
        -- A tall building -- seven cells deep or more, with a door in its
        -- front (Lavender Tower, Silph Co., the Celadon store) -- is drawn
        -- several storeys high: at the two-storey cap it stood lower than
        -- the hills around it, sunk into the mountain.
        if not rock and not foliage and not tree and not narrow and not wet and not caveMound
            and cells >= 7 and not opts.indoor and not opts.cave then
          local function isBorder2(x, y) local c = at(x, y) return c ~= nil and c.border == true end
          local door = false
          for dx = -3, 3 do
            for y = bottom - 1, bottom + 1 do
              local c = at(cx + dx, y)
              if c and (c.kind == "door" or c.warpDoor or c.caveDoor) then
                -- (not a door in a front judged rock: One Island's Poke
                -- Center reads as rock, and the plain columns at its sides
                -- stood up as two four-storey posts)
                local hits, n = 0, 0
                for yy = y - 1, y - 6, -1 do
                  local v = rockKnown(cx + dx, yy)
                  local st = cellStats(cx + dx, yy)
                  if st and isRockColor(st.r, st.g, st.b) then v = true end
                  if v ~= nil then n = n + 1; if v then hits = hits + 1 end end
                end
                -- (and the building as deep at its door: the corner pieces
                -- of a Poke Center's front reach a cell further down)
                local d, yy = 0, y
                while struct(cx + dx, yy) and not isBorder2(cx + dx, yy) and d < 12 do d, yy = d + 1, yy - 1 end
                if not (n > 0 and hits * 2 > n) and d >= 7 then door = true end
              end
            end
          end
          -- (the hill behind a building is split off it -- hillEdge -- so a
          -- grey facade, like the Celadon store's middle, is no hill)
          -- (nor a forest standing behind a house: Emerald's trees are known
          -- only by their art, and the trees behind Route 104's flower shop
          -- joined it into one nine-cell run -- a green tower)
          local leafy = 0
          for y = top, bottom do if foliageCell(cx, y) == true then leafy = leafy + 1 end end
          if door and leafy < 2 then base = 64 end
        end
        -- A small free-standing thing -- a fountain, a statue, a well: no
        -- more than three cells wide or deep, standing on its own -- is not
        -- a building.  Knee-to-shoulder high, no roof, and cut out of the
        -- paving around it (the corners of its cells are the square it
        -- stands on, which stood up as a beige box around a round fountain).
        local small = false
        if not tree and not foliage and not caveMound and not narrow and not wet
            and cells <= 3 and not opts.indoor and not opts.cave then
          local function front(x)
            return struct(x, bottom) and not struct(x, bottom + 1) and not isTreeAt(x, bottom)
          end
          local w = 1
          local x = cx - 1
          while w <= 4 and front(x) do w, x = w + 1, x - 1 end
          x = cx + 1
          while w <= 4 and front(x) do w, x = w + 1, x + 1 end
          -- nothing solid right behind it either (a building's back part)
          local stone = false
          if cells == 3 then
            -- three deep: only pale stone (a fountain, a statue), never a
            -- coloured little house
            local rocky = 0
            for y = top, bottom do
              local st = cellStats(cx, y)
              if rockCell(cx, y) or (st and isRockColor(st.r, st.g, st.b)) then rocky = rocky + 1 end
            end
            stone = rocky * 2 > cells
          end
          -- a block with a door in it is something you go into
          local door = false
          for dx = -2, 2 do
            for y = top, bottom + 1 do
              local c = at(cx + dx, y)
              if c and (c.kind == "door" or c.caveDoor) then door = true end
            end
          end
          small = w <= 3 and (cells <= 2 or stone) and not door and not struct(cx, top - 1)
        end
        if small then base = HF.runHeight(min(cells, 2), false) end
        local h = snap(base * scale)
        if h < VOXEL then h = VOXEL end
        if opts.cave then
          local up, dn = floorOf(cx, top - 1), floorOf(cx, bottom + 1)
          if up and up > (dn or 0) then
            -- a cliff (however shallow) is as tall as the floor it holds up
            h = up
          elseif rock then
            -- a wall with no floor above it stands its usual height over
            -- the floor in front
            h = max(up or 0, dn or 0) + h
          else
            -- a boulder, a sign: standing on the floor in front of it
            h = h + (dn or up or 0)
          end
        end
        if rock then
          stamp(cx, top, bottom, h, lumps, nil, -4, 6)
          markRock(cx, top, bottom)
        else
          local artRun = false
          if tree then
            for y = top, bottom do
              local c = at(cx, y)
              if c and c.artTree then artRun = true break end
            end
          end
          local clipT, clipB = top <= y0 - RUNX, bottom >= y0 + rows + RUNX
          stamp(cx, top, bottom, h, foliage, walk, nil, nil, round and foliage, artRun, foliage and not caveMound,
            clipT, clipB)
          -- a cave mound is a plain block with its art on top: flattening
          -- parts of it by colour, or slanting its walls like rock, cut it
          -- into tall slivers (the "spires")
          if roofs and cells >= 3 and not small and not caveMound and not foliage and not narrow and not wet and not tree
              and top >= y0 and bottom <= y0 + rows - 1 then
            -- rock-coloured blocks too shallow to be mountains are cliffs,
            -- not houses
            -- judged over the whole block, by each cell's average colour as
            -- well: a cave mouth's dark doorway spoils the corner samples
            local rocky, n = 0, 0
            for y = top, bottom do
              n = n + 1
              local st = cellStats(cx, y)
              if rockCell(cx, y) or (st and isRockColor(st.r, st.g, st.b)) then rocky = rocky + 1 end
            end
            if rocky * 2 <= n then
              addRoof(cx, top, bottom, h)
            else
              markRock(cx, top, bottom)
              rockyCols[cx] = { top = top, bottom = bottom, h = h }
            end
          end
          -- small things (fences, posts, signs, sea rocks) stand on their
          -- background instead of filling their whole cell with it
          if cutouts and not caveMound and not foliage and not tree and (cells <= 2 or narrow or wet or small) then
            for y = top, bottom do cutOut(cx, y) end
          end
        end
        cy = bottom + 1
      else
        local c = at(cx, cy)
        if c and c.kind == "ledge" and cy >= y0 then
          stamp(cx, cy, cy, 4 + (floorOf(cx, cy) or 0), false, nil)
        end
        cy = cy + 1
      end
    end
  end

  -- A block with a cave mouth in or beside it (Diglett's Cave, Rock
  -- Tunnel) is a rock mound, not a house: drop its roof and treat it as rock.
  -- A cave mouth is a door whose metatile behaviour is MB_CAVE_DOOR
  -- (cells.lua sets caveDoor); house doors are MB_WARP_DOOR.
  if roofs and #grid.roofs > 0 then
    local keep = {}
    for _, r in ipairs(grid.roofs) do
      local cave = false
      local cx1, cx2 = floor(r.x1 / CELL) - 1, floor(r.x2 / CELL)
      local cy1, cy2 = floor(r.y0 / CELL), floor(r.y1 / CELL)
      for cy = cy1, cy2 do
        for cx = cx1, cx2 do
          local c = at(cx, cy)
          if isCaveMouth(c) then cave = true end
        end
      end
      if cave then
        for cx = floor(r.x1 / CELL), floor(r.x2 / CELL) - 1 do
          markRock(cx, cy1, cy2 - 1)
        end
      else
        keep[#keep + 1] = r
      end
    end
    grid.roofs = keep
  end

  -- A "cliff" column right beside a roof, of exactly the same depth and
  -- height, is part of that house: its pale band or tiles fooled the
  -- colour test, and it stood flat (with rock walls) in the middle of the
  -- roof -- the step in the light band.  Up to three such columns a side.
  if roofs and #grid.roofs > 0 and next(rockyCols) then
    local function same(rc, r)
      return rc and rc.h == r.h and rc.top * CELL == r.y0 and (rc.bottom + 1) * CELL == r.y1
    end
    local function unrock(cx, rc)
      for cy = max(rc.top, y0), min(rc.bottom, y0 + rows - 1) do
        for j = 0, PER - 1 do
          for i = 0, PER - 1 do
            R[vindex((cx - x0) * PER + i, (cy - y0) * PER + j)] = nil
          end
        end
      end
      rockyCols[cx] = nil
    end
    for _, r in ipairs(grid.roofs) do
      for _ = 1, 3 do
        local cx = floor(r.x2 / CELL)
        local rc = rockyCols[cx]
        if not same(rc, r) then break end
        unrock(cx, rc)
        r.x2 = r.x2 + CELL
      end
      for _ = 1, 3 do
        local cx = floor(r.x1 / CELL) - 1
        local rc = rockyCols[cx]
        if not same(rc, r) then break end
        unrock(cx, rc)
        r.x1 = r.x1 - CELL
      end
    end
  end

  -- Gaps in a forest: an impassable lawn cell between trees (RSE staggers
  -- the trees along a forest's edge, leaving teal cells between them) lay
  -- flat as a hole in the canopy.  One with trees on both sides -- east and
  -- west, or north and south -- is filled to the canopy beside it.
  do
    local fills = {}
    local function centre(cx, cy)
      if cx < x0 or cy < y0 or cx > x0 + cols - 1 or cy > y0 + rows - 1 then return nil end
      return vindex((cx - x0) * PER + floor(PER / 2), (cy - y0) * PER + floor(PER / 2))
    end
    -- a raised, leafy cell: a tree (flagged leafy, or leafy art)
    local function treeAt(x, y)
      local k = centre(x, y)
      if not k or (H[k] or 0) <= 4 then return false end
      if F[k] then return true end
      local c = at(x, y)
      return c ~= nil and (c.tree == true or foliageCell(x, y) == true)
    end
    local function walkLawn(x, y)
      local c = at(x, y)
      if not (c ~= nil and (c.kind == "ground" or c.kind == "grass") and not c.canopy) then return false end
      -- lawn that leads somewhere, not a town's paving beyond a fence
      local st = cellStats(x, y)
      return st == nil or st.g > st.r * 1.02
    end
    for cy = y0, y0 + rows - 1 do
      for cx = x0, x0 + cols - 1 do
        local c = at(cx, cy)
        local k = centre(cx, cy)
        local st = c and not opts.cave and k and (H[k] or 0) <= 1 and not F[k] and cellStats(cx, cy)
        -- (lawn-coloured only: a fence or a sign between two trees stays)
        if st and st.g > st.r * 1.02 then
          local blocked = c.kind == "solid" or c.coll == 0x2B
          local src
          if treeAt(cx - 1, cy) and treeAt(cx + 1, cy) then
            -- trees east and west: a walkable cell there is still a path
            -- running north-south, unless it leads nowhere
            if blocked or (not walkLawn(cx, cy - 1) and not walkLawn(cx, cy + 1))
                or treeAt(cx, cy - 1) or treeAt(cx, cy + 1) then
              src = { cx - 1, cy }
            end
          end
          if not src and treeAt(cx, cy - 1) and treeAt(cx, cy + 1) then
            -- trees north and south: likewise for a path running east-west.
            -- RSE's staggered forest edge leaves such cells between the
            -- trees -- walkable, but closed in by the next column of trees
            -- and the fence
            -- (a tree on one more side closes it too: a path is open on
            -- both of its sides)
            if blocked or (not walkLawn(cx - 1, cy) and not walkLawn(cx + 1, cy))
                or treeAt(cx - 1, cy) or treeAt(cx + 1, cy) then
              src = { cx, cy - 1 }
            end
          end
          if src then fills[#fills + 1] = { cx, cy, src[1], src[2] } end
        end
      end
    end
    for _, f in ipairs(fills) do
      local cx, cy, sx, sy = f[1], f[2], f[3], f[4]
      for j = 0, PER - 1 do
        for i = 0, PER - 1 do
          local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
          -- the neighbour's matching voxel: same row (east/west) or same
          -- column (north/south), so the canopy surface continues
          local si = (sx ~= cx) and (sx < cx and PER - 1 or 0) or i
          local sj = (sy ~= cy) and (sy < cy and PER - 1 or 0) or j
          local n = vindex((sx - x0) * PER + si, (sy - y0) * PER + sj)
          H[k], S[k], K[k], C[k], L[k], F[k] = H[n], S[n], K[n], C[n] + (sy - cy) * 0, L[n], true
          W[k], R[k] = nil, nil
        end
      end
    end
    grid.gapFills = #fills
  end

  -- RSE: roofs side by side on one front wall are one building even when
  -- the columns behind them reach back to different depths -- one roof,
  -- one ridge, one mapping of the art over the whole house.
  if roofs and opts.ridge == "ew" and #grid.roofs > 1 then
    local merged = true
    while merged do
      merged = false
      for i, a in ipairs(grid.roofs) do
        for j, b in ipairs(grid.roofs) do
          if i ~= j and a.x2 == b.x1 and a.y1 == b.y1 and a.h == b.h
              and math.abs(a.y0 - b.y0) <= 2 * CELL then
            a.x2 = b.x2
            a.y0 = math.min(a.y0, b.y0)
            local len = a.y1 - a.y0
            a.k = max(len - a.h, VOXEL) / len
            a.c = (a.y1 - a.h) - a.k * a.y1
            table.remove(grid.roofs, j)
            merged = true
            break
          end
        end
        if merged then break end
      end
    end
  end

  -- A roof one cell wide is the edge of the house beside it, not a house:
  -- RSE draws the eave trim down a house's sides in another colour, so the
  -- hue split cut those columns off, and each got a little gable of its own
  -- (the house came out as three roofs side by side).  Fold them into the
  -- neighbour of the same height whose rows they share.
  if roofs and #grid.roofs > 1 then
    local function near(a, b) return math.abs(a - b) <= CELL end
    local gone = {}
    for _, r in ipairs(grid.roofs) do
      if r.x2 - r.x1 <= CELL then
        local best
        for _, o in ipairs(grid.roofs) do
          if o ~= r and not gone[o] and o.x2 - o.x1 > CELL and o.h == r.h
              and (o.x2 == r.x1 or o.x1 == r.x2) and near(o.y0, r.y0) and near(o.y1, r.y1) then
            best = o
            break
          end
        end
        if best then
          if best.x2 == r.x1 then best.x2 = r.x2 else best.x1 = r.x1 end
          gone[r] = true
        end
      end
    end
    if next(gone) then
      local keep = {}
      for _, r in ipairs(grid.roofs) do
        if not gone[r] then keep[#keep + 1] = r end
      end
      grid.roofs = keep
    end
  end

  -- Two roofs side by side over one building: the column-by-column hue
  -- check can trip in the middle of a roof (a dormer, a lighter patch),
  -- leaving a gable -- or a fold -- down the middle of a house.  Roofs of
  -- the same depth and height whose overall colours match are one roof;
  -- an orange house beside a red Poke Center is still two.
  if roofs and #grid.roofs > 1 then
    local function mean(r)
      local hs = r.hsum
      if not hs or hs[4] == 0 then return nil end
      return { r = hs[1] / hs[4], g = hs[2] / hs[4], b = hs[3] / hs[4] }
    end
    local merged = true
    while merged do
      merged = false
      for i, a in ipairs(grid.roofs) do
        for j, b in ipairs(grid.roofs) do
          if i ~= j and a.x2 == b.x1 and a.y0 == b.y0 and a.y1 == b.y1 and a.h == b.h then
            local ma, mb = mean(a), mean(b)
            if ma and mb and math.abs(ma.r - mb.r) < 0.05 and math.abs(ma.g - mb.g) < 0.05
                and math.abs(ma.b - mb.b) < 0.05 then
              a.x2 = b.x2
              for q = 1, 4 do a.hsum[q] = a.hsum[q] + b.hsum[q] end
              table.remove(grid.roofs, j)
              merged = true
              break
            end
          end
        end
        if merged then break end
      end
    end
  end

  -- Indoors, the exit.  RSE puts a room's way out in the black row below
  -- the floor: a walkable cell drawn (nearly) black.  The player arrives
  -- standing on it and in 3D seemed to hover in the void, a row below the
  -- floor's edge.  Such a cell -- dark, walkable, the floor north of it,
  -- nothing walkable south of it -- shows the floor tile above it instead,
  -- so the floor reaches the door like a mat.
  -- Swaying: tree trunks' crowns, the canopies over paths, tall grass --
  -- and any leafy canopy voxel (F).  scene.lua moves them in the wind.
  if opts.indoor ~= true and opts.cave ~= true then
    for cy = y0, y0 + rows - 1 do
      for cx = x0, x0 + cols - 1 do
        local c = at(cx, cy)
        -- (not a small cut-out object -- a fence, a sign, a post on a
        -- lawn can pass for leafy art)
        local small = cutInfo[cy * 65536 + cx] ~= nil
        local leafy = c and not small and (c.tree or c.canopy or c.artTree or kindOf(cx, cy) == "grass")
        if not small then
          local SW = grid.SW
          local base = (cy - y0) * PER * vcols + (cx - x0) * PER + 1
          for j = 0, PER - 1 do
            local rowk = base + j * vcols
            for i = 0, PER - 1 do
              local k = rowk + i
              if leafy or F[k] then SW[k] = true end
            end
          end
        end
      end
    end
  end

  -- Buildings: only their walls light their windows at night (scene.lua)
  -- -- a fountain's water or a blue sign is glass-blue too.  A building is
  -- a block you can go into: the connected structure (solid, not trees)
  -- around a real door (cells.lua: warpDoor; any door where the behaviour
  -- is unknown; never a cave mouth).  Its every cell counts, roof and
  -- walls alike.  A fountain, a statue or a sign has no door.
  -- (This replaced telling them by their roof or their height: a stone
  -- fountain three cells deep was given a roof, or stood tall enough.)
  grid.anyWindows = false
  grid.buildings = 0
  do
    local seen = {}
    local function key(x, y) return (y - y0 + 64) * 65536 + (x - x0 + 64) end
    local function isDoor(c) return c and c.kind == "door" and not c.caveDoor and (c.warpDoor or not c.behKnown) end
    local function part(x, y)
      if x < x0 or y < y0 or x > x0 + cols - 1 or y > y0 + rows - 1 then return false end
      local c = at(x, y)
      return c ~= nil and not c.tree and not c.canopy and struct(x, y)
    end
    for cy = y0, y0 + rows - 1 do
      for cx = x0, x0 + cols - 1 do
        if not seen[key(cx, cy)] and part(cx, cy) then
          -- flood one block, noting whether a door is in it or under it
          local stack, cells, door = { { cx, cy } }, {}, false
          seen[key(cx, cy)] = true
          while #stack > 0 do
            local q = table.remove(stack)
            cells[#cells + 1] = q
            local x, y = q[1], q[2]
            if isDoor(at(x, y)) or isDoor(at(x, y + 1)) then door = true end
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
              local nx, ny = x + d[1], y + d[2]
              local kk = key(nx, ny)
              if not seen[kk] and part(nx, ny) then
                seen[kk] = true
                stack[#stack + 1] = { nx, ny }
              end
            end
          end
          if door then
            grid.buildings = grid.buildings + 1
            for _, q in ipairs(cells) do
              local base = (q[2] - y0) * PER * vcols + (q[1] - x0) * PER + 1
              for j = 0, PER - 1 do
                for i = 0, PER - 1 do grid.B[base + j * vcols + i] = true end
              end
            end
          end
        end
      end
    end
  end

  -- Street lamps, lit at night (lighting.lua).  Only in towns and cities:
  -- routes have no street lighting.
  --
  -- A lamp is known by its tile (tiles.lua): the object in the top layer
  -- of its metatile, read from the game's tileset at full resolution, is a
  -- thin upright post clear of the tile's sides.  The verdict belongs to
  -- the tile, so every lamp built from it is lit alike.  On the map a post
  -- must also stand free below (a fountain's spout stands in its basin) and
  -- above, unless what is above is its own head (a vertical fence runs on
  -- through both).
  --
  -- Where the tileset cannot tell (no layer split), the older guess from
  -- the screen picture is used: a thin grey cut-out post standing alone,
  -- remembered once seen (opts.lampMemory).
  grid.cutouts = 0
  for _ in pairs(cutInfo) do grid.cutouts = grid.cutouts + 1 end
  grid.lampsByTile, grid.lampsByArt = 0, 0
  local shapeOf = provider.shape
  local town = opts.town ~= false
  local function solidAt(x, y) return kindOf(x, y) == "solid" end
  local function addLamp(cx, cy, fx, fy)
    grid.lights[#grid.lights + 1] = { x = cx * CELL + fx, y = cy * CELL + fy, r = 34, s = 1, kind = "lamp" }
  end
  local artCells = {} -- cells the tileset could not judge
  -- (each cell by its own map: cells.lua's town, else the current map's)
  local function inTown(c)
    if c.town ~= nil then return c.town end
    return town
  end
  do
    for cy = y0, y0 + rows - 1 do
      for cx = x0, x0 + cols - 1 do
        local c = at(cx, cy)
        if c and c.kind == "solid" and not c.tree and not c.border and inTown(c) then
          local sh = shapeOf and shapeOf(c)
          -- the tile tells only when its top layer holds an object: empty
          -- (the object drawn into the ground layer) or a full square (the
          -- ground layer itself) leaves it to the picture
          if type(sh) ~= "table" or sh.n == 0 or sh.n >= 200 then
            artCells[cy * 65536 + cx] = true
          elseif HF.isPost(sh) and not solidAt(cx, cy + 1) then
            local ok = true
            if solidAt(cx, cy - 1) then
              -- above: only its own head, with nothing solid over that
              local u = at(cx, cy - 1)
              local ush = shapeOf(u)
              ok = type(ush) == "table" and ush.n > 0 and ush.n <= 110
                and not ush.left and not ush.right and not solidAt(cx, cy - 2)
            end
            if ok then
              -- the light pools at the post's foot
              addLamp(cx, cy, (sh.minX + sh.maxX + 1) / 2, max(8, sh.maxY))
              grid.lampsByTile = grid.lampsByTile + 1
            end
          end
        end
      end
    end
  end
  -- the fallback, only for the cells above
  local lit = {}
  for round = 1, 2 do
  for ckey, ci in pairs(cutInfo) do
    local cx, cy = ci.cx, ci.cy
    if artCells[ckey] and not lit[ckey] then
    local below = kindOf(cx, cy + 1) == "solid"
    local head = cutInfo[(cy - 1) * 65536 + cx]
    local topY = head and cy - 1 or cy
    local mem = opts.lampMemory
    local key = cx .. "," .. cy
    -- (seen by its art: a post pixel or two, depending on how the
    -- quarter-size art lines up with it, so a lamp judged once is kept)
    local seen = ci.count + (head and head.count or 0) >= 2
    -- tall and thin: a post, not a mailbox or a sign (wider than tall)
    local rowsAll = ci.rows + (head and head.rows or 0)
    local looks = ci.count <= 7 and ci.sat < 0.35 and ci.cols <= 2 and rowsAll >= 2
      and rowsAll >= ci.cols
      and (not head or (head.count <= 9 and head.sat < 0.4))
    -- every lamp in a town is the same metatile: one found lights them all
    local mid = at(cx, cy) and at(cx, cy).mid
    local known = mem and (mem[key] or (mid and mem.mids and mem.mids[mid]))
    local ok = not below and (known or (seen and looks))
      and kindOf(cx, topY - 1) ~= "solid"
      and (head ~= nil or kindOf(cx, cy - 1) ~= "solid")
    if ok then
      -- alone: nothing solid on either side, the corners included (a
      -- fountain's spout is a thin grey post too, ringed by its basin)
      for y = topY - 1, cy + 1 do
        if kindOf(cx - 1, y) == "solid" or kindOf(cx + 1, y) == "solid" then ok = false end
      end
    end
    if ok then
      lit[ckey] = true
      addLamp(cx, cy, 8, 12)
      grid.lampsByArt = grid.lampsByArt + 1
      if mem then
        mem[key] = true
        -- (only a metatile judged a lamp by its own art spreads)
        if mid and seen and looks then
          mem.mids = mem.mids or {}
          mem.mids[mid] = true
        end
      end
    end
    end
  end
  end

  -- Outdoors, doorways: at night light spills out of them onto the step.
  -- Real doors only -- the animated door behaviour houses, marts, Poke
  -- Centers and gyms use (cells.lua: warpDoor).  Arrow warps at a route's
  -- edge, cave mouths, holes and ladders share the door collision but are
  -- no lit doorway.  (Behaviour unknown: any door cut into a facade.)
  if not opts.indoor and not opts.cave then
    for cy = y0, y0 + rows - 1 do
      for cx = x0, x0 + cols - 1 do
        local c = at(cx, cy)
        if c and c.kind == "door" and not c.caveDoor and struct(cx, cy)
            and (c.warpDoor or not c.behKnown) then
          grid.lights[#grid.lights + 1] = { x = cx * CELL + 8, y = cy * CELL + 22, r = 26, s = 0.85, kind = "door" }
        end
      end
    end
  end

  -- Indoors, the void.  The black around a room is solid on the map, and
  -- raised like any wall it stood a storey tall along the room's open
  -- south side -- in front of the floor's last row, the exit and the
  -- player's feet, so the player arriving at the door seemed to stand in
  -- the dark.  Black is nothing: it lies flat.
  grid.voidFlat = 0
  if opts.indoor and not opts.cave and color then
    for cy = y0, y0 + rows - 1 do
      for cx = x0, x0 + cols - 1 do
        local c = at(cx, cy)
        if c and c.kind == "solid" and not c.tree then
          local st = cellStats(cx, cy)
          if st and luminance(st.r, st.g, st.b) < 0.06 and st.sd < 0.04 then
            for j = 0, PER - 1 do
              for i = 0, PER - 1 do
                local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
                H[k], S[k], K[k], C[k], L[k] = 0, 0, 1, 0, 1
                W[k], R[k], F[k] = nil, nil, nil
                grid.V = grid.V or {}
                grid.V[k] = true -- (the room's light falls off toward it)
              end
            end
            grid.voidFlat = grid.voidFlat + 1
          end
        end
      end
    end
  end

  -- Indoors, the room.  The outdoor rules (runs of solid cells, one or two
  -- storeys by depth) made a room's back wall a short strip whose pieces
  -- stood at different heights wherever a cabinet's cell joined its run,
  -- left the side walls as low edges and laid the furniture nearly flat.
  -- A room is built as a dollhouse instead:
  --   back wall   the solid band under the black void at the top of each
  --               column, all of it one height, its art upright
  --   side walls  solid cells beside the void on the left or right, as
  --               tall as the back wall
  --   furniture   every other solid cell, a box as tall as its art reaches
  --               above its cell (read from the art: where the wall or
  --               floor pattern behind it starts again)
  --   floor       flat
  grid.room = nil
  if opts.indoor and not opts.cave and color then
    local function isVoid(cx, cy)
      -- (past the cells built: nothing to stand beside)
      if cx < x0 or cx > x0 + cols - 1 or cy < y0 or cy > y0 + rows - 1 then return true end
      local c = at(cx, cy)
      if not c then return true end
      if c.border then return true end
      if c.kind ~= "solid" or c.tree then return false end
      local st = cellStats(cx, cy)
      return st ~= nil and luminance(st.r, st.g, st.b) < 0.06 and st.sd < 0.04
    end
    local function solidThing(cx, cy)
      local c = at(cx, cy)
      -- (kindOf: an impassable cell of the very floor tile beside it is floor;
      -- a staircase is floor too: the player arrives standing on it, and
      -- inside a wall-high box vanished)
      return c ~= nil and c.kind == "solid" and not c.tree and not c.warpTile
        and kindOf(cx, cy) == "solid" and not isVoid(cx, cy)
    end
    local X1, Y1r = x0 + cols - 1, y0 + rows - 1
    -- back wall: per column, the first solid band under the void
    local band = {}
    for cx = x0, X1 do
      for cy = y0, Y1r do
        if solidThing(cx, cy) and isVoid(cx, cy - 1) then
          local e = cy
          while e + 1 <= Y1r and solidThing(cx, e + 1) do e = e + 1 end
          band[cx] = { top = cy, raw = e }
          break
        elseif not isVoid(cx, cy) then
          break -- floor first: no back wall in this column (in view)
        end
      end
    end
    -- the band's bottom: stretches of three or more columns ending on the
    -- same row are wall; a column or two reaching further down is a cabinet
    -- or a shelf standing against it, cut back to the wall beside it
    local ends = {}
    do
      local cx = x0
      while cx <= X1 do
        local b = band[cx]
        if not b then
          cx = cx + 1
        else
          local e = cx
          while e + 1 <= X1 and band[e + 1] and band[e + 1].raw == b.raw do e = e + 1 end
          if e - cx + 1 >= 3 then
            for x = cx, e do ends[x] = b.raw end
          end
          cx = e + 1
        end
      end
      for cx = x0, X1 do
        local b = band[cx]
        if b and not ends[cx] then
          -- nearest wide stretch, else the shallowest band near it
          local best, bd
          for d = 1, cols do
            for _, x in ipairs({ cx - d, cx + d }) do
              if ends[x] and band[x] and band[x].top == b.top and (not bd or d < bd) then best, bd = ends[x], d end
            end
            if best then break end
          end
          ends[cx] = math.min(b.raw, best or b.raw)
          if not best and b.raw - b.top + 1 > 3 then
            -- a lone deep column from the top: a side wall, not a back wall
            band[cx], ends[cx] = nil, nil
          elseif not best then
            for d = 1, 2 do
              for _, x in ipairs({ cx - d, cx + d }) do
                local o = band[x]
                if o and o.top == b.top and o.raw < ends[cx] then ends[cx] = o.raw end
              end
            end
          end
        end
      end
    end
    -- one height for the whole room: its usual band, upright
    local depthCount, depth, nd = {}, 2, 0
    for cx, b in pairs(band) do
      local d = ends[cx] - b.top + 1
      depthCount[d] = (depthCount[d] or 0) + 1
      if depthCount[d] > nd then depth, nd = d, depthCount[d] end
    end
    -- (remembered per map: a big interior -- the Pokemon Mansion, the S.S.
    -- Anne -- shows a different stretch of back wall at every step, and
    -- its walls changed height as you walked)
    do
      local mc = at(x0 + floor(cols / 2), y0 + floor(rows / 2))
      local mk = mc and mc.map
      if mk then
        local mem = HF._roomMem[mk]
        if mem then depth = mem
        elseif nd >= 3 then HF._roomMem[mk] = depth end
      end
    end
    -- (a storey above its art: the room reads as a box you look into, the
    -- extra height its art's top row held -- see CAP)
    local artH = math.max(32, math.min(48, depth * CELL))
    local wallH = snap((artH + 16) * scale)
    local role = {} -- [key] = "wall" | "side" | "thing"
    local function key(cx, cy) return cy * 65536 + cx end
    -- (no deeper than the room's usual wall: a stretch reaching further
    -- down -- the alcove behind a Poke Center's counter -- stood as one
    -- wall-high block cells deep, its top the art's top row smeared over
    -- them; what lies in front of the usual wall is furniture against it)
    for cx, b in pairs(band) do
      if ends[cx] > b.top + depth - 1 then ends[cx] = b.top + depth - 1 end
      for cy = b.top, ends[cx] do role[key(cx, cy)] = "wall" end
    end
    for cy = y0, Y1r do
      for cx = x0, X1 do
        if solidThing(cx, cy) and not role[key(cx, cy)] then
          role[key(cx, cy)] = (isVoid(cx - 1, cy) or isVoid(cx + 1, cy)) and "side" or "thing"
        end
      end
    end
    -- a box h tall over cells cy0..cy1 whose art starts at artTop; with
    -- art shorter than the box (show), its top `h - show` px hold the art's
    -- top row
    -- (a side wall runs along the room: one or two cells beside the void
    -- are a cupboard or a plant in the corner)
    for cx = x0, X1 do
      local cy = y0
      while cy <= Y1r do
        if role[key(cx, cy)] == "side" then
          local e = cy
          while e + 1 <= Y1r and role[key(cx, e + 1)] == "side" do e = e + 1 end
          if e - cy + 1 < 3 then
            for y = cy, e do role[key(cx, y)] = "thing" end
          end
          cy = e + 1
        else
          cy = cy + 1
        end
      end
    end
    local function box(cx, cy0, cy1, h, artTop, show)
      show = show or h
      local Y0, Y1 = cy0 * CELL, (cy1 + 1) * CELL
      local kk = max(Y1 - show - artTop, VOXEL) / (Y1 - Y0)
      local cc = (Y1 - show) - kk * Y1
      local cap = h - show
      for cy = max(cy0, y0), min(cy1, Y1r) do
        for j = 0, PER - 1 do
          for i = 0, PER - 1 do
            local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
            H[k], S[k], K[k], C[k], L[k] = h, h, kk, cc, 1
            grid.CAP[k] = cap > 0 and cap or nil
            W[k], R[k], F[k], grid.SW[k], grid.B[k] = nil, nil, nil, nil, nil
          end
        end
      end
    end
    -- how far a thing's art reaches up past its cell into the cell above:
    -- pixel rows that differ from the same rows beside it (the wall or the
    -- floor behind repeats from cell to cell; the thing does not)
    local function rowDiff(ax, bx, wy)
      local d = 0
      for i = 0, CELL - 1, 2 do
        local r1, g1, b1 = color(ax * CELL + i, wy)
        local r2, g2, b2 = color(bx * CELL + i, wy)
        if not (r1 and r2) then return nil end
        d = d + math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2)
      end
      return d / (CELL / 2)
    end
    local function reach(cx, cy, limit, behind)
      -- reference columns: the nearest cells either side of the same kind
      -- behind (wall or floor) with no thing in front of them
      local refs = {}
      for d = 1, 4 do
        for _, x in ipairs({ cx - d, cx + d }) do
          if #refs < 2 and behind(x, cy - 1) and not (role[key(x, cy)] == "thing") then refs[#refs + 1] = x end
        end
      end
      if #refs == 0 then return 0 end
      local up = 0
      for dy = 1, limit do
        local wy = cy * CELL - dy
        local same = false
        for _, x in ipairs(refs) do
          local df = rowDiff(cx, x, wy)
          if df == nil or df < 0.12 then same = true break end
        end
        if same then
          -- (a row or two matching by chance inside the thing: look on)
          local nxt = false
          for dy2 = dy + 1, math.min(limit, dy + 2) do
            local wy2 = cy * CELL - dy2
            local all = true
            for _, x in ipairs(refs) do
              local df = rowDiff(cx, x, wy2)
              if df == nil or df < 0.12 then all = false break end
            end
            if all then nxt = true break end
          end
          if not nxt then break end
        end
        up = dy
      end
      return up
    end
    local walls, sides, things = 0, 0, 0
    for cx = x0, X1 do
      local cy = y0
      while cy <= Y1r do
        local r = role[key(cx, cy)]
        if r then
          local e = cy
          while e + 1 <= Y1r and role[key(cx, e + 1)] == r do e = e + 1 end
          if r == "wall" then
            local show = snap(math.min(artH, (e - cy + 1) * CELL) * scale)
            -- (its top reads the dark above the wall's art: a dollhouse's
            -- walls are cut through, and a sliver of art smeared over the
            -- top showed as streaks, or as a pale block on an alcove)
            box(cx, cy, e, wallH, (e + 1) * CELL - show - 12, show)
            walls = walls + 1
          elseif r == "side" then
            box(cx, cy, e, wallH, cy * CELL)
            sides = sides + 1
          else
            local n = e - cy + 1
            local against = role[key(cx, cy - 1)] == "wall" or role[key(cx, cy - 1)] == "side"
            local up
            if against then
              up = reach(cx, cy, depth * CELL, function(x, y) return role[key(x, y)] == "wall" end)
            else
              up = reach(cx, cy, CELL, function(x, y) return walkable(at(x, y)) end)
            end
            -- a box as tall as the art standing up from its front edge:
            -- the thing's own cell row and what reaches above it, less
            -- what lies on its top (a deep table shows most of it there)
            local h
            if against then
              h = math.min(wallH - VOXEL, math.max(12, up + (n == 1 and 12 or 8)))
            else
              -- (free-standing: the floor around it is no reliable
              -- reference -- tatami mats lie both ways, a cushion beside a
              -- table differs -- so what reaches above counts for little:
              -- a counter a cell deep stands up to 20, a table stays low)
              if n == 1 then
                h = 12 + math.min(up, 8)
              else
                h = 8 + math.min(up, 4)
              end
            end
            h = snap(h * scale)
            if against and up >= depth * CELL - 2 then
              -- its picture fills the wall above it to the top: part of the
              -- wall stepping forward (an alcove, a built-in cupboard), as
              -- tall as the wall and held at the top the same way -- as a
              -- box a few px short of it, its top showed as a pale block
              local show = math.min(wallH, up + n * CELL)
              box(cx, cy, e, wallH, (e + 1) * CELL - show - 12, show)
              walls = walls + 1
            else
              box(cx, cy, e, h, cy * CELL - up)
              things = things + 1
            end
          end
          cy = e + 1
        else
          cy = cy + 1
        end
      end
    end
    -- the floor lies flat (a staircase with it)
    for cy = y0, Y1r do
      for cx = x0, X1 do
        local c = at(cx, cy)
        if c and (c.kind == "ground" or c.kind == "door" or c.warpTile) and not role[key(cx, cy)] then
          for j = 0, PER - 1 do
            for i = 0, PER - 1 do
              local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
              if (H[k] or 0) > 0 and ((S[k] or 0) < 16 or c.warpTile or c.kind == "door") then
                grid.CAP[k], grid.U[k] = nil, nil
                H[k], S[k], K[k], C[k], L[k] = 0, 0, 1, 0, 1
                W[k], R[k], F[k] = nil, nil, nil
              end
            end
          end
        end
      end
    end
    -- The open sides.  Most rooms have no side walls on the map: the floor
    -- runs to the black.  Turned, or lit, the room showed its floor's raw
    -- edge over the void.  A thin wall (one voxel) stands in the void along
    -- each such edge, as tall as the back wall, and shows the back wall's
    -- art -- its bands and trim running on around the corner (U reads a
    -- plain column of it, one cell in from the room's end).
    local made = 0
    local plainL, plainR, wallTop = nil, nil, nil
    for cx = x0, X1 do
      local b = band[cx]
      if b and ends[cx] then
        wallTop = wallTop or ends[cx]
        if not plainL then plainL = cx end
        plainR = cx
      end
    end
    if plainL then
      -- (a cell in from each end: the end column is often a pillar)
      if plainR - plainL >= 2 then plainL, plainR = plainL + 1, plainR - 1 end
      local A1 = (wallTop + 1) * CELL
      local show = snap(artH * scale)
      local cap = wallH - show
      for cy = wallTop + 1, Y1r do
        for cx = x0, X1 do
          local cc0 = at(cx, cy)
          local inside = not isVoid(cx, cy) and role[key(cx, cy)] ~= "side" and role[key(cx, cy)] ~= "wall"
            and not (cc0 and cc0.kind == "door")
          if inside then
            for _, sd in ipairs({ -1, 1 }) do
              local nx = cx + sd
              if nx >= x0 and nx <= X1 and isVoid(nx, cy) then
                local vx = (nx - x0) * PER + (sd < 0 and PER - 1 or 0)
                local srcX = (sd < 0 and plainL or plainR) * CELL + CELL / 2
                for j = 0, PER - 1 do
                  local k = vindex(vx, (cy - y0) * PER + j)
                  local wx = grid.px + vx * VOXEL + VOXEL / 2
                  H[k], S[k], K[k], C[k], L[k] = wallH, wallH, 0, A1 - show, 1
                  grid.U[k] = srcX - wx
                  grid.CAP[k] = cap > 0 and cap or nil
                  W[k], R[k], F[k] = nil, nil, nil
                end
                made = made + 1
              end
            end
          end
        end
      end
    end
    grid.room = { wallH = wallH, depth = depth, walls = walls, sides = sides, things = things, edges = made }
  end

  grid.exitFloors = 0
  grid.exitNote = nil
  if opts.indoor and color then
    for cy = y0 + 1, y0 + rows - 1 do
      for cx = x0, x0 + cols - 1 do
        local c = at(cx, cy)
        local up = at(cx, cy - 1)
        local down = at(cx, cy + 1)
        local open = down and (down.kind == "ground" or down.kind == "grass" or down.kind == "door")
          and not down.border
        if c and (c.kind == "ground" or c.kind == "door") and walkable(up) and not open then
          local st = cellStats(cx, cy)
          local ust = cellStats(cx, cy - 1)
          local l = st and luminance(st.r, st.g, st.b)
          local ul = ust and luminance(ust.r, ust.g, ust.b)
          -- the north cell's voxels: floor height (relief may lift a pixel)
          local flat = true
          for i = 0, PER - 1 do
            local n = vindex((cx - x0) * PER + i, (cy - y0) * PER - 1)
            if (H[n] or 0) > 2 then flat = false end
          end
          -- dark: black, or a dark mat -- well below the floor beside it
          local dark = l and ul and ul > 0.3 and (l < 0.3 or l < ul * 0.45)
          if dark or c.kind == "door" then grid.exitNote = ("%s %s/%s%s"):format(c.kind, l and ("%.2f"):format(l) or "?",
            ul and ("%.2f"):format(ul) or "?", flat and "" or " raised") end
          -- a door cell there is the exit whatever its colour: a mat in
          -- its own art (it was raised with the black wall row beside it,
          -- as an outdoor door is with its facade); a black one borrows
          -- the floor's
          if flat and (dark or c.kind == "door") then
            for j = 0, PER - 1 do
              for i = 0, PER - 1 do
                local k = vindex((cx - x0) * PER + i, (cy - y0) * PER + j)
                local n = vindex((cx - x0) * PER + i, (cy - 1 - y0) * PER + j)
                H[k], S[k], L[k] = H[n] or 0, 0, L[n] or 1
                if dark then
                  -- the floor voxel straight north: its art one cell on
                  K[k], C[k] = K[n] or 1, (C[n] or 0) - CELL * (K[n] or 1)
                else
                  K[k], C[k] = 1, 0
                end
                W[k], R[k], F[k] = nil, nil, nil
              end
            end
            grid.exitFloors = grid.exitFloors + 1
          end
        end
      end
    end
  end

  -- Shores: how far each water voxel lies from land (0 beside it, 1 four
  -- voxels -- 16 px -- out or further), for the foam and the waves rolling
  -- in (scene.lua, through the light bake's alpha).
  if grid.hasWater then
    local SH, q, qh = {}, {}, 1
    local WATER = HF.WATER
    for k = 1, vcols * vrows do
      if H[k] ~= WATER then SH[k] = 0; q[#q + 1] = k end
    end
    while qh <= #q do
      local k = q[qh]; qh = qh + 1
      local d = SH[k] + 0.25
      if d <= 1 then
        local vx = (k - 1) % vcols
        if vx > 0 and SH[k - 1] == nil then SH[k - 1] = d; q[#q + 1] = k - 1 end
        if vx < vcols - 1 and SH[k + 1] == nil then SH[k + 1] = d; q[#q + 1] = k + 1 end
        if k > vcols and SH[k - vcols] == nil then SH[k - vcols] = d; q[#q + 1] = k - vcols end
        if k + vcols <= vcols * vrows and SH[k + vcols] == nil then SH[k + vcols] = d; q[#q + 1] = k + vcols end
      end
    end
    grid.shore = SH
  end

  return grid
end

-- How far a roof's ridge rises above its eaves: shallower on narrow
-- buildings, capped on wide ones.
-- ridge "ns" (FRLG) rises with the width, "ew" (RSE) with the depth.
function HF.roofRise(r)
  if r.ridge == "ew" then
    return math.min(r.maxRise, math.floor((r.y1 - r.y0) * 0.33 + 0.5))
  end
  return math.min(r.maxRise, math.floor((r.x2 - r.x1) * 0.18 + 0.5))
end

-- Height of the ground a character standing at world pixel (wx, wy) is on.
-- Everything raised reports the floor under it -- a player in a doorway is
-- inside the facade, not on the roof, and tall grass should swallow feet
-- rather than be stood on -- so only water lowers a character (surfing).
function HF.floorAt(grid, wx, wy)
  if not grid then return 0 end
  local vx = floor((wx - grid.px) / VOXEL)
  local vy = floor((wy - grid.py) / VOXEL)
  if vx < 0 or vy < 0 or vx >= grid.vcols or vy >= grid.vrows then return 0 end
  local k = vy * grid.vcols + vx + 1
  if grid.FL and grid.FL[k] then return grid.FL[k] end
  local h = grid.H[k] or 0
  return h < 0 and h or 0
end

-- True when (wx, wy) is inside the footprint of something at least a
-- storey tall -- a doorway, a cave mouth -- rather than in front of it.
-- A tree's walkable canopy row is not inside: the player walks there and
-- is drawn (ghosted through the leaves where hidden).
function HF.insideAt(grid, wx, wy)
  if not grid then return false end
  local vx = floor((wx - grid.px) / VOXEL)
  local vy = floor((wy - grid.py) / VOXEL)
  if vx < 0 or vy < 0 or vx >= grid.vcols or vy >= grid.vrows then return false end
  local k = vy * grid.vcols + vx + 1
  if grid.W and grid.W[k] then return false end
  if grid.FL and grid.FL[k] then return false end
  return (grid.S[k] or 0) >= 16
end

return HF
