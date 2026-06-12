class_name PlayerController
extends CharacterBody3D
## Wizard character: tank controls (turn left/right continuously, move
## forward/backward relative to facing) with free physics-based movement —
## walls confine the player via collision instead of grid stepping.

signal cell_changed(grid_pos: Vector2i)
signal reached_goal
signal entered_portal(index: int)

const CELL := 4.0
const MOVE_SPEED := 6.5   # world units per second
const TURN_SPEED := 14.0  # smoothing lerp rate
const TURN_RATE := 3.2    # radians/sec of turning while key held
const MOUSE_SENS := 0.0035

var look_pitch := 0.0  # mouse pitch, used by the first-person camera

# Wisp lights shot from the staff (left mouse button)
const WISP_SPEED := 12.0
const WISP_TRAVEL := 7.0
const MAX_WISPS := 100
const SHADOWED_WISPS := 10  # only the newest wisps cast shadows (perf)
var _wisps: Array = []  # {node, target}

var maze: Array = []
var grid_pos := Vector2i.ZERO  # nearest cell, derived from position
var active := false

var goal := Vector2i.ZERO
var portals: Array[Vector2i] = []
var portal_cooldown := false

var _facing_angle := 0.0
var _target_facing := 0.0
var _time := 0.0
var _orb_mat: StandardMaterial3D
var _orb_light: OmniLight3D
var _staff_root: Node3D       # whole staff: shaft, bands, prongs, crystal
var _staff_orb: MeshInstance3D  # the crystal (sparks + pulse target)
var _staff_view_mats: Array[StandardMaterial3D] = []  # all staff materials, for the FP depth trick
# Staff root positions: third-person (in the wizard's hand) and first-person
# (held viewmodel, tilted forward), plus the near-wall retraction vector
const STAFF_TP_POS := Vector3(0.5, 0.0, -0.1)
const FP_STAFF_POS := Vector3(0.38, -1.48, -0.68)
const FP_RETRACT := Vector3(0.06, -0.15, 0.6)
var _fp_camera: Camera3D = null
var _retract := 0.0
var _sparks: GPUParticles3D


func _ready() -> void:
	_build_wizard()
	_build_dust_motes()
	# Capsule collider so walls confine free movement
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.45
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.95
	add_child(col)


func setup(p_maze: Array, p_goal: Vector2i, p_portals: Array[Vector2i]) -> void:
	maze = p_maze
	goal = p_goal
	portals = p_portals
	grid_pos = Vector2i.ZERO
	_facing_angle = 0.0
	_target_facing = 0.0
	portal_cooldown = false
	look_pitch = 0.0
	clear_wisps()  # fresh maze, fresh darkness
	position = Vector3.ZERO
	rotation.y = 0
	velocity = Vector3.ZERO
	active = true


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_target_facing += event.relative.x * MOUSE_SENS
		look_pitch = clampf(look_pitch - event.relative.y * MOUSE_SENS, -1.1, 1.1)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_shoot_wisp()


func _process(delta: float) -> void:
	_time += delta
	# Staff orb pulse runs even on menu screen
	_orb_mat.emission_energy_multiplier = 1.1 + 0.55 * sin(_time * 3.4)
	_orb_light.light_energy = 0.7 + 0.35 * sin(_time * 3.4)
	_advance_wisps(delta)


func _physics_process(delta: float) -> void:
	if not active:
		return

	# Gradual turning while key held
	var turn_axis := Input.get_axis("turn_left", "turn_right")
	_target_facing += turn_axis * TURN_RATE * delta
	var ang_diff := wrapf(_target_facing - _facing_angle, -PI, PI)
	_facing_angle += ang_diff * minf(1.0, delta * TURN_SPEED)
	rotation.y = _facing_angle

	# Free movement along the facing direction; walls stop us via collision
	var move_axis := Input.get_axis("move_back", "move_forward")
	var forward := Vector3(sin(_facing_angle), 0, -cos(_facing_angle))
	velocity = forward * move_axis * MOVE_SPEED
	move_and_slide()
	position.y = 0  # stay on the floor plane

	# Derive the current cell for minimap / win / portal checks
	var g := Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
	if g != grid_pos:
		grid_pos = g
		cell_changed.emit(g)

	var cell_center := Vector3(grid_pos.x * CELL, 0, grid_pos.y * CELL)
	if grid_pos == goal and position.distance_to(cell_center) < 1.6:
		active = false
		velocity = Vector3.ZERO
		reached_goal.emit()
		return
	if not portal_cooldown:
		var idx := portals.find(grid_pos)
		if idx != -1 and position.distance_to(cell_center) < 1.2:
			entered_portal.emit(idx)

	_update_fp_staff(delta)


