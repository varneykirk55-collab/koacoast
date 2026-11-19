# Koa Coast slope tool

Read-only developer view of where the island is too steep to leave as-is. It colors the Terrain3D height field by slope, can switch to elevation or both, and writes a map of the whole island. It does not sculpt, save, or otherwise change terrain regions, foliage, water, lighting, or the player.

## Turn it on

The `SlopeAnalysis` node sits in `scenes/KoaCoast.tscn` and starts **off**.

- In the inspector, check **Show Overlay** on `SlopeAnalysis`.
- While the scene is playing, press **F8**. Press F8 again to hide it and get the normal view back.

The keys below are handled inside `tools/slope_overlay.gd`. They are not project input actions.

| Key | Action |
| --- | --- |
| F8 | Show or hide the overlay |
| M | Cycle **Slope**, **Elevation**, **Both** (slope colors plus contour lines) |
| T | Toggle a top-down camera of the whole island. Escaping the overlay (F8) restores the previous camera. |
| `[` `]` | Lower or raise the steep threshold by 1° |
| `,` `.` | Lower or raise the gentle threshold by 1° |

`T` is only available while the overlay is visible. Threshold keys switch **Auto Thresholds** off so the numbers you set stay put.

## Colors

Defaults come from the player body in `player/Player.tscn`. That body has `floor_max_angle = 0.872665` radians (**50°**). The tool reads the value and does not change it.

| Class | Default | Meaning |
| --- | --- | --- |
| Green, gentle | under **15°** | 30% of the 50° walk limit. Comfortable ground. The controller's own flat-spawn test is about 11°. |
| Yellow, moderate | **15° to 35°** | Hilly, still under the walk limit, and the band most likely to need softening. |
| Red, steep | **35° and up** | 70% of the walk limit and beyond. Difficult. Anything at or above **50°** is unwalkable. |

The legend lists the percent of **land** (height at or above mean sea level, Y = 0) in each class, plus the share that exceeds the walk limit. Water is left transparent on the 3D overlay so the ocean still shows. The exported map paints the shelf in blue and the coastline in sand. Contour lines are every **25 m**.

Edit the cuts on the node:

- **Auto Thresholds** — on by default. Gentle = 30% and moderate = 70% of `floor_max_angle`, snapped to 0.5°.
- **Gentle Max Deg** / **Moderate Max Deg** — used when auto is off (the bracket and comma keys do this).
- **View Mode** — Slope, Elevation, or Both.
- **Contour Interval M** — elevation lines in Both and Elevation.
- **Hover M** — how far the drape sits above the ground (default 1 m).

## Map export

From the project root, with Godot 4.7:

```
godot --headless --path . --script res://tools/export_slope_map.gd
```

That writes:

- `docs/slope_map.png` — north-up island, slope classes, 25 m contours, legend, and the six worst steep spots
- `docs/slope_stats.txt` — the same numbers plus cluster bounds

`docs/` is marked with `.gdignore` so Godot does not import those files. The script only reads `Terrain3D` region height maps. It does not save the scene.

Screenshots of the overlay (needs a display; Xvfb works):

```
godot --path . --display-driver x11 --audio-driver Dummy --script res://tools/capture_slope_views.gd
```

## What the numbers mean

Slope at each 2 m sample is the angle whose tangent is the horizontal gradient, from central differences on the region height maps. A sample of those slopes is compared with `Terrain3DData.get_normal` and the heights with `get_height`. The comparison is printed in `docs/slope_stats.txt`.

Steep clusters are connected land cells on the real cliffs. Grouping starts at the walk limit and tightens (60°, 65°, 70°, 75°) if one component would otherwise swallow the whole ridge. A group needs at least 48 cells (192 m²). Groups are ranked by how much slope they carry above that cut. The map marks each group's steepest point. Coordinates are world X and Z in meters.

## Walkability pass

`tools/walkability_edit.py` softens mid-slope steps and cuts three approach valleys. It does not touch the shoreline (everything under 24 m), sea cliffs, the 80° faces, the recorded cliff points, or ground at or above 230 m. The original region files are in `backups/terrain_regions_pre_walkability/` with `SHA256SUMS.txt`.

```
godot --headless --path . --script res://tools/walkability_dump.gd
python3 tools/walkability_edit.py
godot --headless --path . --script res://tools/walkability_apply.gd
```

Foliage is not moved. Plants that were seated on ground which rose or fell are reported by `tools/walkability_validate.gd` and left where they are.
