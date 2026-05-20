extends Node

class Breadcrumb:
	var position: Vector2
	var timestamp: float
	
	func _init(pos: Vector2, time: float):
		position = pos
		timestamp = time

var breadcrumbs: Array[Breadcrumb] = []

const MAX_BREADCRUMBS := 50
const BREADCRUMB_LIFESPAN := 10.0 # seconds

func add_breadcrumb(pos: Vector2) -> void:
	var now := Time.get_ticks_msec() * 0.001
	breadcrumbs.append(Breadcrumb.new(pos, now))
	
	if breadcrumbs.size() > MAX_BREADCRUMBS:
		breadcrumbs.pop_front()

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() * 0.001
	
	var i := 0
	while i < breadcrumbs.size():
		if now - breadcrumbs[i].timestamp > BREADCRUMB_LIFESPAN:
			breadcrumbs.remove_at(i)
		else:
			i += 1

func get_next_target(
	from_pos: Vector2,
	player_pos: Vector2,
	space_state: PhysicsDirectSpaceState2D,
	mask: int
) -> Vector2:

	# 1. Direct line of sight to player
	var direct_query := PhysicsRayQueryParameters2D.create(from_pos, player_pos, mask)
	if space_state.intersect_ray(direct_query).is_empty():
		return player_pos

	# 2. Try breadcrumbs (newest → oldest)
	for i in range(breadcrumbs.size() - 1, -1, -1):
		var b := breadcrumbs[i]

		var query := PhysicsRayQueryParameters2D.create(from_pos, b.position, mask)
		if space_state.intersect_ray(query).is_empty():
			return b.position

	# 3. Fallback: closest breadcrumb (even if obstructed)
	if breadcrumbs.is_empty():
		return player_pos

	var closest_pos := breadcrumbs[0].position
	var min_dist := from_pos.distance_to(closest_pos)

	for b in breadcrumbs:
		var d := from_pos.distance_to(b.position)
		if d < min_dist:
			min_dist = d
			closest_pos = b.position

	return closest_pos
