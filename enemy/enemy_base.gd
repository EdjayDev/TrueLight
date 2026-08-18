class_name Enemy
extends CharacterBody2D

## ------------------------------------------------------------------
## Tunables
## ------------------------------------------------------------------
@export var speed: float = 60.0
@export var chase_speed_mult: float = 1.35   # sprint when actively chasing
@export var attack_range: float = 14.0
@export var damage: int = 10

@export_group("Awareness")
@export var detection_radius: float = 180.0   # can "notice" the player within this range + LOS
@export var peripheral_radius: float = 90.0    # notices player even without clean LOS if this close
@export var lose_interest_time: float = 4.0    # seconds of no LOS before giving up the chase
@export var search_wander_time: float = 2.5    # how long it lingers at last-known position

@export_group("Combat")
@export var attack_cooldown: float = 1.1
@export var attack_windup: float = 0.28        # telegraph before the hit lands
@export var flee_health_pct: float = 0.2       # below this fraction, kite instead of trade hits
@export var flee_duration: float = 1.6

@export_group("Group Behavior")
@export var flank_spread: bool = true          # enemies fan out around the player instead of stacking
@export var max_concurrent_attackers: int = 2  # only this many enemies may attack at once; rest wait their turn
@export var orbit_speed_mult: float = 0.7      # enemies waiting their turn circle instead of piling in

@export_group("Fairness")
@export var alert_reaction_time: float = 0.35  # beat of hesitation before a freshly-spotted enemy reacts
@export var hit_stagger_time: float = 0.35     # landing a hit cancels the enemy's attack and staggers it

@onready var sprite: Sprite2D = $Sprite2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var state_machine: StateMachine = $StateMachine
@onready var health_component: HealthComponent = $HealthComponent
@onready var health_bar: ProgressBar = $HealthBar
@onready var hit_particles: CPUParticles2D = $HitParticles
@onready var los_ray: RayCast2D = $LOSRay if has_node("LOSRay") else null

var player: Player
var is_in_cutscene: bool = false

## ------------------------------------------------------------------
## AI state
## ------------------------------------------------------------------
enum AIState { IDLE, ALERT, CHASE, ATTACK, SEARCH, FLEE }

var ai_state: AIState = AIState.IDLE
var last_known_player_pos: Vector2 = Vector2.ZERO
var time_since_los: float = 0.0
var search_timer: float = 0.0
var flee_timer: float = 0.0
var attack_cooldown_timer: float = 0.0
var attack_windup_timer: float = -1.0          # -1 = not winding up
var attack_target_pos: Vector2 = Vector2.ZERO  # locked position the windup will strike
var flank_angle_offset: float = 0.0
var predicted_player_velocity: Vector2 = Vector2.ZERO
var _last_player_pos_sample: Vector2 = Vector2.ZERO

var reaction_timer: float = 0.0
var stagger_timer: float = 0.0
var has_attack_token: bool = false
var orbit_direction: float = 1.0

# Shared across all enemies: caps how many can be mid-attack at the same
# moment so the player is never forced to read/dodge more than a couple
# of telegraphs at once. Everyone else circles at range instead of piling in.
static var _active_attackers: int = 0

## ------------------------------------------------------------------
## Context steering
## ------------------------------------------------------------------
const ENEMY_MASK := 1 | 8
const OTHER_ENEMY_MASK := 4
const LOS_MASK := 1  # walls / obstacles only

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

	# Give each enemy a stable, unique flank angle so a group spreads
	# around the player instead of every unit converging on the same point.
	flank_angle_offset = deg_to_rad((get_instance_id() % 360))
	orbit_direction = 1.0 if (get_instance_id() % 2 == 0) else -1.0

	# Small per-instance jitter so a whole pack doesn't react and swing in
	# perfect lockstep — it reads as more alive and less like a metronome.
	attack_cooldown *= randf_range(0.85, 1.2)
	alert_reaction_time *= randf_range(0.75, 1.3)

	if health_component:
		health_component.health_depleted.connect(_on_died)
		health_component.health_changed.connect(_on_health_changed)

		if health_bar:
			health_bar.max_value = health_component.max_health
			health_bar.value = health_component.health

	if is_instance_valid(player):
		_last_player_pos_sample = player.global_position


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


