-- GPU half: one shader, three meshes (terrain, actor billboards, blob
-- shadows) and a ground-plane overlay quad.
--
-- The terrain shader samples the live flat render of the map by world pixel
-- (see mesher.lua).  Actors are camera-facing billboards whose every
-- fragment carries the depth of the character's feet, so a sprite is hidden
-- by what stands in front of it and never sliced by the tree behind it --
-- the same promise the engine's flat OAM priorities make.

local Scene = {}

Scene.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "BillOffset", "float", 2 },
  { "VertexColor", "byte", 4 },
}

-- Billboards: the quad faces the camera so a sprite keeps its authored
-- height, but its depth is taken from an UPRIGHT plane through the feet
-- (scale the view ray by t until it meets that plane -- same screen point,
-- different depth).  Upright depth is what makes a character in front of a
-- wall stay in front of all of it, and one behind a tree get hidden by it,
-- with no leaning sprite clipping into whatever stands north of it.
-- Scaling by t makes w vary across the quad, so the sample coordinate is
-- carried pre-multiplied by w and divided back per fragment: screen-affine
-- for billboards (k = w), ordinary perspective-correct for terrain (k = 1).
local SHADER = [[
#ifndef LOVE_HIGHP_OR_MEDIUMP
#define LOVE_HIGHP_OR_MEDIUMP
#endif
// highp where the GPU has it: sample coordinates run into the thousands,
// which a phone's mediump (fp16) varyings cannot carry precisely
varying LOVE_HIGHP_OR_MEDIUMP vec3 vSampleK;
varying LOVE_HIGHP_OR_MEDIUMP float vDepth;
varying LOVE_HIGHP_OR_MEDIUMP vec2 vWorld;
varying float vZ; // height above the ground (terrain): night light fades up walls
// reflections: the scene drawn again mirrored in the water's plane.
// (One uniform per stage: a uniform shared by both must match in
// precision, and a phone's vertex stage defaults to highp, its pixel stage
// to mediump -- the shader would not link.)

#ifdef VERTEX
uniform mat4 uView;
uniform mat4 uProj;
uniform vec2 uShift; // terrain built in a neighbouring map's coordinates
uniform float uKRef; // ~camera distance: keeps the billboard weight near 1
uniform vec2 uBillN; // world direction (xy) a billboard's upright plane faces
uniform float uWaterZ; // height of the water's surface (the mirror)
uniform float uMirrorV; // 1 while drawing the mirrored pass
uniform float uTimeV;   // seconds (vertex stage copy)
uniform float uWindV;   // wind: how far foliage sways (0 = still)
// grass that parts: up to 12 points (mesh space xy, radius, weight) where
// someone walks through tall grass, or just did
uniform vec4 uPartV[12];
uniform float uPartOn;
attribute vec2 BillOffset;

vec4 position(mat4 transform_projection, vec4 vertex_position) {
  // mirrored pass: everything flipped through the water's plane (a
  // character upside down below its own feet)
  // wind: foliage (vertex alpha flags 0.2/0.3 walls, 0.7/0.9 tops, terrain
  // only) leans and swings, more the higher it stands -- a function of the
  // position alone, so neighbouring faces move together and never part
  vec2 xy = vertex_position.xy;
  if (uWindV > 0.0) {
    float f = VertexColor.a;
    float sw = (step(0.15, f) - step(0.35, f)) + (step(0.65, f) - step(0.95, f));
    float hgt = clamp(vertex_position.z / 24.0, 0.0, 1.0);
    float ph = vertex_position.x * 0.11 + vertex_position.y * 0.07;
    xy += vec2(sin(uTimeV * 1.6 + ph) + 0.35 * sin(uTimeV * 2.9 + ph * 1.7),
               0.45 * sin(uTimeV * 1.15 + ph * 1.3)) * (uWindV * hgt * sw);
  }
  // tall grass parts around whoever walks through it: low swaying
  // foliage (not tree crowns) bends away from them and flattens a little,
  // the tips most, and springs back as they leave (the weights fade)
  float zz = vertex_position.z;
  if (uPartOn > 0.5) {
    float f2 = VertexColor.a;
    float sw2 = (step(0.15, f2) - step(0.35, f2)) + (step(0.65, f2) - step(0.95, f2));
    float low = sw2 * step(0.3, zz) * (1.0 - step(14.0, zz));
    if (low > 0.5) {
      float tip = clamp(zz / 8.0, 0.0, 1.0);
      for (int i = 0; i < 12; i++) {
        vec4 pp = uPartV[i];
        if (pp.w > 0.0) {
          vec2 d = xy - pp.xy;
          float dist = length(d);
          float k = clamp(1.0 - dist / pp.z, 0.0, 1.0);
          k = k * k * pp.w;
          xy += (dist > 0.01 ? d / dist : vec2(0.0, 1.0)) * k * 7.0 * tip;
          zz -= zz * 0.75 * k;
        }
      }
    }
  }
  float z = mix(zz, 2.0 * uWaterZ - zz, uMirrorV);
  vec4 anchor = uView * vec4(xy + uShift, z, 1.0);
  vec3 viewPos = anchor.xyz;
  viewPos.xy += vec2(BillOffset.x, BillOffset.y * (1.0 - 2.0 * uMirrorV));
  float bill = step(0.001, abs(BillOffset.x) + abs(BillOffset.y));
  // the upright plane a character stands in faces the camera across the
  // ground (straight south, or turned with CAMERA TURN)
  vec3 n = (uView * vec4(uBillN, 0.0, 0.0)).xyz;
  float den = dot(n, viewPos);
  float t = 1.0;
  if (bill > 0.5 && abs(den) > 0.0001) {
    t = clamp(dot(n, anchor.xyz) / den, 0.5, 1.5);
  }
  vec4 clip = uProj * vec4(viewPos * t, 1.0);
  // k only has to be proportional to w; dividing by the camera distance
  // keeps (sample * k) small enough for fp16 instead of in the millions
  float k = mix(1.0, clip.w / uKRef, bill);
  vSampleK = vec3((VertexTexCoord.xy + uShift) * k, k);
  vDepth = -viewPos.z;
  vWorld = vertex_position.xy; // mesh space, same as the light bake
  vZ = vertex_position.z;
  return clip;
}
#endif

#ifdef PIXEL
uniform Image uTex;
uniform LOVE_HIGHP_OR_MEDIUMP vec2 uOrigin;
uniform LOVE_HIGHP_OR_MEDIUMP vec2 uSize;
uniform vec4 uFog;       // rgb, strength
uniform vec2 uFogRange;  // view depth where fog starts / is total
uniform float uEdge;     // 1 = fade where the source texture runs out
uniform float uCutout;   // alpha below this is discarded
uniform float uLit;      // 1 while drawing terrain: vertex alpha = "top" flag
uniform float uTerrain;  // 1 while drawing terrain (vertex alpha holds flags)
uniform Image uLight;    // baked light: r = sun, g = ambient occlusion
uniform vec4 uLightRect; // world origin xy, size zw of the bake
uniform vec3 uShadow;    // colour a fully shadowed top is multiplied by
uniform vec4 uDark;      // dark cave: Flash circle centre xy (mesh space), radius, on
uniform float uDarkWarm; // the Flash light warm like a torch (0 = plain)
uniform vec3 uTint;      // time of day: the colour everything is lit with
uniform float uDesat;    // ...and how much colour is washed out first (moonlight)
uniform float uTime;     // seconds, for the water's ripple
uniform float uNight;    // 0 day .. 1 night: lamps, doorways and windows light up
uniform Image uRefl;     // the mirrored pass (reflections), screen space
uniform float uReflOn;   // how strongly water shows it (0 = off)
uniform vec2 uScreen;    // target size in pixels
uniform float uWaterLvl; // water surface height (pixel stage copy)
uniform float uMirror;   // 1 while drawing the mirrored pass (pixel stage)
uniform float uActors;   // 1 while drawing characters (vertex alpha 0.988 = blinking)
uniform Image uCloud;    // cloud shadows: a tiling pattern, r = cloud
uniform float uCloudOn;  // how dark a cloud's shadow is (0 = none)
uniform LOVE_HIGHP_OR_MEDIUMP vec2 uCloudXY; // the pattern's drift + this pass's shift (world px)
uniform float uCloudK;   // 1 / the pattern's size in world px
uniform float uStars;    // night sky: stars twinkling in the water (0 = none)
uniform float uFoam;     // shore foam and waves (0 = off)
uniform float uFalls;    // waterfalls streaming (0 = off)
uniform LOVE_HIGHP_OR_MEDIUMP vec3 uSlot; // atlas: first slot row (px), slot height, feet row

const vec3 LUM = vec3(0.299, 0.587, 0.114);
// face: light; eye: darker than face (a dark-grey pixel counts too)
bool lightPx(vec4 t) { return t.a > 0.5 && dot(t.rgb, LUM) > 0.58; }
bool midPx(vec4 t) { return t.a > 0.5 && dot(t.rgb, LUM) < 0.5; }

vec4 effect(vec4 color, Image unused, vec2 tc, vec2 sc) {
  // highp: the atlas runs to thousands of pixels; in a phone's mediump a
  // one-pixel step there rounds away (the blink's neighbour lookups saw
  // the same pixel again, so no eye ever matched)
  LOVE_HIGHP_OR_MEDIUMP vec2 uv = (vSampleK.xy / vSampleK.z - uOrigin) / uSize;
  // water surface (alpha flag 0.97): the art sways a pixel or so, in slow
  // crossing waves, and catches the odd glint
  float water = uTerrain * (step(0.955, color.a) - step(0.985, color.a));
  vec2 wave = vec2(sin(vWorld.y * 0.45 + uTime * 1.7),
                   sin(vWorld.x * 0.35 + vWorld.y * 0.2 + uTime * 1.3)) * 0.9;
  uv += water * wave / uSize;
  // mirrored pass: only what stands above the water is reflected (the
  // water surface itself, and anything under it, is not)
  if (uMirror > 0.5 && vZ < uWaterLvl + 0.5) discard;
  vec4 c = Texel(uTex, uv);
  float glint = pow(max(0.0, sin(vWorld.x * 0.21 + vWorld.y * 0.13 + uTime * 0.9)
                    * sin(vWorld.y * 0.31 - uTime * 1.1)), 12.0);
  c.rgb = mix(c.rgb, c.rgb * vec3(0.86, 0.93, 1.0) + glint * 0.18, water);
  if (c.a < uCutout) discard;
  // Blinking.  Nobody marked where the eyes are on Gen 3's sprites, so they
  // are found by their shape while a character blinks: in the face band of
  // its atlas slot, a short dark stroke (up to 4 pixels tall and 2 wide --
  // RSE eyes are a dark-grey pixel over a black one, often doubled) with
  // face both above and below it and face beside it.  It is painted over
  // with the face above it.  Hair and outlines run on for more than 4
  // pixels (or are dark beside dark), so they stay.
  float blinkFlag = uActors * step(0.97, color.a) * (1.0 - step(0.995, color.a));
  if (blinkFlag > 0.5 && c.a > 0.5 && dot(c.rgb, LUM) < 0.5) {
    LOVE_HIGHP_OR_MEDIUMP float ly = mod(uv.y * uSize.y - uSlot.x, uSlot.y);
    // (the whole upper body: measured on a real NPC its eyes sat only 10
    // pixels above its feet, below where a 16x32 sprite's face would be)
    if (ly > uSlot.z - 40.0 && ly < uSlot.z - 6.0) {
      LOVE_HIGHP_OR_MEDIUMP vec2 px = vec2(1.0) / uSize;
      vec4 skin = vec4(0.0);
      bool up = false, dn = false, side = false;
      for (int k = 1; k <= 4; k++) {
        vec4 t = Texel(uTex, uv - vec2(0.0, float(k) * px.y));
        // the face above an eye is skin -- warm -- not a white shirt (whose
        // dark collar and buttons are not eyes)
        if (lightPx(t)) { up = t.r > t.b + 0.06; skin = t; break; }
        if (!midPx(t)) break;
      }
      for (int k = 1; k <= 4; k++) {
        vec4 t = Texel(uTex, uv + vec2(0.0, float(k) * px.y));
        if (lightPx(t)) { dn = true; break; }
        if (!midPx(t)) break;
      }
      for (int k = 1; k <= 2; k++) {
        vec4 t = Texel(uTex, uv - vec2(float(k) * px.x, 0.0));
        if (lightPx(t)) { side = true; break; }
        if (!midPx(t)) break;
      }
      if (!side) {
        for (int k = 1; k <= 2; k++) {
          vec4 t = Texel(uTex, uv + vec2(float(k) * px.x, 0.0));
          if (lightPx(t)) { side = true; break; }
          if (!midPx(t)) break;
        }
      }
      if (up && dn && side) c.rgb = skin.rgb;
    }
  }
  // alpha flags (mesher.lua): >= 0.6 top, 0.15..0.95 Emerald-style leaf
  // (exact bands: 0.2 / 0.7 are swaying foliage that is not a leaf canopy)
  float leaf = uTerrain * ((step(0.25, color.a) - step(0.35, color.a))
                         + (step(0.85, color.a) - step(0.95, color.a)));
  // RSE draws its round tree crowns on a teal background: on a canopy that
  // teal is the shadow between crowns, so it turns a deep leaf green
  float tealness = clamp((c.b / max(c.r, 0.02) - 1.15) * 4.0, 0.0, 1.0) * step(c.g * 0.5, c.b);
  c.rgb = mix(c.rgb, vec3(0.26, 0.64, 0.17) * c.g, leaf * tealness);
  vec3 raw = c.rgb; // the art itself, before shading (window test)
  c.rgb *= color.rgb;
  float top = step(0.6, color.a) * uLit;
  vec4 L = Texel(uLight, (vWorld - uLightRect.xy) / uLightRect.zw);
  vec3 light = mix(uShadow, vec3(1.0), L.r) * L.g;
  c.rgb *= mix(vec3(1.0), light, top);
  // clouds drifting over: their shadows slide across the ground, the walls
  // and the people alike
  if (uCloudOn > 0.0) {
    float cl = Texel(uCloud, (vWorld + uCloudXY) * uCloudK).r;
    c.rgb *= 1.0 - uCloudOn * cl;
  }
  float alphaMul = mix(color.a, 1.0, max(max(uLit, uTerrain), blinkFlag));
  float f = clamp((vDepth - uFogRange.x) / max(1.0, uFogRange.y - uFogRange.x), 0.0, 1.0);
  vec2 e = min(uv, vec2(1.0) - uv) * uSize;
  float edge = clamp(min(e.x, e.y) / 24.0, 0.0, 1.0);
  f = max(f * f, (1.0 - edge) * uEdge) * uFog.a;
  vec3 lit = mix(c.rgb, vec3(dot(c.rgb, vec3(0.299, 0.587, 0.114))), uDesat) * uTint;
  if (uNight > 0.0) {
    // night lights: the pools of lamplight and doorway light baked into the
    // light texture (blue = 1 - glow), in warm colour, not moonlight
    // (on terrain fading out a storey up: a doorway lights the wall
    // around the door, not the eaves above it)
    // (terrain and characters only: the flat map shown where the voxels
    // have not reached yet lies in the current map's coordinates, the
    // light bake in the mesh's -- crossing into the next map, it showed a
    // ghost of the last town's lamplight out in the fields)
    float pool = (1.0 - L.b) * uNight * mix(1.0, clamp(1.0 - vZ / 26.0, 0.0, 1.0), uTerrain)
      * max(uTerrain, uActors);
    // (plus a little warm light of its own: lawn lit only by recolouring
    // stayed green)
    lit = mix(lit, c.rgb * vec3(1.08, 0.86, 0.58) + vec3(0.16, 0.11, 0.04), pool * 0.9);
    // lit windows: on a building's walls, glass-blue art glows warm
    float wall = uTerrain * (1.0 - step(0.1, color.a));
    // (a small object's walls, flag 0.03 -- a fountain's water -- are not)
    float building = wall * (1.0 - step(0.015, color.a));
    float l = dot(raw, LUM);
    // (clearly blue -- grey-blue walls stay dark -- and above the ground:
    // the banks of water below it are walls of blue art too)
    float glass = building * step(raw.r + 0.18, raw.b) * step(raw.g - 0.02, raw.b) * step(0.38, l)
      * step(0.5, vZ);
    // a window is a small pane in a frame: blue all around (a fountain's
    // water, a blue wall) is not one
    if (glass > 0.5) {
      LOVE_HIGHP_OR_MEDIUMP vec2 px = vec2(1.0) / uSize;
      float around = 0.0;
      vec4 t;
      t = Texel(uTex, uv + vec2(0.0, 5.0 * px.y)); around += step(t.r + 0.18, t.b);
      t = Texel(uTex, uv - vec2(0.0, 5.0 * px.y)); around += step(t.r + 0.18, t.b);
      t = Texel(uTex, uv + vec2(6.0 * px.x, 0.0)); around += step(t.r + 0.18, t.b);
      t = Texel(uTex, uv - vec2(6.0 * px.x, 0.0)); around += step(t.r + 0.18, t.b);
      if (around > 3.5) glass = 0.0;
    }
    lit = mix(lit, vec3(1.0, 0.84, 0.5) * (0.7 + 0.4 * l), glass * uNight * 0.9);
  }
  // reflections on water: the mirrored scene at this very pixel, swayed
  // by the same waves as the water's art
  if (uReflOn > 0.0 && water > 0.5) {
    vec4 R = Texel(uRefl, (sc + wave * 2.5) / uScreen);
    lit = mix(lit, R.rgb, R.a * uReflOn);
  }
  // the shore: foam along the water's edge, and every few seconds a wave
  // rolling in, a line of foam that runs up to the beach and fades
  // (the light bake's alpha: 0 at the edge, 1 out at sea)
  if (uFoam > 0.0 && water > 0.5) {
    float sh = 1.0 - L.a;
    if (sh > 0.0) {
      float n = sin(vWorld.x * 0.13 + vWorld.y * 0.05) + 0.6 * sin(vWorld.x * 0.041 - vWorld.y * 0.09);
      float ph = fract(uTime * 0.2 + n * 0.12);
      float line = (1.0 - smoothstep(0.0, 0.15, abs(sh - ph))) * smoothstep(0.05, 0.45, ph);
      float edge = smoothstep(0.5, 0.9, sh) * (0.8 + 0.2 * sin(uTime * 1.1 + n * 3.0));
      float bub = fract(sin(dot(floor((vWorld + wave * 1.5) / 2.0), vec2(12.9898, 78.233))) * 43758.5453);
      // (white enough to read on a phone: at half strength it passed for
      // the art's own pale shallows)
      float foam = max(edge, line * 0.9) * mix(0.65, 1.0, step(0.3, bub));
      // (by night lighter than the dark water, not the day's white dimmed
      // to the very colour of the water)
      vec3 foamCol = max(vec3(0.97, 0.99, 1.0) * uTint, lit * 1.7 + vec3(0.1));
      lit = mix(lit, foamCol, clamp(foam, 0.0, 1.0) * 0.92 * uFoam);
    }
  }
  // waterfalls (vertex alpha 0.62, mesher.lua): bright streaks run down
  // the sheet, each thread of water at its own speed, whiter toward the
  // foot where it churns
  float falls = uTerrain * (step(0.605, color.a) - step(0.64, color.a));
  if (uFalls > 0.0 && falls > 0.5) {
    float colh = fract(sin(floor(vWorld.x / 2.0) * 12.9898) * 43758.5453);
    float run = fract(vWorld.y * 0.045 - uTime * (1.3 + colh * 0.9) + colh * 7.0);
    float streak = smoothstep(0.0, 0.2, run) * (1.0 - smoothstep(0.2, 0.55, run));
    float sheen = 0.5 + 0.5 * sin(vWorld.x * 0.9 + colh * 6.0);
    vec3 white = max(vec3(0.92, 0.97, 1.0) * uTint, lit * 1.5 + vec3(0.08));
    lit = mix(lit, white, streak * (0.3 + 0.35 * sheen) * uFalls);
    // (the foot: within a few px of the water, all froth)
    float foot = 1.0 - smoothstep(0.0, 10.0, vZ - uWaterLvl);
    lit = mix(lit, white, foot * (0.45 + 0.25 * sin(uTime * 5.0 + vWorld.x * 0.7)) * uFalls);
  }
  // the night sky in the water: here and there a star, twinkling and
  // trembling with the waves (the sky itself is mostly off the screen)
  if (uStars > 0.0 && water > 0.5) {
    vec2 g = floor(vWorld / 9.0);
    float hs = fract(sin(dot(g, vec2(12.9898, 78.233))) * 43758.5453);
    if (hs > 0.955) {
      vec2 cpos = (g + 0.5 + (vec2(fract(hs * 13.1), fract(hs * 7.7)) - 0.5) * 0.6) * 9.0;
      float d = length(vWorld + wave * 1.2 - cpos);
      float tw = 0.35 + 0.65 * (0.5 + 0.5 * sin(uTime * (1.5 + hs * 2.0) + hs * 60.0));
      lit += vec3(1.0, 0.97, 0.85) * (1.0 - smoothstep(0.25, 1.0, d)) * tw * uStars;
    }
  }
  vec3 rgb = mix(lit, uFog.rgb, f);
  // dark cave: everything standing outside the Flash circle is black.
  // Judged by where it stands in the world (a wall by its foot), so the
  // lit area is a clean circle on the ground with whole walls inside it.
  vec2 dd = vWorld - uDark.xy;
  rgb *= 1.0 - uDark.w * step(uDark.z * uDark.z, dot(dd, dd));
  // ...and inside it the Flash light is warm, like a torch: golden toward
  // its rim and dimming there, breathing a little
  if (uDark.w > 0.0 && uDarkWarm > 0.0) {
    float e = clamp(length(dd) / max(1.0, uDark.z), 0.0, 1.0);
    float fl = 1.0 + 0.035 * sin(uTime * 7.3) + 0.025 * sin(uTime * 13.1 + 1.7);
    vec3 warm = mix(vec3(1.06, 1.0, 0.9), vec3(1.18, 0.84, 0.52), smoothstep(0.25, 1.0, e));
    rgb *= mix(vec3(1.0), warm * (1.0 - 0.3 * smoothstep(0.55, 1.0, e)) * fl, uDarkWarm);
  }
  return vec4(rgb, c.a * alphaMul);
}
#endif
]]

