# KoaCoast performance and hardware readiness

Baseline: merged main `3cec8c8` (Hydrogen integration audit). Measurements used
Godot 4.7.2, Linux, an AMD EPYC 9V74 worker with 9 reported logical CPUs, the
Compatibility renderer, and the Medium preset. The worker had no hardware GPU.
The headless and software OpenGL numbers measure different workloads and should
be read independently.

## Baseline and matched results

These are headless elapsed milliseconds per engine iteration with fixed 60 Hz
simulation steps. They include the fixture and are useful for relative CPU-side
comparison. Each short case measured 360 iterations. Each extended case measured
7,200 iterations, or 120 seconds of simulated play. Single-run tails include
host scheduling noise. Lower is faster.

| Scenario | Mean before / after | P99 before / after | Max before / after |
|---|---:|---:|---:|
| Coast, clear day | 2.56 / 2.46 | 5.26 / 5.17 | 9.26 / 5.80 |
| Dense jungle, clear day | 2.10 / 2.38 | 3.75 / 4.41 | 5.48 / 5.73 |
| Mountain, long view | 1.20 / 0.90 | 3.40 / 3.07 | 6.14 / 6.99 |
| Dense jungle, heavy rain | 2.28 / 2.30 | 3.48 / 6.45 | 4.38 / 69.21 |
| Night, campfire and wildlife | 2.12 / 2.38 | 5.41 / 4.00 | 23.72 / 16.08 |
| Eruption and ashfall | 1.80 / 1.98 | 3.55 / 4.92 | 5.04 / 21.86 |
| Tropical storm and eruption | 1.78 / 1.91 | 3.80 / 3.27 | 6.00 / 4.11 |
| Heavy rain and mudflow | 1.57 / 1.83 | 2.98 / 4.24 | 21.67 / 6.83 |
| Extended normal play | 2.33 / 2.20 | 5.13 / 4.82 | 18.22 / 28.73 |
| Extended combined stress | 2.08 / 1.86 | 5.19 / 4.18 | 21.84 / 62.42 |

The combined fixture adds a storm, eruption, seeded moving mud front, shelter,
campfire and wildlife threat while the player walks. Both versions walked
174.83 m, ended with 92.2 hunger, finished the mudflow, and survived save/load.
Normal play covered 182.44 m on both versions. The same weather and volcano
nodes stayed in service throughout. The dedicated hazard and movement suites
cover terrain contact and respawn independently. Both extended means and
P99 values improved, with worse maximum spikes. Several short cases also ran
slower, so this pass does not establish a uniform frame-time improvement.

| Targeted probe | Mean before | Mean after |
|---|---:|---:|
| Shoreline ambience lookup (3,000 locations) | 68.17 µs | 12.58 µs |
| Clear-weather presentation (3,000 locations) | 1.91 µs | 0.66 µs |
| Active ash surface tick (280 ticks) | 785.47 µs | 580.93 µs |

### Software OpenGL render sample

The matched coastal sample used Mesa llvmpipe at 640×360, Medium, and dummy
audio. There were 20 measured frames per version, so the observed P99 is also
the maximum. The rendered comparison covers this coastal camera. The other
matched scenario results above are headless.

| Coastal render metric | Before | After |
|---|---:|---:|
| Mean wall frame time | 930.84 ms | 959.86 ms |
| Mean throughput | 1.07 FPS | 1.04 FPS |
| P99 and max | 999.57 ms | 1,355.41 ms |
| Mean draw calls | 3,620 | 3,288 |
| Mean visible render objects | 3,936 | 3,604 |

Draw submissions fell about 9%. Mean software-rendered frame time rose about
3%, and the largest observed spike was worse. The software sample establishes a lower draw count. Gaming-PC frame rate
remains unverified.

## Changes

- Terrain shader skips deposit sampling without accumulated ash and gates
  animated emissive calculations to active glow inside the volcanic zones.
  Terrain LODs, map regions, collision mode and material blending are preserved.
- Undergrowth retains the current deterministic placements, MultiMeshes and
  shader fade. Tiles fully beyond that fade skip drawing while remaining loaded
  for gameplay. Leaf and canopy shaders skip gust calculations at zero wind.
- Shoreline audio searches pre-binned samples inside its existing audible range.
  Freshwater voice selection and audio levels stay on the existing paths.
