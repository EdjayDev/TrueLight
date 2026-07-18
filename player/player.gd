extends CharacterBody2D
class_name Player

signal fuel_changed(new_fuel: float)

@onready var player_sprite: Sprite2D = $player_sprite

const SPEED = 100.0
var animation_direction : String = "down"
var last_animation : String = ""
var state : String = "idle"

@onready var player_animation: AnimationPlayer = $player_animation
@onready var camera: Camera2D = $Camera2D

var is_in_cutscene : bool = false
var flicker_timer : float = 0.0
var shake_intensity : float = 0.0
var shake_duration : float = 0.0

var fuel: float = 100.0
var max_fuel: float = 100.0
var attack_boost_timer: float = 0.0
var base_damage: int = 25
var current_damage: int = 25

var breadcrumb_timer: float = 0.0
const BREADCRUMB_INTERVAL = 0.5

@onready var light: PointLight2D = $PointLight2D

func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	add_to_group("player")

	# ✅ Camera smoothing
	camera.enabled = true
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 6.0 # tweak (3–10 range)

	var health = get_node_or_null("HealthComponent")
	if health:
		health.health_depleted.connect(_on_died)
		health.health_changed.connect(_on_health_changed)

func _process(delta: float) -> void:
	# Fuel depletion
	if fuel > 0:
		fuel -= delta * 2.0
		fuel = max(0, fuel)
		fuel_changed.emit(fuel)

	# Light behavior
	if light:
		var fuel_ratio = fuel / max_fuel
		light.energy = 0.5 + (fuel_ratio * 0.5)
		light.texture_scale = 1.0 + (fuel_ratio * 1.5)
		
		if fuel < 20:
			flicker_timer += delta * 10
			light.energy *= 0.8 + (sin(flicker_timer) * 0.2)

	# Attack boost
	if attack_boost_timer > 0:
		attack_boost_timer -= delta
		current_damage = base_damage * 2
		player_sprite.modulate = Color(1.5, 0.5, 0.5)
	else:
		current_damage = base_damage
		if player_sprite.modulate != Color.WHITE:
			player_sprite.modulate = Color.WHITE

	# Breadcrumbs
	breadcrumb_timer += delta
	if breadcrumb_timer >= BREADCRUMB_INTERVAL:
		breadcrumb_timer = 0.0
		BreadcrumbManager.add_breadcrumb(global_position)

	# Camera shake (works with smoothing)
	if shake_duration > 0:
		shake_duration -= delta
		camera.offset = Vector2(
			randf_range(-shake_intensity, shake_intensity),
			randf_range(-shake_intensity, shake_intensity)
		)
	else:
		camera.offset = Vector2.ZERO

func apply_shake(intensity: float, duration: float) -> void:
	shake_intensity = intensity
	shake_duration = duration

func _on_health_changed(_old: float, new_health: float) -> void:
	apply_shake(3.0, 0.3)
	
	var tween = create_tween()
	player_sprite.modulate = Color.RED
	tween.tween_property(player_sprite, "modulate", Color.WHITE, 0.2)
	
	var health = get_node_or_null("HealthComponent")
	if health and health.health < 30:
		flicker_timer += 4.5

func _on_died() -> void:
	print("Player died!")
	var game = get_tree().root.get_node_or_null("Game")
	if game and game.has_method("game_over"):
		game.game_over()
	else:
		get_tree().reload_current_scene()

func _physics_process(_delta: float) -> void:
	if is_in_cutscene:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if Input.is_action_just_pressed("Attack") and state != "attack":
		attack()
	
	if state == "attack":
		return

	var direction := Vector2(Input.get_axis("Left", "Right"), Input.get_axis("Up", "Down"))
	if not direction:
		direction = Vector2(Input.get_axis("ui_left", "ui_right"), Input.get_axis("ui_up", "ui_down"))
	
	if direction != Vector2.ZERO:
		state = "walk"
		if abs(direction.x) > abs(direction.y):
			animation_direction = "side"
			player_sprite.scale.x = -1.0 if direction.x > 0 else 1.0
		else:
			animation_direction = "down" if direction.y > 0 else "up"
		velocity = direction.normalized() * SPEED
	else:
		state = "idle"
		velocity = velocity.move_toward(Vector2.ZERO, SPEED)
	
	update_animation()
	move_and_slide()

func update_animation()->void:
	var current_animation = state + "_" + animation_direction
	if current_animation != last_animation:
		player_animation.play(current_animation)
		last_animation = current_animation

func attack() -> void:
	state = "attack"
	update_animation()
	await player_animation.animation_finished
	state = "idle"
	last_animation = ""

func deal_damage() -> void:
	var attack_pos = global_position
	if animation_direction == "side":
		attack_pos += Vector2(12 * player_sprite.scale.x * -1, 0)
	elif animation_direction == "down":
		attack_pos += Vector2(0, 12)
	elif animation_direction == "up":
		attack_pos += Vector2(0, -12)

	for enemy in get_tree().get_nodes_in_group("enemy"):
		if global_position.distance_to(enemy.global_position) < 20.0:
			var health = enemy.get_node_or_null("HealthComponent")
			if health:
				health.damage(current_damage)

func add_fuel(amount: float) -> void:
	fuel = min(max_fuel, fuel + amount)
	var tween = create_tween()
	tween.tween_property(light, "energy", 2.0, 0.2)
	tween.tween_property(light, "energy", 1.0, 0.2)

func add_attack_boost(duration: float) -> void:
	attack_boost_timer = duration
	current_damage = base_damage * 2
