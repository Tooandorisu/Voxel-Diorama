-- Heightfield -> triangle list.
--
-- Every vertex carries the world pixel it shows (the "sample" coordinate,
-- in VertexTexCoord) rather than a UV: the shader looks the art up in the
-- live flat render of the map, so water, flowers, doors and weather keep
-- animating on the voxels with no re-mesh.
--
-- Only faces the camera can ever see are emitted.  The camera always looks
-- north, so north-facing walls never show; tops are greedy-merged into
-- rectangles, so a flat field costs a handful of quads.
--
-- Vertex layout (matches Scene.FORMAT):
--   x, y, z,  u, v (sample world px),  ox, oy (billboard offset, 0 here),
--   r, g, b (shade), a (1 = a top that takes baked light, 0 = a wall)

local Mesher = {}

local floor, min, max = math.floor, math.min, math.max

local SHADE_SOUTH, SHADE_WEST, SHADE_EAST = 0.80, 0.90, 0.68
local FOOT_DARK = 0.78 -- side faces darken toward their base: cheap AO
-- Every face is grown by this much (world px) on all sides so neighbouring
-- faces overlap a hair.  Merged rectangles meet at T-junctions, and on
-- phone GPUs those rasterise with pixel-thin cracks (long lines across the
-- mountains); an overlap of coplanar, identically textured faces can't.
local E = 0.08

