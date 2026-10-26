# Changelog

## 1.30.0

- Neighbours built ahead.  While you are on a map, the maps next to it are
  built too, in the background -- the nearest first, one at a time -- so
  walking across into one finds it ready: no rebuild, no pause, nothing
  changing shape at the seam.
  - Only while the frame has time to spare: paused the moment frames slow
    down (an average over 20 ms, or any frame over 33 ms in the last
    second), while the view itself is being rebuilt, and for the first
    few seconds on a new map.  Off on the lowest quality.
  - Walking into a neighbour that is still being built carries that build
    on where it was.
  - The current map always comes first: a neighbour's build gives way to
    it after a warp, Fly or Teleport, and is taken up again later.
  - Up to five maps are kept (three on the lowest quality): the current
    one and the maps around it go last.
  - FireRed/LeafGreen once the neighbour's tileset is loaded;
    Ruby/Sapphire/Emerald once most of its tiles have been seen.
  - New option BUILD NEIGHBOURS (on by default; BUILD AHEAD works without
    it, as in 1.29).
- Smoother background building, for whole maps and neighbours alike: every
  long pass over a whole map now gives the frame back -- judging a forest's
  or a mountain's hundred-cell runs, the light bake, the shores.  On a
  phone, the longest single slice of a build went from 40-110 ms to under
  8 ms.  What is built is exactly the same.
- Saving the learned tile art no longer re-encodes every tile ever seen (a
  60-110 ms hitch on a phone every save): only the new ones.
- Fixed: "VOXEL VIEW error (render: scene.lua:366: Cannot use object after
  it has been released)" and a few seconds of black screen, on a map built
  whole when the sun moved on (every half hour of the day) or a setting
  changed.
- Fixed: once a whole map had been shown, the view's own meshes were never
  drawn again until the next whole map -- rooms half black, or parts
  popping in and out, right after a door (also in 1.29).
- PERF STATS, a new line: "near: kept 4 maps (900k verts), built 3,
  building EM_ROUTE102 420 ms (paused: frame 24 ms)  last: EM_OLDALE_TOWN
  860 ms over 310 frames, worst 2.4 ms (mesh)  hitches 0/30s  frame 8.3 ms"
  -- maps kept, neighbours built, the one building (or why the next is
  not), the last one's cost and its longest slice (and in which part of
  the build), and frames over 33 ms in the last 30 seconds.

## 1.29.1

- Fences that run alongside a building or a row of trees are fences again,
  knee-high and cut out of the lawn: told by their tiles' outline (thin
  rails or posts drawn over the grass), not by what stands beside them.
  Route 7's fence by the Saffron gate stood up as a long raised slab of
  lawn.
- Stepping out of a building, the town's sides no longer stand black for
  half a second while the camera eases out of the room's zoom: the first
  mesh is built for the view the camera opens up to.

## 1.29.0

- Build ahead in Ruby, Sapphire and Emerald too.  Their tilesets' own art
  never matched what the screen shows, so the mod now learns each map
  tile's art from the screen: the first time a whole tile is on screen,
  its picture is kept -- and remembered on disk, so a tile seen once is
  known for good -- and stands in for the screen wherever that tile lies
  beyond it.  A map is built ahead once most of its tiles have been seen
  (on a first visit, after a short walk; after that, at once), and built
  again in the background when many more have been -- counting the
  margin into the maps around it too: Route 102 built before Oldale had
  been seen showed Oldale as a jumble of raised paths as you walked in.
- Walking across a seam into the next map (Route 104 into Petalburg,
  Route 102 into Oldale) no longer shows the town as a jumble of raised
  paths and flat buildings for a second or two.  Several things there are
  now checked before anything is built: that the game has handed over the
  new map's data (it names the new map a moment before), that the
  picture matches the tiles already known, and that a mesh started for
  the last map is not shown as this one's.  And right after a seam the
  view is not rebuilt at all while the new map's whole build is on its
  way: the last map's mesh stays up until it is ready.
- The view's own meshes use the learned art beyond the screen as well:
  checked on every Emerald map, far fewer cells change as you walk
  (Route 104: 57 to 11, Route 119: 47 to 16, Rustboro: 24 to 11).
- PERF STATS: "tiles seen 85%" on a map built ahead in these games, or
  why it is not built yet ("seen 40% of its tiles, needs 60%").

## 1.28.0

- Build ahead.  Until now the 3D map was rebuilt around you every few
  steps as you walked -- the work behind the stutter, and a little
  different every time.  Now, a few seconds after you arrive, the whole
  map (and a margin into the maps around it) has been built in the
  background, and from then on nothing is rebuilt while you stay on it:
  walking is only the camera moving.  It is drawn in pieces, only those in
  view.  The last three maps are kept, so going back is instant (through a
  door and out again, a town is there at once).
  - FireRed/LeafGreen outdoors, and indoors in every game.  Ruby,
    Sapphire and Emerald outdoors keep the rebuilding for now: beyond the
    screen they have no art to build from (FireRed/LeafGreen have their
    tilesets).
  - Maps up to about Saffron City's size; longer routes keep the
    rebuilding.
  - Until it is done, and past its edge, the view builds itself as before.
- New option BUILD AHEAD (on by default).
- PERF STATS: "whole map: in use, pieces 6/12, built in 2400 ms" (pieces
  drawn / all) or "whole map: building".

## 1.27.0

- Waterfalls.  A waterfall is no longer a flat strip of river between the
  cliffs: it falls from the cliff tops to the pool below as a sloping
  sheet of water, the game's own falling-water art laid on it and bright
  threads streaming down it, each at its own speed, whiter where it
  churns at the foot.  Where it lands, mist billows up and drifts off,
  drops of spray are thrown out and fall back, and froth spreads on the
  pool.  Route 119, Route 114, Ever Grande City, Meteor Falls, Victory
  Road, Cape Brink, Icefall Cave, Seafoam Islands and the Safari Zone.
  Surfing up one, you ride up its slope.
- New option WATERFALLS (on by default).
- Smoother walking (the stutter since 1.26.1, reported by Ayush).  Since
  1.26.1 every rebuild looks forty cells past the view, so that nothing
  changes shape as you walk -- and read every one of those cells afresh,
  judging each blocked cell by the 48 around it, every few steps: a
  rebuild took about twice as long.  The map's cells and what each one
  is are now remembered while you stay on the map, and the art tests
  are asked once per cell per rebuild.
- PERF STATS with a waterfall nearby: "falls N mN sN fN" -- waterfalls,
  mist puffs, spray drops, froth.

## 1.26.1

- Tall buildings -- seven cells deep or more, with a door in front (Lavender
  Tower, Silph Co., the big department stores) -- stand several storeys
  high, not capped at two: Lavender Tower stood lower than the hills
  around it, sunk into the mountain.
- A building set into a hillside is no longer part of the hill: Lavender
  Town's Poke Center had a long strip of roof running back into the rock.
- Indoors, staircases lie flat with the floor, and nobody vanishes on
  them: arriving downstairs at the start of the game, the player stood
  inside a wall-high box and disappeared.
