class_name WorldMapPanel
extends Control
## 大世界地图导航面板 -- 阶段 F §5.7.5（2026-08 升级：目的地动态生成）。
##
## Tab 键 / 顶边界停留 3 秒打开。打开时按**当前地图**动态生成目的地：
##   1. 当前地图的步行出口（左右边界各一，SceneLoader 出口配置）
##   2. 快速旅行：其余全部已注册地图
## 点击按钮触发 travel_requested（由 SystemSetup 转发 SceneLoader）。
##
## 与 dev_playtest/主页菜单互补：本面板是游戏内"去哪"的入口。

## 请求旅行到目标地图
signal travel_requested(target_map_id: String, entry_side: int)

var _buttons_container: VBoxContainer = null
var _is_open: bool = false
## SceneLoader 引用（由 SystemSetup 注入，用于动态查询出口/地图）
var _scene_loader: Node = null

## 地图显示名（map_id -> 中文名）
const MAP_DISPLAY_NAMES: Dictionary = {
	"village_a": "村落 A（初始村）",
	"village_b": "村落 B",
	"road_a_b": "道路（村落 A↔B）",
	"battlefield": "遭遇战战场",
	"forest_zone": "森林区域",
	"mega_interior": "大建筑内部",
}


func _ready() -> void:
	visible = false
	_build_ui()


func _build_ui() -> void:
	# 半透明背景
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	# 面板容器（anchors + offsets 同时设置才真正居中）
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(440, 400)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	add_child(panel)
	# 标题
	var title := Label.new()
	title.text = "大世界地图（简易导航）"
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


## 注入 SceneLoader 引用（由 SystemSetup 调用）。
func setup(scene_loader: Node) -> void:
	_scene_loader = scene_loader


## 打开面板：按当前地图动态生成目的地。
func open_panel() -> void:
	_is_open = true
	visible = true
	_refresh_dynamic_destinations()


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


## 按当前地图动态生成目的地并渲染：
## 1) 步行出口（左右边界）2) 快速旅行（其余全部地图）
func _refresh_dynamic_destinations() -> void:
	if _buttons_container == null:
		return
	for child in _buttons_container.get_children():
		child.queue_free()
	if _scene_loader == null or not _scene_loader.has_method("get_current_map_id"):
		var hint := Label.new()
		hint.text = "（SceneLoader 未注入）"
		_buttons_container.add_child(hint)
		return
	var current_id: String = _scene_loader.get_current_map_id()
	# 1. 步行出口
	var exit_added: int = 0
	for side in [WorldAPI.EntrySide.LEFT, WorldAPI.EntrySide.RIGHT]:
		var exit: Dictionary = _scene_loader.get_map_exit(current_id, side) if _scene_loader.has_method("get_map_exit") else {}
		if exit.is_empty():
			continue
		var target: String = exit.get("target", "")
		if target.is_empty() or target == current_id:
			continue
		var side_name: String = "左边界" if side == WorldAPI.EntrySide.LEFT else "右边界"
		var btn := Button.new()
		btn.text = "步行：%s → %s" % [side_name, _display_name(target)]
		btn.custom_minimum_size = Vector2(380, 36)
		btn.pressed.connect(_on_dest_selected.bind(target, exit.get("entry", WorldAPI.EntrySide.LEFT)))
		_buttons_container.add_child(btn)
		exit_added += 1
	if exit_added == 0:
		var hint := Label.new()
		hint.text = "（当前地图无步行出口）"
		_buttons_container.add_child(hint)
	# 2. 快速旅行：其余全部地图
	var fast_title := Label.new()
	fast_title.text = "快速旅行（测试用）："
	fast_title.add_theme_font_size_override("font_size", 11)
	fast_title.modulate = Color(0.7, 0.7, 0.7)
	_buttons_container.add_child(fast_title)
	var ids: Array = _scene_loader.get_registered_map_ids() if _scene_loader.has_method("get_registered_map_ids") else []
	for map_id in ids:
		if map_id == current_id:
			continue
		var btn := Button.new()
		btn.text = "前往 %s" % _display_name(map_id)
		btn.custom_minimum_size = Vector2(380, 36)
		btn.pressed.connect(_on_dest_selected.bind(map_id, WorldAPI.EntrySide.LEFT))
		_buttons_container.add_child(btn)


## map_id -> 显示名
func _display_name(map_id: String) -> String:
	return MAP_DISPLAY_NAMES.get(map_id, map_id)


func _on_dest_selected(map_id: String, entry_side: int) -> void:
	travel_requested.emit(map_id, entry_side)
	close_panel()
