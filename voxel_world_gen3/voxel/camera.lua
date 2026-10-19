-- The diorama camera.
--
-- World axes are the map's own: x east, y south (down the screen), z up, all
-- in GBA pixels.  The camera sits south of the player and looks north,
-- tipped `pitch` degrees away from straight down -- so the map still reads
-- the way the cart lays it out and north faces never show.  It may turn
-- (`yaw`, degrees: + = the camera swings round to the east, showing east
-- sides, looking north-west; - the other way) up to
-- 30 degrees either way to see behind things; north faces stay hidden.

local Camera = {}

local rad, sin, cos, tan = math.rad, math.sin, math.cos, math.tan

-- cam = { fx, fy, fz (focus), pitch (deg), yaw (deg), fov (deg vertical),
--         scale (screen px per world px at the focus), width, height }
function Camera.solve(cam)
  local th = rad(cam.pitch)
  local ps = rad(math.max(-30, math.min(30, cam.yaw or 0)))
  local sp, cp = sin(ps), cos(ps)
  local fov = rad(cam.fov or 30)
  local visibleH = cam.height / cam.scale -- world px tall at the focus
  local dist = (visibleH * 0.5) / tan(fov * 0.5)
  local st, ct = sin(th), cos(th)
  cam.dist = dist
  cam.ex = cam.fx + dist * st * sp
  cam.ey = cam.fy + dist * st * cp
  cam.ez = (cam.fz or 0) + dist * ct
  -- view basis (rows of the view matrix): za from the focus to the eye,
  -- xa level and to the right, ya = xa x za
  cam.xa = { cp, -sp, 0 }
  cam.ya = { -sp * ct, -cp * ct, st }
  cam.za = { st * sp, st * cp, ct }
  cam.near = math.max(1, dist * 0.05)
  cam.far = dist * 6 + 2000
  cam.aspect = cam.width / cam.height
  cam.f = 1 / tan(fov * 0.5)
  return cam
end

-- row-major 4x4 tables for Shader:send(name, "row", m)
function Camera.view(cam)
  local xa, ya, za = cam.xa, cam.ya, cam.za
  local ex, ey, ez = cam.ex, cam.ey, cam.ez
  local function dot(a) return a[1] * ex + a[2] * ey + a[3] * ez end
  return {
    { xa[1], xa[2], xa[3], -dot(xa) },
    { ya[1], ya[2], ya[3], -dot(ya) },
    { za[1], za[2], za[3], -dot(za) },
    { 0, 0, 0, 1 },
  }
end

-- `flip` pre-flips clip Y: LOVE 11 renders canvases upside down relative to
-- a plain GL projection, and the engine's world-override blit expects the
-- LOVE 11 convention (see Renderer.mirrorsWorldOverride).
function Camera.projection(cam, flip)
  local f, n, fr = cam.f, cam.near, cam.far
  local fy = flip and -f or f
  return {
    { f / cam.aspect, 0, 0, 0 },
    { 0, fy, 0, 0 },
    { 0, 0, (fr + n) / (n - fr), 2 * fr * n / (n - fr) },
    { 0, 0, -1, 0 },
  }
end

-- World point -> screen pixels (y down), or nil when behind the camera.
function Camera.project(cam, x, y, z)
  local dx, dy, dz = x - cam.ex, y - cam.ey, z - cam.ez
  local xa, ya, za = cam.xa, cam.ya, cam.za
  local vx = xa[1] * dx + xa[2] * dy + xa[3] * dz
  local vy = ya[1] * dx + ya[2] * dy + ya[3] * dz
  local vz = za[1] * dx + za[2] * dy + za[3] * dz
  if vz >= -1e-3 then return nil end
  local w = -vz
  local nx = (cam.f / cam.aspect) * vx / w
  local ny = cam.f * vy / w
  return (nx * 0.5 + 0.5) * cam.width, (0.5 - ny * 0.5) * cam.height, w
end

-- Where the ray through screen pixel (sx, sy) meets the plane z = h.
function Camera.groundHit(cam, sx, sy, h)
  local nx = (sx / cam.width) * 2 - 1
  local ny = 1 - (sy / cam.height) * 2
  local vx = nx * cam.aspect / cam.f
  local vy = ny / cam.f
  local xa, ya, za = cam.xa, cam.ya, cam.za
  -- direction in world = vx*xa + vy*ya - 1*za
  local dx = vx * xa[1] + vy * ya[1] - za[1]
  local dy = vx * xa[2] + vy * ya[2] - za[2]
  local dz = vx * xa[3] + vy * ya[3] - za[3]
  if dz > -1e-4 then return nil end
  local t = ((h or 0) - cam.ez) / dz
  if t <= 0 then return nil end
  return cam.ex + dx * t, cam.ey + dy * t
end

-- World-pixel rectangle of ground the frame can see, padded for anything
-- standing up to `tall` px (its top shows further north than its base).
function Camera.visibleRect(cam, tall, maxNorth)
  maxNorth = maxNorth or 800
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  local function take(x, y)
    if not x then return end
    if x < minX then minX = x end
    if x > maxX then maxX = x end
    if y < minY then minY = y end
    if y > maxY then maxY = y end
  end
  for _, h in ipairs({ -2, tall or 32 }) do
    for _, c in ipairs({ { 0, 0 }, { cam.width, 0 }, { 0, cam.height },
                         { cam.width, cam.height }, { cam.width * 0.5, 0 } }) do
      local x, y = Camera.groundHit(cam, c[1], c[2], h)
      if not x then
        -- the top edge looks over the horizon: cap at the far limit
        x, y = cam.fx + (c[1] / cam.width - 0.5) * maxNorth * 2, cam.fy - maxNorth
      end
      take(x, y)
    end
  end
  if minY < cam.fy - maxNorth then minY = cam.fy - maxNorth end
  local span = maxNorth * 1.5
  if minX < cam.fx - span then minX = cam.fx - span end
  if maxX > cam.fx + span then maxX = cam.fx + span end
  return minX, minY, maxX, maxY
end

return Camera
