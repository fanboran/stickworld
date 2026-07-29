class_name WorldMapPanel
extends Control
## 大世界地图占位 UI -- 阶段 F §5.7.5
##
## P0 占位版：显示几个按钮选项，点击触发地图切换。
## Tab 键打开/关闭。正式版需要战略图模块完成（P1+）。

## 请求旅行到目标地图
signal travel_requested(target_map_id: String, entry_side: int)

var _buttons_container: VBoxContainer = null
var _is_open: bool = false
## 目的地配置：[{label, map_id, entry_side}]
var _destinations: Array = []


func _ready() -> void:
	visible = false
	_build_ui()


func _build_ui() -> void:
	# 半透明背景
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	# 面板容器
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(400, 300)
	add_child(panel)
	# 标题
	var title := Label.new()
	title.text = "大世界地图（占位）"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)
	# 按钮容器
	_buttons_container = VBoxContainer.new()
	_buttons_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_buttons_container.offset_top = 40
	_buttons_container.offset_bottom = -40
	_buttons_container.offset_left = 20
	_buttons_container.offset_right = -20
	panel.add_child(_buttons_container)
	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭 (Tab)"
	close_btn.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	close_btn.offset_top = -35
	close_btn.offset_bottom = -5
	close_btn.offset_left = 20
	close_btn.offset_right = -20
	close_btn.pressed.connect(close_panel)
	panel.add_child(close_btn)


## 设置目的地列表
func set_destinations(dests: Array) -> void:
	_destinations = dests
	_refresh_buttons()


func _refresh_buttons() -> void:
	if _buttons_container == null:
		return
	for child in _buttons_container.get_children():
		child.queue_free()
	for dest in _destinations:
		var btn := Button.new()
		btn.text = dest.get("label", "未知")
		btn.custom_minimum_size = Vector2(360, 40)
		var map_id: String = dest.get("map_id", "")
		var entry_side: int = dest.get("entry_side", 0)
		btn.pressed.connect(func(): _on_dest_selected(map_id, entry_side))
		_buttons_container.add_child(btn)


func _on_dest_selected(map_id: String, entry_side: int) -> void:
	travel_requested.emit(map_id, entry_side)
	close_panel()


func open_panel() -> void:
	_is_open = true
	visible = true


func close_panel() -> void:
	_is_open = false
	visible = false


func is_open() -> bool:
	return _is_open


func toggle() -> void:
	if _is_open:
		close_panel()
	else:
		open_panel()
