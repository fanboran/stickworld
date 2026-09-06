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
## 条带预览容器（单元格宽蓝色描边小长方形拼接）
var _ghost: Node2D = null
## 两阶段放置：false=选址阶段（鼠标显示预览），true=已放下草稿（拉伸左右边界阶段）
var _draft_placed: bool = false
## 拉伸阶段是否正在按住左键拖动（拖动时边界跟随鼠标，松开后条带固定）
var _drag_active: bool = false
## 拖动侧：0=拖左边界，1=拖右边界（决定拖动时哪一侧跟随鼠标，互不影响）
var _drag_side: int = 0
## 按下时的鼠标 cell 与该侧边界值（拖拽增量基准：按下不移动则边界不跳变）
var _drag_start_mouse: int = 0
var _drag_start_boundary: int = 0
## 草稿锚点（左边界所在 cell，由选址阶段左键落下）
var _anchor_cell: int = 0
## 默认大小区间（锚点..锚点+默认宽），橙色角框标定未调整前的大小
var _default_start: int = 0
var _default_end: int = 0
## 当前预览的 cell 区间 [左, 右)
var _cell_start: int = 0
var _cell_end: int = 0
## 上一帧的边界（变化时触发端部格抖动反馈）
var _last_cell_start: int = 0
var _last_cell_end: int = 0
## 确定建造按钮（stage 2 才显示）
var _confirm_btn: Button = null
## ghost 预览高度（像素，向上，接近大多数建筑视觉高度）
const _GHOST_HEIGHT: float = 280.0
const _CELL_SIZE: int = 32
## 放置默认宽度（cell 数）
const _DEFAULT_WIDTH_CELLS: int = 16

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
	# Demo 引导：建造目标激活时按钮呼吸高亮（quest_advanced 信号驱动）
	if EventBus != null and EventBus.has_signal("quest_advanced"):
		EventBus.quest_advanced.connect(_on_quest_advanced)
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
	_toggle_btn.offset_top = -42.0
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
	# 与右下角「建造」按钮等高（30px），保证建造菜单内按钮尺寸统一
	btn.custom_minimum_size = Vector2(0, 30)
	btn.pressed.connect(_on_building_selected.bind(def_id))
	vbox.add_child(btn)
	# 资源消耗摘要
	var cost_label := Label.new()
	cost_label.text = _format_cost(def)
	cost_label.add_theme_font_size_override("font_size", 11)
	cost_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	vbox.add_child(cost_label)
	# 资源不足时灰显按钮 + 红字缺口提示（新手引导：缺什么、去哪补）
	if not _can_afford(def):
		btn.disabled = true
		btn.modulate = Color(0.6, 0.6, 0.6)
		var missing: String = _missing_summary(def)
		if not missing.is_empty():
			var miss := Label.new()
			miss.text = "缺 %s —— 按 F 采集可获取" % missing
			miss.add_theme_font_size_override("font_size", 11)
			miss.add_theme_color_override("font_color", Color(0.95, 0.55, 0.45))
			vbox.add_child(miss)
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


## 汇总资源缺口（"木 20 · 石 40"；无缺口返回空串）
func _missing_summary(def: Dictionary) -> String:
	var parts: Array = []
	for field: String in _COST_FIELD_TO_RESOURCE.keys():
		var v: float = float(def.get(field, 0))
		if v <= 0:
			continue
		var res_id: String = _COST_FIELD_TO_RESOURCE[field]
		var stock: float = _resources_api.get_stock(res_id, _BUILD_REGION) if _resources_api != null and _resources_api.has_method("get_stock") else 0.0
		if stock < v:
			parts.append("%s %d" % [_COST_FIELD_ZH.get(field, field), int(ceil(v - stock))])
	return " · ".join(parts)


# ─────────────────────────────── 信号回调 ────────────────────────────────

func _on_resource_changed(_rid: String, _amt: float, _delta: float, _region: String) -> void:
	# 隐藏期间跳过重建（resource_changed 高频触发）；打开路径 _on_toggle_pressed 必刷新
	if _list_panel == null or not _list_panel.visible:
		return
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
	_draft_placed = false
	_default_start = 0
	_default_end = 0
	_last_cell_start = 0
	_last_cell_end = 0
	# 放置期间关闭相机边缘滚动，避免拖动边界靠近屏幕边缘时世界跟着滚
	if _camera_rig != null and is_instance_valid(_camera_rig) and _camera_rig.has_method("set_edge_scroll_enabled"):
		_camera_rig.set_edge_scroll_enabled(false)
	_hint_label.visible = true
	_hint_label.text = "选址：左键放下草稿(默认16格) | 右键/Esc 取消"
	_toggle_btn.visible = false
	# 创建条带预览容器（挂到当前地图的 BuildMaskLayer）
	var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	if map != null:
		var mask_layer: Node2D = map.get("build_mask_layer") if "build_mask_layer" in map else null
		if mask_layer == null:
			mask_layer = map.get_node_or_null("BuildMaskLayer")
		if mask_layer != null:
			_ghost = PlacementGhost.new()
			_ghost.z_index = WorldZ.OVERLAY_HINT
			mask_layer.add_child(_ghost)
	# 确定建造按钮（stage 2 拉伸后才显示）
	_confirm_btn = Button.new()
	_confirm_btn.name = "ConfirmBtn"
	_confirm_btn.text = "确定建造"
	_confirm_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_confirm_btn.offset_left = -140.0
	_confirm_btn.offset_top = -102.0
	_confirm_btn.offset_right = -12.0
	_confirm_btn.offset_bottom = -72.0
	_confirm_btn.pressed.connect(_confirm_place)
	_confirm_btn.visible = false
	add_child(_confirm_btn)
	set_process(true)