- Trees, cliffs and buildings no longer change shape while walking (the
  rest of it, reported on FireRed and Emerald alike).  The map's art is
  read from a quarter-size copy of the screen, one pixel per 4x4 block --
  but blocks of the screen, which follows the camera pixel by pixel, so
  the pixel each block was read at moved with every step, and the pine
  crowns and cliff edges built from it came out a little different on
  every rebuild.  The copy is now aligned to the world's 4x4 blocks: the
  same pixel is read every time, wherever the camera is.  (The tileset
  art used past the screen's edge reads the very same pixels; that is
  FireRed/LeafGreen only now -- in Emerald it turned the forest north of
  Petalburg into tall striped walls.)  In FireRed/LeafGreen, once a
  tileset's art is seen to match the screen it is used everywhere, on
  screen too: the screen mixes in characters and animation frames, and
  Viridian Gym's roof changed shape as they came and went.
- And everything that still changed as you walked, found by building every
  map of FireRed/LeafGreen, Ruby/Sapphire and Emerald from many places
  along a walk through it and comparing: long forests and tree walls (the
  crown rounding and the dark rows between trees followed the edge of the
  view), long mountains and cave walls (judged rock, tree or wall by how
  much of them was in view), cliffs running into the border past the
  map's edge (Cape Brink, Four Island), the Safari Zone's tree lines, Rock
  Tunnel's walls, and the walls of big interiors (the Pokemon Mansion, the
  S.S. Anne) that changed height from room to room.  Emerald and
  Ruby/Sapphire read the screen world-aligned too now (their forests
  changed at thousands of cells), a tile judged foliage on screen stays
  foliage off it, and a forest standing on a cliff or behind a house is
  split from it: Route 119's trees stood as rock, and Route 104's flower
  shop with its trees as a green tower.
- Emerald's forests: no flat strips of trees (grass showing between the
  crowns) along the seams between maps, west and east of Petalburg.  The
  sliver of border tiles between two maps' edges was split off the forest
  as a run of its own.  The screen is also read at the very middle of each
  pixel now, not on the corner between two.
- Island coasts: the sea border around an island is remembered as sea,
  not a wall that came and went (One, Seven and Birth Island).
- Fireflies, birds, smoke, rain and cave dust stay over the map: on a
  phone whose picture leaves a band of black below the map (the touch
  buttons' area), fireflies glowed in that black too.

## 1.26.0

- Cave atmosphere.  In caves:
  - Dust hangs in the air, faint motes drifting and catching the light,
    most of them around you.
  - Now and then a drop of water falls from the dark above and lands with
    a little splash -- on cave water a ring that spreads out.
  - In a dark cave the Flash circle glows warm like a torch: golden toward
    its edge, dimming there, and breathing a little.
- New option CAVE ATMOSPHERE (on by default).
- PERF STATS in caves: "cavefx mN dN rN" -- dust motes, falling drops,
  splashes.

## 1.25.1

- The scene no longer changes shape as you walk (cliffs, trees and
  buildings deforming "here and there", reported on FireRed, PC and
  Android).  Many of the heightfield's choices -- rock or house, tree or
  wall, the relief on cliffs and treetops -- read the map's art, and that
  art came from a quarter-size capture of the screen: a cell near its
  edge, or past it, read differently from the same cell in the middle a
  few steps later, and every rebuild while walking reshaped it.  Where the
  capture has no picture of a cell, its art is now read from the tileset
  itself -- the same pixels the screen would show -- so a cell is judged
  the same before it comes on screen as after.  (Not for the border
  tiling beyond every map.)  A tileset's art is only used once it has been
  seen to match the screen (80% of samples), so a tileset whose art reads
  differently is never trusted.
- PERF STATS: after "art", each tileset seen and how well its art matches
  the screen ("sw": with red and blue swapped).
- PERF STATS: "art tN sM" -- art samples read from the tilesets / from the
  screen capture in the last rebuild.

## 1.25.0

- Grass that parts.  Tall grass stands a little taller, and bends away
  around whoever walks through it -- you, your follower, NPCs -- and
  flattens a little under their feet.  Where they just were it springs
  back over half a second, with a small overshoot, so a path through the
  grass ripples closed behind you.  Comes with SWAYING TREES.
- The forest pattern test (1.24.1) runs in FireRed/LeafGreen only: in
  Ruby/Sapphire/Emerald, whose forests already came out right, it turned
  Petalburg Woods into one block of tree tops.
- Wilds of Hoenn: its wild Pokemon now leave footprints too (sand, ash,
  wet prints out of puddles -- their own mod draws their wake in the
  water).  Being characters of the scene, they already stood up in 3D
  with shadows, the day's light and night lamps, reflections in the
  water, cloud shadows passing over them, and now part the tall grass.

## 1.24.1

- Mountains and rocky hills no longer change shape as you walk (FireRed's
  Lavender Town and Route 8 showed it most).  Whether a block is rock or
  a house was judged from the map's picture, which is only there near the
  camera: the far columns of a mountain came out as houses with roofs,
  then turned to rock once on screen, every few steps.  A tile judged rock
  once is now remembered as rock, everywhere and every time after.
- Forests are also found by their tile pattern (a tree is two cells by two)
  or by a crown drawn over sprites (FRLG), not only by the FRLG tree list
  or a green colour -- trees in a tileset of their own, whatever colour.
- PERF STATS: "ptree N/C/K" -- forest cells found by pattern, cells
  matching it, cells with a crown over sprites.

## 1.24.0

- Waves & shorelines:
  - Foam along the water's edge, wherever the sea, a lake or a river meets
    sand, grass, rock or a pier, gently breathing.
  - Every few seconds a wave rolls in: a line of foam that runs up to the
    shore and fades, the timing varying along the coast.
  - Surfing (and anyone swimming) leaves a wake: ripples of foam either
    side of the path, spreading out as they fade.
  The foam is lit by the hour -- by night a pale grey, still lighter than
  the dark water around it -- and needs SUN SHADOWS on (it
  rides the same light bake); the wake comes with FOOTPRINTS.
- New option WAVES & FOAM (on by default).

## 1.23.0

- Clouds & stars.  Outdoors under an open sky:
  - By day, soft cloud shadows drift across the land with the wind --
    over the ground, the walls and roofs, and the people walking about.
    Stronger wind, faster clouds.
  - Clouds drift across the sky above the far edge of the map, tinted by
    the hour (warm at sunset).
  - At night the sky fills with twinkling stars, and they shine in the
    sea, ponds and rivers too, trembling with the waves (the sky itself
    is often off the top of the screen).  The moon's cloud shadows drift
    over the land, fainter.
  Not indoors or in caves, and not in rain, snow or falling ash (their
  own grey sky).
- New option CLOUDS & STARS (on by default).

## 1.22.0

- PERF STATS indoors: "room hH dD wW sS fF eE" -- wall height, wall rows,
  wall and side-wall columns, furniture pieces, open-edge wall pieces.
- Interiors rebuilt as a dollhouse:
  - The back wall stands as one wall, all of it the same height, its art
    upright -- no longer a short strip whose pieces stuck out wherever a
    cabinet stood against it.
  - The side walls stand as tall as the back wall.
  - Furniture stands up as boxes as tall as its art: a cabinet or a
    bookshelf against the wall rises as far as its picture reaches up the
    wall, a pot is knee-high, a table low.  The height is read from the
    art (where the wall or floor pattern behind it starts again), so it
    works in every house, shop and centre without a list.
  - The floor lies flat.
  - Walls stand a storey above their art (the top of the picture held),
    so the room reads as a box you look into; their tops are cut dark,
    like a dollhouse's.  An alcove whose picture fills the wall above it
    (a tokonoma, the arch behind a Poke Center counter) is the wall
    stepping forward.
  - Open sides closed: most rooms have no side walls on the map (the floor
    runs to the black), so a thin wall stands along each open edge,
    showing the back wall's bands and trim running on round the corner.
  - Room lighting: light from high up toward the back wall -- furniture
    throws a soft shadow forward, the back wall a band along its foot,
    and the floor darkens toward the walls and corners (with SUN SHADOWS
    on).
  - CAMERA TURN now works indoors too, and rooms are seen from a flatter
    angle (ten degrees lower), so wall faces and furniture fronts show.

## 1.21.0

- Footprints.  Characters leave prints where the ground is soft, a pair
  every half a cell, left and right foot in turn, fading after a while:
  - Sand: NPCs, your follower and other characters walking on the
    beaches and the desert now leave prints too.  (Your own the game
    already draws.)
  - Ash: on Route 113, under the falling ash, everyone leaves grey prints
    on the open ground -- you too.
  - Wet: out of a puddle or shallow water, a few dark wet prints on the
    dry ground after you, drying within seconds.
  - On a bike you leave a tire track instead: one line of marks.  (In
    sand the game draws its own.)
  The ground is read from the metatile behaviour, the same sand, puddle
  and shallow-water values the game's own footprints and splashes use.
  Prints follow the game's own characters (its objects, you and your
  follower) by name and position.  Only characters leave prints -- not the game's grass, ash-puff and
  splash effects -- and never while standing still.
