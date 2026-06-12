extends Node3D
## Root game manager: builds the world (environment, camera, maze, wizard),
## runs the menu → playing → won state machine, UI, stats, audio, minimap.

const CELL := 4.0
const FP_EYE_HEIGHT := 2.1
const FP_LOOK_AHEAD := 4.0

const DIFFICULTIES := {
	"easy": {"cols": 11, "rows": 11, "name": "Squire", "portals": 2},
	"medium": {"cols": 19, "rows": 19, "name": "Knight", "portals": 4},
	"hard": {"cols": 31, "rows": 31, "name": "Champion", "portals": 6},
	"legendary": {"cols": 45, "rows": 45, "name": "Legendary", "portals": 8},
}

var difficulty := "easy"
var maze: Array = []
var goal := Vector2i.ZERO
var portals: Array[Vector2i] = []
var steps := 0
var start_time := 0.0
var game_active := false
var music_muted := true   # start muted by default

var builder: MazeBuilder
var player: PlayerController
var camera: Camera3D
var visited := {}

# UI
var stats_label: Label
var overlay: CenterContainer
var overlay_title: Label
var overlay_msg: Label
var minimap: MiniMap
var flash_rect: ColorRect
var music_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer

var _config := ConfigFile.new()
const SAVE_PATH := "user://best_times.cfg"


func _ready() -> void:
	randomize()
	_config.load(SAVE_PATH)
	_build_environment()
	_build_world_nodes()
	_build_ui()
	_load_audio()
	# First person is the only mode: hide the wizard model, mount the staff
	# on the camera as a viewmodel
	player.set_model_visible(false)
	player.attach_staff_to_camera(camera)
	_show_menu("The Labyrinth Awaits", "Choose your trial, brave wizard")


func _unhandled_input(event: InputEvent) -> void:
	if not game_active:
		return
	# Esc frees the mouse (to reach the UI buttons); clicking recaptures it
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	# First-person camera: eye height at the wizard's head, looking along
	# facing with mouse-controlled pitch
	var fa := player.rotation.y
	var wp := player.position
	var eye := Vector3(wp.x, wp.y + FP_EYE_HEIGHT, wp.z)
	camera.position = camera.position.lerp(eye, minf(1.0, delta * 25.0))
	var pitch: float = player.look_pitch
	camera.look_at(Vector3(
		wp.x + sin(fa) * cos(pitch) * FP_LOOK_AHEAD,
		wp.y + FP_EYE_HEIGHT + sin(pitch) * FP_LOOK_AHEAD,
		wp.z - cos(fa) * cos(pitch) * FP_LOOK_AHEAD))

	# Teleport flash fade
	if flash_rect.modulate.a > 0:
		flash_rect.modulate.a = maxf(0, flash_rect.modulate.a - delta * 1.9)

	if game_active:
		var elapsed := Time.get_ticks_msec() / 1000.0 - start_time
		stats_label.text = "Steps: %d   |   Time: %s   |   Best: %s" % [
			steps, _fmt_time(elapsed), _best_time_str()]
		minimap.player_pos = Vector2(player.position.x, player.position.z) / CELL
		minimap.player_angle = player.rotation.y


func start_game(diff: String) -> void:
	difficulty = diff
	var cfg: Dictionary = DIFFICULTIES[diff]
	goal = Vector2i(cfg.cols - 1, cfg.rows - 1)
	maze = MazeGenerator.generate(cfg.cols, cfg.rows)
	portals = MazeGenerator.generate_portals(cfg.portals, cfg.cols, cfg.rows, goal)
	if OS.is_debug_build():
		print(MazeGenerator.to_ascii(maze))

	builder.build(maze, portals, goal)
	player.setup(maze, goal, portals)
	visited = {Vector2i.ZERO: true}

	minimap.maze = maze
	minimap.visited = visited
	minimap.portals = portals
	minimap.goal = goal
	minimap.player_pos = Vector2.ZERO

	steps = 0
	start_time = Time.get_ticks_msec() / 1000.0
	game_active = true
	overlay.visible = false
	camera.position = Vector3(0, FP_EYE_HEIGHT, 0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not music_muted and music_player.stream:
		music_player.play()


func _on_cell_changed(pos: Vector2i) -> void:
	steps += 1
	visited[pos] = true


func _on_reached_goal() -> void:
	game_active = false
	music_player.stop()
	_play_sfx("fanfare")
	var elapsed := Time.get_ticks_msec() / 1000.0 - start_time
	var best: float = _config.get_value("best", difficulty, -1.0)
	var msg := "Conquered in %d steps and %s!" % [steps, _fmt_time(elapsed)]
	if best < 0 or elapsed < best:
		_config.set_value("best", difficulty, elapsed)
		_config.save(SAVE_PATH)
		msg += "\nNew best time!"
	_show_menu("Victory!", msg)


func _on_entered_portal(index: int) -> void:
	var others: Array[Vector2i] = []
	for i in portals.size():
		if i != index:
			others.append(portals[i])
	var dest: Vector2i = others[randi() % others.size()]
	player.teleport_to(dest)
	visited[dest] = true
	flash_rect.modulate.a = 0.65
	_play_sfx("portal")


# ── World construction ────────────────────────────────────────────────────────
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.01, 0.005, 0.02)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	# No ambient light at all — torches and the player's wisp lights are the
	# only illumination in the dungeon
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.15
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.15
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.02
	env.volumetric_fog_albedo = Color(0.5, 0.38, 0.28)
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)