func _cancel_placing() -> void:
	_placing = false
	_draft_placed = false
	_drag_active = false
	_placing_def_id = ""
	# 恢复相机边缘滚动
	if _camera_rig != null and is_instance_valid(_camera_rig) and _camera_rig.has_method("set_edge_scroll_enabled"):
		_camera_rig.set_edge_scroll_enabled(true)
	_hint_label.visible = false
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
		_ghost = null
	if _confirm_btn != null and is_instance_valid(_confirm_btn):
		_confirm_btn.queue_free()
		_confirm_btn = null
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
	var width: int = maxi(1, _cell_end - _cell_start)
	var result: Dictionary = api.start_construction_at(_BUILD_REGION, _placing_def_id, _cell_start, "", width)
	if result.get("ok", false):
		_show_notify("开始建造: %s (cell=%d, 宽=%d)" % [_placing_def_id, _cell_start, width])
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
	var ml: float = float(map.get("map_left") if "map_left" in map else 0.0)
	var mr: float = float(map.get("map_right") if "map_right" in map else 8192.0)
	# 地图边界对应 cell（负 cell 区域合法，2026-08 修复：原硬编码 0 下限在负区非法致左边界飞走）
	var min_cell: int = int(floor(ml / float(_CELL_SIZE)))
	var max_cell: int = int(floor(mr / float(_CELL_SIZE)))
	var mouse_cell: int = _get_mouse_cell()
	if _draft_placed:
		# 拉伸阶段：条带固定，按住左键拖动时按"按下基准 + 相对位移"更新对应边界，
		# 按下未移动则不跳变（互不影响、不会向内溃缩）。
		# 最小宽度 = 建筑定义宽度（def.width，默认 16 格）：拖动时不能缩到更小。
		var min_width: int = _get_def_width()
		if _drag_active:
			var delta: int = mouse_cell - _drag_start_mouse
			if _drag_side == 0:
				_cell_start = clampi(_drag_start_boundary + delta, min_cell, maxi(min_cell, _cell_end - min_width))
			else:
				_cell_end = clampi(_drag_start_boundary + delta, mini(max_cell, _cell_start + min_width), max_cell)
		if _hint_label != null:
			_hint_label.text = "按住左键拖动左右两侧方块调整边界 | 点击「确定建造」确认 | 右键/Esc 取消"
	else:
		# 选址阶段：以鼠标为左边界，默认宽度
		var w: int = _get_def_width()
		_cell_start = mouse_cell
		_cell_end = mouse_cell + w
	# 记录默认大小（放下草稿时定格，用于橙色角框标定）
	if _draft_placed and _default_end <= _default_start:
		_default_start = _anchor_cell
		_default_end = _anchor_cell + _get_def_width()
	if _confirm_btn != null:
		_confirm_btn.visible = _draft_placed
	# 更新 ghost 参数并重绘（单节点自绘，避免每帧建删数十个节点导致卡顿/闪烁）
	var width: int = maxi(1, _cell_end - _cell_start)
	var ground_y: float = float(map.get("ground_y") if "ground_y" in map else 810.0)
	var baseline_offset: float = float(map.get("building_baseline_offset") if "building_baseline_offset" in map else 96.0)
	var baseline: float = ground_y + baseline_offset
	var top: float = baseline - _GHOST_HEIGHT
	var in_bounds: bool = true
	for c in range(width):
		var cx: int = _cell_start + c
		var left: float = float(cx) * float(_CELL_SIZE)
		var right: float = left + float(_CELL_SIZE)
		if left < ml or right > mr:
			in_bounds = false
	_ghost.cell_start = _cell_start
	_ghost.cell_end = _cell_end
	_ghost.in_bounds = in_bounds
	_ghost.draft_placed = _draft_placed
	_ghost.default_start = _default_start
	_ghost.default_end = _default_end
	_ghost.top = top
	_ghost.baseline = baseline
	# 已有建筑占用格（绿/红斜纹标识）：每帧从 PlacementGrid 收集。
	# 用 get_occupant（仅建筑占用），不含 blockage 地形标记
	var grid: Node = map.get("placement_grid") if "placement_grid" in map else null
	var occ: Array[int] = []
	if grid != null and grid.has_method("get_occupant"):
		for c in range(min_cell, max_cell + 1):
			if grid.get_occupant(c) != null:
				occ.append(c)
	_ghost.occupied_cells = occ
	# 边界变化时触发对应端部格抖动反馈（拖动每移动一格抖一次）
	if _draft_placed and (_cell_start != _last_cell_start or _cell_end != _last_cell_end):
		if _cell_start != _last_cell_start and _ghost.has_method("trigger_feedback"):
			_ghost.trigger_feedback(0)
		if _cell_end != _last_cell_end and _ghost.has_method("trigger_feedback"):
			_ghost.trigger_feedback(1)
		_last_cell_start = _cell_start
		_last_cell_end = _cell_end
	# 悬停检测：水平上位于最左/最右端格，且垂直范围也在条带矩形内
	_ghost.hover_side = -1
	if _draft_placed:
		var mwy: float = _get_mouse_world_y()
		var within_v: bool = mwy >= top and mwy <= baseline
		if within_v and mouse_cell == _cell_start:
			_ghost.hover_side = 0
		elif within_v and mouse_cell == _cell_end - 1:
			_ghost.hover_side = 1
	_ghost.queue_redraw()


