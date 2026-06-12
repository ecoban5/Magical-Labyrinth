class_name MazeGenerator
## Recursive backtracker maze generation — direct port of generateMaze /
## generatePortals from labyrinth3d.html. Pure logic, no scene nodes.

## Returns cells[y][x] = {x, y, walls = {N, S, E, W}}
static func generate(cols: int, rows: int) -> Array:
	var cells: Array = []
	for y in rows:
		var row: Array = []
		for x in cols:
			row.append({
				"x": x, "y": y,
				"walls": {"N": true, "S": true, "E": true, "W": true},
				"visited": false,
			})
		cells.append(row)

	var dirs := [
		{"dx": 0, "dy": -1, "from": "S", "to": "N"},
		{"dx": 0, "dy": 1, "from": "N", "to": "S"},
		{"dx": 1, "dy": 0, "from": "W", "to": "E"},
		{"dx": -1, "dy": 0, "from": "E", "to": "W"},
	]

	var stack: Array = []
	var start: Dictionary = cells[0][0]
	start.visited = true
	stack.push_back(start)

	while not stack.is_empty():
		var cur: Dictionary = stack.back()
		var neighbours: Array = []
		for d in dirs:
			var nx: int = cur.x + d.dx
			var ny: int = cur.y + d.dy
			if nx >= 0 and nx < cols and ny >= 0 and ny < rows and not cells[ny][nx].visited:
				neighbours.append({"d": d, "cell": cells[ny][nx]})
		if neighbours.is_empty():
			stack.pop_back()
			continue
		var pick: Dictionary = neighbours[randi() % neighbours.size()]
		cur.walls[pick.d.to] = false
		pick.cell.walls[pick.d.from] = false
		pick.cell.visited = true
		stack.push_back(pick.cell)

	return cells


## Random portal cells, never at start (0,0) or goal.
static func generate_portals(count: int, cols: int, rows: int, goal: Vector2i) -> Array[Vector2i]:
	var portals: Array[Vector2i] = []
	var taken := {Vector2i(0, 0): true, goal: true}
	var guard := 0
	while portals.size() < count and guard < 5000:
		guard += 1
		var p := Vector2i(randi() % cols, randi() % rows)
		if taken.has(p):
			continue
		taken[p] = true
		portals.append(p)
	return portals


## Debug helper: ASCII rendering of the maze for quick correctness checks.
static func to_ascii(cells: Array) -> String:
	var rows := cells.size()
	var cols: int = cells[0].size()
	var out := ""
	for x in cols:
		out += "+--" if cells[0][x].walls.N else "+  "
	out += "+\n"
	for y in rows:
		var mid := ""
		var bot := ""
		for x in cols:
			mid += "|  " if cells[y][x].walls.W else "   "
			bot += "+--" if cells[y][x].walls.S else "+  "
		mid += "|" if cells[y][cols - 1].walls.E else " "
		out += mid + "\n" + bot + "+\n"
	return out
