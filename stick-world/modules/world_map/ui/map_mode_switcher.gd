extends Control
class_name MapModeSwitcher
## 地图模式切换器 —— 简洁的按钮栏，用于切换不同的地图视图

## 模式管理器引用
@export var map_mode_manager: MapModeManager

## 按钮容器（HBoxContainer）
@export var button_container: Control

const MODE_DATA: Array[Dictionary] = [
	{"mode": 0, "label": "势力", "tooltip": "政治模式：按势力归属着色"},
	{"mode": 1, "label": "地形", "tooltip": "地形模式：按地块类型着色"},
	{"mode": 2, "label": "资源", "tooltip": "资源模式：按资源类型着色"},
	{"mode": 3, "label": "人口", "tooltip": "人口模式：按火柴人种类着色"},
	{"mode": 4, "label": "战线", "tooltip": "战线模式：高亮交战地块"},
]

func _ready():
	_create_buttons()

func _create_buttons():
	if button_container == null:
		return

	for data in MODE_DATA:
		var btn := Button.new()
		btn.text = data["label"]
		btn.tooltip_text = data["tooltip"]
		btn.toggle_mode = true
		btn.pressed.connect(_on_mode_button_pressed.bind(data["mode"]))
		btn.set_meta("mode", data["mode"])
		button_container.add_child(btn)

func _on_mode_button_pressed(mode: int):
	if map_mode_manager:
		map_mode_manager.switch_mode(mode)
	# 更新按钮状态
	_update_button_states(mode)

func _update_button_states(active_mode: int):
	if button_container == null:
		return
	for child in button_container.get_children():
		if child is Button:
			var btn_mode: int = child.get_meta("mode", -1)
			child.button_pressed = (btn_mode == active_mode)
