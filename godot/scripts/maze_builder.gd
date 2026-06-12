class_name MazeBuilder
extends Node3D
## Builds the 3D dungeon from maze data: floor, deduplicated walls, torches,
## decorations, portals, and the goal tower. Mirrors buildSceneGeometry()
## from labyrinth3d.html.

const CELL := 4.0
const WALL_H := 3.6
const WALL_T := 0.35
const MAX_TORCHES_PER_100_CELLS := 8.0

var portal_nodes: Array[Node3D] = []
var goal_light: OmniLight3D = null
var _torches: Array = []  # {flame_mat, light, phase}
var _time := 0.0

var _wall_mat: StandardMaterial3D
var _floor_mat: StandardMaterial3D
var _iron_mat: StandardMaterial3D
var _wood_mat: StandardMaterial3D


func _ready() -> void:
	_make_materials()


func _process(delta: float) -> void:
	_time += delta
	for t in _torches:
		var f: float = 1.5 + 0.9 * sin(_time * 7.1 + t.phase) + 0.45 * sin(_time * 13.7 + t.phase * 1.7)
		t.flame_mat.emission_energy_multiplier = f * 2.2
		t.light.light_energy = f * 0.55
	var i := 0
	for p in portal_nodes:
		for child in p.get_children():
			if child.has_meta("spin"):
				child.rotate_z(child.get_meta("spin") * delta)
		var pl: OmniLight3D = p.get_node("Light")
		pl.light_energy = 1.2 + 0.5 * sin(_time * 3.0 + i * 1.4)
		i += 1
	if goal_light:
		goal_light.light_energy = 1.4 + 0.5 * sin(_time * 2.1)


func clear_maze() -> void:
	for c in get_children():
		c.queue_free()
	portal_nodes.clear()
	_torches.clear()
	goal_light = null


func build(maze: Array, portals: Array[Vector2i], goal: Vector2i) -> void:
	clear_maze()
	var rows := maze.size()
	var cols: int = maze[0].size()
	var cx := (cols - 1) * CELL / 2.0
	var cz := (rows - 1) * CELL / 2.0

	# Floor
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(cols * CELL + 1, rows * CELL + 1)
	floor_mesh.mesh = plane
	floor_mesh.material_override = _floor_mat
	floor_mesh.position = Vector3(cx, 0, cz)
	add_child(floor_mesh)

	# Ceiling — stone like the walls, visible from below in first person.
	# flip_faces keeps it one-sided (facing down), so the third-person camera
	# above it still sees straight through into the maze.
	var ceil_mesh := MeshInstance3D.new()
	var ceil_plane := PlaneMesh.new()
	ceil_plane.size = Vector2(cols * CELL + 1, rows * CELL + 1)
	ceil_plane.flip_faces = true
	ceil_mesh.mesh = ceil_plane
	var ceil_mat: StandardMaterial3D = _wall_mat.duplicate()
	ceil_mat.albedo_color = Color(0.45, 0.4, 0.38)  # darker, soot-stained stone
	ceil_mesh.material_override = ceil_mat
	ceil_mesh.position = Vector3(cx, WALL_H, cz)
	add_child(ceil_mesh)

	# Walls — deduplicated exactly like the JS version
	var wall_set := {}
	var wall_data: Array = []
	# Walls are CELL - WALL_T long so they never overlap; pillars fill the
	# lattice corners between them (no coplanar faces anywhere → no z-fighting)
	var corner_set := {}
	for row in maze:
		for cell in row:
			if cell.walls.N:
				_add_wall(wall_set, wall_data, corner_set, cell.x, cell.y, false)
			if cell.walls.S:
				_add_wall(wall_set, wall_data, corner_set, cell.x, cell.y + 1, false)
			if cell.walls.W:
				_add_wall(wall_set, wall_data, corner_set, cell.x, cell.y, true)
			if cell.walls.E:
				_add_wall(wall_set, wall_data, corner_set, cell.x + 1, cell.y, true)

	for c in corner_set:
		_add_pillar(c)

	_add_decorations(wall_data, cols * rows)
	_build_goal_tower(goal)
	for p in portals:
		_build_portal(p)