local shader, shaderErr
local depthCanvas, depthFormat
local reflCanvas, reflTargets
local meshes = {}
local shadowImage
local lightImage, lightRect, whiteImage

local function send(name, ...)
  if shader:hasUniform(name) then shader:send(name, ...) end
end

function Scene.init()
  if shader ~= nil or shaderErr then return shader ~= nil end
  local ok, result = pcall(love.graphics.newShader, SHADER)
  if not ok then
    shaderErr = tostring(result)
    return false
  end
  shader = result
  return true
end

function Scene.error() return shaderErr end

local depthErr
local meshOk, meshErr

local function canvasFormats()
  local g = love.graphics
  if g.getCanvasFormats then
    local ok, f = pcall(g.getCanvasFormats, false)
    if ok and type(f) == "table" then return f end
  end
  if g.getTextureFormats then -- LOVE 12
    local ok, f = pcall(g.getTextureFormats, { canvas = true })
    if ok and type(f) == "table" then return f end
  end
  return {}
end

local function depthTarget(w, h)
  if depthCanvas and depthCanvas:getWidth() == w and depthCanvas:getHeight() == h then
    return depthCanvas
  end
  if depthCanvas then depthCanvas:release() end
  depthCanvas = nil
  local formats = canvasFormats()
  local order = { "depth24", "depth16", "depth24stencil8", "depth32f" }
  if depthFormat then table.insert(order, 1, depthFormat) end
  local lastErr
  for _, fmt in ipairs(order) do
    if formats[fmt] ~= false then
      for _, opts in ipairs({
        { format = fmt, readable = false, dpiscale = 1 },
        { format = fmt, dpiscale = 1 },
        { format = fmt },
      }) do
        local ok, c = pcall(love.graphics.newCanvas, w, h, opts)
        if ok and c then
          depthCanvas, depthFormat, depthErr = c, fmt, nil
          return c
        end
        lastErr = c
      end
    end
  end
  depthErr = "no depth buffer (" .. tostring(lastErr) .. ")"
  return nil
