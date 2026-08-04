class_name BuildMenu
extends Control
## 建造菜单 UI -- 阶段 E 任务 E1。
##
## 详见 docs/项目/P0收口执行计划.md §七.5 E.2。
## EXPLORE 模式下显示"建造"按钮，点击展开建筑列表（仅已注册场景的类型）。
## 选中建筑类型进入选址模式：鼠标移动显示半透明 ghost 预览，左键确认建造，右键/Esc 取消。
## 资源不足或无场景的建筑类型灰显。由 GameRoot 在 _ready 中 set_script 装配，setup(game_root)。

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _construction_manager: Node = null
var _construction_api: Node = null
var _resources_api: Node = null
var _input_dispatcher: Node = null
var _camera_rig: Camera2D = null

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _toggle_btn: Button = null
var _list_panel: PanelContainer = null
var _list_container: VBoxContainer = null
var _hint_label: Label = null  # 选址模式提示

# ─────────────────────────────── 选址状态 ────────────────────────────────
var _placing: bool = false
var _placing_def_id: String = ""
var _ghost: Polygon2D = null
## ghost 预览高度（像素，向上，接近大多数建筑视觉高度）
const _GHOST_HEIGHT: float = 280.0
const _CELL_SIZE: int = 32

# ─────────────────────────────── 配置 ────────────────────────────────
## 建造使用的 region_id（与初始资源扣减一致）
const _BUILD_REGION: String = "test_region"

## 建筑成本字段 → 资源 id 映射（def 字段名 → ResourcesApi 资源 id）
const _COST_FIELD_TO_RESOURCE: Dictionary = {
	"build_cost_wood": "res_wood",
	"build_cost_stone": "res_stone",
	"build_cost_metal": "res_metal_ore",
}

## 建筑成本字段 → 显示名
const _COST_FIELD_ZH: Dictionary = {
	"build_cost_wood": "木",
	"build_cost_stone": "石",
	"build_cost_metal": "铁",
}


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 GameRoot 调用，注入引用并构建 UI。
func setup(game_root: Node) -> void:
	# 始终接收输入（即使游戏暂停，建造菜单仍可取消）
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)
	_game_root = game_root
	_construction_manager = game_root.get_construction_manager() if game_root.has_method("get_construction_manager") else null
	_construction_api = game_root.get_construction_api() if game_root.has_method("get_construction_api") else null
	_resources_api = game_root.get_resources_api() if game_root.has_method("get_resources_api") else null
	_input_dispatcher = game_root.get("input_dispatcher") if "input_dispatcher" in game_root else null
	_camera_rig = game_root.get("camera_rig") if "camera_rig" in game_root else null
	_build_ui()
	_refresh_list()
	# 监听资源变化刷新按钮可用性
	if _resources_api != null and _resources_api.has_signal("resource_changed"):
		_resources_api.resource_changed.connect(_on_resource_changed)
	# 监听模式切换，仅 EXPLORE 显示建造按钮
	if _input_dispatcher != null and _input_dispatcher.has_signal("mode_changed"):
		_input_dispatcher.mode_changed.connect(_on_mode_changed)
	_update_visibility()
	set_process(false)  # 选址模式才开启


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	# 父 Control 的位置/范围由 ui_root.tscn 预置节点配置（编辑器可见可调）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 右下角"建造"按钮（避开左侧 ResourceBar）
	_toggle_btn = Button.new()
	_toggle_btn.name = "ToggleBtn"
	_toggle_btn.text = "建造"
	_toggle_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_toggle_btn.offset_left = -108.0
	_toggle_btn.offset_top = -48.0
	_toggle_btn.offset_right = -12.0
	_toggle_btn.offset_bottom = -12.0
	_toggle_btn.pressed.connect(_on_toggle_pressed)
	add_child(_toggle_btn)
	# 建筑列表面板（按钮上方，右侧）
	_list_panel = PanelContainer.new()
	_list_panel.name = "ListPanel"
	_list_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_list_panel.offset_left = -220.0
	_list_panel.offset_top = -470.0
	_list_panel.offset_right = -12.0
	_list_panel.offset_bottom = -54.0
	_list_panel.visible = false
	add_child(_list_panel)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_list_panel.add_child(scroll)
	_list_container = VBoxContainer.new()
	_list_container.name = "List"
	_list_container.add_theme_constant_override("separation", 4)
	scroll.add_child(_list_container)
	# 选址模式提示（顶部居中偏右，GlobalHUD 下方且避开地图中央）
	_hint_label = Label.new()
	_hint_label.name = "HintLabel"
	_hint_label.text = "选址模式：左键建造 | 右键/Esc 取消"
	_hint_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hint_label.offset_left = -440.0
	_hint_label.offset_top = 80.0
	_hint_label.offset_right = -12.0
	_hint_label.offset_bottom = 104.0
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint_label.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	_hint_label.add_theme_font_size_override("font_size", 14)
	_hint_label.visible = false
	add_child(_hint_label)


