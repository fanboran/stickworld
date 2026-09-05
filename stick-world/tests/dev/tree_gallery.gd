extends Node2D
## 树/石变体画廊 —— 手动验收场景（Godot 编辑器打开 tree_gallery.tscn 按 F6 运行）。
## 方向键/WASD 平移视口；展品按游戏内实际显示尺寸摆放（树 480×840、石 120×94），
## 每件下方标注变体号。验收点：干棕/冠绿是否分清、边缘有无白边黑边、变体差异、树形比例。

const SPEED := 900.0
var _cam: Camera2D


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.72, 0.78, 0.85)
	bg.size = Vector2(12000, 2200)
	bg.position = Vector2(-400, -300)
	add_child(bg)
	var ground := ColorRect.new()
	ground.color = Color(0.42, 0.52, 0.33)
	ground.size = Vector2(12000, 6)
	ground.position = Vector2(-400, 1000)
	add_child(ground)
	var ground2 := ground.duplicate() as ColorRect
	ground2.position = Vector2(-400, 1700)
	add_child(ground2)

	_cam = Camera2D.new()
	_cam.position = Vector2(500, 400)
	add_child(_cam)
	_cam.make_current()

	# 第一排：树 10 棵（显示基线 500×1080 ≈ 火柴人 260px 身高的 4.2 倍；贴图内自带高度差）
	for i in 10:
		_place("res://assets/resources/tree_paint_tree_v%d.png" % i,
			Vector2(i * 640.0, 1000.0), Vector2(570.0, 998.0), "树 v%d" % i)
	# 第二排：石头 6 + 铁矿 4
	for j in 6:
		_place("res://assets/resources/stone_paint_stone_v%d.png" % j,
			Vector2(j * 300.0, 1700.0), Vector2(120.0, 94.0), "石 v%d" % j)
	for k in 4:
		_place("res://assets/resources/metal_paint_metal_v%d.png" % k,
			Vector2(1900.0 + k * 300.0, 1700.0), Vector2(120.0, 94.0), "铁 v%d" % k)


func _place(path: String, base: Vector2, size: Vector2, tag: String) -> void:
	var spr := Sprite2D.new()
	spr.texture = load(path)
	spr.scale = size / Vector2(spr.texture.get_width(), spr.texture.get_height())
	spr.position = base + Vector2(0.0, -size.y * 0.5)
	add_child(spr)
	var label := Label.new()
	label.text = tag
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(0.1, 0.1, 0.12))
	label.position = base + Vector2(-40.0, 10.0)
	add_child(label)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		get_tree().change_scene_to_file("res://modules/ui_global/scenes/menus/main_menu.tscn")
		return
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.y += 1.0
	_cam.position += dir * SPEED * delta
