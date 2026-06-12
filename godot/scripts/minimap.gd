class_name MiniMap
extends Control
## Mini-map drawn with Control._draw() — port of drawMiniMap() from
## labyrinth3d.html: walls, visited cells, portals, goal, player dot.

var maze: Array = []
var visited := {}
var portals: Array[Vector2i] = []
var goal := Vector2i.ZERO
var player_pos := Vector2.ZERO  # fractional for smooth dot
var player_angle := 0.0         # facing, radians (0 = north/up)

const MAP_SIZE := 150.0


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if maze.is_empty():
		return
	var rows := maze.size()
	var cols: int = maze[0].size()
	var cs := MAP_SIZE / maxf(cols, rows)

	draw_rect(Rect2(0, 0, cols * cs, rows * cs), Color(0.06, 0.04, 0.09, 0.85))

	for key in visited:
		var v: Vector2i = key
		draw_rect(Rect2(v.x * cs, v.y * cs, cs, cs), Color(0.25, 0.18, 0.35, 0.5))

	var wall_col := Color(0.78, 0.56, 0.25)
	for row in maze:
		for cell in row:
			var x: float = cell.x * cs
			var y: float = cell.y * cs
			if cell.walls.N:
				draw_line(Vector2(x, y), Vector2(x + cs, y), wall_col, 1.0)
			if cell.walls.W:
				draw_line(Vector2(x, y), Vector2(x, y + cs), wall_col, 1.0)
			if cell.walls.S:
				draw_line(Vector2(x, y + cs), Vector2(x + cs, y + cs), wall_col, 1.0)
			if cell.walls.E:
				draw_line(Vector2(x + cs, y), Vector2(x + cs, y + cs), wall_col, 1.0)

	for p in portals:
		draw_circle(Vector2((p.x + 0.5) * cs, (p.y + 0.5) * cs), cs * 0.28, Color(0.7, 0.35, 1.0))

	draw_circle(Vector2((goal.x + 0.5) * cs, (goal.y + 0.5) * cs), cs * 0.3, Color(0.25, 0.95, 0.35))
	# Player: dot plus a cone showing facing direction
	var center := Vector2((player_pos.x + 0.5) * cs, (player_pos.y + 0.5) * cs)
	draw_circle(center, cs * 0.28, Color(1.0, 0.85, 0.3))
	var dir := Vector2(sin(player_angle), -cos(player_angle))
	var tip := center + dir * cs * 0.62
	var back_l := center + dir.rotated(2.5) * cs * 0.3
	var back_r := center + dir.rotated(-2.5) * cs * 0.3
	draw_colored_polygon(PackedVector2Array([tip, back_l, back_r]), Color(1.0, 0.85, 0.3))