## ------------------------------------------------------------------
## Main loop
## ------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if is_in_cutscene or not is_instance_valid(player):
		velocity = velocity.lerp(Vector2.ZERO, 0.2)
		move_and_slide()
		return

	# A landed hit buys the player a guaranteed breather: the enemy is
	# locked out of moving/attacking for a beat instead of trading blows.
	if stagger_timer > 0.0:
		stagger_timer -= delta
		velocity = velocity.lerp(Vector2.ZERO, 0.25)
		move_and_slide()
		return

	_update_player_velocity_estimate(delta)
	_update_perception(delta)
	_update_ai_state(delta)

	var dist_to_player := global_position.distance_to(player.global_position)
	var is_orbiting := ai_state == AIState.CHASE and not has_attack_token \
			and dist_to_player <= attack_range + 6.0

	var dir := _get_movement_direction_for_state(delta)

	var target_speed := speed
	if is_orbiting:
		target_speed = speed * orbit_speed_mult
	elif ai_state == AIState.CHASE:
		target_speed *= chase_speed_mult
	elif ai_state == AIState.FLEE:
		target_speed *= 1.1

	# Freeze movement mid-attack-windup so the telegraph is readable.
	if attack_windup_timer >= 0.0:
		dir = Vector2.ZERO

	# Enemies mid-reaction-delay hesitate visibly instead of instantly snapping to you.
	if ai_state == AIState.ALERT and reaction_timer > 0.0:
		dir = Vector2.ZERO

	velocity = velocity.lerp(dir * target_speed, 0.15)

	if dir.length_squared() > 0.0001:
		play_directional_animation("move", dir)
	elif ai_state == AIState.ATTACK:
		play_directional_animation("attack", _facing_direction())

	move_and_slide()


func _update_player_velocity_estimate(delta: float) -> void:
	if delta <= 0.0:
		return
	var current_pos := player.global_position
	predicted_player_velocity = (current_pos - _last_player_pos_sample) / delta
	_last_player_pos_sample = current_pos


## ------------------------------------------------------------------
## Perception: line-of-sight + memory, instead of omniscient tracking
## ------------------------------------------------------------------
func _update_perception(delta: float) -> void:
	var dist := global_position.distance_to(player.global_position)
	var can_see := dist <= peripheral_radius or (dist <= detection_radius and _has_line_of_sight())

	if can_see:
		last_known_player_pos = player.global_position
		time_since_los = 0.0
	else:
		time_since_los += delta


func _has_line_of_sight() -> bool:
	if los_ray == null:
		# No LOSRay child configured; fall back to a one-off physics query.
		var space_state := get_world_2d().direct_space_state
		var query := PhysicsRayQueryParameters2D.create(global_position, player.global_position, LOS_MASK)
		query.exclude = [get_rid()]
		var result := space_state.intersect_ray(query)
		return result.is_empty()

	los_ray.global_position = global_position
	los_ray.target_position = to_local(player.global_position)
	los_ray.force_raycast_update()
	return not los_ray.is_colliding()


