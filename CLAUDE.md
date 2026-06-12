# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project layout

Three implementations of the same maze game live side by side:

- **`godot/` — the Godot 4.6 native game. This is where active development happens.**
- `index.html` — original 2D browser game (frozen, kept working)
- `labyrinth3d.html` — original Three.js 3D browser prototype (frozen; the Godot game supersedes it)

## Godot game (`godot/`)

### Commands

Godot 4.6 is installed via winget (shell aliases `godot` / `godot_console`; full path
`%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\Godot_v4.6.3-stable_win64_console.exe`).

```
godot_console --headless --path godot --import                 # import assets / surface script errors
godot_console --headless --path godot -s tools/smoke_test.gd   # maze connectivity + boot test
```

**Run the smoke test after every change** — it validates all four maze sizes for full connectivity and boots the main scene through `start_game()` for 10 frames, which catches most script errors. (A `1 resources still in use at exit` warning at the end is a known artifact of the test's abrupt `quit()`, not a failure.) Visual changes still need the editor (open `godot/` and press F5) since headless can't render.

Audio WAVs in `godot/audio/` are pre-rendered by `py godot/tools/render_audio.py`, which reimplements the Web Audio synth from the HTML games (same note tables/envelope). Re-run it only if the music data changes.

### Architecture

Everything is built **in code** — `scenes/main.tscn` is a single root node running `game_manager.gd`; there are no other scene files. The scripts under `godot/scripts/`:

- **`game_manager.gd`** (root) — owns the state machine (menu → playing → won), builds the WorldEnvironment, camera, and all UI Controls in `_ready`, runs the first-person camera in `_process`, handles mouse capture (captured during play, released on menu/Esc, recaptured on click), difficulty presets, best-time persistence (`ConfigFile` at `user://best_times.cfg`), and audio players.
- **`maze_generator.gd`** — pure logic, `static` functions only: recursive backtracker returning `cells[y][x]` dictionaries with `walls: {N,S,E,W}`, portal placement, and an ASCII dump for debugging.
- **`maze_builder.gd`** — constructs the dungeon from maze data. Key invariants:
  - Walls are deduplicated via keys `NS:x,y` / `EW:x,y` and are `CELL - WALL_T` long; **pillar posts** (slightly fatter and taller) fill every lattice corner so no two faces are ever coplanar — this is the z-fighting fix, don't reintroduce overlapping wall boxes.
  - Each wall is a `StaticBody3D` + `BoxShape3D` + `MeshInstance3D` (the player moves by physics collision).
  - Wall-face decoration rotation convention: `rot` maps local **+Z** to the face normal; the torch assembly extends along **−Z** so it takes `rot + PI`. Getting this wrong puts lights inside walls.
  - Fire/ember particle resources are cached per builder and shared across torches.
- **`player_controller.gd`** — `CharacterBody3D`. Free movement (no grid): forward/back along the smoothed facing angle, continuous turning via held keys or mouse (yaw + clamped pitch via `look_pitch`). Grid position is *derived* from world position for the minimap/portal/win checks (proximity-based). Also owns:
  - The staff viewmodel (`_staff_root`): permanently parented to the camera (the game is first-person only; the wizard body model still exists but is hidden). Materials in `_staff_view_mats` use `no_depth_test` + high `render_priority` so the staff never clips through walls, plus a raycast-driven retraction near walls that triggers contact sparks.
  - **Wisps** — LMB shoots a blue-flame light that flies along the aim, parks before walls, then hovers/flickers. Capped at `MAX_WISPS` (oldest freed); only the newest `SHADOWED_WISPS` have shadow-mapped lights. Wisp/flame visuals are layered additive billboard quads with gradient textures — resources cached in `_*_cache` vars.
- **`minimap.gd`** — `Control._draw()` port of the canvas minimap (walls, visited trail, portals, goal, player dot + facing cone).

### Conventions and gotchas

- Grid cell `(x, y)` ↔ world `(x * CELL, 0, y * CELL)`, `CELL = 4.0`, walls `WALL_H = 3.6` tall.
- **Lighting policy: no ambient light at all.** Illumination comes only from torches, portals, the goal, the staff orb, and wisps. Every static light (torch/portal/goal) must have `shadow_enabled = true` or it bleeds through walls.
- The ceiling plane is one-sided (`flip_faces`, facing down). The third-person view is gone, but keep it one-sided anyway.
- PBR textures in `godot/assets/` are CC0 from ambientCG (JPG maps only — **don't add `.blend`/`.usdc` files, Godot tries to import them**). Materials use `uv1_triplanar` so texel density is independent of mesh size.
- `project.godot` is hand-edited (input map actions: `turn_left/turn_right/move_forward/move_back`); the user also edits it from the editor (window size etc.) — merge, don't overwrite.

## Browser games (frozen)

Serve statically (configured in `.claude/launch.json`): `python -m http.server 5500`, then open `http://localhost:5500/index.html` (2D) or `labyrinth3d.html` (3D). Both are fully self-contained single-file games (inline `<script>`, no build step; Three.js r128 from cdnjs in the 3D one).

Shared mechanics (also the origin of the Godot port): recursive backtracker `generateMaze` producing `walls:{N,S,E,W}` cells; two-layer movement (`player` logical grid position + `playerVis` lerping at 10 cells/sec, `moveQueue`/`heldKeys` buffering); portals teleporting to a random other portal with a 600 ms cooldown; Web Audio synthesized D Dorian melody, portal whoosh, and fanfare (`playNote`/`scheduleMelody`/`playPortalSound`/`playFanfare`); four difficulty presets (`easy` 11×11 … `legendary` 45×45). The 3D version is fixed to Easy and uses third-person tank controls.