- New option FOOTPRINTS (on by default).
- PERF STATS: "prints N +R wW mvM fxF top ..." -- footprints on the
  ground, laid in the last second, characters followed, of them walking,
  field effects skipped, and who walked furthest in that second.

## 1.20.0

- Chimney smoke.  Houses get a small brick chimney on the front slope of
  their roof, toward one end, standing up above the ridge; soft grey puffs
  rise from it, swell, lean away with the wind and fade.  More smoke on a
  rainy or snowy day (a fire is lit).  The smoke takes the time of day's
  light -- warm at sunset, dim at night.
  - Homes only: roofs two to seven cells wide.  Poke Centers, Marts, gyms
    and the big buildings have none.
  - Most houses have one, chosen by where the house stands, so the same
    houses always do.
  - Walking about (the 3D rebuilding every few steps) keeps the smoke in
    the air; at night it is lifted out of the moonlight so it shows
    against the streets.
- New option CHIMNEY SMOKE (on by default).
- PERF STATS: "smoke C/P vN" -- chimneys, puffs in the air, chimneys in view.
- Fixed: Slateport's fountain glowed at night like a lit window.  A
  building is now a block with a door in it -- its walls light their
  windows -- instead of anything with a roof or two storeys tall; a
  fountain, a statue or a sign has no door.

## 1.19.0

- Fireflies and birds.
  - At night, fireflies drift over grass, shrubs and trees: soft round
    glows with a hot core, each pulsing on its own beat, wandering and
    bobbing, fading in through dusk.  Up to sixty in view.
  - By day, every 3 to 8 seconds a small flock (three to five) flies up
    (flocks may overlap)
    out of a tree near you, wings flapping, and climbs away across the map.
- PERF STATS: "crit F/B fN" -- fireflies and birds in view, flocks so far.
  - Both live where the swaying foliage is, so they keep to grass and
    woods; none in towns' paved squares, indoors or in caves.  Rain,
    snow and ash keep them away.
- New option FIREFLIES & BIRDS (on by default).

## 1.18.1

- Faster warps.  Entering a map builds its 3D in one go behind the
  warp's fade, and the game waits for it: in a dense forest like
  Petalburg Woods that stretched the black screen by half a second on a
  phone.  About half of that is gone:
  - The warp builds what the camera sees plus two cells, not the usual
    five-cell margin; the background job grows it from the next frame.
  - The light bake (ambient occlusion and sun shadows) reads the heights
    directly instead of through a call per neighbour, and skips voxels
    with nothing higher around them.  Same result, a third of the time
    on a phone, where Lua runs without its JIT.
  - The heightfield remembers which cells are building/forest structure
    (asked again and again by the column runs), keeps its colour samples
    flat instead of a table each, and only searches for "impassable lawn"
    around tiles that actually appear on walkable ground nearby.
- Nothing looks different.

## 1.18.0

- Swaying trees and grass.  Tree crowns, the canopies over paths, leafy
  shrubs and tall grass move gently in the wind, the higher the more, each
  spot on its own rhythm so a forest ripples rather than rocking as one.
  The wind follows the weather: a light breeze on a fair day, stronger in
  rain and snow, a gale in a thunderstorm or downpour, and it eases from
  one to the next over a few seconds.  Trunks stay rooted; houses, fences,
  signs and posts stand still.  Done on the GPU from each vertex's
  position, so neighbouring faces move together and never come apart;
  reflections sway with them.  Outdoors only.
- New option SWAYING TREES (on by default).

## 1.17.0

- Water reflections.  Ponds, rivers and the sea mirror what stands beside
  them: trees, houses, rocks and characters (upside down, under their own
  feet).  The scene is drawn a second time flipped through the water's
  surface, at half size, and the water shows it at each pixel, swayed by
  the same waves as its art.  Only what stands above the water is
  mirrored.  At night the reflections are dark too and carry the lit
  windows and lamps.
- New option REFLECTIONS (on by default).  The extra pass is only drawn
  when the view has water in it.
- PERF STATS counts reflected frames ("refl") where there is water.
- Fixed: crossing from a town into the next route at night, a ghost of
  the town's lamplight showed out in the fields for a moment (the flat
  map shown where the 3D has not reached yet took the light bake's pools
  in the wrong coordinates).  Night light now falls on the 3D ground and
  characters only.
- Fixed: a tall dark wall standing out in the sea west of Route 115
  while you walked up from Rustboro.  It was a sliver beyond both maps'
  edges, filled with the current map's border tile (Rustboro's is
  forest); border beside a neighbouring map's water now lies flat as
  that water.  (And the sea closed off at a map's edge with the water
  tile, collision set, lies flat as water like impassable lawn does.)
- A neighbouring map counts as a town (street lamps) by its own header
  type, remembered from when it was the current map and kept in the mod's
  cache; one never visited is not taken for a town (the engine's "kind"
  calls routes towns too).
- (Each shader uniform belongs to one stage: one shared by both stages
  failed to link on phones, whose stages differ in default precision.)

## 1.16.0

- Night lights.  As it gets dark (with DAY/NIGHT on), the town lights up:
  - Windows glow warm: on a building's walls, small glass-blue panes in a
    frame turn to lamplight.
  - Street lamps cast a soft pool of light around their foot.
  - Doorways spill light onto the step in front of them.
  - The light comes on through dusk and goes out through dawn.  It falls
    on the ground and fades a storey up the walls; characters standing
    in it are lit too.  It adds a little warm light of its own, so a lawn
    under it turns golden.