end

-- true, or false + a short reason + a detail the player can report
function Scene.available()
  if not Scene.init() then return false, "shader", "shader failed: " .. tostring(shaderErr) end
  if not (love.graphics.setDepthMode and love.graphics.newMesh) then
    return false, "depth", "this LOVE build has no 3D depth support"
  end
  if meshOk == nil then
    local ok, err = pcall(function()
      love.graphics.newMesh(Scene.FORMAT, 4, "triangles", "dynamic"):release()
    end)
    meshOk = ok
    if not ok then meshErr = tostring(err) end
  end
  if not meshOk then return false, "mesh", "mesh format rejected: " .. tostring(meshErr) end
  -- probe once; after that the render-sized buffer is the proof (asking
  -- for a 16x16 one every frame would throw the full-size one away)
  if depthCanvas == nil and depthFormat == nil then
    if not depthTarget(16, 16) then return false, "depth", depthErr end
  elseif depthErr and not depthCanvas then
    return false, "depth", depthErr
  end
  return true
end

-- A mesh that grows by half again whenever it runs out, so a walk across a
-- busy town does not reallocate every rebuild.
local function fill(name, verts, nv, idx, ni)
  local m = meshes[name]
  if nv == 0 then
    if m then m.count = 0 end
    return
  end
  if not m or m.capacity < nv then
    if m and m.mesh then m.mesh:release() end
    local cap = math.max(64, math.floor(nv * 1.5))
    local mesh = love.graphics.newMesh(Scene.FORMAT, cap, "triangles", "dynamic")
    m = { mesh = mesh, capacity = cap, count = 0 }
    meshes[name] = m
  end
  m.mesh:setVertices(verts, 1, nv)
  if idx then
    m.mesh:setVertexMap(idx)
    m.mesh:setDrawRange(1, ni)
  else
    m.mesh:setVertexMap()
    m.mesh:setDrawRange(1, nv)
  end
  m.count = nv
