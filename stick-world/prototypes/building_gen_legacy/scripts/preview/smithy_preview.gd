@tool
extends Node2D

const GUIDE_COLORS  = [Color(0.85,0.65,0.35), Color(0.55,0.85,0.55), Color(0.35,0.55,0.85), Color(0.85,0.35,0.35)]
const GUIDE_LEFT     = -248
const GUIDE_RIGHT    = 252
const GUIDE_BASE_Y   = -24.0


func _ready():
	if Engine.is_editor_hint():
		return
	var cam = Camera2D.new()
	cam.name = "Camera"; cam.position = Vector2(0, -200); cam.enabled = true
	add_child(cam)


func _draw():
	for i in 4:
		draw_line(Vector2(GUIDE_LEFT, GUIDE_BASE_Y + i * 8.0), Vector2(GUIDE_RIGHT, GUIDE_BASE_Y + i * 8.0), GUIDE_COLORS[i], 1.0)


func _input(event):
	if Engine.is_editor_hint(): return
	var cam = get_node_or_null("Camera")
	if cam == null: return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:   cam.zoom -= Vector2(0.1, 0.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: cam.zoom += Vector2(0.1, 0.1)
	if event is InputEventKey and event.pressed:
		var o = 50.0 / cam.zoom.x
		match event.keycode:
			KEY_LEFT:  cam.position.x -= o
			KEY_RIGHT: cam.position.x += o
			KEY_UP:    cam.position.y -= o
			KEY_DOWN:  cam.position.y += o