## Switch between third-person (full model) and first-person (staff only).
## The staff lives inside _staff_root (a Node3D), so hiding the wizard's
## direct MeshInstance3D children leaves it untouched.
func set_model_visible(model_visible: bool) -> void:
	for child in get_children():
		if child is MeshInstance3D:
			child.visible = model_visible


## First person: parent the staff to the camera as a viewmodel so it is
## locked to the view and turns with every camera motion.
func attach_staff_to_camera(cam: Camera3D) -> void:
	_fp_camera = cam
	_retract = 0.0
	_staff_root.get_parent().remove_child(_staff_root)
	cam.add_child(_staff_root)
	_staff_root.position = FP_STAFF_POS
	_staff_root.rotation.x = -0.2  # slight forward tilt in hand
	# Viewmodel trick: draw the staff on top of world geometry so it can
	# never visually clip into a wall, whatever the retraction does
	for mat in _staff_view_mats:
		mat.no_depth_test = true
		mat.render_priority = 100


## Shoot a small floating light from the staff orb: it flies forward a short
## distance (stopping early at walls), then hangs in place. Oldest wisp is
## removed once the cap is reached.
func _shoot_wisp() -> void:
	var from: Vector3 = _staff_orb.global_position
	var dir: Vector3
	if _fp_camera:
		dir = -_fp_camera.global_transform.basis.z  # includes mouse pitch
	else:
		dir = Vector3(sin(rotation.y), 0, -cos(rotation.y))
	var to := from + dir * WISP_TRAVEL
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		to = hit.position - dir * 0.3  # park just in front of the wall
	to.y = clampf(to.y, 0.3, 3.3)  # keep inside the dungeon vertically

	var wisp := Node3D.new()
	# Flame core: vertically-stretched ellipsoid, near-white hot center whose
	# strong emission drives the bloom glow
	var core := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.035
	mesh.height = 0.11
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.96, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.8, 1.0)
	mat.emission_energy_multiplier = 5.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core.mesh = mesh
	core.material_override = mat
	wisp.add_child(core)
	# Soft additive glow halo (billboard with radial gradient)
	var halo := MeshInstance3D.new()
	halo.mesh = _wisp_halo_mesh()
	wisp.add_child(halo)
	# Blue flame tongues licking upward around the core
	var flame := GPUParticles3D.new()
	flame.process_material = _wisp_flame_pm()
	flame.draw_pass_1 = _wisp_flame_mesh()
	flame.amount = 26
	flame.lifetime = 0.65
	wisp.add_child(flame)
	# Stray ember dots drifting around the flame, like the reference art
	var embers := GPUParticles3D.new()
	embers.process_material = _wisp_ember_pm()
	embers.draw_pass_1 = _wisp_ember_mesh()
	embers.amount = 8
	embers.lifetime = 1.8
	wisp.add_child(embers)
	var light := OmniLight3D.new()
	light.light_color = Color(0.55, 0.75, 1.0)
	light.omni_range = 7.5
	light.light_energy = 1.8
	light.shadow_enabled = true  # newest wisps cast shadows; revoked as they age
	wisp.add_child(light)
	wisp.position = from
	get_parent().add_child(wisp)

	_wisps.append({"node": wisp, "target": to, "light": light, "mat": mat,
		"phase": randf() * TAU})
	if _wisps.size() > MAX_WISPS:
		var oldest: Dictionary = _wisps.pop_front()
		oldest.node.queue_free()
	# Only the newest SHADOWED_WISPS keep shadow mapping — 100 shadow casters
	# would crush the framerate, and old wisps are usually far behind anyway
	for i in _wisps.size():
		_wisps[i].light.shadow_enabled = i >= _wisps.size() - SHADOWED_WISPS


# Shared particle resources for all wisps (built once)
var _flame_pm_cache: ParticleProcessMaterial = null
var _flame_mesh_cache: QuadMesh = null
var _halo_mesh_cache: QuadMesh = null
var _ember_pm_cache: ParticleProcessMaterial = null
var _ember_mesh_cache: SphereMesh = null