## ------------------------------------------------------------------
## State machine: decides *why* the enemy is moving, not just *how*
## ------------------------------------------------------------------
func _update_ai_state(delta: float) -> void:
	var dist_to_player := global_position.distance_to(player.global_position)
	var can_see := time_since_los <= 0.05

	# Low-health kiting takes priority over everything else.
	if health_component and health_component.health <= health_component.max_health * flee_health_pct:
		if ai_state != AIState.FLEE:
			_release_attack_token()
			flee_timer = flee_duration
			ai_state = AIState.FLEE
	elif ai_state == AIState.FLEE:
		flee_timer -= delta
		if flee_timer <= 0.0:
			ai_state = AIState.ALERT if can_see else AIState.SEARCH

	if ai_state == AIState.FLEE:
		return

	match ai_state:
		AIState.IDLE:
			if can_see or (dist_to_player <= detection_radius and time_since_los < lose_interest_time * 0.3):
				# Spotting the player doesn't mean instantly reacting — a short
				# beat of "wait, what was that" gives the player room to react first.
				ai_state = AIState.ALERT
				reaction_timer = alert_reaction_time

		AIState.ALERT:
			if reaction_timer > 0.0:
				reaction_timer -= delta
			elif not can_see and time_since_los > lose_interest_time:
				ai_state = AIState.SEARCH
				search_timer = search_wander_time
			elif can_see:
				ai_state = AIState.CHASE

		AIState.CHASE:
			if not can_see and time_since_los > lose_interest_time:
				ai_state = AIState.SEARCH
				search_timer = search_wander_time
			elif dist_to_player <= attack_range + 6.0 and can_see:
				if _try_acquire_attack_token():
					ai_state = AIState.ATTACK
				# else: no free attack slot right now — stays in CHASE, which
				# makes it orbit at range instead of shoving into melee (see
				# _get_movement_direction_for_state / is_orbiting).

		AIState.ATTACK:
			if dist_to_player > attack_range + 12.0 or not can_see:
				_release_attack_token()
				ai_state = AIState.CHASE if can_see else AIState.SEARCH
				search_timer = search_wander_time
			else:
				_process_attack(delta)

		AIState.SEARCH:
			if can_see:
				ai_state = AIState.ALERT
				reaction_timer = alert_reaction_time * 0.4  # quicker to re-engage once already alert once
			else:
				search_timer -= delta
				if search_timer <= 0.0:
					ai_state = AIState.IDLE

	if attack_cooldown_timer > 0.0:
		attack_cooldown_timer -= delta


func _process_attack(delta: float) -> void:
	if attack_windup_timer >= 0.0:
		attack_windup_timer -= delta
		if attack_windup_timer <= 0.0:
			attack_windup_timer = -1.0
			deal_damage_at(attack_target_pos)
			attack_cooldown_timer = attack_cooldown
			# Free the slot right away rather than holding it through the
			# whole cooldown — lets a packmate take its turn while this one
			# backs off, instead of one enemy hogging the "active" role.
			_release_attack_token()
		return

	if attack_cooldown_timer <= 0.0:
		# Lock in the strike point now so a sidestep after the windup starts
		# can actually dodge the hit — rewards player movement.
		attack_target_pos = player.global_position
		attack_windup_timer = attack_windup
		if animation_player and animation_player.has_animation("windup"):
			animation_player.play("windup")


func _try_acquire_attack_token() -> bool:
	if has_attack_token:
		return true
	if Enemy._active_attackers < max_concurrent_attackers:
		Enemy._active_attackers += 1
		has_attack_token = true
		return true
	return false


func _release_attack_token() -> void:
	if has_attack_token:
		Enemy._active_attackers = max(0, Enemy._active_attackers - 1)
		has_attack_token = false


func _exit_tree() -> void:
	# Don't let a killed-mid-attack enemy permanently eat a slot in the pool.
	_release_attack_token()


## ------------------------------------------------------------------
## Movement per state
## ------------------------------------------------------------------
func _get_movement_direction_for_state(_delta: float) -> Vector2:
	match ai_state:
		AIState.IDLE:
			return Vector2.ZERO

		AIState.ALERT:
			# Cautious approach: move toward last known position, slower reaction.
			return get_steering_direction(last_known_player_pos)

		AIState.CHASE:
			var dist := global_position.distance_to(player.global_position)
			if not has_attack_token and dist <= attack_range + 6.0:
				return _get_orbit_direction()
			return get_steering_direction(_get_intercept_point())

		AIState.ATTACK:
			return Vector2.ZERO

		AIState.SEARCH:
			return get_steering_direction(last_known_player_pos)

		AIState.FLEE:
			return _get_flee_direction()

	return Vector2.ZERO


