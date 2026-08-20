extends Node2D

@onready var point_light: PointLight2D = $PointLight2D

func _ready() -> void:
	_start_glow_tween()

func _start_glow_tween() -> void:
	var tween = create_tween().set_loops()
	# Smoothly pulse energy between 0.5 and 1.8 over 1.2 seconds
	tween.tween_property(point_light, "energy", 1.8, 1.2).from(0.5)
	tween.tween_property(point_light, "energy", 0.5, 1.2).from(1.8)
