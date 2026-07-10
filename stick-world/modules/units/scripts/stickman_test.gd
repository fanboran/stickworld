extends Node2D
## 火柴人渲染测试控制器
##
## 按 1/2/3/4 切换 idle/walk/attack/dead 动画
## 按 ←/-> 移动火柴人，按 ↑/↓ 缩放

const RigScript = preload("res://modules/units/scripts/stickman_rig.gd")

var _rig: Node2D
var _label: Label
var _anim_names: Array[String] = ["idle", "walk", "attack", "dead"]


func _ready() -> void:
	# 使用场景中已有的 StickmanRig 节点，不再新建
	_rig = get_node("StickmanRig") as Node2D
	_rig.position = Vector2(400, 300)
	_rig.scale = Vector2(0.8, 0.8)

	# 状态标签
	_label = Label.new()
	_label.position = Vector2(10, 10)
	_label.text = "[1] idle  [2] walk  [3] attack  [4] dead  | ←/→ 移动  ↑/↓ 缩放"
	add_child(_label)

	# 动画名标签
	var anim_label := Label.new()
	anim_label.name = "AnimLabel"
	anim_label.position = Vector2(10, 35)
	anim_label.text = "当前动画: idle"
	anim_label.add_theme_font_size_override("font_size", 20)
	add_child(anim_label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var key := event as InputEventKey
		match key.keycode:
			KEY_1:
				_switch_anim(0)
			KEY_2:
				_switch_anim(1)
			KEY_3:
				_switch_anim(2)
			KEY_4:
				_switch_anim(3)
			KEY_LEFT:
				_rig.position.x -= 20
			KEY_RIGHT:
				_rig.position.x += 20
			KEY_UP:
				_rig.scale *= 1.1
			KEY_DOWN:
				_rig.scale *= 0.9


func _switch_anim(index: int) -> void:
	if index < 0 or index >= _anim_names.size():
		return
	var anim_name: String = _anim_names[index]
	_rig.play(anim_name)
	var lbl := get_node_or_null("AnimLabel") as Label
	if lbl:
		lbl.text = "当前动画: %s" % anim_name