## Wall segment at lattice position (a, b). NS walls run along X between
## lattice corners (a,b)-(a+1,b); EW walls run along Z between (a,b)-(a,b+1).
## Segments are CELL - WALL_T long: they end at the pillar faces, with the
## ends tucked 0.04 inside the (slightly fatter) pillars so no face is ever
## coplanar with another.
func _add_wall(wall_set: Dictionary, wall_data: Array, corner_set: Dictionary, a: int, b: int, is_ew: bool) -> void:
	corner_set[Vector2i(a, b)] = true
	corner_set[Vector2i(a + (0 if is_ew else 1), b + (1 if is_ew else 0))] = true
	var key := "%s:%d,%d" % ["EW" if is_ew else "NS", a, b]
	if wall_set.has(key):
		return
	wall_set[key] = true
	var wx := a * CELL - (CELL / 2 if is_ew else 0.0)
	var wz := b * CELL - (0.0 if is_ew else CELL / 2)
	var size := Vector3(WALL_T, WALL_H, CELL - WALL_T) if is_ew else Vector3(CELL - WALL_T, WALL_H, WALL_T)
	var body := StaticBody3D.new()
	body.position = Vector3(wx, WALL_H / 2, wz)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	m.material_override = _wall_mat
	body.add_child(m)
	add_child(body)
	wall_data.append({"wx": wx, "wz": wz, "is_ew": is_ew})


## Corner post at a lattice corner. Slightly fatter and taller than the walls
## so the wall ends are buried inside it — hides the seams and reads as a
## buttress detail.
func _add_pillar(c: Vector2i) -> void:
	var size := Vector3(WALL_T + 0.08, WALL_H + 0.02, WALL_T + 0.08)
	var body := StaticBody3D.new()
	body.position = Vector3(c.x * CELL - CELL / 2, WALL_H / 2, c.y * CELL - CELL / 2)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	m.mesh = box
	m.material_override = _wall_mat
	body.add_child(m)
	add_child(body)


func _add_decorations(wall_data: Array, cell_count: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("dungeon-decor")
	var torch_budget := int(ceil(cell_count / 100.0 * MAX_TORCHES_PER_100_CELLS)) + 2
	var eps := 0.06

	for wd in wall_data:
		# "rot" turns a node's local +Z to point along the face normal n
		# (out of the wall). Quads face +Z so they use rot directly; the
		# torch assembly extends along -Z, so it gets rot + PI.
		var faces := []
		if wd.is_ew:
			faces = [{"n": Vector3(1, 0, 0), "rot": PI / 2}, {"n": Vector3(-1, 0, 0), "rot": -PI / 2}]
		else:
			faces = [{"n": Vector3(0, 0, 1), "rot": 0.0}, {"n": Vector3(0, 0, -1), "rot": PI}]
		for face in faces:
			var r := rng.randf()
			var face_pos: Vector3 = Vector3(wd.wx, 0, wd.wz) + face.n * (WALL_T / 2 + eps)
			var lat := (rng.randf() - 0.5) * CELL * 0.68
			var pos := face_pos + (Vector3(0, 0, lat) if wd.is_ew else Vector3(lat, 0, 0))

			if r < 0.10 and torch_budget > 0:
				torch_budget -= 1
				_add_torch(pos, face.rot + PI, rng)


func _add_torch(pos: Vector3, rot_y: float, rng: RandomNumberGenerator) -> void:
	var tg := Node3D.new()
	tg.position = Vector3(pos.x, 1.55 + rng.randf() * 0.4, pos.z)
	tg.rotation.y = rot_y

	# Wall mount plate
	var plate := MeshInstance3D.new()
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(0.12, 0.3, 0.03)
	plate.mesh = plate_mesh
	plate.material_override = _iron_mat
	plate.position.z = -0.015
	tg.add_child(plate)

	# Tapered iron sconce body, leaning slightly away from the wall
	var body := Node3D.new()
	body.position = Vector3(0, -0.02, -0.16)
	body.rotation.x = -0.16  # top tips outward (away from the wall, -Z)
	tg.add_child(body)
	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.055
	shaft_mesh.bottom_radius = 0.018
	shaft_mesh.height = 0.55
	shaft.mesh = shaft_mesh
	shaft.material_override = _iron_mat
	body.add_child(shaft)
	# Decorative collar rings on the sconce
	for ring_def in [[-0.12, 0.032], [0.1, 0.045], [0.24, 0.058]]:
		var ring := MeshInstance3D.new()
		var rm := TorusMesh.new()
		rm.inner_radius = ring_def[1]
		rm.outer_radius = ring_def[1] + 0.022
		ring.mesh = rm
		ring.material_override = _iron_mat
		ring.position.y = ring_def[0]
		body.add_child(ring)
	# Flared cup holding the fire
	var cup := MeshInstance3D.new()
	var cup_mesh := CylinderMesh.new()
	cup_mesh.top_radius = 0.085
	cup_mesh.bottom_radius = 0.05
	cup_mesh.height = 0.14
	cup.mesh = cup_mesh
	cup.material_override = _iron_mat
	cup.position.y = 0.33
	body.add_child(cup)

	# Fire: hot emissive core (drives bloom + flicker) over billboard flames.
	# Position derived from the cup's place in the tilted body, so the fire
	# sits exactly in the cup mouth instead of hovering beside it.
	var fire_pos: Vector3 = body.position + body.transform.basis * Vector3(0, 0.42, 0)
	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.035
	core_mesh.height = 0.1
	var flame_mat := StandardMaterial3D.new()
	flame_mat.albedo_color = Color(1.0, 0.85, 0.5)
	flame_mat.emission_enabled = true
	flame_mat.emission = Color(1.0, 0.55, 0.1)
	flame_mat.emission_energy_multiplier = 3.5
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core.mesh = core_mesh
	core.material_override = flame_mat
	core.position = fire_pos
	tg.add_child(core)
	var flames := GPUParticles3D.new()
	flames.process_material = _torch_flame_pm()
	flames.draw_pass_1 = _torch_flame_mesh()
	flames.amount = 16
	flames.lifetime = 0.55
	flames.position = fire_pos
	tg.add_child(flames)
	# Embers drifting up from the fire
	var embers := GPUParticles3D.new()
	embers.process_material = _torch_ember_pm()
	embers.draw_pass_1 = _torch_ember_mesh()
	embers.amount = 5
	embers.lifetime = 1.6
	embers.position = fire_pos
	tg.add_child(embers)

	# Flickering light with real shadows
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.45, 0.12)  # warm ember orange
	light.omni_range = 9.0
	light.shadow_enabled = true
	light.position = fire_pos + Vector3(0, 0.08, -0.04)
	tg.add_child(light)
	add_child(tg)
	_torches.append({"flame_mat": flame_mat, "light": light, "phase": rng.randf() * TAU})