func _get_intercept_point() -> Vector2:
	# Aim slightly ahead of the player's current velocity so the enemy
	# leads its target instead of always trailing directly behind it.
	var dist := global_position.distance_to(player.global_position)
	var time_to_reach := dist / max(speed * chase_speed_mult, 1.0)
	# Capped and scaled down: a partial, believable read on where you're
	# headed rather than a perfect intercept every time.
	var lead := predicted_player_velocity * clampf(time_to_reach, 0.0, 0.4) * 0.7
	var base_target := player.global_position + lead

	if flank_spread:
		var to_enemy := (global_position - player.global_position)
		if to_enemy.length_squared() > 0.0001:
			var desired_dir := to_enemy.normalized().rotated(flank_angle_offset * 0.15)
			# Blend a flank offset in near the player so the group approaches
			# from spread angles rather than a single file line.
			var flank_point := player.global_position + desired_dir * attack_range * 1.5
			base_target = base_target.lerp(flank_point, 0.35)

	return base_target


func _get_orbit_direction() -> Vector2:
	# Waiting-your-turn behavior: circle the player at roughly attack range
	# instead of shoving into melee on top of the enemy that has the token.
	# This is what actually keeps fights readable — the player faces one or
	# two live threats at a time instead of a wall of simultaneous hits.
	var to_player := player.global_position - global_position
	if to_player.length_squared() < 0.0001:
		return Vector2.ZERO

	var tangent := to_player.normalized().rotated(PI * 0.5 * orbit_direction)
	var radial_error := to_player.length() - (attack_range + 6.0)
	var inward := to_player.normalized() * clampf(radial_error * 0.02, -1.0, 1.0)

	set_danger()
	var desired := (tangent + inward).normalized()

	var chosen := Vector2.ZERO
	for i in range(num_rays):
		var alignment := max(0.0, ray_directions[i].dot(desired))
		var value := max(0.0, alignment - danger[i])
		chosen += ray_directions[i] * value

	if chosen.length_squared() < 0.0001:
		return desired
	return chosen.normalized()


func _get_flee_direction() -> Vector2:
	var away := (global_position - player.global_position)
	if away.length_squared() < 0.0001:
		away = Vector2.RIGHT.rotated(flank_angle_offset)
	# Still run danger/avoidance so fleeing enemies don't clip into walls
	# or stack on top of each other.
	set_danger()
	var desired := away.normalized()

	var chosen := Vector2.ZERO
	for i in range(num_rays):
		var alignment := max(0.0, ray_directions[i].dot(desired))
		var value := max(0.0, alignment - danger[i])
		chosen += ray_directions[i] * value

	if chosen.length_squared() < 0.0001:
		return desired
	return chosen.normalized()


func _facing_direction() -> Vector2:
	if velocity.length_squared() > 0.01:
		return velocity.normalized()
	return (player.global_position - global_position).normalized()


## ------------------------------------------------------------------
## Damage / feedback
## ------------------------------------------------------------------
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

	# Getting hit always refreshes awareness, even from off-screen or behind.
	if is_instance_valid(player):
		last_known_player_pos = player.global_position
		time_since_los = 0.0
		if ai_state == AIState.IDLE or ai_state == AIState.SEARCH:
			ai_state = AIState.ALERT

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

	if animation_player and animation_player.has_animation(anim_base + suffix):
		animation_player.play(anim_base + suffix)


func _on_died() -> void:
	if state_machine:
		state_machine.on_child_transition("death")
		return

	if animation_player:
		animation_player.play("death")
		await animation_player.animation_finished

	queue_free()


func deal_damage_at(target_snapshot_pos: Vector2) -> void:
	if not is_instance_valid(player):
		return

	# The strike lands where the player *was* when the windup locked in,
	# so a dodge after the telegraph actually avoids the hit.
	if global_position.distance_to(target_snapshot_pos) <= attack_range + 5.0 \
			and global_position.distance_to(player.global_position) <= attack_range + 14.0:
		var health := player.get_node_or_null("HealthComponent")
		if health:
			health.damage(damage)


## Kept for backward compatibility with external callers (e.g. animation
## call methods) that still invoke the old no-arg signature.
func deal_damage() -> void:
	deal_damage_at(player.global_position if is_instance_valid(player) else global_position)


## ------------------------------------------------------------------
## Context steering (unchanged core algorithm, now driven by a target
## point chosen by the state machine rather than always the player)
## ------------------------------------------------------------------
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