func _build_world_nodes() -> void:
	builder = MazeBuilder.new()
	add_child(builder)
	player = PlayerController.new()
	player.cell_changed.connect(_on_cell_changed)
	player.reached_goal.connect(_on_reached_goal)
	player.entered_portal.connect(_on_entered_portal)
	add_child(player)
	camera = Camera3D.new()
	camera.position = Vector3(0, FP_EYE_HEIGHT, 0)
	camera.fov = 80
	add_child(camera)


# ── UI ────────────────────────────────────────────────────────────────────────
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	stats_label = Label.new()
	stats_label.position = Vector2(16, 12)
	stats_label.add_theme_font_size_override("font_size", 18)
	layer.add_child(stats_label)

	var music_btn := Button.new()
	music_btn.text = "♪ Music OFF"
	music_btn.position = Vector2(16, 44)
	music_btn.pressed.connect(func() -> void:
		music_muted = not music_muted
		music_btn.text = "♪ Music OFF" if music_muted else "♪ Music ON"
		if music_muted:
			music_player.stop()
		elif game_active and music_player.stream:
			music_player.play())
	layer.add_child(music_btn)


	minimap = MiniMap.new()
	minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	minimap.position = Vector2(-170, 14)
	minimap.size = Vector2(MiniMap.MAP_SIZE, MiniMap.MAP_SIZE)
	layer.add_child(minimap)

	var hint := Label.new()
	hint.text = "↑/W forward   ↓/S back   ←→/AD or mouse turn   LMB shoot light   Esc free mouse"
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(16, -36)
	hint.modulate = Color(1, 1, 1, 0.55)
	layer.add_child(hint)

	flash_rect = ColorRect.new()
	flash_rect.color = Color(0.63, 0.31, 1.0)
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.modulate.a = 0
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(flash_rect)

	# Menu / win overlay
	overlay = CenterContainer.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(overlay)
	var panel := PanelContainer.new()
	overlay.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.custom_minimum_size = Vector2(360, 0)
	panel.add_child(vbox)
	overlay_title = Label.new()
	overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_title.add_theme_font_size_override("font_size", 30)
	vbox.add_child(overlay_title)
	overlay_msg = Label.new()
	overlay_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(overlay_msg)
	for key in DIFFICULTIES:
		var btn := Button.new()
		var diff_key: String = key
		btn.text = "⚔  %s  (%d×%d)" % [DIFFICULTIES[key].name, DIFFICULTIES[key].cols, DIFFICULTIES[key].rows]
		btn.pressed.connect(func() -> void: start_game(diff_key))
		vbox.add_child(btn)


func _show_menu(title: String, msg: String) -> void:
	overlay_title.text = title
	overlay_msg.text = msg
	overlay.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ── Audio ─────────────────────────────────────────────────────────────────────
func _load_audio() -> void:
	music_player = AudioStreamPlayer.new()
	add_child(music_player)
	sfx_player = AudioStreamPlayer.new()
	add_child(sfx_player)
	if ResourceLoader.exists("res://audio/melody.wav"):
		var stream: AudioStreamWAV = load("res://audio/melody.wav")
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = stream.data.size() / 2  # 16-bit mono samples
		music_player.stream = stream
		music_player.volume_db = -6


func _play_sfx(sfx: String) -> void:
	if music_muted:
		return
	var path := "res://audio/%s.wav" % sfx
	if ResourceLoader.exists(path):
		sfx_player.stream = load(path)
		sfx_player.play()


# ── Helpers ───────────────────────────────────────────────────────────────────
func _fmt_time(seconds: float) -> String:
	return "%d:%02d" % [int(seconds / 60.0), int(seconds) % 60]


func _best_time_str() -> String:
	var best: float = _config.get_value("best", difficulty, -1.0)
	return _fmt_time(best) if best >= 0 else "--"