# ─────────────────────────────── 建筑列表 ────────────────────────────────

## 刷新建筑列表（仅显示已注册场景的类型）
func _refresh_list() -> void:
	if _list_container == null or _construction_manager == null:
		return
	for child in _list_container.get_children():
		child.queue_free()
	if not _construction_manager.has_method("get_registered_def_ids"):
		return
	var registered: Array = _construction_manager.get_registered_def_ids()
	for def_id in registered:
		var def: Dictionary = _construction_manager.get_building_def(def_id) if _construction_manager.has_method("get_building_def") else {}
		if def.is_empty():
			continue
		var entry := _create_build_entry(def_id, def)
		_list_container.add_child(entry)
	if _list_container.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "（无可建建筑）"
		_list_container.add_child(empty)


## 创建单个建筑条目（按钮 + 资源消耗摘要）
func _create_build_entry(def_id: String, def: Dictionary) -> Control:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	var btn := Button.new()
	btn.text = str(def.get("name_zh", def_id))
	btn.custom_minimum_size = Vector2(0, 30)
	btn.pressed.connect(_on_building_selected.bind(def_id))
	vbox.add_child(btn)
	# 资源消耗摘要
	var cost_label := Label.new()
	cost_label.text = _format_cost(def)
	cost_label.add_theme_font_size_override("font_size", 11)
	cost_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	vbox.add_child(cost_label)
	# 资源不足时灰显按钮
	if not _can_afford(def):
		btn.disabled = true
		btn.modulate = Color(0.6, 0.6, 0.6)
	# 把按钮存到 entry 元数据，便于刷新
	vbox.set_meta("btn", btn)
	vbox.set_meta("def", def)
	return vbox


## 格式化资源消耗文本
func _format_cost(def: Dictionary) -> String:
	var parts: Array = []
	for field: String in _COST_FIELD_TO_RESOURCE.keys():
		var v: float = float(def.get(field, 0))
		if v > 0:
			parts.append("%s:%d" % [_COST_FIELD_ZH.get(field, field), int(v)])
	if parts.is_empty():
		return "免费"
	return " · ".join(parts)


## 检查资源是否足够建造
func _can_afford(def: Dictionary) -> bool:
	if _resources_api == null:
		return true
	for field: String in _COST_FIELD_TO_RESOURCE.keys():
		var v: float = float(def.get(field, 0))
		if v <= 0:
			continue
		var res_id: String = _COST_FIELD_TO_RESOURCE[field]
		var stock: float = _resources_api.get_stock(res_id, _BUILD_REGION) if _resources_api.has_method("get_stock") else 0.0
		if stock < v:
			return false
	return true


# ─────────────────────────────── 信号回调 ────────────────────────────────

func _on_resource_changed(_rid: String, _amt: float, _delta: float, _region: String) -> void:
	_refresh_list()


func _on_mode_changed(_old: int, new_mode: int) -> void:
	_update_visibility()
	# 离开 EXPLORE 时取消选址
	if _placing and new_mode != PlayerControlAPI.Mode.EXPLORE:
		_cancel_placing()


func _update_visibility() -> void:
	var explore: bool = _input_dispatcher != null and _input_dispatcher.has_method("get_mode") and _input_dispatcher.get_mode() == PlayerControlAPI.Mode.EXPLORE
	_toggle_btn.visible = explore
	if not explore:
		_list_panel.visible = false
		_cancel_placing()


# ─────────────────────────────── 按钮回调 ────────────────────────────────

func _on_toggle_pressed() -> void:
	_list_panel.visible = not _list_panel.visible
	if _list_panel.visible:
		_refresh_list()


func _on_building_selected(def_id: String) -> void:
	_list_panel.visible = false
	_start_placing(def_id)


# ─────────────────────────────── 选址模式 ────────────────────────────────

