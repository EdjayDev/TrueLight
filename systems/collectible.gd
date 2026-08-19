extends Area2D
class_name Collectible

enum Type { LIGHT_FUEL, ATTACK_BOOST }

@export var type: Type = Type.LIGHT_FUEL
@export var amount: float = 10.0
@export var pickup_radius: float = 80.0   # set your CollisionShape2D to match this
@export var magnet_speed: float = 300.0
@export var collect_distance: float = 12.0

var _player: Node2D = null
var _magnet_active: bool = false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _process(delta: float) -> void:
	if _magnet_active and is_instance_valid(_player):
		var direction := (_player.global_position - global_position).normalized()
		global_position += direction * magnet_speed * delta
		if global_position.distance_to(_player.global_position) <= collect_distance:
			_collect(_player)

func _on_body_entered(body: Node2D) -> void:
	if not body is Player:
		return
	_player = body
	_magnet_active = true

func _on_body_exited(body: Node2D) -> void:
	if body == _player:
		_magnet_active = false
		_player = null

func _collect(body: Node2D) -> void:
	match type:
		Type.LIGHT_FUEL:
			_apply_effect(body, "add_fuel")
		Type.ATTACK_BOOST:
			_apply_effect(body, "add_attack_boost")
	queue_free()

func _apply_effect(body: Node, method_name: String) -> void:
	if body.has_method(method_name):
		body.call(method_name, amount)