func _wisp_halo_mesh() -> QuadMesh:
	if _halo_mesh_cache == null:
		var grad := Gradient.new()
		grad.set_color(0, Color(0.5, 0.75, 1.0, 0.75))
		grad.set_color(1, Color(0.2, 0.4, 1.0, 0.0))
		var tex := GradientTexture2D.new()
		tex.gradient = grad
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(0.5, 0.0)
		tex.width = 128
		tex.height = 128
		var hm := StandardMaterial3D.new()
		hm.albedo_texture = tex
		hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		hm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		hm.no_depth_test = false
		_halo_mesh_cache = QuadMesh.new()
		_halo_mesh_cache.size = Vector2(1.1, 1.4)
		_halo_mesh_cache.material = hm
	return _halo_mesh_cache


func _wisp_ember_pm() -> ParticleProcessMaterial:
	if _ember_pm_cache == null:
		_ember_pm_cache = ParticleProcessMaterial.new()
		_ember_pm_cache.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		_ember_pm_cache.emission_sphere_radius = 0.18
		_ember_pm_cache.direction = Vector3(0, 1, 0)
		_ember_pm_cache.spread = 60.0
		_ember_pm_cache.gravity = Vector3(0, 0.35, 0)
		_ember_pm_cache.initial_velocity_min = 0.05
		_ember_pm_cache.initial_velocity_max = 0.25
		_ember_pm_cache.turbulence_enabled = true
		_ember_pm_cache.turbulence_noise_strength = 0.3
		_ember_pm_cache.scale_min = 0.5
		_ember_pm_cache.scale_max = 1.0
		var curve := Curve.new()
		curve.add_point(Vector2(0, 1))
		curve.add_point(Vector2(1, 0))
		var ct := CurveTexture.new()
		ct.curve = curve
		_ember_pm_cache.scale_curve = ct
	return _ember_pm_cache


func _wisp_ember_mesh() -> SphereMesh:
	if _ember_mesh_cache == null:
		_ember_mesh_cache = SphereMesh.new()
		_ember_mesh_cache.radius = 0.014
		_ember_mesh_cache.height = 0.028
		_ember_mesh_cache.radial_segments = 4
		_ember_mesh_cache.rings = 2
		var em := StandardMaterial3D.new()
		em.albedo_color = Color(0.8, 0.92, 1.0)
		em.emission_enabled = true
		em.emission = Color(0.7, 0.85, 1.0)
		em.emission_energy_multiplier = 4.0
		em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ember_mesh_cache.material = em
	return _ember_mesh_cache


func _wisp_flame_pm() -> ParticleProcessMaterial:
	if _flame_pm_cache == null:
		_flame_pm_cache = ParticleProcessMaterial.new()
		_flame_pm_cache.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		_flame_pm_cache.emission_sphere_radius = 0.09
		_flame_pm_cache.direction = Vector3(0, 1, 0)
		_flame_pm_cache.spread = 40.0
		_flame_pm_cache.gravity = Vector3(0, 1.6, 0)  # buoyant, flames rise fast
		_flame_pm_cache.initial_velocity_min = 0.1
		_flame_pm_cache.initial_velocity_max = 0.7
		_flame_pm_cache.lifetime_randomness = 0.45
		_flame_pm_cache.turbulence_enabled = true
		_flame_pm_cache.turbulence_noise_strength = 1.1
		_flame_pm_cache.turbulence_noise_scale = 1.3
		_flame_pm_cache.turbulence_influence_min = 0.05
		_flame_pm_cache.turbulence_influence_max = 0.25
		_flame_pm_cache.angle_min = -180.0
		_flame_pm_cache.angle_max = 180.0  # random billboard spin per particle
		_flame_pm_cache.scale_min = 0.35
		_flame_pm_cache.scale_max = 1.9
		_flame_pm_cache.hue_variation_min = -0.04
		_flame_pm_cache.hue_variation_max = 0.04
		# Shrink and fade as they rise, like flame tips
		var curve := Curve.new()
		curve.add_point(Vector2(0, 1))
		curve.add_point(Vector2(1, 0))
		var ct := CurveTexture.new()
		ct.curve = curve
		_flame_pm_cache.scale_curve = ct
		# White-hot at birth → blue → transparent at the flame tip
		var ramp := Gradient.new()
		ramp.add_point(0.4, Color(0.5, 0.7, 1.0, 0.8))
		ramp.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
		ramp.set_color(ramp.get_point_count() - 1, Color(0.15, 0.3, 1.0, 0.0))
		var ramp_tex := GradientTexture1D.new()
		ramp_tex.gradient = ramp
		_flame_pm_cache.color_ramp = ramp_tex
	return _flame_pm_cache