- How light sources are found -- from the game's own data, not from how
  the screen looks:
  - Street lamps by their TILE.  The engine keeps every tileset's
    metatiles as full-size images, the ground layer apart from the object
    layer on top of it.  A metatile whose top-layer object is a thin
    upright post, clear of the tile's sides, is a lamp post -- read once
    per (tileset, metatile), so every lamp built from that tile is lit
    alike, in FireRed/LeafGreen and Ruby/Sapphire/Emerald, with no list
    of maps or tiles.  On the map the post must stand free below (a
    fountain's spout stands in its basin) and above, unless that is its
    own head (a vertical fence runs on through both).
  - Only in towns and cities (the map header's map type, judged for each
    cell by the map it belongs to): routes have no street lighting, and a
    town's lamps stay lit while you look at it from the route next door.
  - Doorways by their metatile BEHAVIOUR: the animated door houses, marts,
    Poke Centers and gyms use.  Arrow warps at a route's edge, cave
    mouths, holes and ladders share the door collision and are not lit.
  - Windows only on buildings: under a roof, or (in towns) a block a
    storey and a half tall -- a fountain's water, a waterfall or a blue
    sign is glass-blue too.
  - Where a tileset has no layer split to tell by, lamps fall back to the
    older guess from the screen picture, remembered per map in the mod's
    cache once seen.
- New option NIGHT LIGHTS (on by default).
- PERF STATS: "lights L(tT aA)/D" -- L lamps, T of them known by their
  tile, A by the fallback guess, D lit doorways.

## 1.15.0

- Camera turn.  The camera can swing round to the left or right of the
  player (15 or 30 degrees) to look at the diorama from an angle and see
  behind houses and trees -- the sides of buildings come into view.  It
  eases into the new angle; north faces stay hidden as before.
  Indoors the camera stays straight: a room has nothing behind its walls
  to see, and turned it only showed the cut ends of the side walls.
- New option CAMERA TURN: LEFT 30 / LEFT 15 / STRAIGHT (default) /
  RIGHT 15 / RIGHT 30.  On a keyboard, 7 cycles it live.
- Characters stand in a plane facing the camera however it is turned.
- Indoors, the floor reaches the exit.  The black around a room was
  raised like a wall, a storey tall along the room's open south side, and
  hid the floor's last row and the exit mat: the player arriving at the
  door seemed to stand in the dark.  The black now lies flat, and a black
  exit cell shows the floor tile above it.

## 1.14.0

- Characters breathe.  Everyone on the map -- you, your follower, NPCs,
  Pokemon -- rises and settles by a fraction of a pixel, scaled from the
  feet, each on their own slow clock so a crowd never breathes in step.
  After last_swagger's Voxel Characters (Gen 1), which does the same.
- New option BREATH: OFF / SUBTLE (default) / NORMAL.
- Characters blink, every few seconds each on their own clock.  Gen 3's
  sprites have no marked eyes, so the eyes are found by their shape while
  a character blinks: in the face, a short dark stroke (up to 4 pixels
  tall and 2 wide -- RSE draws an eye as a dark-grey pixel over black ones)
  with face above, below and beside it is painted over with the face above
  it.  Hair, hat brims and outlines run on longer and are left alone.
- New option BLINK (on by default).
- PERF STATS counts the frames characters had their eyes shut ("blink").
- The shader works out atlas coordinates in high precision where the GPU
  has it: in a phone's medium precision a one-pixel step across the
  character atlas rounded away.

## 1.13.2

- Volcanic ash (Route 113, Fallarbor Town) is easy to see: big pale
  flakes (4px) instead of specks that, with the camera pulled back, were
  no bigger than the ash already painted on the ground.  The small grey specks were lost against
  the ash-covered ground, above all at night.
- Snow flakes are bigger too, and raindrops thicker and longer.
- Falling weather catches more light than the ground, so rain, snow and ash
  stay visible at night.

## 1.13.0

- 3D weather.  Rain, thunderstorms, downpours, snow and Mt. Chimney's
  volcanic ash now fall through the 3D scene -- in front of and behind
  buildings and trees, hidden by what stands in front of them -- instead of
  being painted over the map, where they ran down every wall and roof.
  - Rain darkens and cools the light; thunderstorms add lightning flashes;
    ash gives the air a dusty grey.
  - Weather fades in and out with the game's own.
  - It follows the time of day (rain at night is dark rain).
  - Fog, sandstorms and the like stay the game's own overlay.
- New option 3D WEATHER (on by default; OFF brings back the game's flat
  weather).
- PERF STATS shows the weather being drawn ("wx rain").

## 1.12.0

- Water with depth.  Sea, rivers and ponds lie lower than the land (6px,
  was 2px), so every shore has a bank going down to the water -- earth in
  shade -- and the water reads as sitting in the land rather than painted
  on it.  The banks also darken the water right along the shore a little.
- The water surface moves: its art sways a pixel or so in slow crossing
  waves and catches the odd glint, on top of the game's own animated water.
- Surfing rides on the lower water; rocks in the sea stand on it.

## 1.11.1

- Moonlight: nights wash the colours out and light them a soft cool blue,
  instead of painting everything blue (brown rock came out purple).  Rock
  is grey-blue at night, grass a dark blue-green.

## 1.11.0

- Day and night.  Outdoors, the light follows the time of day:
  - the sun rises in the east and sets in the west, so shadows fall west in
    the morning, short around noon, and long to the east in the evening;
  - warm light at sunrise and sunset, plain daylight in between;
  - blue, darker nights without sun shadows, with a night sky;
  - everything fades smoothly from one to the next; the shadows move every
    half hour, rebuilt in the background.
- New option DAY/NIGHT: GAME CLOCK (default -- the clock you set in Ruby,
  Sapphire and Emerald; FireRed/LeafGreen have none and use the device
  clock), DEVICE CLOCK, or OFF (always midday, as before).
- Indoors and in caves nothing changes.
- PERF STATS shows the time the light is following.

## 1.10.24

- The last teal holes along Rustboro's forest edge are filled: a lawn cell
  between two trees counts as closed in when a tree stands on a third side
  as well (a real path is open on both of its sides).
- No more "cave mounds" in towns.  Ruby, Sapphire and Emerald use the same
  door behaviour for cave mouths and for some buildings' doors; a block is
  a cave mound only when the column over its mouth is rock.

## 1.10.23

- Rustboro's forest edge, third try: the lawn cells between the staggered
  edge trees can be walkable ground too (closed in by the next column of
  trees and the fence), which the gap fill skipped.  A lawn cell between
  two trees is now filled whether it is walkable or not -- unless it is a
  real path, i.e. it continues as lawn on the open sides.
- PERF STATS shows how many forest gaps were filled ("gaps").

## 1.10.22

- Rustboro's forest edge, properly this time.  The staggered lawn cells
  between the edge trees carry the "cave floor" tile behaviour, which the
  3D view took for a doorway: it glued each column of edge trees into one
  long flat wall with teal steps, and made the forest beside it a "cave
  mound".  Those cells are plain ground now (filled in with leaves between
  two trees), and cave mouths are recognised by their own tile behaviour
  only.