## 获取鼠标所在 cell（相对当前地图）
func _get_mouse_cell() -> int:
	return int(floor(_get_mouse_world_x() / float(_CELL_SIZE)))


## 获取当前建筑的默认宽度（cell 数），异常时回退 16
func _get_def_width() -> int:
	var def: Dictionary = _construction_manager.get_building_def(_placing_def_id) if _construction_manager.has_method("get_building_def") else {}
	var w: int = int(def.get("width", _DEFAULT_WIDTH_CELLS))
	return w if w > 0 else _DEFAULT_WIDTH_CELLS


# ─────────────────────────────── 输入处理 ────────────────────────────────

## 选址模式下用 _input 抢回事件（先于任何 _unhandled_input）。
## 按钮的 _gui_input 不会到这里（按钮自己消耗了），但点空地/按 ESC 会到这里。
func _input(event: InputEvent) -> void:
	if not _placing:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if not _draft_placed:
					# 选址阶段：放下草稿（固定 16 格条带），进入拉伸阶段
					_anchor_cell = _get_mouse_cell()
					_draft_placed = true
					var w: int = _get_def_width()
					_cell_start = _anchor_cell
					_cell_end = _anchor_cell + w
					# 放下草稿后按住即可调整边界（无需松开再点；2026-08 修复"按住拖不动"）：
					# 放下时鼠标在左边界（_anchor_cell），侧=0，按下基准=放下位置，不移动则不跳变
					_drag_side = 0
					_drag_start_mouse = _anchor_cell
					_drag_start_boundary = _cell_start
					_drag_active = true
					get_viewport().set_input_as_handled()
				else:
					# 点击落在「确定建造」按钮上：交给按钮处理，不启动拖动
					if _confirm_btn != null and is_instance_valid(_confirm_btn) and _confirm_btn.visible \
							and _confirm_btn.get_global_rect().has_point(event.position):
						return
					# 拉伸阶段：按住左键开始拖动。先判定拖动侧（靠近哪条边界拖哪条），
					# 记录按下基准，拖动按"相对位移"更新边界——按下不移动则边界不跳变
					# （修复"点击瞬间范围向内溃缩一格"）
					var mid: int = (_cell_start + _cell_end) / 2
					_drag_side = 0 if _get_mouse_cell() <= mid else 1
					_drag_start_mouse = _get_mouse_cell()
					_drag_start_boundary = _cell_start if _drag_side == 0 else _cell_end
					_drag_active = true
					if _ghost != null and is_instance_valid(_ghost):
						_ghost.trigger_feedback(_drag_side)
					get_viewport().set_input_as_handled()
			else:
				# 松开左键：结束拖动，条带固定
				if _drag_active:
					_drag_active = false
					get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
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


## 获取鼠标在世界坐标的 Y（悬停的垂直范围判断用）
func _get_mouse_world_y() -> float:
	if _camera_rig != null and is_instance_valid(_camera_rig):
		return _camera_rig.get_global_mouse_position().y
	var map: Node2D = _game_root.get_current_map() if _game_root != null and _game_root.has_method("get_current_map") else null
	if map != null:
		return map.get_global_mouse_position().y
	return 0.0


func _show_notify(msg: String) -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("建造", msg, "info")


# ─────────────────────────────── Demo 引导强调 ────────────────────────────────

var _pulse_tween: Tween = null

func _on_quest_advanced(quest_id: String) -> void:
	_stop_build_pulse()
	if quest_id != "build" or _toggle_btn == null or not is_instance_valid(_toggle_btn):
		return
	_pulse_tween = _toggle_btn.create_tween().set_loops()
	_pulse_tween.tween_property(_toggle_btn, "modulate", Color(1.35, 1.15, 0.8), 0.6)
	_pulse_tween.tween_property(_toggle_btn, "modulate", Color.WHITE, 0.6)

func _stop_build_pulse() -> void:
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
		_pulse_tween = null
	if _toggle_btn != null and is_instance_valid(_toggle_btn):
		_toggle_btn.modulate = Color.WHITE
