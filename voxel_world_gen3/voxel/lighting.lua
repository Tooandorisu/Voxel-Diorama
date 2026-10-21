-- Baked sunlight and ambient occlusion over a voxel heightfield.
--
-- Done once per mesh rebuild (in the background job), never per frame: the
-- result is one value per voxel column that the terrain shader reads from a
-- small texture with linear filtering, so shadows cost a texture lookup and
-- nothing else, and the mesh's greedy merging is untouched.
--
--   sun  1 = in sunlight, 0 = something stands between this top and the sun
--   ao   1 = open sky around it, less where walls and trees crowd in
--
-- The sun sits behind-left of the camera (north-west), high enough that a
-- shadow is a little shorter than the thing casting it, so shadows fall to
-- the south-east -- in front of things, where the north-looking camera sees
-- them.

local Lighting = {}

local floor, min, max = math.floor, math.min, math.max

-- world px a shadow travels per px of height: +x (east), +y (south)
Lighting.SUN_X, Lighting.SUN_Y = 0.7, 0.45

-- opts: tick, sun (false = ambient occlusion only, e.g. indoors)
function Lighting.bake(grid, VOXEL, opts)
  opts = opts or {}
  VOXEL = VOXEL or 4
  local tick = opts.tick or function() end
  local useSun = opts.sun ~= false
  local H = grid.H
  local vcols, vrows = grid.vcols, grid.vrows
  -- sloped roofs cast their ridge: bake over the heights with roofs added
  if grid.roofs and #grid.roofs > 0 then
    local R = {}
    for i = 1, vcols * vrows do R[i] = H[i] end
    for _, r in ipairs(grid.roofs) do
      local ew = r.ridge == "ew"
      local rise = ew and math.min(r.maxRise, math.floor((r.y1 - r.y0) * 0.33 + 0.5))
        or math.min(r.maxRise, math.floor((r.x2 - r.x1) * 0.18 + 0.5))
      local xm, half = (r.x1 + r.x2) / 2, (r.x2 - r.x1) / 2
      local ym, halfY = (r.y0 + r.y1) / 2, (r.y1 - r.y0) / 2
      local vx1 = max(0, floor((r.x1 - grid.px) / VOXEL))
      local vx2 = min(vcols - 1, floor((r.x2 - grid.px) / VOXEL) - 1)
      local vy1 = max(0, floor((r.y0 - grid.py) / VOXEL))
      local vy2 = min(vrows - 1, floor((r.y1 - grid.py) / VOXEL) - 1)
      for vy = vy1, vy2 do
        for vx = vx1, vx2 do
          local cx = grid.px + (vx + 0.5) * VOXEL
          local cy = grid.py + (vy + 0.5) * VOXEL
          local z = ew and (r.h + rise * (1 - math.abs(cy - ym) / halfY))
            or (r.h + rise * (1 - math.abs(cx - xm) / half))
          local k = vy * vcols + vx + 1
          if z > R[k] then R[k] = z end
        end
      end
    end
    H = R
  end
  -- opts.sunX/sunY: the sun of the hour (daynight.lua); the default is
  -- the classic afternoon sun from the north-west
  local sunX, sunY = opts.sunX or Lighting.SUN_X, opts.sunY or Lighting.SUN_Y
  local SUN, AO = {}, {}

  local maxH = 0
  for i = 1, vcols * vrows do
    local h = H[i]
    if h > maxH then maxH = h end
  end

  -- the highest height within two voxels of each one (a separable max):
  -- where nothing around stands above a top, it has no occlusion to add up
  local M5
  do
    local R5 = {}
    for vy = 0, vrows - 1 do
      local b = vy * vcols
      for vx = 0, vcols - 1 do
        local m = H[b + vx + 1]
        for dx = -2, 2 do
          local x = vx + dx
          if x >= 0 and x < vcols then
            local h = H[b + x + 1]
            if h > m then m = h end
          end
        end
        R5[b + vx + 1] = m
      end
    end
    M5 = {}
    for vy = 0, vrows - 1 do
      for vx = 0, vcols - 1 do
        local m = R5[vy * vcols + vx + 1]
        for dy = -2, 2 do
          local y = vy + dy
          if y >= 0 and y < vrows then
            local h = R5[y * vcols + vx + 1]
            if h > m then m = h end
          end
        end
        M5[vy * vcols + vx + 1] = m
      end
    end
  end

  -- height rise per ray step: one voxel along x, the dominant direction
  local step = VOXEL / math.max(0.05, math.abs(sunX))
  -- relief bumps on a canopy must not freckle each other with shadow
  local TOL = 2.5

  local function height(ix, iy)
    if ix < 0 or iy < 0 or ix >= vcols or iy >= vrows then return nil end
    return H[iy * vcols + ix + 1]
  end

  for vy = 0, vrows - 1 do
    tick()
    local cy = (vy + 0.5) * VOXEL
    for vx = 0, vcols - 1 do
      local k = vy * vcols + vx + 1
      local h = H[k]
      local base = h > 0 and h or 0
      local cx = (vx + 0.5) * VOXEL

      -- sun: march toward the sun until the ray clears everything there is
      local sun = 1
      if useSun and maxH > h + TOL then
        local t = step
        while h + t <= maxH do
          local ix = floor((cx - sunX * t) / VOXEL)
          local iy = floor((cy - sunY * t) / VOXEL)
          if ix < 0 or iy < 0 or ix >= vcols or iy >= vrows then break end
          if H[iy * vcols + ix + 1] > h + t + TOL then sun = 0 break end
          t = t + step
        end
      end
      SUN[k] = sun

      -- ambient occlusion: how much rises around this top, near and a step
      -- further out.  (Indexed straight into the heights, no call per
      -- neighbour, and skipped outright where nothing nearby stands higher:
      -- on a phone this bake ran without the JIT, and it was half of the
      -- one-off build behind a warp's fade.)
      local occ = 0
      if (M5[k] or 0) > base then
        local ylo, yhi = vy - 2, vy + 2
        if ylo < 0 then ylo = 0 end
        if yhi > vrows - 1 then yhi = vrows - 1 end
        local xlo, xhi = vx - 2, vx + 2
        if xlo < 0 then xlo = 0 end
        if xhi > vcols - 1 then xhi = vcols - 1 end
        for ny = ylo, yhi do
          local rowb = ny * vcols + 1
          local dy = ny - vy
          local nearY = dy >= -1 and dy <= 1
          for nx = xlo, xhi do
            local hn = H[rowb + nx]
            if hn > base then
              local dx = nx - vx
              local d = hn - base
              if d > 12 then d = 12 end
              occ = occ + ((nearY and dx >= -1 and dx <= 1) and 1 or 0.35) * d / 12
            end
          end
        end
      end
      AO[k] = max(0.6, 1 - 0.034 * occ)
    end
  end

  -- Indoors (opts.room): the room's light is brightest in the middle and
  -- falls off toward its walls and the dark around it, so the floor reads
  -- as the inside of a box rather than a flat picture.
  if opts.room then
    local V = grid.V or {}
    local D = {}
    local queue, qh = {}, 1
    for vy = 0, vrows - 1 do
      for vx = 0, vcols - 1 do
        local k = vy * vcols + vx + 1
        if V[k] or H[k] >= 24 then D[k] = 0; queue[#queue + 1] = k end
      end
    end
    while qh <= #queue do
      local k = queue[qh]; qh = qh + 1
      local d = D[k] + 1
      if d <= 8 then
        local vx, vy = (k - 1) % vcols, floor((k - 1) / vcols)
        if vx > 0 and not D[k - 1] then D[k - 1] = d; queue[#queue + 1] = k - 1 end
        if vx < vcols - 1 and not D[k + 1] then D[k + 1] = d; queue[#queue + 1] = k + 1 end
        if vy > 0 and not D[k - vcols] then D[k - vcols] = d; queue[#queue + 1] = k - vcols end
        if vy < vrows - 1 and not D[k + vcols] then D[k + vcols] = d; queue[#queue + 1] = k + vcols end
      end
    end
    for k = 1, vcols * vrows do
      local d = D[k] or 9
      if H[k] < 24 then AO[k] = (AO[k] or 1) * (0.8 + 0.2 * math.min(1, d / 8)) end
    end
  end

  grid.sun, grid.ao = SUN, AO
  grid.glow = Lighting.glow(grid, VOXEL)
  return SUN, AO
end

-- Night lights: how much each voxel is lit by the lamps and doorways the
-- heightfield found (grid.lights, world px), 0..1 -- a soft pool around
-- each, brightest at its foot.  nil when there are none.
function Lighting.glow(grid, VOXEL)
  local lights = grid.lights
  if not lights or #lights == 0 then return nil end
  VOXEL = VOXEL or 4
  local vcols, vrows = grid.vcols, grid.vrows
  local H = grid.H
  local G = {}
  for _, l in ipairs(lights) do
    local lx, ly, r = l.x - grid.px, l.y - grid.py, l.r
    local vx1 = max(0, floor((lx - r) / VOXEL))
    local vx2 = min(vcols - 1, floor((lx + r) / VOXEL))
    local vy1 = max(0, floor((ly - r) / VOXEL))
    local vy2 = min(vrows - 1, floor((ly + r) / VOXEL))
    for vy = vy1, vy2 do
      for vx = vx1, vx2 do
        local dx = (vx + 0.5) * VOXEL - lx
        -- a little squashed north-south: the pool lies on the ground
        local dy = ((vy + 0.5) * VOXEL - ly) * 1.15
        local d = math.sqrt(dx * dx + dy * dy) / r
        local k = vy * vcols + vx + 1
        -- light falls on the ground (and on the lamp itself), not up onto
        -- the roof of the house whose door it shines from
        local wx, wy = (vx + 0.5) * VOXEL + grid.px, (vy + 0.5) * VOXEL + grid.py
        local own = l.kind == "lamp" and math.floor(wx / 16) == math.floor(l.x / 16)
          and math.floor(wy / 16) == math.floor(l.y / 16)
        if own then d = 0 end
        if d < 1 and ((H[k] or 0) <= 4 or own) then
          local q = 1 - d
          local v = l.s * q * q * (3 - 2 * q)
          local o = G[k] or 0
          -- overlapping pools add up, softly
          G[k] = o + v - o * v
        end
      end
    end
  end
  return G
end

-- sun and ao at a world pixel, for characters standing there
function Lighting.at(grid, wx, wy, VOXEL)
  if not (grid and grid.sun) then return 1, 1 end
  VOXEL = VOXEL or 4
  local vx = floor((wx - grid.px) / VOXEL)
  local vy = floor((wy - grid.py) / VOXEL)
  if vx < 0 or vy < 0 or vx >= grid.vcols or vy >= grid.vrows then return 1, 1 end
  local k = vy * grid.vcols + vx + 1
  return grid.sun[k] or 1, grid.ao[k] or 1
end

-- The bake as image data: red = sun, green = ambient occlusion,
-- blue = 1 - night light.
function Lighting.imageData(grid, tick)
  tick = tick or function() end
  local w, h = grid.vcols, grid.vrows
  local data = love.image.newImageData(w, h)
  local SUN, AO, GLOW = grid.sun, grid.ao, grid.glow
  local SH = grid.shore
  for y = 0, h - 1 do
    if y % 16 == 0 then tick() end
    local row = y * w
    for x = 0, w - 1 do
      local k = row + x + 1
      -- blue: 1 - night light (so a missing bake, all white, is unlit)
      -- alpha: the shore (heightfield.lua: 0 on land and at the water's
      -- edge, 1 out at sea) -- the foam and the waves (scene.lua)
      data:setPixel(x, y, SUN[k], AO[k], 1 - (GLOW and GLOW[k] or 0), SH and (SH[k] or 1) or 1)
    end
  end
  return data
end

return Lighting