# Shared fire particle resources for all torches (built once per builder)
var _torch_flame_pm_cache: ParticleProcessMaterial = null
var _torch_flame_mesh_cache: QuadMesh = null
var _torch_ember_pm_cache: ParticleProcessMaterial = null
var _torch_ember_mesh_cache: SphereMesh = null


func _torch_flame_pm() -> ParticleProcessMaterial:
	if _torch_flame_pm_cache == null:
		_torch_flame_pm_cache = ParticleProcessMaterial.new()
		_torch_flame_pm_cache.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		_torch_flame_pm_cache.emission_sphere_radius = 0.05
		_torch_flame_pm_cache.direction = Vector3(0, 1, 0)
		_torch_flame_pm_cache.spread = 25.0
		_torch_flame_pm_cache.gravity = Vector3(0, 1.4, 0)
		_torch_flame_pm_cache.initial_velocity_min = 0.1
		_torch_flame_pm_cache.initial_velocity_max = 0.5
		_torch_flame_pm_cache.lifetime_randomness = 0.4
		_torch_flame_pm_cache.turbulence_enabled = true
		_torch_flame_pm_cache.turbulence_noise_strength = 0.7
		_torch_flame_pm_cache.turbulence_noise_scale = 1.5
		_torch_flame_pm_cache.angle_min = -180.0
		_torch_flame_pm_cache.angle_max = 180.0
		_torch_flame_pm_cache.scale_min = 0.4
		_torch_flame_pm_cache.scale_max = 1.6
		var curve := Curve.new()
		curve.add_point(Vector2(0, 1))
		curve.add_point(Vector2(1, 0))
		var ct := CurveTexture.new()
		ct.curve = curve
		_torch_flame_pm_cache.scale_curve = ct
		# White-yellow heart → orange → smoky transparent red at the tips
		var ramp := Gradient.new()
		ramp.add_point(0.45, Color(1.0, 0.5, 0.08, 0.75))
		ramp.set_color(0, Color(1.0, 0.95, 0.7, 1.0))
		ramp.set_color(ramp.get_point_count() - 1, Color(0.55, 0.08, 0.0, 0.0))
		var ramp_tex := GradientTexture1D.new()
		ramp_tex.gradient = ramp
		_torch_flame_pm_cache.color_ramp = ramp_tex
	return _torch_flame_pm_cache


