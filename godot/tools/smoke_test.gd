extends SceneTree
## Headless smoke test: godot --headless -s tools/smoke_test.gd
## Generates mazes for every difficulty, verifies full connectivity,
## then boots the main scene and starts a game for a few frames.

func _init() -> void:
	var ok := true

	for diff in [["easy", 11, 11], ["medium", 19, 19], ["hard", 31, 31], ["legendary", 45, 45]]:
		var maze: Array = MazeGenerator.generate(diff[1], diff[2])
		var reached := _flood_fill(maze, diff[1], diff[2])
		var total: int = diff[1] * diff[2]
		print("%s: %d/%d cells reachable %s" % [diff[0], reached, total, "OK" if reached == total else "FAIL"])
		if reached != total:
			ok = false

	print(MazeGenerator.to_ascii(MazeGenerator.generate(11, 11)))

	# Boot the main scene and start a game
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_game("easy")
	for i in 10:
		await process_frame
	print("main scene ran 10 frames after start_game: OK")

	quit(0 if ok else 1)


func _flood_fill(maze: Array, cols: int, rows: int) -> int:
	var seen := {Vector2i.ZERO: true}
	var queue: Array[Vector2i] = [Vector2i.ZERO]
	var dirs := {"N": Vector2i(0, -1), "S": Vector2i(0, 1), "E": Vector2i(1, 0), "W": Vector2i(-1, 0)}
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		var cell: Dictionary = maze[c.y][c.x]
		for d in dirs:
			if not cell.walls[d]:
				var n: Vector2i = c + dirs[d]
				if n.x >= 0 and n.x < cols and n.y >= 0 and n.y < rows and not seen.has(n):
					seen[n] = true
					queue.push_back(n)
	return seen.size()
