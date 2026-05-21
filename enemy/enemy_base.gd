class_name Enemy
extends CharacterBody2D

@export var speed: float = 60.0
@export var attack_range: float = 14.0
@export var damage: int = 10

@onready var sprite: Sprite2D = $Sprite2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var state_machine: StateMachine = $StateMachine
@onready var health_component: HealthComponent = $HealthComponent
@onready var health_bar: ProgressBar = $HealthBar
@onready var hit_particles: CPUParticles2D = $HitParticles

var player: Player
var is_in_cutscene: bool = false

# Context steering
const ENEMY_MASK := 1 | 8
const OTHER_ENEMY_MASK := 4

var num_rays: int = 16
var ray_directions: Array[Vector2] = []
var interest: Array[float] = []
var danger: Array[float] = []
var look_ahead: float = 64.0

func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	add_to_group("enemy")

	_init_rays()

	player = _resolve_player()

	if health_component:
		health_component.health_depleted.connect(_on_died)
		health_component.health_changed.connect(_on_health_changed)

		if health_bar:
			health_bar.max_value = health_component.max_health
			health_bar.value = health_component.health


func _init_rays() -> void:
	ray_directions.resize(num_rays)
	interest.resize(num_rays)
	danger.resize(num_rays)

	for i in range(num_rays):
		var angle := TAU * float(i) / float(num_rays)
		ray_directions[i] = Vector2.RIGHT.rotated(angle)
		interest[i] = 0.0
		danger[i] = 0.0


func _resolve_player() -> Player:
	var p := get_tree().get_first_node_in_group("player")
	if p:
		return p

	return get_tree().get_root().find_child("Player", true, false) as Player


func _physics_process(_delta: float) -> void:
	if is_in_cutscene or not is_instance_valid(player):
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var dir := get_steering_direction(player.global_position)

	velocity = velocity.lerp(dir * speed, 0.1)

	if dir.length_squared() > 0.0001:
		play_directional_animation("move", dir)

	move_and_slide()


func _on_health_changed(_old_health: float, new_health: float) -> void:
	if health_bar:
		health_bar.value = new_health
		health_bar.visible = true

	if hit_particles:
		hit_particles.restart()
		hit_particles.emitting = true

	sprite.modulate = Color.WHITE
	var tween := create_tween()
	tween.tween_property(sprite, "modulate", Color(0.8, 0.4, 1.0), 0.1)

	if is_instance_valid(player):
		var knock_dir := (global_position - player.global_position).normalized()
		velocity = knock_dir * 100.0

		var v_tween := create_tween()
		v_tween.tween_property(self, "velocity", Vector2.ZERO, 0.2)


func play_directional_animation(anim_base: String, dir: Vector2) -> void:
	var suffix := "_down"

	if abs(dir.x) > abs(dir.y):
		suffix = "_side"
		sprite.scale.x = -1.0 if dir.x > 0 else 1.0
	elif dir.y < 0:
		suffix = "_up"

	if animation_player:
		animation_player.play(anim_base + suffix)


func _on_died() -> void:
	if state_machine:
		state_machine.on_child_transition("death")
		return

	if animation_player:
		animation_player.play("death")
		await animation_player.animation_finished

	queue_free()


func deal_damage() -> void:
	if not is_instance_valid(player):
		return

	if global_position.distance_to(player.global_position) <= attack_range + 5.0:
		var health := player.get_node_or_null("HealthComponent")
		if health:
			health.damage(damage)


func get_steering_direction(target_pos: Vector2) -> Vector2:
	set_interest(target_pos)
	set_danger()

	var chosen := Vector2.ZERO

	for i in range(num_rays):
		var value := max(0.0, interest[i] - danger[i])
		chosen += ray_directions[i] * value

	if chosen.length_squared() < 0.0001:
		var fallback := Vector2.ZERO
		var max_idx := 0
		var max_val := -1.0

		for i in range(num_rays):
			if danger[i] > max_val:
				max_val = danger[i]
				max_idx = i

		fallback = ray_directions[max_idx].rotated(PI * 0.5)
		return fallback.normalized()

	return chosen.normalized()


func set_interest(target_pos: Vector2) -> void:
	var to_target := target_pos - global_position
	if to_target.length_squared() < 0.0001:
		return

	var dir := to_target.normalized()

	for i in range(num_rays):
		interest[i] = max(0.0, ray_directions[i].dot(dir))


func set_danger() -> void:
	var space_state := get_world_2d().direct_space_state

	for i in range(num_rays):
		var end := global_position + ray_directions[i] * look_ahead

		var query := PhysicsRayQueryParameters2D.create(global_position, end, ENEMY_MASK)
		query.exclude = [get_rid()]

		var result := space_state.intersect_ray(query)
		danger[i] = 0.0

		if result:
			var dist := global_position.distance_to(result.position)
			danger[i] = pow(1.0 - (dist / look_ahead), 0.5)

	# smoothing pass
	var smoothed := danger.duplicate()

	for i in range(num_rays):
		var prev := (i - 1 + num_rays) % num_rays
		var next := (i + 1) % num_rays

		smoothed[i] = max(danger[i], max(danger[prev] * 0.5, danger[next] * 0.5))

	danger = smoothed

	# enemy avoidance
	for i in range(num_rays):
		var end := global_position + ray_directions[i] * 32.0

		var query := PhysicsRayQueryParameters2D.create(global_position, end, OTHER_ENEMY_MASK)
		query.exclude = [get_rid()]

		var result := space_state.intersect_ray(query)

		if result:
			var dist := global_position.distance_to(result.position)
			danger[i] = max(danger[i], 0.8 * (1.0 - dist / 32.0))
