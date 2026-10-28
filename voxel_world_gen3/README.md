# Voxel Diorama (Gen 3)

Turns the FireRed / LeafGreen / Ruby / Sapphire / Emerald overworld into a
3D voxel diorama. It's the Gen 3 version of the Gen 1 voxel mode. It works
on every map without per-map assets. The geometry comes from the map's own
collision grid, and the textures come from the game's live flat render.
Water, flowers, doors, weather and Flash darkness keep animating on the
voxels.

## Controls

| | |
|---|---|
| **6** | cycle the view: OFF → LOW → MID → HIGH (free roam only) |
| Mod options (OPTION → MODS, or the F10 mod manager) | the mode it starts in, plus the settings below |

| Option | Values | What it does |
|---|---|---|
| VOXEL VIEW | OFF / LOW / MID / HIGH | camera tilt: 30° / 45° / 55° from straight down |
| VOXEL QUALITY | AUTO / HIGH / BALANCED / POTATO | AUTO starts balanced and steps down by itself while the frame rate stays under ~48 fps; POTATO is the lightest (0.35 MP, 3D every other frame, coarse relief, shorter view) |
| VOXEL HEIGHT | 75–150% | how tall buildings, trees and fences stand |
| VOXEL RES | AUTO / FULL / HALF / PIXEL | render resolution; AUTO follows VOXEL QUALITY's pixel budget (1 MP balanced), PIXEL renders at GBA-pixel size for a chunky look and is the cheapest |
| VOXEL ZOOM | 100–200% | brings the camera closer everywhere (handy on phones) |
| INDOOR ZOOM | FIT / OFF | zoom in so small rooms fill the screen (up to 3x) |
| LEAF RELIEF | on / off | lumpy tree canopies, grass and rock tops in 8px bumps (a whole cell on POTATO); off = flat tops, fewest triangles |
| SEE-THROUGH | on / off | show characters hidden behind trees, roofs and cliffs as a faint ghost |
| 3D RATE | AUTO / FULL / HALF | HALF redraws the 3D scene every other frame; AUTO does that on 120 Hz screens, when frames run slow, or when the quality calls for it |
| PERF STATS | on / off | FPS, the mod's per-frame milliseconds, the quality tier and the 3D resolution in the corner |
| SUN SHADOWS | on / off | buildings, trees, fences and rocks cast soft sun shadows, and the ground darkens where walls and trees crowd in; worked out once per area, so it costs almost nothing per frame |
| BREATH | OFF / SUBTLE / NORMAL | characters gently breathe, each on their own clock (after last_swagger's Voxel Characters) |
| BLINK | on / off | characters blink every few seconds; the eyes are found by their shape, so the odd sprite may not blink or may blink a stray pixel |
| NIGHT LIGHTS | on / off | at night windows glow, street lamps and doorways cast pools of warm light (needs DAY/NIGHT and sun shadows on) |
| REFLECTIONS | on / off | water mirrors trees, houses and characters beside it (a second, half-size render pass, only when water is in view) |
| SWAYING TREES | on / off | trees, shrubs and tall grass move in the wind, harder in rain and storms |
| FIREFLIES & BIRDS | on / off | fireflies over grass and woods at night, small flocks of birds flying up out of trees by day |
| CHIMNEY SMOKE | on / off | houses get a chimney, smoke rises from it and drifts with the wind |
| FOOTPRINTS | on / off | prints in sand (NPCs too), in Route 113's ash, and wet prints out of puddles |
| CLOUDS & STARS | on / off | cloud shadows drift over the land by day, clouds cross the sky, stars come out at night |
| WAVES & FOAM | on / off | foam along shores, waves rolling in, a wake behind you when surfing |
| CAVE ATMOSPHERE | on / off | dust in the air and dripping water in caves; the Flash circle glows warm like a torch |
| WATERFALLS | on / off | waterfalls fall from the cliff tops as sheets of streaming water, with mist, spray and froth where they land |
| BUILD AHEAD | on / off | builds the whole map in the background (in Ruby/Sapphire/Emerald once most of its tiles have been on screen; maps up to about Saffron's size), then stops rebuilding while you walk: no stutter, nothing changes shape |
| BUILD NEIGHBOURS | on / off | also builds the maps next to the current one in the background, while frames have time to spare, so crossing into one is seamless |
| TREE STYLE | rounded / classic | ROUNDED shapes each tree's crown from its own art; CLASSIC is the older look (rows of ridges) |
| PRE-BUILD AT START | off / on | on arriving somewhere new (Continue, New Game, Fly, Teleport, a warp out of doors), builds the map (and at the start its neighbours) behind a short loading screen; B skips |
| CAMERA TURN | LEFT 30 / LEFT 15 / STRAIGHT / RIGHT 15 / RIGHT 30 | look at the diorama from an angle, to see behind houses; key 7 cycles it |
| 3D WEATHER | on / off | rain, snow and volcanic ash fall through the 3D scene, behind and in front of buildings, instead of being painted over the map; rain darkens the light, thunderstorms flash |
| DAY/NIGHT | GAME CLOCK / DEVICE CLOCK / OFF | outdoors, the light follows the time of day: morning and evening sun from the side with long shadows, warm sunsets, blue nights with no shadows. GAME CLOCK uses the clock you set in Ruby/Sapphire/Emerald (FireRed/LeafGreen have none and use the device clock) |
| DISTANCE BLUR | on / off | the far distance (top of the screen) goes soft, like a miniature; off on POTATO |
| ROUND TREES | on / off | trees, bushes and hedges get rounded crowns instead of flat-topped blocks (full domes on HIGH, softer on BALANCED/AUTO, flat on POTATO) |
| SLOPED ROOFS | on / off | buildings get a gable roof (ridge front to back, triangle over the front wall) instead of a flat top; outdoors only |
| SOLID CHARACTERS | OFF / THIN / SLAB / THICK | characters get a body 2, 3 or 5px deep built from their own sprite, instead of a flat card (idea from Voxel Characters) |
| SHADOWS | on / off | soft blob shadows under characters |

The hotkey changes the mode for the current session. The OPTION value is
the mode it boots into. The mode switches TILT (key 3) off while it's on,
because the two do the same job.

**Slow phone or PC?** Set VOXEL QUALITY to POTATO, or leave it on AUTO and
let it find its level (turn on PERF STATS to see which tier it picked).
Turning LEAF RELIEF off saves the most geometry of any single setting.

## How it works

The GBA draws the overworld in an oblique projection: anything standing up
is painted shifted north by its own height. So a pixel of art at `(x, y)`
belongs to the 3D point `(x, y + z, z)`. The mod runs that backwards:

1. **Heights from collision.** Each column of solid cells (buildings,
   trees, fences, cliffs, signs) is a *run*. A run of 1
   cell is an 8px slab, a run of 2 is one storey (16px), and 3 or more is
   two storeys (32px). Doors and cave mouths count as part of the facade
   they're cut into. Water sits 2px low. Ledges are a 4px lip. Tall grass
   gets a few px of relief.
2. **Footprints from the art.** A run of height `h` stands on its southern
   rows, and its top `h` pixels of art become the hidden ground behind it.
   Every voxel samples the art at `(x, y - z)`. So a house's front wall,
   door and windows stand upright, its roof sits on top, and a fence stays
   thin.
3. **Interiors.** A room is built as a dollhouse: the solid band under the
   black void at the top is the back wall, one height across the room;
   solid cells beside the void are side walls as tall; everything else is
   furniture, a box as tall as its art reaches above its cell (read from
   where the wall or floor pattern behind it repeats again). The floor is
   flat.
4. **FRLG trees.** The walkable canopy cell above a trunk is the top of the
   same tree, so the tree stands on its trunk with its crown on top.
5. **Characters.** These are camera-facing billboards. Their depth comes
   from an upright plane through their feet, so a character is never
   clipped by a tree or wall behind it. They're still hidden by anything in
   front, and they disappear into doorways like on the cart.

Everything is 4px voxels, greedy-meshed, and rebuilt only when you walk a
few cells, change maps, or a tile changes (Cut, Rock Smash, doors that
rewrite the layout).

## Engine seams it uses (`engine_internals`)

Gen 3 has no target for `render_pipelines` yet (`src/mods/Schemas.lua`
`GEN3`), so the mod hooks the two points the Gen 3 frame already has:

- `src/core/game3/field_view.lua` `FieldView.draw`. When it's called for the
  Renderer's world pass, the field is drawn twice into the mod's own
  canvases: the map without characters, then characters only. Each
  character is redirected into an atlas slot through the same
  `Tilt.groundPoint` billboard hook TILT mode uses.
- `src/render/Renderer.lua` `Renderer:endWorldPass`. The scene is rendered
  at window resolution and handed to `Renderer:setWorldOverride`, the same
  seam the Gen 1 voxel pipeline uses. The UI plane, warp fades, SHADER FX
  and present pipelines all composite on top unchanged.

It falls back to the vanilla flat frame during battle transitions, the shop
camera and the Seagallop scene. A frame that throws is drawn flat. Three
failures in a row switch the mode off for the session and log the reason.

If the engine ever composites `drawWorld` on Gen 3, this can become a
normal `render_pipelines` record. The heightfield, mesher, camera and scene
modules don't know about the hooks.

## Files

| File | Job |
|---|---|
| `main.lua` | options, hotkey, install |
| `voxel/cells.lua` | reads Gen 3 map cells (primary map, connected maps, border) |
| `voxel/heightfield.lua` | cells → 4px voxel heights and art offsets (pure Lua) |
| `voxel/mesher.lua` | voxels → triangles with per-vertex art lookups (pure Lua) |
| `voxel/lighting.lua` | baked sun shadows and ambient occlusion per voxel (pure Lua bake) |
| `voxel/camera.lua` | view/projection, visible-ground bounds |
| `voxel/scene.lua` | shader, meshes, depth target, draw |
| `voxel/engine.lua` | sandbox-safe engine module lookup (require, cached) |
| `voxel/bridge.lua` | the two engine hooks and per-frame flow |

## Test

```sh
python3 tools/modkit.py validate mods/voxel_world_gen3
luajit mods/voxel_world_gen3/tests/voxel_world_gen3_test.lua
```

The test loads the mod through the real loader on a Gen 3 boot. It checks
the hotkey gating, the un-projection rules, termination at map borders,
greedy meshing and camera framing.

## Known limits (v1.0)

- Heights come from collision, not hand-made models. Big rock masses rise
  higher (40–56px) with rugged tops. Raised plateaus that
  are walkable (Mt. Ember terraces, Victory Road platforms) stay at ground
  level with their cliff faces standing as walls.
- Engine OAM field sprites (emote bubbles, field-move sprites) are laid on
  the ground plane under the player, the way TILT anchors them. They're
  close to their owner, but they aren't billboards.
- The grass-over-feet overlay and water reflections are baked into the
  ground texture rather than layered over characters.
- A jump's arc moves the character's shadow along the ground instead of
  lifting the sprite.
- RSE trees aren't recognized as trees by metatile id (FRLG's are). They
  still get leaf relief from their colours, but a lone RSE tree is a short
  bush rather than a full tree.


## Credits

- Built on [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) by
  bryanthaboi / BOIS CLUB GAMES, LLC.
- SOLID CHARACTERS follows the SLAB shape of
  [Voxel Characters](https://github.com/last-swagger/gen1recomp-voxel-characters)
  by **last_swagger** (Gen 1), carried forward to Gen 3 with their blessing.