func _wisp_flame_mesh() -> QuadMesh:
	if _flame_mesh_cache == null:
		# Soft radial-gradient billboard; dozens of these overlapping and
		# blending additively form the flame body
		var grad := Gradient.new()
		grad.add_point(0.35, Color(0.45, 0.7, 1.0, 0.65))
		grad.set_color(0, Color(0.95, 1.0, 1.0, 0.95))
		grad.set_color(grad.get_point_count() - 1, Color(0.1, 0.25, 0.9, 0.0))
		var tex := GradientTexture2D.new()
		tex.gradient = grad
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(0.5, 0.0)
		tex.width = 64
		tex.height = 64
		var fm := StandardMaterial3D.new()
		fm.albedo_texture = tex
		fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		fm.vertex_color_use_as_albedo = true  # lets the color ramp tint/fade
		_flame_mesh_cache = QuadMesh.new()
		_flame_mesh_cache.size = Vector2(0.3, 0.42)
		_flame_mesh_cache.material = fm
	return _flame_mesh_cache


func _advance_wisps(delta: float) -> void:
	for w in _wisps:
		var n: Node3D = w.node
		if n.position.distance_to(w.target) > 0.001 and not w.has("settled"):
			n.position = n.position.move_toward(w.target, WISP_SPEED * delta)
			if n.position.distance_to(w.target) <= 0.001:
				w["settled"] = true
		else:
			# Gentle vertical hover once in place
			n.position.y = w.target.y + sin(_time * 1.7 + w.phase) * 0.09
		# Flame flicker: light and core emission dance out of phase per wisp
		var f: float = 1.0 + 0.35 * sin(_time * 9.0 + w.phase) + 0.2 * sin(_time * 15.7 + w.phase * 1.3)
		w.light.light_energy = 1.8 * f
		w.mat.emission_energy_multiplier = 4.5 * f


func clear_wisps() -> void:
	for w in _wisps:
		w.node.queue_free()
	_wisps.clear()


## Pull the staff in toward the player when the camera is close to a wall so
## the viewmodel never clips through geometry; spark while it touches.
func _update_fp_staff(delta: float) -> void:
	if _fp_camera == null:
		return
	var from := _fp_camera.global_position
	# Aim at the staff tip (plus margin), not the view center — catches walls
	# to the side that the offset staff would hit while the center ray misses
	var to: Vector3 = _staff_orb.global_position + (_staff_orb.global_position - from).normalized() * 0.45
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var target := 0.0
	if not hit.is_empty():
		var full := from.distance_to(to)
		target = clampf(1.0 - from.distance_to(hit.position) / full, 0.0, 1.0)
	_retract = lerpf(_retract, target, minf(1.0, delta * 14.0))
	_staff_root.position = FP_STAFF_POS + FP_RETRACT * _retract
	_sparks.emitting = _retract > 0.3


## Called by the game manager after a teleport.
func teleport_to(p: Vector2i) -> void:
	grid_pos = p
	position = Vector3(p.x * CELL, 0, p.y * CELL)
	velocity = Vector3.ZERO
	portal_cooldown = true
	get_tree().create_timer(0.6).timeout.connect(func() -> void: portal_cooldown = false)


## Sparse drifting dust specks in a volume around the player — they emit in
## world space, so the field trails naturally as the player moves and the
## motes catch the torch light.
func _build_dust_motes() -> void:
	var dust := GPUParticles3D.new()
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(8, 1.7, 8)
	pm.gravity = Vector3(0, -0.015, 0)
	pm.initial_velocity_min = 0.02
	pm.initial_velocity_max = 0.08
	pm.direction = Vector3(0, 0, 0)
	pm.spread = 180.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.12
	pm.turbulence_noise_scale = 1.5
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	dust.process_material = pm
	dust.amount = 110
	dust.lifetime = 7.0
	dust.preprocess = 7.0  # field is already populated when the game starts
	dust.local_coords = false
	var mote := SphereMesh.new()
	mote.radius = 0.012
	mote.height = 0.024
	mote.radial_segments = 4
	mote.rings = 2
	var mote_mat := StandardMaterial3D.new()
	mote_mat.albedo_color = Color(0.9, 0.8, 0.6, 0.4)
	mote_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote.material = mote_mat
	dust.draw_pass_1 = mote
	dust.position.y = 1.7
	add_child(dust)