func _torch_flame_mesh() -> QuadMesh:
	if _torch_flame_mesh_cache == null:
		var grad := Gradient.new()
		grad.add_point(0.35, Color(1.0, 0.6, 0.15, 0.6))
		grad.set_color(0, Color(1.0, 0.95, 0.75, 0.95))
		grad.set_color(grad.get_point_count() - 1, Color(0.8, 0.2, 0.0, 0.0))
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
		fm.vertex_color_use_as_albedo = true
		_torch_flame_mesh_cache = QuadMesh.new()
		_torch_flame_mesh_cache.size = Vector2(0.22, 0.32)
		_torch_flame_mesh_cache.material = fm
	return _torch_flame_mesh_cache


func _torch_ember_pm() -> ParticleProcessMaterial:
	if _torch_ember_pm_cache == null:
		_torch_ember_pm_cache = ParticleProcessMaterial.new()
		_torch_ember_pm_cache.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		_torch_ember_pm_cache.emission_sphere_radius = 0.06
		_torch_ember_pm_cache.direction = Vector3(0, 1, 0)
		_torch_ember_pm_cache.spread = 35.0
		_torch_ember_pm_cache.gravity = Vector3(0, 0.5, 0)
		_torch_ember_pm_cache.initial_velocity_min = 0.1
		_torch_ember_pm_cache.initial_velocity_max = 0.4
		_torch_ember_pm_cache.lifetime_randomness = 0.5
		_torch_ember_pm_cache.turbulence_enabled = true
		_torch_ember_pm_cache.turbulence_noise_strength = 0.5
		var curve := Curve.new()
		curve.add_point(Vector2(0, 1))
		curve.add_point(Vector2(1, 0))
		var ct := CurveTexture.new()
		ct.curve = curve
		_torch_ember_pm_cache.scale_curve = ct
	return _torch_ember_pm_cache


func _torch_ember_mesh() -> SphereMesh:
	if _torch_ember_mesh_cache == null:
		_torch_ember_mesh_cache = SphereMesh.new()
		_torch_ember_mesh_cache.radius = 0.012
		_torch_ember_mesh_cache.height = 0.024
		_torch_ember_mesh_cache.radial_segments = 4
		_torch_ember_mesh_cache.rings = 2
		var em := StandardMaterial3D.new()
		em.albedo_color = Color(1.0, 0.7, 0.25)
		em.emission_enabled = true
		em.emission = Color(1.0, 0.5, 0.1)
		em.emission_energy_multiplier = 4.0
		em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_torch_ember_mesh_cache.material = em
	return _torch_ember_mesh_cache


func _build_goal_tower(goal: Vector2i) -> void:
	var g := Node3D.new()
	g.position = Vector3(goal.x * CELL, 0, goal.y * CELL)
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.48, 0.38, 0.25)
	var roof_mat := StandardMaterial3D.new()
	roof_mat.albedo_color = Color(0.13, 0.13, 0.33)
	var flag_mat := StandardMaterial3D.new()
	flag_mat.albedo_color = Color(0.8, 0.13, 0.13)
	flag_mat.emission_enabled = true
	flag_mat.emission = Color(0.27, 0, 0)

	for section in [[0.85, 0.9, 2.0, 1.0], [0.62, 0.78, 1.2, 2.6]]:
		var cyl := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = section[0]
		mesh.bottom_radius = section[1]
		mesh.height = section[2]
		mesh.radial_segments = 8
		cyl.mesh = mesh
		cyl.material_override = stone
		cyl.position.y = section[3]
		g.add_child(cyl)

	for i in 6:
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.22, 0.3, 0.22)
		b.mesh = bm
		b.material_override = stone
		var a := TAU * i / 6.0
		b.position = Vector3(cos(a) * 0.62, 3.35, sin(a) * 0.62)
		g.add_child(b)

	var roof := MeshInstance3D.new()
	var roof_mesh := CylinderMesh.new()
	roof_mesh.top_radius = 0.0
	roof_mesh.bottom_radius = 0.72
	roof_mesh.height = 1.1
	roof_mesh.radial_segments = 8
	roof.mesh = roof_mesh
	roof.material_override = roof_mat
	roof.position.y = 3.85
	g.add_child(roof)

	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.02
	pole_mesh.bottom_radius = 0.02
	pole_mesh.height = 0.9
	pole.mesh = pole_mesh
	pole.material_override = _iron_mat
	pole.position.y = 4.75
	g.add_child(pole)
	var flag := MeshInstance3D.new()
	var flag_mesh := QuadMesh.new()
	flag_mesh.size = Vector2(0.55, 0.32)
	flag.mesh = flag_mesh
	flag.material_override = flag_mat
	flag.position = Vector3(0.3, 4.95, 0)
	g.add_child(flag)

	goal_light = OmniLight3D.new()
	goal_light.light_color = Color(0.3, 1.0, 0.3)
	goal_light.omni_range = 8.0
	goal_light.shadow_enabled = true  # walls must occlude the glow
	goal_light.position.y = 3.0
	g.add_child(goal_light)
	add_child(g)