end

-- With `tick`, the upload is done into a fresh mesh in chunks (tick may
-- yield to the next frame between them) and only swapped in when complete,
-- so the old terrain keeps drawing while the new one is uploaded.
function Scene.setTerrain(verts, idx, nv, ni, tick)
  terrainPieces = nil
  if not tick or nv == 0 then
    return fill("terrain", verts, nv, idx, ni)
  end
  local mesh = love.graphics.newMesh(Scene.FORMAT, nv, "triangles", "dynamic")
  local CHUNK = 2048
  for first = 1, nv, CHUNK do
    local last = math.min(nv, first + CHUNK - 1)
    local part = {}
    for i = first, last do part[i - first + 1] = verts[i] end
    mesh:setVertices(part, first)
    tick()
  end
  mesh:setVertexMap(idx)
  mesh:setDrawRange(1, ni)
  local old = meshes.terrain
  meshes.terrain = { mesh = mesh, capacity = nv, count = nv }
  if old and old.mesh then old.mesh:release() end
end

-- A whole map built ahead (bridge.lua) is meshed in pieces, and only the
-- pieces in view are drawn: all of Route 24 every frame would cost more than
-- the rebuilds it saves.  A piece: { mesh, count, x0, y0, x1, y1 } (mesh
-- space px).  Pieces belong to the caller, who releases them.
local terrainPieces = nil
local cullRect = nil

