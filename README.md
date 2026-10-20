# Voxel Diorama (Gen 3)

A graphics mod for Gen1Recomp that turns the overworld of Pokémon FireRed/LeafGreen and Ruby/Sapphire/Emerald into a 3D voxel diorama: buildings, trees and cliffs stand up from the map, with sloped roofs, sun shadows, day and night, night lights, 3D weather, water reflections, swaying trees, fireflies and birds, chimney smoke, footprints in sand and ash, and rooms built as dollhouses.

Releases (the zip to install) are on the [Releases](../../releases) page. This repository holds the source.

## Layout

```
voxel_world_gen3/
  manifest.json        mod id, version, permissions
  main.lua             options and hooks into the engine
  mod.card             mod manager card
  README.md            options, for players
  CHANGELOG.md         what changed in each version
  voxel/
    bridge.lua         the frame: captures the flat map, builds and draws the 3D view
    cells.lua          reads map cells (collision, metatile, behaviour) from the engine
    heightfield.lua    turns cells and their art into voxel heights (buildings, trees, roofs, water...)
    mesher.lua         heightfield -> triangle mesh
    lighting.lua       baked sun shadows, ambient occlusion, night-light pools
    scene.lua          the shader and all draw passes (terrain, characters, reflections, weather...)
    camera.lua         camera (tilt, turn, zoom)
    daynight.lua       time of day: tint, sky, sun direction
    weather3d.lua      rain, snow, ash falling through the scene
    tiles.lua          street lamps found from the tileset's object layer
    critters.lua       fireflies and birds
    smoke.lua          chimneys and smoke
    footprints.lua     footprints and tire tracks
    engine.lua         engine module lookup inside the mod sandbox
  tests/
    voxel_world_gen3_test.lua
```

## Tests

The tests run inside a Gen1Recomp checkout (they load engine modules such as `src.mods.Sandbox`). Copy `voxel_world_gen3` into the checkout's `mods/` folder and, from the checkout's root:

```
luajit mods/voxel_world_gen3/tests/voxel_world_gen3_test.lua
```

## Packaging

From the folder that contains `voxel_world_gen3`:

```
zip -qr voxel_world_gen3.zip voxel_world_gen3 -x '*/tests/*'
```