# ── Wizard model (primitives, like the Three.js original) ────────────────────
func _build_wizard() -> void:
	var robe_mat := StandardMaterial3D.new()
	robe_mat.albedo_color = Color(0.13, 0.16, 0.45)
	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = Color(0.95, 0.8, 0.65)
	var beard_mat := StandardMaterial3D.new()
	beard_mat.albedo_color = Color(0.92, 0.92, 0.92)
	var belt_mat := StandardMaterial3D.new()
	belt_mat.albedo_color = Color(0.45, 0.3, 0.1)

	# Robe
	var robe := MeshInstance3D.new()
	var robe_mesh := CylinderMesh.new()
	robe_mesh.top_radius = 0.4
	robe_mesh.bottom_radius = 0.6
	robe_mesh.height = 1.8
	robe.mesh = robe_mesh
	robe.material_override = robe_mat
	robe.position.y = 0.9
	add_child(robe)
	# Belt
	var belt := MeshInstance3D.new()
	var belt_mesh := CylinderMesh.new()
	belt_mesh.top_radius = 0.47
	belt_mesh.bottom_radius = 0.5
	belt_mesh.height = 0.12
	belt.mesh = belt_mesh
	belt.material_override = belt_mat
	belt.position.y = 1.0
	add_child(belt)
	# Head
	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.3
	head_mesh.height = 0.6
	head.mesh = head_mesh
	head.material_override = skin_mat
	head.position.y = 2.0
	add_child(head)
	# Nose (points forward = -Z)
	var nose := MeshInstance3D.new()
	var nose_mesh := CylinderMesh.new()
	nose_mesh.top_radius = 0.0
	nose_mesh.bottom_radius = 0.05
	nose_mesh.height = 0.16
	nose.mesh = nose_mesh
	nose.material_override = skin_mat
	nose.rotation.x = -PI / 2
	nose.position = Vector3(0, 1.98, -0.32)
	add_child(nose)
	# Beard
	var beard := MeshInstance3D.new()
	var beard_mesh := SphereMesh.new()
	beard_mesh.radius = 0.18
	beard_mesh.height = 0.5
	beard.mesh = beard_mesh
	beard.material_override = beard_mat
	beard.position = Vector3(0, 1.78, -0.16)
	add_child(beard)
	# Hat brim
	var brim := MeshInstance3D.new()
	var brim_mesh := CylinderMesh.new()
	brim_mesh.top_radius = 0.45
	brim_mesh.bottom_radius = 0.45
	brim_mesh.height = 0.08
	brim.mesh = brim_mesh
	brim.material_override = robe_mat
	brim.position.y = 2.24
	add_child(brim)
	# Hat cone
	var hat := MeshInstance3D.new()
	var hat_mesh := CylinderMesh.new()
	hat_mesh.top_radius = 0.0
	hat_mesh.bottom_radius = 0.4
	hat_mesh.height = 0.9
	hat.mesh = hat_mesh
	hat.material_override = robe_mat
	hat.position.y = 2.7
	add_child(hat)
	# ── Staff: twisted dark-wood shaft, gold ornament bands, four prongs
	# cradling a glowing blue crystal (built as one group for FP/TP switching)
	_staff_root = Node3D.new()
	_staff_root.position = STAFF_TP_POS
	add_child(_staff_root)

	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.16, 0.10, 0.05)
	wood_mat.roughness = 0.8
	var gold_mat := StandardMaterial3D.new()
	gold_mat.albedo_color = Color(0.78, 0.58, 0.22)
	gold_mat.metallic = 0.9
	gold_mat.roughness = 0.32
	_staff_view_mats = [wood_mat, gold_mat]

	# Shaft: three stacked, slightly offset/tilted tapered segments fake the
	# organic twisted look of the reference
	for seg in [[0.0, 0.36, 0.035, 0.045, 0.015, 0.0],
			[0.7, 0.34, 0.04, 0.035, -0.012, 0.03],
			[1.38, 0.32, 0.045, 0.04, 0.01, -0.025]]:
		var s := MeshInstance3D.new()
		var sm := CylinderMesh.new()
		sm.height = seg[1] * 2.1
		sm.top_radius = seg[3]
		sm.bottom_radius = seg[2]
		s.mesh = sm
		s.material_override = wood_mat
		s.position = Vector3(seg[4], seg[0] + seg[1], 0)
		s.rotation.z = seg[5]
		s.rotation.x = seg[5] * -0.7
		_staff_root.add_child(s)

	# Gold ornament bands along the shaft
	for band_y in [0.45, 1.05, 1.62]:
		var band := MeshInstance3D.new()
		var bm := TorusMesh.new()
		bm.inner_radius = 0.036
		bm.outer_radius = 0.062
		band.mesh = bm
		band.material_override = gold_mat
		band.position.y = band_y
		_staff_root.add_child(band)

	# Gold collar where the prongs meet the shaft
	var collar := MeshInstance3D.new()
	var collar_mesh := CylinderMesh.new()
	collar_mesh.top_radius = 0.075
	collar_mesh.bottom_radius = 0.05
	collar_mesh.height = 0.14
	collar.mesh = collar_mesh
	collar.material_override = gold_mat
	collar.position.y = 1.74
	_staff_root.add_child(collar)

	# Four wooden prongs curving up around the crystal like petals
	for i in 4:
		var a := TAU * i / 4.0 + 0.4
		var prong := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.006
		pm.bottom_radius = 0.026
		pm.height = 0.46
		prong.mesh = pm
		prong.material_override = wood_mat
		prong.position = Vector3(cos(a) * 0.085, 2.0, sin(a) * 0.085)
		# Tilt each prong outward so the tips flare around the gem
		var out_axis := Vector3(-sin(a), 0, cos(a))
		prong.transform.basis = Basis(out_axis, 0.38)
		_staff_root.add_child(prong)

	# The crystal: low-poly faceted sphere, glowing blue like the wisps
	_staff_orb = MeshInstance3D.new()
	var orb_mesh := SphereMesh.new()
	orb_mesh.radius = 0.11
	orb_mesh.height = 0.26
	orb_mesh.radial_segments = 6
	orb_mesh.rings = 4
	_staff_orb.mesh = orb_mesh
	_orb_mat = StandardMaterial3D.new()
	_orb_mat.albedo_color = Color(0.45, 0.7, 1.0)
	_orb_mat.emission_enabled = true
	_orb_mat.emission = Color(0.35, 0.6, 1.0)
	_orb_mat.roughness = 0.15
	_staff_orb.material_override = _orb_mat
	_staff_orb.position = Vector3(0, 2.06, 0)
	_staff_root.add_child(_staff_orb)
	_staff_view_mats.append(_orb_mat)
	# Sparks burst from the orb while it presses against a wall (first person)
	_sparks = GPUParticles3D.new()
	var spark_pm := ParticleProcessMaterial.new()
	spark_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	spark_pm.emission_sphere_radius = 0.1
	spark_pm.direction = Vector3(0, 0.4, 1)
	spark_pm.spread = 75.0
	spark_pm.initial_velocity_min = 1.2
	spark_pm.initial_velocity_max = 2.8
	spark_pm.gravity = Vector3(0, -7.0, 0)
	spark_pm.scale_min = 0.25
	spark_pm.scale_max = 0.6
	spark_pm.damping_min = 0.5
	spark_pm.damping_max = 1.5
	_sparks.process_material = spark_pm
	_sparks.amount = 28
	_sparks.lifetime = 0.4
	_sparks.explosiveness = 0.0
	_sparks.local_coords = false  # sparks trail in world space
	_sparks.emitting = false
	var spark_mesh := SphereMesh.new()
	spark_mesh.radius = 0.018
	spark_mesh.height = 0.036
	spark_mesh.radial_segments = 4
	spark_mesh.rings = 2
	var spark_mat := StandardMaterial3D.new()
	spark_mat.albedo_color = Color(0.6, 0.85, 1.0)
	spark_mat.emission_enabled = true
	spark_mat.emission = Color(0.4, 0.7, 1.0)  # blue sparks off the crystal
	spark_mat.emission_energy_multiplier = 3.5
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mesh.material = spark_mat
	_sparks.draw_pass_1 = spark_mesh
	_staff_orb.add_child(_sparks)
	_orb_light = OmniLight3D.new()
	_orb_light.light_color = Color(0.5, 0.75, 1.0)  # blue, matching the crystal
	_orb_light.omni_range = 5.0
	_orb_light.position = Vector3(0, 2.06, 0)
	_staff_root.add_child(_orb_light)