- Rain skips roof-mask and particle-material updates while it is hidden.
  Volcano ash updates reuse cell coordinates and normalized wind, keep the
  deposit texture bound, and upload only when deposits change. Idle glow avoids
  redundant parameter writes.
- Shark detection shares one height sample per simulation tick, and skips that
  sample for players above the swimming threshold. Wildlife update cadence and
  attack logic are preserved. Shelter tests reject distant pieces before rotation.
- Base markers cache until placement, removal or reset. Hidden debug text stops
  formatting every frame, duplicate prompt text stops assigning, and build mode
  skips queries whose results it would discard.
- The existing F6 presets are also available on a focusable Survival Menu button
  and persist separately from world saves. Low / Medium / High use shadow
  distances of 900 / 1,800 / 2,400 m and terrain patch sizes of 32 / 48 / 64.
  Medium and High retain 640 rain, 115 local ash, 112 plume and 46 cinder
  slots. Low uses 384 rain, 70 ash, 112 plume and 30 cinder slots. These are
  capacities, not counts of active particles. Both settings and debug paths
  leave weather, ash and damage rates on the same simulation.

## Visual preservation

The shoreline suite reported identical heightmap and foliage-transform hashes
and counted 111,564 baked foliage instances across 1,131 MultiMeshes before and
after. The procedural placement rules and densities are unchanged. No terrain
geometry, waterway layouts, hazard stages or survival systems were removed. The
High preset keeps the original shadow distance, particle budgets and foliage
draw ranges. Medium reduces far shadow work while retaining nearby density.

## Regression results

All 12 existing suites exited successfully both before and after.

| Suite | Baseline | Branch |
|---|---|---|
| Integration audit | Pass | Pass |
| Terrain walkability | Pass | Pass |
| Gameplay loop | Pass | Pass |
| Hunger and thirst | Pass | Pass |
| Day/night and wildlife | Pass | Pass |
| Death and recovery | Pass | Pass |
| Tropical weather | Pass | Pass |
| Volcanic hazards | Pass | Pass |
| Kekoa movement | Pass | Pass |
| Freshwater geometry | Pass | Pass |
| Island audio | Pass | Pass |
| Shoreline and placement invariants | Pass | Pass |

Hydrogen’s walkability probe reported 25 seam hits without collision out of
188 route samples and 16 out of 87 grid samples on both versions. There were
zero interior misses on both versions. The graphics smoke test activated the
focusable menu button, confirmed Low budgets, preserved the hazard state, and
read the chosen preset back in a newly loaded scene. Physical controller input
was outside that test.

## Resource lifetime and limitations

Combined-stress static memory ended about 31 KiB below its starting value.
Normal play ended about 113 KiB higher, compared with 118 KiB on baseline.
Normal node count held at 5,667 throughout the optimized run. Combined-stress
nodes peaked at 5,676 and finished at 5,667, with one active physics object in
the final sample on both versions. The combined run averaged about 0.2 MB more
allocated static memory at the start than baseline. The cache and spatial
index trade a little memory for less recurring work.

Repeated scene teardown returned to one root node on both versions. A verbose
immediate headless quit traced the remaining diagnostics to Ogg Vorbis streams,
packet sequences and playback references. Some existing suites still print
that shutdown diagnostic. Explicit audio stop and scene teardown in the
benchmark completed without it. There was no evidence of accumulating scene
nodes or runtime audio playback leaks during the test window.

The machine has no hardware GPU. Separate GPU frame time, GPU memory, actual
Windows FPS, GPU driver compatibility and long-session performance beyond the
scripted two-minute samples remain unverified. Headless zeros for draw calls
and visible objects are unavailable observations. The fixed-step engine
process/physics timers returned stale or inconsistent values, so the table
uses elapsed iteration time rather than reporting those as subsystem timings.
Dense alpha-tested foliage, terrain shading and shadow cost remain the main
rendering candidates for a hardware trace.

Run from the repository root:

```sh
godot --headless --fixed-fps 60 -s tools/benchmark_island.gd
godot --headless --fixed-fps 60 -s tools/benchmark_island.gd -- --normal-only
godot --headless --fixed-fps 60 -s tools/benchmark_hotspots.gd
godot --audio-driver Dummy --resolution 640x360 --fixed-fps 60 -s tools/benchmark_island.gd -- --case=coastal_day
```