function Mesher.build(grid, VOXEL, tick)
  VOXEL = VOXEL or 4
  tick = tick or function() end
  local H, S, K, C, L = grid.H, grid.S, grid.K, grid.C, grid.L
  local R = grid.R or {}
  local F = grid.F or {}
  local B = grid.B or {} -- buildings: the only walls with lit windows
  local SW = grid.SW or {} -- foliage that sways in the wind
  local U = grid.U or {}     -- art read this far sideways (px), indoors
  local CAP = grid.CAP or {} -- a wall's top px that hold its art's top row
  local vcols, vrows = grid.vcols, grid.vrows
  local px, py = grid.px, grid.py

  local verts, idx = {}, {}
  local nv, ni = 0, 0

  -- alpha is a flag for the shader, not transparency: 1 on tops, which
  -- take the baked sun/ambient light (lighting.lua), 0 on walls
  -- leaf (art-tree canopy, grid.F) is a second flag in the same byte:
  -- 0.9 on a leaf top, 0.3 on a leaf wall -- the shader greens the teal
  -- background RSE draws between its round tree crowns
  -- water (a top below the land) is a third: 0.97 on its surface, which the
  -- shader ripples
  -- walls that are not a building's (grid.B) are 0.03: no lit windows
  -- swaying foliage that is not a leaf canopy (grid.SW): 0.7 on its top,
  -- 0.2 on its walls (a leaf canopy sways too)
  local leaf, water, obj, sway = false, false, false, false
  local function vert(x, y, z, u, v, s, top)
    nv = nv + 1
    local a = top and (water and 0.97 or (leaf and 0.9 or (sway and 0.7 or 1)))
      or (leaf and 0.3 or (sway and 0.2 or (obj and 0.03 or 0)))
    verts[nv] = { x, y, z, u, v, 0, 0, s, s, s, a }
  end

  local function quadIdx()
    local b = nv - 4
    idx[ni + 1], idx[ni + 2], idx[ni + 3] = b + 1, b + 2, b + 3
    idx[ni + 4], idx[ni + 5], idx[ni + 6] = b + 1, b + 3, b + 4
    ni = ni + 6
  end

  local function k(vx, vy) return vy * vcols + vx + 1 end

  -- the bank down to the water: shore art, wet and in shade
  local function bank(ha, hn)
    if hn < 0 and ha <= 5 then return 0.72 end
    return 1
  end

  -- ------- tops: greedy rectangles of equal (H, S, K, C, L)
  local done = {}
  for vy = 0, vrows - 1 do
    tick()
    for vx = 0, vcols - 1 do
      local a = k(vx, vy)
      if not done[a] then
        local h, s, kk, cc, l, f, sw, uo = H[a], S[a], K[a], C[a], L[a], F[a], SW[a], U[a]
        leaf, sway = f == true, sw == true
        water = h < 0
        -- low swaying tops (tall grass) stay in 8 px pieces: merged into
        -- big rectangles there were no corners for it to part at
        local cap = (sw == true and h > 0 and h < 14) and 2 or 1e9
        local w = 1
        while vx + w < vcols and w < cap do
          local c = k(vx + w, vy)
          if done[c] or H[c] ~= h or S[c] ~= s or K[c] ~= kk or C[c] ~= cc or L[c] ~= l or F[c] ~= f or SW[c] ~= sw or U[c] ~= uo then break end
          w = w + 1
        end
        local hgt = 1
        while vy + hgt < vrows and hgt < cap do
          local ok = true
          for i = 0, w - 1 do
            local c = k(vx + i, vy + hgt)
            if done[c] or H[c] ~= h or S[c] ~= s or K[c] ~= kk or C[c] ~= cc or L[c] ~= l or F[c] ~= f or SW[c] ~= sw or U[c] ~= uo then
              ok = false
              break
            end
          end
          if not ok then break end
          hgt = hgt + 1
        end
        for j = 0, hgt - 1 do
          for i = 0, w - 1 do done[k(vx + i, vy + j)] = true end
        end
        local x1, y1 = px + vx * VOXEL - E, py + vy * VOXEL - E
        local x2, y2 = px + (vx + w) * VOXEL + E, py + (vy + hgt) * VOXEL + E
        local v1, v2 = kk * y1 + cc, kk * y2 + cc
        local du = uo or 0
        vert(x1, y1, h, x1 + du, v1, l, true)
        vert(x2, y1, h, x2 + du, v1, l, true)
        vert(x2, y2, h, x2 + du, v2, l, true)
        vert(x1, y2, h, x1 + du, v2, l, true)
        quadIdx()
      end
    end
  end

  -- ------- sloped roofs (heightfield.lua): a gable over a building's flat
  -- top, ridge running north-south.  The two slopes carry the roof art
  -- exactly as the flat top did (same rows at the same y), so the front
  -- edge still meets the facade; the front gable shows the art just above
  -- the eave, upright, by the same oblique rule as the walls.
  leaf, water, obj, sway = false, false, false, false
  for _, r in ipairs(grid.roofs or {}) do
    tick()
    if r.ridge == "ew" then
      -- RSE: the ridge runs east-west, the way the art draws these roofs
      -- (the yellow trim down a house's sides is its gable ends).  The
      -- front slope faces the camera and carries the art row for row, so
      -- nothing in it bends; the gables close the two sides.
      local x1, x2, y0, y1 = r.x1, r.x2, r.y0, r.y1
      local ym = (y0 + y1) / 2
      local zl = r.h
      local rise = math.min(r.maxRise, math.floor((y1 - y0) * 0.33 + 0.5)) -- = HF.roofRise
      local zr = zl + rise
      local k, c = r.k, r.c
      -- The ridge stands up toward the camera, so on screen it sits higher
      -- than the flat top did.  Sample the art where the flat top showed it
      -- at that spot on screen (a point raised by d px shows the art d px
      -- further north): the picture stays as the game draws it, and only the
      -- light and the silhouette tell the slope.  Without this the back half
      -- of a Poke Center's roof squeezed its logo up into the ridge.
      local v0, vm, v1 = k * (y0 - E) + c, k * (ym - rise) + c, k * (y1 + E) + c
      -- back slope (mostly hidden), then the front slope
      vert(x1 - E, y0 - E, zl, x1 - E, v0, 0.86, true)
      vert(x2 + E, y0 - E, zl, x2 + E, v0, 0.86, true)
      vert(x2 + E, ym, zr, x2 + E, vm, 0.86, true)
      vert(x1 - E, ym, zr, x1 - E, vm, 0.86, true)
      quadIdx()
      vert(x1 - E, ym, zr, x1 - E, vm, 1, true)
      vert(x2 + E, ym, zr, x2 + E, vm, 1, true)
      vert(x2 + E, y1 + E, zl, x2 + E, v1, 1, true)
      vert(x1 - E, y1 + E, zl, x1 - E, v1, 1, true)
      quadIdx()
      -- west and east gables: the edge column's own art (the trim)
      for _, side in ipairs({ { x1, 2, 0.96 }, { x2, -2, 0.78 } }) do
        local x, du, sh = side[1], side[2], side[3]
        vert(x, y0, zl - E, x + du, v0, sh)
        vert(x, ym, zr, x + du, vm, sh)
        vert(x, y1, zl - E, x + du, v1, sh)
        vert(x, y1, zl - E, x + du, v1, sh)
        quadIdx()
      end
      goto continue
    end
    local x1, x2 = r.x1, r.x2
    local xm = (x1 + x2) / 2
    local y0, y1 = r.y0, r.y1
    local zl = r.h
    local rise = math.min(r.maxRise, math.floor((x2 - x1) * 0.18 + 0.5)) -- = HF.roofRise
    local zr = zl + rise
    local k, c = r.k, r.c
    local v0, v1 = k * (y0 - E) + c, k * (y1 + E) + c
    -- west slope (toward the sun) and east slope
    vert(x1 - E, y0 - E, zl, x1 - E, v0, 0.98, true)
    vert(xm, y0 - E, zr, xm, v0, 0.98, true)
    vert(xm, y1 + E, zr, xm, v1, 0.98, true)
    vert(x1 - E, y1 + E, zl, x1 - E, v1, 0.98, true)
    quadIdx()
    vert(xm, y0 - E, zr, xm, v0, 0.84, true)
    vert(x2 + E, y0 - E, zl, x2 + E, v0, 0.84, true)
    vert(x2 + E, y1 + E, zl, x2 + E, v1, 0.84, true)
    vert(xm, y1 + E, zr, xm, v1, 0.84, true)
    quadIdx()
    -- front and back gables (a triangle as a quad with one corner doubled)
    local vEave = y1 - zl
    vert(x1, y1, zl - E, x1, vEave, SHADE_SOUTH)
    vert(xm, y1, zr, xm, vEave - rise, SHADE_SOUTH)
    vert(x2, y1, zl - E, x2, vEave, SHADE_SOUTH)
    vert(x2, y1, zl - E, x2, vEave, SHADE_SOUTH)
    quadIdx()
    vert(x1, y0, zl - E, x1, y0, SHADE_SOUTH)
    vert(xm, y0, zr, xm, y0, SHADE_SOUTH)
    vert(x2, y0, zl - E, x2, y0, SHADE_SOUTH)
    vert(x2, y0, zl - E, x2, y0, SHADE_SOUTH)
    quadIdx()
    ::continue::
  end

  -- sample row for a point at height z on a voxel's wall
  -- (the top's row at y, then down the facade: z = s is the top's row,
  -- z = 0 is s rows further south in the art)
  local function wallV(y, z, s, kk, cc, cap)
    local t = kk * y + cc
    if s <= 0 then return t end
    s = s - (cap or 0) -- (the cap holds the top row)
    return t + s - max(0, min(z, s))
  end

  -- one vertical quad from zb to za, split at the voxel's facade height so
  -- the part above it (foliage relief) keeps the roof texture
  -- shear: px the art slides sideways per px of height (rock side walls,
  -- so a face shows rock texture instead of one streaked pixel column)
  local function wall(ax, ay, bx, by, zb, za, uOff, vOff, s, kk, cc, shade, shear, cap)
    shear = shear or 0
    local cuts = { zb - E }
    local sc = cap and (s - cap) or nil
    if sc and sc > zb and sc < za and sc < s then cuts[#cuts + 1] = sc end
    if s > zb and s < za then cuts[#cuts + 1] = s end
    cuts[#cuts + 1] = za + E
    for c = 1, #cuts - 1 do
      local z1, z2 = cuts[c], cuts[c + 1]
      local d1 = shade * (z1 <= zb + E and FOOT_DARK or 1)
      local d2 = shade
      vert(ax, ay, z1, ax + uOff + shear * z1, wallV(ay + vOff, z1, s, kk, cc, cap), d1)
      vert(bx, by, z1, bx + uOff + shear * z1, wallV(by + vOff, z1, s, kk, cc, cap), d1)
      vert(bx, by, z2, bx + uOff + shear * z2, wallV(by + vOff, z2, s, kk, cc, cap), d2)
      vert(ax, ay, z2, ax + uOff + shear * z2, wallV(ay + vOff, z2, s, kk, cc, cap), d2)
      quadIdx()
    end
  end

  -- ------- south faces, merged along x
  for vy = 0, vrows - 2 do
    tick()
    local vx = 0
    while vx < vcols do
      local a, n = k(vx, vy), k(vx, vy + 1)
      if H[a] > H[n] then
        local ha, hn, s, kk, cc, l, f, o, sw, uo, cp = H[a], H[n], S[a], K[a], C[a], L[a], F[a], B[a], SW[a], U[a], CAP[a]
        leaf, obj, sway = f == true, o ~= true and not grid.anyWindows, sw == true
        local w = 1
        while vx + w < vcols do
          local a2, n2 = k(vx + w, vy), k(vx + w, vy + 1)
          if H[a2] ~= ha or H[n2] ~= hn or S[a2] ~= s or K[a2] ~= kk or C[a2] ~= cc or L[a2] ~= l or F[a2] ~= f or B[a2] ~= o or SW[a2] ~= sw
              or U[a2] ~= uo or CAP[a2] ~= cp then break end
          w = w + 1
        end
        local y = py + (vy + 1) * VOXEL
        local x1, x2 = px + vx * VOXEL, px + (vx + w) * VOXEL
        wall(x1 - E, y, x2 + E, y, hn, ha, uo or 0, -0.5, s, kk, cc, SHADE_SOUTH * l * bank(ha, hn), nil, cp)
        vx = vx + w
      else
        vx = vx + 1
      end
    end
  end

  -- ------- east / west faces, merged along y
  local function sides(dx, shade, uOff)
    for vx = 0, vcols - 1 do
      tick()
      local nx = vx + dx
      if nx >= 0 and nx < vcols then
        local vy = 0
        while vy < vrows do
          local a, n = k(vx, vy), k(nx, vy)
          if H[a] > H[n] then
            local ha, hn, s, kk, cc, l, rk, f, o, sw, uo, cp = H[a], H[n], S[a], K[a], C[a], L[a], R[a], F[a], B[a], SW[a], U[a], CAP[a]
            leaf, obj, sway = f == true, o ~= true and not grid.anyWindows, sw == true
            local hgt = 1
            while vy + hgt < vrows do
              local a2, n2 = k(vx, vy + hgt), k(nx, vy + hgt)
              if H[a2] ~= ha or H[n2] ~= hn or S[a2] ~= s or K[a2] ~= kk or C[a2] ~= cc or L[a2] ~= l or R[a2] ~= rk or F[a2] ~= f or B[a2] ~= o or SW[a2] ~= sw
                  or U[a2] ~= uo or CAP[a2] ~= cp then break end
              hgt = hgt + 1
            end
            local x = px + (dx > 0 and (vx + 1) or vx) * VOXEL
            local y1, y2 = py + vy * VOXEL, py + (vy + hgt) * VOXEL
            -- wind so both sides read the same way round; culling is off,
            -- this only keeps the vertex order tidy for debugging
            -- slide inward (away from the face) as the wall rises
            -- (forest sides too: a tree block's side smeared one column of
            -- leaves into long stripes down the face)
            wall(x, y2 + E, x, y1 - E, hn, ha, uOff + (uo or 0), 0, s, kk, cc, shade * l * bank(ha, hn), (rk or f) and -dx * 0.4 or 0, cp)
            vy = vy + hgt
          else
            vy = vy + 1
          end
        end
      end
    end
  end
  sides(1, SHADE_EAST, -0.5)
  sides(-1, SHADE_WEST, 0.5)

  return verts, idx, nv, ni
end

return Mesher