func _build_portal(p: Vector2i) -> void:
	var g := Node3D.new()
	g.position = Vector3(p.x * CELL, WALL_H * 0.48, p.y * CELL)

	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.6, 0.3, 1.0)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.5, 0.15, 1.0)
	ring_mat.emission_energy_multiplier = 1.6

	for ring_def in [[0.65, 0.78, 1.6], [0.85, 0.95, -1.0]]:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = ring_def[0]
		torus.outer_radius = ring_def[1]
		ring.mesh = torus
		ring.material_override = ring_mat
		ring.rotation.x = PI / 2  # vertical ring
		ring.set_meta("spin", ring_def[2])
		g.add_child(ring)

	# Swirling particles inside the ring
	var particles := GPUParticles3D.new()
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.55
	pm.gravity = Vector3.ZERO
	pm.orbit_velocity_min = 0.6
	pm.orbit_velocity_max = 1.2
	pm.scale_min = 0.04
	pm.scale_max = 0.10
	pm.color = Color(0.75, 0.45, 1.0)
	particles.process_material = pm
	particles.amount = 40
	particles.lifetime = 1.6
	var pmesh := SphereMesh.new()
	pmesh.radius = 0.5
	pmesh.height = 1.0
	var pmat := StandardMaterial3D.new()
	pmat.emission_enabled = true
	pmat.emission = Color(0.7, 0.4, 1.0)
	pmat.emission_energy_multiplier = 2.0
	pmesh.material = pmat
	particles.draw_pass_1 = pmesh
	g.add_child(particles)

	var light := OmniLight3D.new()
	light.name = "Light"
	light.light_color = Color(0.6, 0.25, 1.0)
	light.omni_range = 6.0
	light.shadow_enabled = true  # walls must occlude the glow
	g.add_child(light)

	add_child(g)
	portal_nodes.append(g)


func _make_materials() -> void:
	# CC0 PBR texture sets from ambientCG (Bricks075A walls, PavingStones131 floor)
	_wall_mat = _pbr_material("res://assets/wall/Bricks075A_1K-JPG", Vector3(0.35, 0.35, 0.35))
	_wall_mat.albedo_color = Color(0.85, 0.78, 0.72)  # age the bricks down
	_floor_mat = _pbr_material("res://assets/floor/PavingStones131_1K-JPG", Vector3(0.3, 0.3, 0.3))
	_floor_mat.albedo_color = Color(0.7, 0.68, 0.66)

	_iron_mat = StandardMaterial3D.new()
	_make_secondary_materials()


func _pbr_material(base: String, uv_scale: Vector3) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(base + "_Color.jpg")
	m.normal_enabled = true
	m.normal_texture = load(base + "_NormalGL.jpg")
	m.roughness_texture = load(base + "_Roughness.jpg")
	m.ao_enabled = true
	m.ao_texture = load(base + "_AmbientOcclusion.jpg")
	# Triplanar keeps texel density consistent on every wall size
	m.uv1_triplanar = true
	m.uv1_scale = uv_scale
	return m


func _make_secondary_materials() -> void:
	_iron_mat.albedo_color = Color(0.1, 0.1, 0.1)
	_iron_mat.metallic = 0.85
	_iron_mat.roughness = 0.45

	_wood_mat = StandardMaterial3D.new()
	_wood_mat.albedo_color = Color(0.29, 0.17, 0.06)
	_wood_mat.roughness = 0.9