func _start_placing(def_id: String) -> void:
	_placing_def_id = def_id
	_placing = true
	_hint_label.visible = true
	_toggle_btn.visible = false
	# 创建 ghost（挂到当前地图的 BuildMaskLayer）
	var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	if map != null:
		var mask_layer: Node2D = map.get("build_mask_layer") if "build_mask_layer" in map else null
		if mask_layer == null:
			mask_layer = map.get_node_or_null("BuildMaskLayer")
		if mask_layer != null:
			_ghost = Polygon2D.new()
			_ghost.color = Color(0.2, 0.9, 0.3, 0.35)
			_ghost.z_index = 20
			mask_layer.add_child(_ghost)
	set_process(true)


func _cancel_placing() -> void:
	_placing = false
	_placing_def_id = ""
	_hint_label.visible = false
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
		_ghost = null
	set_process(false)
	# 恢复建造按钮可见性
	if _input_dispatcher != null and _input_dispatcher.has_method("get_mode") and _input_dispatcher.get_mode() == PlayerControlAPI.Mode.EXPLORE:
		_toggle_btn.visible = true


func _confirm_place() -> void:
	if not _placing or _placing_def_id.is_empty():
		return
	# 2026-08 收敛：建造走 ConstructionApi（发射 building_started 信号），查询仍走模块内 manager
	var api: Node = _construction_api if _construction_api != null else _construction_manager
	if api == null or not api.has_method("start_construction_at"):
		return
	var world_x: float = _get_mouse_world_x()
	var cell_x: int = int(floor(world_x / float(_CELL_SIZE)))
	var result: Dictionary = api.start_construction_at(_BUILD_REGION, _placing_def_id, cell_x, "")
	if result.get("ok", false):
		_show_notify("开始建造: %s (cell=%d)" % [_placing_def_id, cell_x])
	else:
		_show_notify("建造失败: %s" % result.get("error", "未知错误"))
	# 建造后退出选址模式
	_cancel_placing()


# ─────────────────────────────── 每帧更新 ghost ────────────────────────────────

func _process(_delta: float) -> void:
	if not _placing or _ghost == null or not is_instance_valid(_ghost):
		return
	var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	if map == null:
		return
	var def: Dictionary = _construction_manager.get_building_def(_placing_def_id) if _construction_manager.has_method("get_building_def") else {}
	var width: int = int(def.get("width", 2))
	var world_x: float = _get_mouse_world_x()
	var cell_x: int = int(floor(world_x / float(_CELL_SIZE)))
	var ground_y: float = float(map.get("ground_y") if "ground_y" in map else 810.0)
	# 实际建筑底部对齐 baseline = ground_y + baseline_offset（地平线向下）
	var baseline_offset: float = float(map.get("building_baseline_offset") if "building_baseline_offset" in map else 96.0)
	var baseline: float = ground_y + baseline_offset
	var left: float = float(cell_x) * float(_CELL_SIZE)
	var right: float = float(cell_x + width) * float(_CELL_SIZE)
	var top: float = baseline - _GHOST_HEIGHT
	_ghost.polygon = PackedVector2Array([
		Vector2(left, baseline),
		Vector2(right, baseline),
		Vector2(right, top),
		Vector2(left, top),
	])
	# 超出地图边界时变红提示
	var ml: float = float(map.get("map_left") if "map_left" in map else 0.0)
	var mr: float = float(map.get("map_right") if "map_right" in map else 8192.0)
	if left < ml or right > mr:
		_ghost.color = Color(0.9, 0.2, 0.2, 0.35)
	else:
		_ghost.color = Color(0.2, 0.9, 0.3, 0.35)


# ─────────────────────────────── 输入处理 ────────────────────────────────

## 选址模式下用 _input 抢回事件（先于任何 _unhandled_input）。
## 按钮的 _gui_input 不会到这里（按钮自己消耗了），但点空地/按 ESC 会到这里。
func _input(event: InputEvent) -> void:
	if not _placing:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_confirm_place()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_placing()
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_cancel_placing()
			get_viewport().set_input_as_handled()


# ─────────────────────────────── 内部 ────────────────────────────────

## 获取鼠标在世界坐标的 X
func _get_mouse_world_x() -> float:
	if _camera_rig != null and is_instance_valid(_camera_rig):
		return _camera_rig.get_global_mouse_position().x
	# 回退：通过 viewport 鼠标位置 + 当前地图 transform
	var map: Node2D = _game_root.get_current_map() if _game_root != null and _game_root.has_method("get_current_map") else null
	if map != null:
		return map.get_global_mouse_position().x
	return 0.0


func _show_notify(msg: String) -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("建造", msg, "info")