function Scene.makePiece(verts, idx, nv, ni, tick, x0, y0, x1, y1)
  if nv == 0 then return { count = 0, x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
  local mesh = love.graphics.newMesh(Scene.FORMAT, nv, "triangles", "static")
  local CHUNK = 2048
  for first = 1, nv, CHUNK do
    local last = math.min(nv, first + CHUNK - 1)
    local part = {}
    for i = first, last do part[i - first + 1] = verts[i] end
    mesh:setVertices(part, first)
    if tick then tick() end
  end
  mesh:setVertexMap(idx)
  mesh:setDrawRange(1, ni)
  return { mesh = mesh, count = ni, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

function Scene.releasePieces(pieces)
  for _, pc in ipairs(pieces or {}) do
    if pc.mesh then pc.mesh:release(); pc.mesh = nil end
  end
end

-- draw these pieces as the terrain (nil: the single terrain mesh again)
function Scene.setTerrainPieces(pieces)
  terrainPieces = pieces
end

function Scene.piecesDrawn() return Scene._drawnPieces or 0, terrainPieces and #terrainPieces or 0 end

-- The baked sun/ambient texture for the terrain (nil = no lighting).
-- keep: the image belongs to the caller (a whole map's, kept for coming
-- back), so it is not released when replaced.
local keptLight = setmetatable({}, { __mode = "k" })
function Scene.setLight(image, x, y, w, h, keep)
  if lightImage and lightImage ~= image and not keptLight[lightImage] then lightImage:release() end
  if image and keep then keptLight[image] = true end
  lightImage = image
  lightRect = image and { x, y, w, h } or nil
end

local function white()
  if not whiteImage then
    local d = love.image.newImageData(1, 1)
    d:setPixel(0, 0, 1, 1, 1, 1)
    whiteImage = love.graphics.newImage(d)
  end
  return whiteImage
end

-- a soft round glow, bright core fading out (fireflies)
local glowImage
local function glowTexture()
  if glowImage then return glowImage end
  local n = 16
  local data = love.image.newImageData(n, n)
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local dx, dy = (x + 0.5 - n / 2) / (n / 2), (y + 0.5 - n / 2) / (n / 2)
      local d = math.sqrt(dx * dx + dy * dy)
      local a = d < 1 and ((1 - d) ^ 2.2 + (d < 0.22 and 0.6 or 0)) or 0
      data:setPixel(x, y, 1, 1, 1, math.min(1, a))
    end
  end
  glowImage = love.graphics.newImage(data)
  glowImage:setFilter("linear", "linear")
  return glowImage
end

-- a soft round puff, evenly dense with a fuzzy edge (chimney smoke)
local puffImage
local function puffTexture()
  if puffImage then return puffImage end
  local n = 16
  local data = love.image.newImageData(n, n)
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local dx, dy = (x + 0.5 - n / 2) / (n / 2), (y + 0.5 - n / 2) / (n / 2)
      local d2 = dx * dx + dy * dy
      local a = d2 < 1 and (1 - d2) ^ 1.3 or 0
      data:setPixel(x, y, 1, 1, 1, a)
    end
  end
  puffImage = love.graphics.newImage(data)
  puffImage:setFilter("linear", "linear")
  return puffImage
end

-- a small solid oval with a soft rim (footprints)
local printImage
local function printTexture()
  if printImage then return printImage end
  local n = 8
  local data = love.image.newImageData(n, n)
  for y = 0, n - 1 do
    for x = 0, n - 1 do
      local dx, dy = (x + 0.5 - n / 2) / (n / 2), (y + 0.5 - n / 2) / (n / 2)
      local d = math.sqrt(dx * dx + dy * dy)
      data:setPixel(x, y, 1, 1, 1, d < 0.7 and 1 or (d < 1 and (1 - d) / 0.3 or 0))
    end
  end
  printImage = love.graphics.newImage(data)
  printImage:setFilter("linear", "linear")
  return printImage
end

local function shadowTexture()
  if shadowImage then return shadowImage end
  local w, h = 16, 8
  local data = love.image.newImageData(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local dx = (x + 0.5 - w / 2) / (w / 2)
      local dy = (y + 0.5 - h / 2) / (h / 2)
      local d = math.sqrt(dx * dx + dy * dy)
      local a = d < 1 and (1 - d * d) * 0.38 or 0
      data:setPixel(x, y, 0, 0, 0, a)
    end
  end
  shadowImage = love.graphics.newImage(data)
  shadowImage:setFilter("linear", "linear")
  return shadowImage
end

-- actors = { { x, y, z (feet), sx, sy (slot origin in the atlas) }, ... }
-- slot geometry: SLOT_W x SLOT_H, feet at (FOOT_X, FOOT_Y)
-- Solid characters (after Voxel Characters by last_swagger, whose SLAB
-- shape gives each sprite a body a few pixels deep).  Here the body is made
-- on the GPU: `depth` darkened copies of the sprite stand 1px apart behind
-- it, so the cut-out silhouette gains thickness -- a dark top edge from this
-- tilted camera, and dark sides toward the screen edges -- with no per-frame
-- read-back of the sprite.  depth 0 = flat cards.
local SIDE_SHADE = 0.32

-- Breathing (after last_swagger's Voxel Characters): each character's
-- body rises and settles a fraction of a pixel, scaled from the feet, on
-- its own slow clock so a crowd never breathes in step.  Its clock is
-- tied to the cell it stands on.
-- amp: height change as a fraction (0 = off); now: seconds
function Scene.breathScale(x, y, amp, now)
  if not amp or amp <= 0 then return 1 end
  local cx, cy = math.floor(x / 16), math.floor(y / 16)
  local h = (cx * 73856093 + cy * 19349663) % 1000 / 1000
  local period = 2.8 + h * 1.4
  local phase = h * 6.2832
  return 1 + amp * (0.5 + 0.5 * math.sin((now or 0) * 6.2832 / period + phase))
end

-- Blinking: a blink every 3.5 to 6 s, an eighth of a second long, each
-- character on its own clock (by the cell it stands on, like its breath).
function Scene.blinking(x, y, now)
  local cx, cy = math.floor(x / 16), math.floor(y / 16)
  local h = (cx * 83492791 + cy * 2971215073) % 1000 / 1000
  local period = 3.5 + h * 2.5
  return ((now or 0) + h * period) % period < 0.12
end

function Scene.setActors(actors, SLOT_W, SLOT_H, FOOT_X, FOOT_Y, depth, breath, now, blink)
  depth = depth or 0
  local verts, idx, nv, ni = {}, {}, 0, 0
  local sverts, sidx, snv, sni = {}, {}, 0, 0
  for _, a in ipairs(actors) do
    local x, y, z = a.x, a.y, a.z
    local u0, v0 = a.sx, a.sy
    local l, r = -FOOT_X, SLOT_W - FOOT_X
    local t, b = FOOT_Y, FOOT_Y - SLOT_H -- up is +
    local bs = Scene.breathScale(x, y, breath, now)
    local blinkNow = blink and Scene.blinking(x, y, now)
    if blinkNow then Scene.blinkFrames = (Scene.blinkFrames or 0) + 1 end
    t, b = t * bs, b * bs
    -- a character standing in a shadow is shaded like the ground under it
    local cr, cg, cb = a.lr or 1, a.lg or 1, a.lb or 1
    -- layers a third of a pixel apart, so the body stays one solid edge even
    -- under INDOOR ZOOM (1px apart, zoomed 3x, they showed as stripes)
    local steps = math.floor(depth * 3 + 0.5)
    for layer = steps, 0, -1 do
      -- each layer a little further north (behind), and darker: the sides
      local ly = y - layer / 3
      local k = layer == 0 and 1 or SIDE_SHADE
      local r1, g1, b1 = cr * k, cg * k, cb * k
      -- the front layer of a blinking character carries the blink flag
      local fa = (blinkNow and layer == 0) and 0.988 or 1
      nv = nv + 4
      verts[nv - 3] = { x, ly, z, u0, v0, l, t, r1, g1, b1, fa }
      verts[nv - 2] = { x, ly, z, u0 + SLOT_W, v0, r, t, r1, g1, b1, fa }
      verts[nv - 1] = { x, ly, z, u0 + SLOT_W, v0 + SLOT_H, r, b, r1, g1, b1, fa }
      verts[nv] = { x, ly, z, u0, v0 + SLOT_H, l, b, r1, g1, b1, fa }
      idx[ni + 1], idx[ni + 2], idx[ni + 3] = nv - 3, nv - 2, nv - 1
      idx[ni + 4], idx[ni + 5], idx[ni + 6] = nv - 3, nv - 1, nv
      ni = ni + 6
    end
    if a.shadow ~= false then
      local gz = (a.ground or z) + 0.4
      -- centred right under the feet: further south it showed as a dark
      -- blob floating below the sprite ("shadows are floating")
      local sy = y - 2 -- mostly under and behind the feet, peeking out around them
      snv = snv + 4
      sverts[snv - 3] = { x - 6, sy - 2.5, gz, 0, 0, 0, 0, 1, 1, 1, 1 }
      sverts[snv - 2] = { x + 6, sy - 2.5, gz, 16, 0, 0, 0, 1, 1, 1, 1 }
      sverts[snv - 1] = { x + 6, sy + 2.5, gz, 16, 8, 0, 0, 1, 1, 1, 1 }
      sverts[snv] = { x - 6, sy + 2.5, gz, 0, 8, 0, 0, 1, 1, 1, 1 }
      sidx[sni + 1], sidx[sni + 2], sidx[sni + 3] = snv - 3, snv - 2, snv - 1
      sidx[sni + 4], sidx[sni + 5], sidx[sni + 6] = snv - 3, snv - 1, snv
      sni = sni + 6
    end
  end
  fill("actors", verts, nv, idx, ni)
  fill("shadows", sverts, snv, sidx, sni)
end

-- A flat quad on the ground carrying a screen-space layer (the engine's OAM
-- field sprites) under the 3D camera, the way Tilt anchors its overlays.
-- The flat map as one ground quad just under the voxels.  Where the voxel
-- mesh does not reach yet (a new area still building in the background) the
-- player sees the map flat instead of a hole in the world.  Sits below water
-- (-2) so it never shows through anything that was built.
function Scene.setWeather(verts, nv, idx, ni)
  fill("weather", verts, nv, idx, ni)
end

function Scene.setPrints(v, n, idx, ni, wv, wn, widx, wni)
  fill("prints", v, n or 0, idx, ni)
  fill("wakes", wv or {}, wn or 0, widx or {}, wni or 0)
end

function Scene.setSmoke(cv, cn, ci, cni, pv, pn, pi, pni)
  fill("chimneys", cv, cn or 0, ci, cni)
  fill("puffs", pv, pn or 0, pi, pni)
end

function Scene.count(name)
  local m = meshes[name]
  return m and m.count or 0
end

-- cave dust and drips (caves.lua): soft glows drawn over the scene
function Scene.setCaveFx(v, n, idx, ni)
  fill("cavefx", v, n or 0, idx, ni)
end

-- waterfall mist, spray and froth (falls.lua): soft glows over the scene
function Scene.setFallsFx(v, n, idx, ni)
  fill("fallsfx", v, n or 0, idx, ni)
end

function Scene.setCritters(gv, gn, gi, gni, bv, bn, bi, bni)
  fill("flies", gv, gn or 0, gi, gni)
  fill("birds", bv, bn or 0, bi, bni)
end

function Scene.setBackdrop(x, y, w, h)
  local z = -3
  local verts = {
    { x, y, z, x, y, 0, 0, 0.92, 0.92, 0.92, 1 },
    { x + w, y, z, x + w, y, 0, 0, 0.92, 0.92, 0.92, 1 },
    { x + w, y + h, z, x + w, y + h, 0, 0, 0.92, 0.92, 0.92, 1 },
    { x, y + h, z, x, y + h, 0, 0, 0.92, 0.92, 0.92, 1 },
  }
  fill("backdrop", verts, 4, { 1, 2, 3, 1, 3, 4 }, 6)
end

function Scene.setOverlay(x, y, w, h, z)
  local verts = {
    { x, y, z, 0, 0, 0, 0, 1, 1, 1, 1 },
    { x + w, y, z, w, 0, 0, 0, 1, 1, 1, 1 },
    { x + w, y + h, z, w, h, 0, 0, 1, 1, 1, 1 },
    { x, y + h, z, 0, h, 0, 0, 1, 1, 1, 1 },
  }
  fill("overlay", verts, 4, { 1, 2, 3, 1, 3, 4 }, 6)
end

local function drawMesh(name)
  local m = meshes[name]
  if m and m.count > 0 then love.graphics.draw(m.mesh) end
end

-- the terrain: the single mesh, or the pieces of a whole map in view
local function drawTerrain()
  if not terrainPieces then return drawMesh("terrain") end
  local c, n = cullRect, 0
  for _, pc in ipairs(terrainPieces) do
    if pc.mesh and pc.count > 0 and (not c or (pc.x1 >= c[1] and pc.x0 <= c[3] and pc.y1 >= c[2] and pc.y0 <= c[4])) then
      love.graphics.draw(pc.mesh)
      n = n + 1
    end
  end
  Scene._drawnPieces = n
end

local function terrainReady()
  if terrainPieces then return #terrainPieces > 0 end
  return meshes.terrain ~= nil and meshes.terrain.count > 0
end

local skyMesh
local function skyGradient(w, h, top, bottom)
  -- one reusable mesh: creating a Mesh every frame is a GPU allocation
  if not skyMesh then
    skyMesh = love.graphics.newMesh(4, "fan", "dynamic")
  end
  skyMesh:setVertices({
    { 0, 0, 0, 0, top[1], top[2], top[3], 1 },
    { w, 0, 0, 0, top[1], top[2], top[3], 1 },
    { w, h, 0, 0, bottom[1], bottom[2], bottom[3], 1 },
    { 0, h, 0, 0, bottom[1], bottom[2], bottom[3], 1 },
  })
  love.graphics.draw(skyMesh)
end

-- the reflection canvas and its own depth buffer (half the target's size)
local reflDepth
reflTargets = function(w, h)
  if reflCanvas and reflCanvas:getWidth() == w and reflCanvas:getHeight() == h and reflDepth then
    return reflCanvas, reflDepth
  end
  if reflCanvas then reflCanvas:release() end
  if reflDepth then reflDepth:release() end
  reflCanvas, reflDepth = nil, nil
  local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not ok then return nil end
  c:setFilter("linear", "linear")
  local fmt = depthFormat or "depth16"
  local okD, d = pcall(love.graphics.newCanvas, w, h, { format = fmt, readable = false, dpiscale = 1 })
  if not okD then
    okD, d = pcall(love.graphics.newCanvas, w, h, { format = fmt, dpiscale = 1 })
  end
  if not okD then c:release() return nil end
  reflCanvas, reflDepth = c, d
  return c, d
end

-- Cloud shadows: soft blobs in a tiling 128x128 pattern (value noise, a
-- few octaves, wrapped so it tiles), thresholded into separate clouds.
local cloudImage
local function cloudTexture()
  if cloudImage then return cloudImage end
  local N = 128
  local function hash(x, y, p)
    local h = (x * 374761393 + y * 668265263 + p * 1442695041) % 2147483647
    h = (h * 1274126177) % 2147483647
    return (h % 10000) / 10000
  end
  local function noise(x, y, period, p)
    local x0, y0 = math.floor(x), math.floor(y)
    local fx, fy = x - x0, y - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    local function g(i, j) return hash((x0 + i) % period, (y0 + j) % period, p) end
    local a = g(0, 0) + (g(1, 0) - g(0, 0)) * fx
    local b = g(0, 1) + (g(1, 1) - g(0, 1)) * fx
    return a + (b - a) * fy
  end
  local data = love.image.newImageData(N, N)
  for y = 0, N - 1 do
    for x = 0, N - 1 do
      local v, amp, tot = 0, 1, 0
      for o = 0, 3 do
        local period = 4 * 2 ^ o
        v = v + amp * noise(x / N * period, y / N * period, period, o + 1)
        tot = tot + amp
        amp = amp * 0.5
      end
      v = v / tot
      local c = math.min(1, math.max(0, (v - 0.5) / 0.16))
      c = c * c * (3 - 2 * c)
      data:setPixel(x, y, c, c, c, 1)
    end
  end
  cloudImage = love.graphics.newImage(data)
  cloudImage:setFilter("linear", "linear")
  cloudImage:setWrap("repeat", "repeat")
  return cloudImage
end
Scene._cloudTexture = cloudTexture

-- The sky behind the map: clouds drifting across it by day, stars at
-- night.  Screen space, under everything (what stands in front hides it).
local skyStars
local function skyDecor(w, h, sky)
  if not sky then return end
  local band = h * 0.42 -- (the sky shows above the far edge of the map)
  if (sky.stars or 0) > 0.01 then
    if not skyStars then
      skyStars = {}
      local r = love.math.newRandomGenerator(7)
      for i = 1, 90 do skyStars[i] = { r:random(), r:random() ^ 1.6, r:random() * 6.28, 0.6 + r:random() * 1.4 } end
    end
    local t = sky.time or 0
    for _, st in ipairs(skyStars) do
      local a = sky.stars * (0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 1.3 + st[3])))
      love.graphics.setColor(1, 0.97, 0.88, a)
      local sz = st[4] * math.max(1, h / 900)
      love.graphics.rectangle("fill", st[1] * w, st[2] * band, sz, sz)
    end
  end
  if (sky.clouds or 0) > 0.01 then
    local img = puffTexture()
    local t = sky.time or 0
    local col = sky.color or { 1, 1, 1 }
    local r = love.math.newRandomGenerator(11)
    local unit = w / 6
    for i = 1, 7 do
      local speed = (sky.speed or 6) * (0.6 + r:random() * 0.8) * (w / 720)
      local span = w + unit * 4
      local x = ((r:random() * span + t * speed) % span) - unit * 2
      local y = band * (0.12 + r:random() * 0.6)
      local s = unit * (0.7 + r:random() * 0.7)
      for k = 1, 5 do
        local ox, oy = (r:random() - 0.5) * s * 1.4, (r:random() - 0.5) * s * 0.3
        local ps = s * (0.45 + r:random() * 0.4)
        love.graphics.setColor(col[1], col[2], col[3], sky.clouds * 0.75)
        love.graphics.draw(img, x + ox - ps, y + oy - ps * 0.5, 0, ps * 2 / 16, ps / 16)
      end
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- p = { target, cam (solved), view, proj, ground, groundX, groundY,
--       atlas, overlay, skyTop, skyBottom, fog, fogStart, fogEnd }
function Scene.render(p)
  local w, h = p.target:getWidth(), p.target:getHeight()
  local depth = depthTarget(w, h)
  if not depth then return false end
  love.graphics.push("all")
  love.graphics.setCanvas({ p.target, depthstencil = depth })
  love.graphics.origin()
  love.graphics.clear(p.skyBottom[1], p.skyBottom[2], p.skyBottom[3], 1, true, true)
  love.graphics.setDepthMode("always", false)
  love.graphics.setColor(1, 1, 1, 1)
  skyGradient(w, h, p.skyTop, p.skyBottom)
  skyDecor(w, h, p.sky)

  love.graphics.setShader(shader)
  send("uKRef", math.max(1, p.cam and p.cam.dist or 500))
  send("uView", "row", p.view)
  do
    local za = p.cam and p.cam.za
    local hx, hy = za and za[1] or 0, za and za[2] or 1
    local l = math.sqrt(hx * hx + hy * hy)
    if l < 1e-6 then hx, hy, l = 0, 1, 1 end
    send("uBillN", { hx / l, hy / l })
  end
  send("uProj", "row", p.proj)
  send("uFog", { p.fog[1], p.fog[2], p.fog[3], p.fogStrength or 1 })
  send("uFogRange", { p.fogStart, p.fogEnd })
  local lit = p.light ~= false and lightImage ~= nil
  send("uLight", lit and lightImage or white())
  send("uLightRect", lit and lightRect or { 0, 0, 1, 1 })
  send("uShadow", p.shadowTint or { 0.58, 0.62, 0.76 })
  send("uLit", lit and 1 or 0)
  local cloud = p.clouds
  send("uCloud", cloud and cloudTexture() or white())
  send("uCloudK", 1 / ((cloud and cloud.size) or 512))
  send("uCloudOn", 0)
  send("uStars", 0)
  send("uFoam", 0)
  send("uFalls", 0)
  local dk = p.dark
  send("uDark", dk and { dk[1], dk[2], dk[3], 1 } or { 0, 0, 0, 0 })
  send("uDarkWarm", (dk and p.warmFlash) and 1 or 0)
  send("uTint", p.tint or { 1, 1, 1 })
  send("uDesat", p.desat or 0)
  send("uNight", p.night or 0)
  send("uTime", (love.timer and love.timer.getTime() or 0) % 1000)
  send("uTimeV", (p.time or (love.timer and love.timer.getTime()) or 0) % 1000)
  send("uWindV", 0)
  send("uPartOn", 0)

  -- reflections: first the scene mirrored in the water's plane, at half
  -- size, into its own canvas; the water samples it below
  send("uMirror", 0)
  send("uMirrorV", 0)
  local reflOn = false
  cullRect = p.cull
  if p.reflect and p.waterZ and terrainReady() then
    local rw, rh = math.max(1, math.floor(w / 2)), math.max(1, math.floor(h / 2))
    local rc, rd = reflTargets(rw, rh)
    if rc and rd then
      love.graphics.setCanvas({ rc, depthstencil = rd })
      love.graphics.clear(0, 0, 0, 0, true, true)
      send("uMirror", 1)
      send("uMirrorV", 1)
      send("uWaterZ", p.waterZ)
      send("uWaterLvl", p.waterZ)
      love.graphics.setDepthMode("lequal", true)
      send("uShift", { p.shiftX or 0, p.shiftY or 0 })
      send("uTex", p.ground)
      send("uOrigin", { p.groundX, p.groundY })
      send("uSize", { p.ground:getWidth(), p.ground:getHeight() })
      send("uEdge", 1)
      send("uCutout", -1)
      send("uTerrain", 1)
      send("uWindV", p.wind or 0)
      drawTerrain()
      send("uWindV", 0)
      send("uTerrain", 0)
      send("uShift", { 0, 0 })
      if p.atlas then
        local wasLit = lit
        send("uLit", 0)
        send("uEdge", 0)
        send("uTex", p.atlas)
        send("uOrigin", { 0, 0 })
        send("uSize", { p.atlas:getWidth(), p.atlas:getHeight() })
        send("uCutout", 0.5)
        drawMesh("actors")
        send("uLit", wasLit and 1 or 0)
      end
      send("uMirror", 0)
      send("uMirrorV", 0)
      love.graphics.setCanvas({ p.target, depthstencil = depth })
      reflOn = true
      Scene.reflFrames = (Scene.reflFrames or 0) + 1
    end
  end
  send("uRefl", reflOn and reflCanvas or white())
  send("uReflOn", reflOn and (p.reflectStrength or 0.42) or 0)
  send("uScreen", { w, h })

  -- terrain
  love.graphics.setDepthMode("lequal", true)
  send("uShift", { p.shiftX or 0, p.shiftY or 0 })
  send("uTex", p.ground)
  send("uOrigin", { p.groundX, p.groundY })
  send("uSize", { p.ground:getWidth(), p.ground:getHeight() })
  send("uEdge", 1)
  send("uCutout", -1)
  send("uTerrain", 1)
  send("uWindV", p.wind or 0)
  local parts = p.parters
  if parts and #parts > 0 then
    local arr = {}
    for i = 1, 12 do
      local q = parts[i]
      arr[i] = q and { q[1], q[2], q[3], q[4] } or { 0, 0, 1, 0 }
    end
    send("uPartV", unpack(arr))
    send("uPartOn", 1)
  end
  if cloud then
    send("uCloudOn", cloud.strength or 0)
    send("uCloudXY", { cloud.x + (p.shiftX or 0), cloud.y + (p.shiftY or 0) })
  end
  send("uStars", p.sky and p.sky.stars or 0)
  send("uFoam", (lit and p.foam) and 1 or 0)
  send("uFalls", p.falls and 1 or 0)
  send("uWaterLvl", p.waterZ or -6)
  drawTerrain()
  send("uPartOn", 0)
  send("uFoam", 0)
  send("uFalls", 0)
  send("uStars", 0)
  send("uCloudOn", 0)
  send("uWindV", 0)
  send("uTerrain", 0)
  send("uShift", { 0, 0 })
  send("uLit", 0)
  drawMesh("backdrop")

  send("uEdge", 0)
  -- footprints (footprints.lua): pressed into the ground, under everything
  if (meshes.prints and meshes.prints.count or 0) > 0 then
    love.graphics.setDepthMode("lequal", false)
    send("uTex", printTexture())
    send("uOrigin", { 0, 0 })
    send("uSize", { 8, 8 })
    send("uCutout", 0.01)
    drawMesh("prints")
  end
  -- the wake behind a swimmer: foam, lit (at night the day's tint made it
  -- the colour of the water around it)
  -- (no depth test: on the phone it lost to the water's surface however
  -- high it floated -- 98 ripples alive, none on screen.  It lies flat on
  -- open water and fades within two seconds; the characters drawn after
  -- it still stand in front)
  if (meshes.wakes and meshes.wakes.count or 0) > 0 then
    love.graphics.setDepthMode("always", false)
    send("uTex", printTexture())
    send("uOrigin", { 0, 0 })
    send("uSize", { 8, 8 })
    send("uCutout", 0.01)
    local t = p.tint or { 1, 1, 1 }
    send("uTint", { t[1] + (1 - t[1]) * 0.55, t[2] + (1 - t[2]) * 0.55, t[3] + (1 - t[3]) * 0.55 })
    drawMesh("wakes")
    send("uTint", t)
  end
  -- blob shadows: depth-tested, never written, so they cannot hide a sprite
  if p.shadows ~= false then
    love.graphics.setDepthMode("lequal", false)
    send("uTex", shadowTexture())
    send("uOrigin", { 0, 0 })
    send("uSize", { 16, 8 })
    send("uCutout", 0.01)
    drawMesh("shadows")
  end

  -- characters
  if p.atlas then
    love.graphics.setDepthMode("lequal", true)
    send("uTex", p.atlas)
    send("uOrigin", { 0, 0 })
    send("uSize", { p.atlas:getWidth(), p.atlas:getHeight() })
    send("uCutout", 0.5)
    send("uSlot", p.slot or { 0, 96, 80 })
    send("uActors", 1)
    if p.xray ~= false then
      -- see-through pass: only the parts of a character that something
      -- stands in front of (depth "greater"), as a faint cool ghost.  The
      -- normal pass below then draws everything that is in plain view.
      love.graphics.setDepthMode("greater", false)
      love.graphics.setColor(0.55, 0.65, 0.9, 0.45)
      drawMesh("actors")
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.setDepthMode("lequal", true)
    end
    if cloud then
      send("uCloudOn", cloud.strength or 0)
      send("uCloudXY", { cloud.x, cloud.y })
    end
    drawMesh("actors")
    send("uCloudOn", 0)
    send("uActors", 0)
  end

  -- chimneys and their smoke (smoke.lua): the stacks solid, in the day's
  -- light; the puffs soft, hidden by what stands in front, hiding nothing
  local nc = meshes.chimneys and meshes.chimneys.count or 0
  local np = meshes.puffs and meshes.puffs.count or 0
  if nc > 0 or np > 0 then
    send("uTex", white())
    send("uOrigin", { 0, 0 })
    send("uSize", { 1, 1 })
    send("uCutout", -1)
    send("uEdge", 0)
    send("uTint", p.tint or { 1, 1, 1 })
    send("uDesat", p.desat or 0)
    if nc > 0 then
      love.graphics.setDepthMode("lequal", true)
      drawMesh("chimneys")
    end
    if np > 0 then
      love.graphics.setDepthMode("lequal", false)
      local t = p.tint or { 1, 1, 1 }
      -- (lifted toward white more than the ground: grey smoke in moonlight
      -- otherwise matched the blue-grey streets under it)
      send("uTint", { t[1] + (1 - t[1]) * 0.6, t[2] + (1 - t[2]) * 0.6, t[3] + (1 - t[3]) * 0.6 })
      send("uDesat", (p.desat or 0) * 0.4)
      send("uTex", puffTexture())
      send("uSize", { 16, 16 })
      drawMesh("puffs")
    end
  end

  -- weather (weather3d.lua): falling through the scene, hidden behind what
  -- stands in front of it, never hiding anything itself
  if (meshes.weather and meshes.weather.count or 0) > 0 then
    love.graphics.setDepthMode("lequal", false)
    send("uTex", white())
    send("uOrigin", { 0, 0 })
    send("uSize", { 1, 1 })
    send("uCutout", -1)
    -- flakes and drops catch more light than the ground they fall on: at
    -- night they would vanish into it otherwise
    local t = p.tint or { 1, 1, 1 }
    send("uTint", { t[1] + (1 - t[1]) * 0.45, t[2] + (1 - t[2]) * 0.45, t[3] + (1 - t[3]) * 0.45 })
    send("uDesat", (p.desat or 0) * 0.5)
    drawMesh("weather")
  end

  -- critters (critters.lua): birds in the day's light, fireflies glowing
  -- (added to what is behind them, untinted by the night)
  local nb = meshes.birds and meshes.birds.count or 0
  local nf = meshes.flies and meshes.flies.count or 0
  if nb > 0 or nf > 0 then
    love.graphics.setDepthMode("lequal", false)
    send("uTex", white())
    send("uOrigin", { 0, 0 })
    send("uSize", { 1, 1 })
    send("uCutout", -1)
    if nb > 0 then
      send("uTint", p.tint or { 1, 1, 1 })
      send("uDesat", p.desat or 0)
      drawMesh("birds")
    end
    if nf > 0 then
      send("uTint", { 1, 1, 1 })
      send("uDesat", 0)
      send("uTex", glowTexture())
      send("uSize", { 16, 16 })
      love.graphics.setBlendMode("add")
      drawMesh("flies")
      love.graphics.setBlendMode("alpha")
    end
  end

  -- cave dust and drips: blended over what is behind, in the cave's light
  -- (the Flash darkness falls on them too)
  if (meshes.cavefx and meshes.cavefx.count or 0) > 0 then
    love.graphics.setDepthMode("lequal", false)
    send("uTex", glowTexture())
    send("uOrigin", { 0, 0 })
    send("uSize", { 16, 16 })
    send("uCutout", -1)
    send("uTint", { 1, 1, 1 })
    send("uDesat", 0)
    love.graphics.setBlendMode("alpha")
    drawMesh("cavefx")
  end

  -- waterfall mist and spray: the same soft glows, blended over the scene
  if (meshes.fallsfx and meshes.fallsfx.count or 0) > 0 then
    love.graphics.setDepthMode("lequal", false)
    send("uTex", glowTexture())
    send("uOrigin", { 0, 0 })
    send("uSize", { 16, 16 })
    send("uCutout", -1)
    send("uTint", { 1, 1, 1 })
    send("uDesat", 0)
    love.graphics.setBlendMode("alpha")
    drawMesh("fallsfx")
  end

  -- engine OAM layer (emotes, field-move sprites): always on top, untinted
  send("uTint", { 1, 1, 1 })
  send("uDesat", 0)
  send("uNight", 0)
  if p.overlay then
    love.graphics.setDepthMode("always", false)
    send("uTex", p.overlay)
    send("uOrigin", { 0, 0 })
    send("uSize", { p.overlay:getWidth(), p.overlay:getHeight() })
    send("uCutout", 0.02)
    drawMesh("overlay")
  end

  love.graphics.setShader()
  love.graphics.setDepthMode()
  love.graphics.setCanvas()
  love.graphics.pop()
  return true
end

-- Distance blur, applied while the finished 3D picture is copied (and
-- upscaled) to the screen-size canvas: sharp in the lower part of the
-- screen, growing softer toward the top, where the camera looks furthest
-- away -- the "miniature" look.  Rows below the band take one texture read,
-- rows inside it seventeen.
local BLUR = [[
uniform vec2 uTexel;    // 1 / source size
uniform float uRadius;  // blur radius in source pixels at the very top
uniform float uStart;   // screen fraction from the top where blur begins

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
  float t = clamp((uStart - uv.y) / uStart, 0.0, 1.0);
  float r = uRadius * t * t;
  if (r < 0.75) return Texel(tex, uv) * color;
  vec4 sum = Texel(tex, uv) * 2.0;
  vec2 d = vec2(r, 0.0);
  const float c = 0.70710678;
  for (int i = 0; i < 8; i++) {
    sum += Texel(tex, uv + d * uTexel);
    sum += Texel(tex, uv + d * 0.5 * uTexel);
    d = vec2(d.x * c - d.y * c, d.x * c + d.y * c); // next 45 degrees
  }
  return (sum / 18.0) * color;
}
]]
local blurShader, blurErr

function Scene.blurShader()
  if blurShader or blurErr then return blurShader end
  local ok, sh = pcall(love.graphics.newShader, BLUR)
  if ok then blurShader = sh else blurErr = tostring(sh) end
  return blurShader
end

function Scene.release()
  for _, m in pairs(meshes) do
    if m.mesh then m.mesh:release() end
  end
  meshes = {}
  if depthCanvas then depthCanvas:release() end
  depthCanvas = nil
  Scene.setLight(nil)
end

return Scene