## 1.10.21

- No more holes in forest edges.  Ruby, Sapphire and Emerald stagger the
  trees along a forest's edge, leaving impassable lawn cells between them
  (Rustboro's east side); those lay flat as teal pits in the canopy.  A
  lawn cell with trees on both sides is now filled to the canopy, and the
  leaf-green fix covers it.

## 1.10.20

- Forests beside towns (Rustboro's east edge) are trees again.  A cave
  mouth was also recognised by the door collision value, which Ruby,
  Sapphire and Emerald use for ordinary doors and warps too: the forest
  next to one stood as flat "cave mound" columns.  Cave mouths now come
  from the tile behaviour alone whenever the map has it, and a forest
  running off the bottom of the screen is judged by the part that is
  visible.
- Fountains, statues and other small stone things (up to 3x3 cells, no
  door) stand low and are cut out of the paving around them, instead of
  standing as a box with the square's corners raised around them.

## 1.10.19

- Characters no longer vanish after walking from a route into a town (e.g.
  Route 104 into Rustboro).  For a few seconds after a map border -- until
  the 3D view had rebuilt in the background -- every character, the player
  included, was hidden: the check that keeps characters off the sky past
  the built terrain compared the new map's coordinates with the old map's.

## 1.10.18

- Walking up to an NPC no longer draws the NPC over you.  An NPC standing
  right in front of you (one cell north, same column) was mistaken for the
  player mid ledge-jump: it was pulled onto your spot and lifted into the
  air, so it covered your character.  Only the player can be mid-jump now,
  and only when nobody stands on the player's spot.

## 1.10.17

- Jumping down a ledge no longer cuts a band across your character.  Mid-
  hop the feet are on the ledge's own cell, and the top of the ledge's low
  lip stood in front of the sprite; the sprite now stands at the ledge's
  front edge while it is on it.

## 1.10.16

- No more blink when walking from a route into a town (or any map
  border).  For the frame or two in which the game hands over to the next
  map, the 3D view could not draw and showed the flat map (or nothing)
  instead.  It now keeps the last 3D picture up through those frames
  (at most half a second; a real stop -- the mode switched off, a shop --
  still goes flat at once).

## 1.10.15

- Caves have levels.  The raised parts of a cave (the ledges and
  platforms you reach by stairs) now stand one level up, read from the
  map's own elevation data, and each cliff is exactly as tall as the floor
  on top of it.  Before, every floor was flat and every cliff stood a
  storey tall in front of it: cliffs blocked the view of the floor behind
  them, and walking up the stairs looked like walking into the wall.
  Characters on a raised floor stand on it, and the camera rises with you.
  Outdoors nothing changes.

## 1.10.14

- Dark caves (Granite Cave before Flash): the lit circle is clean.  The
  darkness used to be painted into the map art, so in 3D it followed the
  art up every wall: the circle's edge was ragged, with pieces of wall
  sticking out into the dark and notches cut into the floor.  The 3D view
  now cuts the circle itself, by where things stand: a clean circle on the
  ground, and every wall inside it lit whole.

## 1.10.13

- The sides of forest blocks show leaves instead of long stripes.  A side
  wall smeared one column of the tree art all the way down the face (very
  visible along narrow paths between two forests, e.g. Route 103); it now
  slides the art across the face the way rock walls do.

## 1.10.12

- RSE sloped roofs keep the art as the game draws it.  The ridge stands
  up toward the camera, which squeezed the back half of a roof: the Poke
  Center's and Mart's logos were pushed up and shrunk.  The roof now shows
  the art where the flat top showed it on screen, so only the light and
  the outline tell the slope.

## 1.10.11

- Sloped roofs cover the whole house.  A house's pale light band made the
  columns it covers look like a cliff to the colour test, so they were left
  flat (with rock walls) beside the sloped part of the roof: the step in
  the light band on RSE houses.  A "cliff" column right beside a roof, of
  the same depth and height, now joins that roof.

## 1.10.10

- RSE houses get one roof each (PERF STATS showed 5 roofs for Oldale's
  two houses and the lab: each house was split in two).  The part of the
  house without a roof showed the flat art beside the sloped part, which
  is the step in the light band.  Ruby, Sapphire and Emerald roofs no
  longer split by colour, and roofs on one front wall are joined even when
  part of the house reaches further back.

## 1.10.9

- RSE houses: the roof art no longer jumps at a seam partway across (the
  light band higher on one side than the other).  These houses leave some
  top cells walkable -- the corners, and a cell here and there along the
  roof -- so their columns had different depths and each stretched the art
  its own way.  All columns of one building now share its top, unless the
  cells it would grow over show the lawn behind it.

## 1.10.8

- RSE houses, again:
  - A house's roof is no longer split in two down the middle (which left a
    dark gable, or a fold, through the light band).  The column-by-column
    colour check could trip on a lighter patch mid-roof; roofs of the same
    depth whose overall colours match are now joined.
  - The gable-trim columns at a house's sides take the house's height even
    when the corner is up to two cells shorter (it was one), and only a
    building's outer columns are adjusted.
- PERF STATS: the second line shows how many sloped roofs are built and
  which way they ridge (ew / ns), to help tell what a house is doing.

## 1.10.7

- Ruby, Sapphire and Emerald houses:
  - Sloped roofs now ridge east-west, the way RSE draws them (the yellow
    trim down a house's sides is its gable ends).  The roof art is no longer
    folded down the middle, which bent the house's light band into a V.
    FRLG keeps its north-south ridge.
  - A house's corner columns no longer stick out as a notched strip down
    each side: where the top corner is walkable, that column used to stand
    a cell shorter and stretch the art differently from the rest.

## 1.10.6

- The wall of trees around a town (Oldale, Littleroot...) is trees again,
  not a plain green block.  Whether a block is foliage was decided by its
  southernmost cells, and a forest running off the bottom of the screen has
  no art there yet, so it never counted.  It now gets the round tree tops
  and the leaf-green fix like every other forest.

## 1.10.5

- Houses in Ruby, Sapphire and Emerald get one roof again.  RSE draws the
  eave trim down a house's sides in a different colour, and the roof was
  split there: the house came out as three roofs side by side, each edge
  column with a tiny gable of its own.
- The leaf-green fix for the teal between tree crowns now covers dense
  forests too (the solid walls of trees around towns like Oldale), not only
  forests with walkable tree tops.

## 1.10.4

- Emerald, Ruby and Sapphire forests: the teal background RSE draws between
  its round tree crowns turns deep leaf green on the forest canopy, so a
  forest reads as one dense wood instead of rows of bushes with holes.
  Only tree canopies are touched; the mint town ground keeps its colour.
- Battles no longer flash the flat 2D map during the screen transition: the
  last 3D picture is held under the wipe, the way the game freezes the
  overworld.
- Fix: with sun shadows off, the walls of blocks could draw see-through.

## 1.10.3

- Emerald, Ruby and Sapphire forests are one continuous canopy.  With round
  trees on, every tree used to get its own dome, and since RSE draws each
  tree as a round crown on a teal background the forest looked like a
  pegboard of separate bushes with holes between them.  Now the crowns join
  up, and only the forest's outer edge is rounded.  FRLG forests are
  unchanged.

## 1.10.2

- Trees in Ruby, Sapphire and Emerald: forests no longer turn into a grid of
  separate bush boxes with flat green strips between them.  FRLG trees are
  known by tile id; RSE has no such list, and its forests alternate a solid
  trunk row with a walkable treetop row.  A walkable cell with busy foliage
  art right above a solid leafy cell is now taken as that tree's top, so
  each tree stands whole and gets the round crown.
- Internal: the heightfield keeps its own copy of every map cell it marks.

## 1.10.1

- Cave walls (Granite Cave, Mt. Moon...) stand 24px instead of mountain
  height.  The cave art already draws the cliff face; stretched down a 48px
  wall it turned into long rock "teeth" along every ledge.
- Solid characters stay solid under INDOOR ZOOM: the body's layers are a
  third of a pixel apart instead of one, so zoomed in they no longer show
  as stripes across hats and heads.

## 1.10.0 -- solid characters

- SOLID CHARACTERS (new, default SLAB): characters are no longer flat cards.
  Each one gets a body a few pixels deep made of its own sprite, with
  darkened sides -- from the tilted camera a dark top edge on hats, heads and
  shoulders.  OFF / THIN (2px) / SLAB (3px) / THICK (5px).
- The idea and the SLAB look come from **Voxel Characters** by
  **last_swagger** for Gen 1, carried forward to Gen 3 with their blessing.
  This version builds the body on the GPU (stacked layers of the sprite), so
  it costs no per-frame sprite read-back and runs on POTATO too.

## 1.9.12

- Renamed to **Voxel Diorama (Gen 3)**.  The mod id stays
  `voxel_world_gen3`, so existing installs and settings carry over.
- manifest: github = Tooandorisu/Voxel-Diorama.

## 1.9.11

- Character shadows moved a little further under the feet: the sprites'
  feet are drawn a couple of pixels above their tile's edge, so the shadow
  still showed a sliver of gap in front of them.

## 1.9.10

- Character shadows sit right under the feet.  They were centred 4px south
  of the feet, which from the tilted camera showed as a dark blob floating
  below each sprite.  Slightly smaller too.

## 1.9.9

- Indoors (the S.S. Anne cabins), one-cell-wide walls beside the black void
  stay whole walls.  The outdoor fence rules (knee-high, cut out of the
  ground) were applied to them too, leaving only a few stray specks.

## 1.9.8

- Cave mounds (Diglett's Cave, Rock Tunnel and the like) are low and flat:
  half height (16px), so their rounded art is barely stretched over the
  block and looks close to the flat game, with no spikes at the corners.

## 1.9.7

- The middle of the Diglett's Cave mound no longer sinks.  The cave mouth is
  walkable, so the column above it is a cell shorter than its neighbours: it
  got a lower height and was put through the small-object cut-out, which
  flattened it.  The outer columns' side walls stood up beside the gap and
  read as two spires.  Every column of a cave mound now stands at the same
  height and is never cut out.

## 1.9.6

- The Diglett's Cave mound is one plain, level block with its art on top.
  The spires came from the mod's own reshaping: parts of the top flattened
  by colour left tall slivers, and slanted rock wall texture made their
  edges look pointed.  Both are off for cave mounds.

## 1.9.5

- Cave mounds: the dark teal forest shadow around the mound also lies flat
  (only bright grass did), so the mound should lose the two spires of
  forest art on its top corners.
- PERF STATS "cave cols N flat M": M is how many voxels of the mound were
  flattened.

## 1.9.4

- The whole Diglett's Cave mound is now treated as rock, not just the three
  columns beside its mouth: the columns further out were still being shaped
  like round trees (the two spires).  The mound is followed sideways through
  its own solid cells, stopping at open ground and at the forest beside it.

## 1.9.3

- Cave mouths are looked for on every walkable cell, not only on cells with
  a door collision (the Diglett's Cave mouth seems to have none).
- PERF STATS shows "cave cols": how many rock columns were recognised as a
  cave mound in the current view.

## 1.9.2

- The S.S. Anne is no longer cut in half.  Each character was captured into
  a 64px-wide slot centred on its feet, and the ship is drawn from its left
  end, so everything past 32px to the right was lost.  Slots are now 160x96
  with room for big sprites.
- The Diglett's Cave entrance takes the shape it is drawn in: the parts of
  the block whose art is grass or trees (the upper corners around the mound)
  lie flat instead of stretching up into green spires.

## 1.9.1

- The Diglett's Cave entrance was never roofed: it was being shaped like a
  row of round trees (the grooves and pointed tips).  The forest around the
  brown mound showed in the corners the foliage test samples.  A cell now
  also has to be green on average to count as foliage, and any block with a
  cave mouth in or beside it is always level rock: no tree rounding, no roof.

## 1.9.0

- The Diglett's Cave entrance (third try): cave mouths are now recognised by
  their metatile behaviour (MB_CAVE_DOOR) instead of their collision byte,
  which the engine sets to the same door value as a house door.  A block
  with a cave mouth in or beside it never gets a roof.

## 1.8.9

- The Diglett's Cave entrance really loses its roof: a block with a cave
  mouth in or beside it (cave mouths have their own collision, 0x2B, unlike
  house doors) is a rock mound and never gets one.  1.8.8's colour test was
  not enough on the real art.
- No more long straight north-south steps across mountains and cave walls.
  Rock height used to grow with each column's depth (40/48/56px), so
  neighbouring columns of one rock mass stood at different heights.  All
  rock now stands 48px (relief still makes it rugged).
- Inside caves every solid mass three or more cells deep is cave wall, so
  the walls stand at one height instead of a patchwork of 32 and 48px.

## 1.8.8

- The Diglett's Cave entrance (and other rock mounds) no longer gets a house
  roof.  Whether a block is rock is now judged over the whole block and by
  each cell's average colour, so a dark cave mouth can't hide it.
- Rock side walls (caves, cliffs, mountains) slant the rock art down the
  face instead of smearing a single column of pixels into long streaks.

## 1.8.7

- PERF STATS has a second line: the map's type, kind and environment as the
  game reports them, how much of it is water or grass, and whether the view
  treats it as outdoors (sky, sun shadows, roofs).  Helps track down maps
  that get the wrong background.
- PERF STATS shrinks to fit narrow phone screens.

## 1.8.6

- The S.S. Anne harbour really gets its sky now: the cart calls it an
  indoor map, so 1.8.5's check never reached it.  A map marked indoor is now
  treated as outdoors when at least half of it is open sea or grass.  Caves
  and secret bases are never promoted; an indoor pool is far too small.

## 1.8.5

- The S.S. Anne harbour (and any map whose type says neither indoors nor
  outdoors) gets the sky, sun shadows and roofs when a fair share of it is
  sea or tall grass.  It used to fall back to the indoor black background.
  Caves, houses and secret bases are never affected.

## 1.8.4

- Chains of sea rocks (Vermilion harbour) no longer stand as tall blue
  blocks with a roof.  Rocks touching one another three or more deep were
  taken for a building.  A run of solid cells that mostly borders water is
  now always small things in the sea: knee-high, cut out of the water, no
  roof.

## 1.8.3

- Fixed a crash ("heightfield.lua:335: attempt to compare number with nil")
  near trees far into a connected map to the west or north, whose cells have
  negative coordinates.  The tree-gap search used -100 as "none yet", which
  a real row number could fall below.

## 1.8.2

- Round trees line up with the tree art.  The dip between one crown and the
  next followed a fixed two-cell rhythm, which drifts out of step with the
  art on long forest columns (the top art is squeezed to fit), so dips cut
  through the middle of trees and one tree's tip sat on the next one's
  crown.  The dips are now placed on the art's own dark rows -- the shadow
  where one crown meets the next.

## 1.8.1

- Sea rocks no longer stand on a raised square of water.  The water around
  a rock was compared with the open sea's average colour, which strong wave
  stripes and the darker ring drawn around each rock never match.  The
  background is now matched against every colour it shows, and in water
  anything clearly blue counts as water (on grass, anything clearly green
  counts as grass).

## 1.8.0 -- fences and sea rocks

- Small solid things -- fences, posts, signs, rocks in the sea -- are cut
  out of their background instead of filling their whole cell with it.
  Voxel by voxel, whatever looks like the walkable ground or water beside
  the cell lies flat with it; only the object stands.  Fences are posts and
  rails with grass between them, sea rocks stand in the water instead of on
  a raised blue square.
- Each raised voxel of a cut-out shows its own pixel of the art, top and
  sides, like extruded pixel art.

## 1.7.2

- Fixed: a house built right up against a forest (Vermilion, top right)
  came out ridged, roof / tree / roof / tree.  Wherever a tree trunk stood
  directly behind it, that column of house was taken for the forest's edge.
  A run of solid cells now never mixes tree trunks with anything else.
- Striped roofs are a little more tolerant of shade changes before a roof
  is split into two buildings.

## 1.7.1

- Striped roofs (light and dark orange) no longer break into a row of tiny
  ridges: buildings standing wall to wall are now told apart by roof hue
  (brightness divided out), not raw colour.
- Sun shadows include the roof ridge.

## 1.7.0 -- sloped roofs

- SLOPED ROOFS (new, on by default): buildings get a gable roof instead of
  a flat top.  The ridge runs front to back, so the roof folds left and
  right (the sunny west slope lighter) and a triangle stands over the front
  wall.  The roof art lies on the slopes exactly as it lay on the flat top,
  so the front edge still meets the facade.
- A building is a solid block three or more cells deep that is not trees,
  rock or a fence; outdoors only.  Buildings standing wall to wall get a
  roof each, split where the roof colour changes.
- A few quads per building: costs next to nothing.

## 1.6.0 -- round trees

- ROUND TREES (new, on by default): trees, bushes and hedges get rounded
  crowns instead of flat-topped blocks.  Each tree column drops away at its
  sides and each tree at its ends, so a forest reads as rows of crowns.
  How round follows VOXEL QUALITY: full domes on HIGH, crown edges and a dip
  between trees on BALANCED/AUTO, edges only on AUTO's third step, flat on
  POTATO -- rounding costs vertices.
- The lowered crown edges still line up with the trunk art on the front.
- Fixed: a forest running past the top of the captured view could be
  outvoted by the unseen part and stay a plain block (no leaf relief, no
  rounding).  Foliage is now judged by the cells nearest the front, like
  rock, and only where the art is on hand.

## 1.5.0 -- distance blur

- DISTANCE BLUR (new, on by default): the top of the screen, where the
  camera looks furthest away, grows softer, for a tilt-shift "miniature"
  look.  The lower part of the screen stays sharp.
- Done while the 3D picture is copied to the screen, in one pass that only
  works harder in the blurred band.  Off on POTATO and on AUTO's lowest
  step.

## 1.4.4

- Fixed: the middle of the Poke Mart (its sign) and of the Vermilion Gym
  (its door section) sank flat in 1.4.3.  Impassable lawn was found by
  comparing colours with walkable cells nearby, and a building can match
  the walkable row of its own roof.  It is now found by the map's tile id:
  impassable lawn is the same metatile as the lawn beside it, with only the
  collision changed, so buildings can no longer be mistaken for it.

## 1.4.3

- The flat-lawn test compares a solid cell with every walkable cell within
  three (not just the nearest, which is often a sand path), so strips of
  impassable grass beside fences and paths lie flat too.
- Fixed a cell cache that could mix up cells far outside the build window.

## 1.4.2

- Impassable lawn (the grass around a copse, map corners you cannot walk
  on) is no longer raised into a tall block of grass: a solid cell whose
  art looks like the walkable ground beside it stays flat.
- Sea in the map's border lies flat as water instead of standing as a tall
  block of water at the edge of town.
- Both used to cast large sun shadows (Vermilion City).

## 1.4.1

- Fences, hedges and rows of posts running north-south (one cell wide) are
  now knee-high like the ones running east-west.  They used to be built as
  two-storey walls because the height came from how far a run went north,
  and with sun shadows on they cast a wide dark band (Vermilion City).

## 1.4.0 -- sun shadows

- SUN SHADOWS (new, on by default): buildings, trees, fences, ledges and
  mountains cast soft shadows on the ground, falling to the lower right as
  if the sun were behind you on the left.  Ground hugging a wall or tucked
  between trees is shaded a little darker (ambient occlusion), which makes
  everything look more solid.
- Characters standing in a shadow are shaded with it.
- Indoors and in caves there is no sun, only the corner darkening.
- The light is worked out once whenever an area is built (in the background,
  like the mesh) and read from a small texture, so it costs almost nothing
  per frame and works on POTATO too.

## 1.3.0 -- smooth on low-end phones and PCs

- Leaf and rock relief is built in 8px bumps with three heights instead of
  one bump per 4px voxel.  On a forest-and-mountain view that is ~16x fewer
  triangles (91k -> 5.6k vertices), so meshes build faster, upload faster
  and draw faster, and much less memory is churned.  Mountains and trees
  still look bumpy.
- VOXEL QUALITY (new): AUTO / HIGH / BALANCED / POTATO.
  - BALANCED: 3D pass at ~1 MP, coarse relief.
  - HIGH: ~2 MP, finer relief.
  - POTATO: ~0.35 MP, 3D redrawn every other frame, relief in whole-cell
    bumps, and a shorter view north (less map captured and meshed).
  - AUTO (default) starts balanced and, while the frame rate stays under
    ~48 fps, steps down on its own: fewer pixels, then half-rate 3D, then
    the potato settings.  It only climbs back after 30 s at full speed.
- VOXEL RES AUTO now follows the quality's pixel budget (was a fixed 1.2 MP).
- PERF STATS also shows the quality tier, the 3D resolution and "1/2" when
  the 3D is drawn at half rate.

## 1.2.7

- No more striped bands behind buildings, tree rows, ledges and rocks at
  LOW (and MID) pitch.  The strip of ground behind each one, which the flat
  art never shows, used to be filled by smearing a single pixel row; now the
  building, tree block or ledge covers its whole footprint and its roof or
  top art is stretched across it.
- The walkable canopy row above an FRLG tree is part of the tree; a player
  walking there stays drawn (ghosted through the leaves) instead of being
  hidden like in a doorway.

## 1.2.6

- Characters beyond the north/south edge of the built terrain are no longer
  drawn floating in the sky strip.

## 1.2.5

- Fixed thin crack lines across mountains and other large flat surfaces.
  Merged faces meet at T-junctions that phone GPUs rasterise with
  pixel-wide gaps; every face now overlaps its neighbours by a hair.
- PERF STATS is drawn once per frame (no overlapping ghost text).

## 1.2.4

- PERF STATS: background rebuild time is shown on its own as "bg" (0 when
  nothing is building) instead of being counted in "3d".

## 1.2.3

- No more sky holes after crossing into a new area: the flat map is drawn as
  a ground plane just under the voxels, so anything the background rebuild
  has not reached yet shows flat instead of missing.
- While part of the view is uncovered, the background rebuild gets 9 ms per
  frame instead of 3 ms, so it fills in about three times sooner.

## 1.2.2 -- no more walking stutter

- The voxel mesh rebuild (measured at ~280 ms on a Galaxy S25+) no longer
  happens in one frame.  It runs as a background job with 3 ms per frame,
  started while you are still well inside the old mesh, which keeps drawing
  until the new one is uploaded and swapped in.  Only the first build after
  a warp is done at once, hidden by the fade.
- Walking across a seamless border (route <-> town) keeps the old mesh,
  shifted into the new map's coordinates, while the new one builds -- no
  freeze at every border.
- PERF STATS "mesh" is now the total rebuild work, spread over many frames.

## 1.2.1 -- performance

- 3D RATE (AUTO / FULL / HALF): on high-refresh screens (120 Hz phones) or
  when a frame takes over 12 ms, the 3D scene is redrawn every other frame
  and the last picture is shown in between.  The game still runs every frame.
- PERF STATS toggle: shows FPS and the mod's milliseconds per frame
  (capture, 3D draw, last mesh rebuild) in the corner.
- The view reaches less far north (560px instead of 900px): less map is
  drawn and meshed every frame, and the far edge is fogged anyway.
- The sky gradient reuses one mesh instead of allocating one every frame.

## 1.2.0 -- performance

- VOXEL RES has a new default, AUTO: the 3D pass is kept near 1.2 million
  pixels and upscaled, so a 1440p+ phone panel no longer renders at full
  native size (FULL is still there for desktops that want it).
- The flat field the voxels sample is drawn off-centre through FieldView's
  camera pan, so it covers what the north-looking camera sees instead of a
  square around the player -- on a tall phone screen roughly half the
  pixels, every frame.  Dark caves keep the centred canvas so Flash stays on
  the player.
- The art read-back for leaf/rock relief is taken from a quarter-size copy:
  1/16th of the GPU->CPU transfer that stalled phones on every rebuild.
- The 3D mesh is rebuilt less often (5-cell margin instead of 3).
- manifest: github = Tooandorisu/Voxel-World.

## 1.1.1

- SEE-THROUGH (on by default): the part of a character hidden behind a tree
  block, a roof or a cliff is drawn as a faint ghost through it, so you can
  always find yourself -- the 3D trees are taller than the GBA canopy that
  only ever covered your legs.

## 1.1.0

- Mountains: a deep run of rock (warm tan/pink rock art, 6+ cells north to
  south) now rises above the two-storey cap -- 40, 48 or 56px the deeper it
  runs -- with rugged per-voxel relief on top (LEAF RELIEF toggles it).
  Runs are measured a dozen cells past the view so heights do not change as
  you walk.  Outdoors and in caves only; house walls are never taken for rock,
  and roofs are told apart by colour.

## 1.0.9

- VOXEL ZOOM (100–200%): brings the camera closer everywhere, for phones
  where the field is otherwise tiny (there is no zoom key on a touch screen).
  INDOOR ZOOM still fits small rooms on top of it.

## 1.0.8

- Fixed: the player could vanish while hopping a ledge.  The hop draws the
  sprite higher up the flat screen, which read as walking north into the
  next structure (and got hidden like a doorway).  The player's feet now
  stay on the ground under the hop and the sprite rises into the air, with
  its shadow left on the ground.

## 1.0.7

- INDOOR ZOOM (FIT / OFF, default FIT): indoors the camera comes in until the
  room fills the screen width (or height), up to 3x, and keeps the room in
  frame instead of centring on the player.

## 1.0.6

- Indoor maps and caves get a black background instead of the outdoor sky.
  Indoors is now read from the cart's map type; the importer's `kind`
  defaults to "town", so it is only the fallback.

## 1.0.5

- Fixed: characters invisible on phones (only their shadows showed).  The
  billboard texture coordinates were carried pre-multiplied by clip w, which
  reaches the millions and overflows a mobile GPU's fp16 varyings, so every
  sprite pixel was discarded.  The weight is now normalised by the camera
  distance, and the varyings ask for highp where the GPU offers it.

## 1.0.4

- Character capture rewritten: the atlas is the flat view plus a strip of
  slots under it, so characters are moved into their slots by the billboard
  hook alone (no transform of our own that field code could undo), with
  scissor, shader, blend and colour mask reset for both capture passes.
- One-time self-check on the first frame with characters: if their sprites
  did not reach the atlas, an on-screen notice says so with pixel counts.

## 1.0.3

- Fixed: the view never drew in the real game.  Inside the mod sandbox
  `package.loaded` is an empty stand-in, so every engine lookup came back
  nil ("renderer module not loaded").  Lookups now go through require
  (voxel/engine.lua); a test guards against package.loaded creeping back.

## 1.0.2

- Falls back to painting the 3D scene into the world canvas (world-pixel
  resolution) when the Renderer has no setWorldOverride / frameRects, so it
  runs on builds that lack the Gen 1 pipeline seam.
- The "on but not drawing" notice now names the exact check that failed,
  plus the LOVE version and whether the override seam exists.
- Render/capture errors are shown on screen and in the mod manager feed,
  including when the view switches itself off.

## 1.0.1

- The view now says when it can't run instead of silently staying flat: an
  on-screen notice plus an entry in the mod manager's error feed, naming the
  reason (shader, mesh format or depth buffer), and a notice if it's on but
  the field keeps drawing flat.
- "VOXEL VIEW: MID" (etc.) shows briefly when the 3D view starts.
- World-pass detection no longer compares canvases (more robust on LOVE 12 / iOS).
- Depth buffer lookup also tries LOVE 12's texture-format API and more formats.
- Fixed the full-screen depth buffer being reallocated every frame.

## 1.0.0

- First release: 3D voxel overworld for FRLG and RSE.
- OFF / LOW / MID / HIGH views, hotkey 6, options for height, resolution,
  leaf relief and shadows.
- Oblique un-projection of collision runs: upright facades, roofs on top,
  doors cut into walls, FRLG trees standing on their trunks.
- Billboard characters with upright-plane depth; hidden in doorways and
  outside the Flash circle.
- Falls back to the flat frame on battle transitions, the shop camera,
  Seagallop, and on error.
