class_name DebugToolsPanel
extends Control
## 调试工具面板 —— F4 切换的交互式调试窗口（区别于 F3 绘制覆盖层）。
##
## 四个页签，覆盖 2026-08-22 新系统的可视化调试：
##   特效   —— 三种粒子效果试放（视口中心 / 点击放置 / 压力测试）
##   市场   —— 资源×区域 库存/价格实时表 + 增减库存 + 强制结算
##   环境   —— 时间轴滑杆 + 昼夜颜色/CampLight 能量读数
##   建筑   —— 全部建筑列表 + 升级/修理即时操作
##
## 数据获取：按固定节点路径解析（/root/GameRoot/<Child>），未装配时显示"未找到"，
## 每秒重试。样式复用 StickKit/StickTokens（与全 UI 同主题）。

# ─────────────────────────────── 常量 ────────────────────────────────
## 一次性爆发型特效（视口中心试放 + 点放）
const FX_IDS: Array = [FxLibrary.BUILD_DUST, FxLibrary.GATHER_DEBRIS, FxLibrary.HIT_SPARK]
const FX_LABELS := {
	FxLibrary.BUILD_DUST: "建造尘土",
	FxLibrary.GATHER_DEBRIS: "采集飘屑",
	FxLibrary.HIT_SPARK: "打击火花",
}
const MARKET_ADJUST_AMOUNT := 50.0
const AUTO_REFRESH_INTERVAL := 0.5
const TAB_NAMES: Array = ["特效", "市场", "环境", "建筑"]

# ─────────────────────────────── 状态 ────────────────────────────────
var _res_api: Node = null
var _construction: Node = null
var _env: Node = null
var _resolve_retry: float = 0.0

var _tabs: Dictionary = {}          # tab 名 -> VBoxContainer；tab名+"_btn" -> Button
var _active_tab: String = "特效"
## 点击放置模式：armed 时下一次世界点击在点击处试放当前选中特效
var _place_mode_armed := false
var _place_fx_id: String = FxLibrary.BUILD_DUST
## 列表自动刷新
var _refresh_accum: float = 0.0
## 时间轴是否正被拖动（Slider 无 dragging 属性，用信号打标）
var _time_slider_held := false
## 标题栏拖动
var _dragging := false
var _drag_offset := Vector2.ZERO


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _process(delta: float) -> void:
	if not visible:
		return
	# 标题栏拖动
	if _dragging:
		position = get_global_mouse_position() - _drag_offset
	# 系统引用每秒重试解析（GameRoot 装配晚于本面板属常态）
	_resolve_retry -= delta
	if _resolve_retry <= 0.0:
		_resolve_retry = 1.0
		_resolve_systems()
	# 市场/建筑列表半秒自动刷新
	_refresh_accum += delta
	if _refresh_accum >= AUTO_REFRESH_INTERVAL:
		_refresh_accum = 0.0
		if _active_tab == "市场":
			_rebuild_market_rows()
			_update_env_readout()
		elif _active_tab == "建筑":
			_rebuild_building_rows()
		elif _active_tab == "环境":
			_update_env_readout()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not _place_mode_armed:
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var world_pos: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * event.position
		_spawn_fx(world_pos)
		get_viewport().set_input_as_handled()


## 按效果 ID 分发：GPUParticles 爆发（FX_IDS 均为一次性爆发型）
func _spawn_fx(world_pos: Vector2) -> void:
	FxPool.spawn_burst(get_tree(), _place_fx_id, world_pos)


func _find_fx_pool() -> Node:
	return get_tree().get_first_node_in_group("fx_pool")


# ─────────────────────────────── 系统解析 ────────────────────────────────

func _resolve_systems() -> void:
	if _res_api != null and _construction != null and _env != null:
		return
	var root_node := get_tree().root.get_node_or_null("GameRoot")
	if root_node == null:
		return
	_res_api = root_node.get_node_or_null("ResourcesApi")
	_construction = root_node.get_node_or_null("ConstructionManager")
	_env = root_node.get_node_or_null("EnvironmentSystem")


func _sys_label(missing_hint: String) -> Label:
	var l := Label.new()
	l.text = "⚠ 系统未找到（%s）——进入游戏装配后自动恢复" % missing_hint
	l.modulate = StickTokens.WARN
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(360, 0)
	return l


# ─────────────────────────────── UI 骨架 ────────────────────────────────

func _build_ui() -> void:
	var panel := SketchPanel.new()
	panel.name = "Panel"
	panel.position = Vector2(24, 90)
	panel.custom_minimum_size = Vector2(440, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# 标题行（可拖动区域）
	var title := Label.new()
	title.text = "调试工具（开关在 F3 调试面板 · 拖此行移动）"
	title.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	title.modulate = StickTokens.ACCENT
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.gui_input.connect(_on_title_gui_input)
	vbox.add_child(title)

	# 页签按钮行
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	vbox.add_child(tab_row)
	for tab_name in TAB_NAMES:
		var b := StickKit.sketch_button(tab_row, tab_name, _switch_tab.bind(tab_name))
		b.toggle_mode = true
		_tabs[tab_name + "_btn"] = b

	# 内容区（每页签一个 VBox，切换显隐）
	for tab_name in TAB_NAMES:
		var content := VBoxContainer.new()
		content.name = tab_name
		content.add_theme_constant_override("separation", 6)
		content.visible = tab_name == _active_tab
		vbox.add_child(content)
		_tabs[tab_name] = content

	_build_fx_tab(_tabs["特效"])
	_build_market_tab(_tabs["市场"])
	_build_env_tab(_tabs["环境"])
	_build_building_tab(_tabs["建筑"])
	_sync_tab_buttons()


func _switch_tab(tab_name: String) -> void:
	_active_tab = tab_name
	for key in TAB_NAMES:
		_tabs[key].visible = key == tab_name
	_sync_tab_buttons()
	match tab_name:
		"市场":
			_rebuild_market_rows()
		"建筑":
			_rebuild_building_rows()
		"环境":
			_update_env_readout()


func _sync_tab_buttons() -> void:
	for key in TAB_NAMES:
		var b: Button = _tabs[key + "_btn"]
		b.button_pressed = key == _active_tab


func _on_title_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_drag_offset = get_global_mouse_position() - position


# ─────────────────────────────── 页签：特效 ────────────────────────────────

func _build_fx_tab(parent: VBoxContainer) -> void:
	var hint := Label.new()
	hint.text = "粒子效果为 PLACEHOLDER 占位视觉（替换项 P1，见待办文档）。点放模式下左键在世界任意处试放。"
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(400, 0)
	parent.add_child(hint)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	parent.add_child(row1)
	for fx_id in FX_IDS:
		StickKit.sketch_button(row1, FX_LABELS[fx_id], _spawn_fx_at_view_center.bind(fx_id))

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	parent.add_child(row2)
	for fx_id in FX_IDS:
		var b := StickKit.sketch_button(row2, "点放:" + FX_LABELS[fx_id], _arm_place_mode.bind(fx_id))
		b.toggle_mode = true
		_tabs["place_" + fx_id] = b

	StickKit.sketch_button(parent, "压力测试：三效果 × 各10 连发", _stress_test_fx)
	StickKit.sketch_button(parent, "挂载水晶闪光：全部资源点（持续闪烁，对齐药剂工艺）", _attach_all_sparkles)


## 对全部资源点挂载 CrystalSparkles 持续闪烁系统（药工 SpriteParticleApplier 等价）
func _attach_all_sparkles() -> void:
	var nodes: Array = get_tree().get_nodes_in_group("resource_node")
	if nodes.is_empty():
		EventBus.ui_notification.emit("水晶闪光", "无资源点节点（resource_node 组为空）——请走到村落地图再试", "warn")
		return
	var attached := 0
	var count := 0
	for n in nodes:
		if not is_instance_valid(n):
			continue
		var node := n as Node2D
		if node == null:
			continue
		count += 1
		if node.has_node("CrystalSparkles"):
			continue
		CrystalSparkles.attach_to(node)
		attached += 1
	EventBus.ui_notification.emit("水晶闪光", "资源点 %d 个，新挂载 %d（常开闪烁，面积驱动速率）" % [count, attached], "info")


func _spawn_fx_at_view_center(fx_id: String) -> void:
	var cam := get_viewport().get_camera_2d()
	var pos := cam.get_screen_center_position() if cam != null else Vector2.ZERO
	FxPool.spawn_burst(get_tree(), fx_id, pos)


func _arm_place_mode(fx_id: String) -> void:
	_place_mode_armed = true
	_place_fx_id = fx_id
	for other in FX_IDS:
		var b: Button = _tabs.get("place_" + other)
		if b != null:
			b.button_pressed = other == fx_id


func _stress_test_fx() -> void:
	var cam := get_viewport().get_camera_2d()
	var center := cam.get_screen_center_position() if cam != null else Vector2.ZERO
	for i in 30:
		var fx_id: String = FX_IDS[i % FX_IDS.size()]
		var jitter := Vector2(randf_range(-260, 260), randf_range(-160, 160))
		FxPool.spawn_burst(get_tree(), fx_id, center + jitter)


# ─────────────────────────────── 页签：市场 ────────────────────────────────

func _build_market_tab(parent: VBoxContainer) -> void:
	var info := Label.new()
	info.name = "Info"
	info.modulate = Color(1, 1, 1, 0.7)
	parent.add_child(info)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	parent.add_child(head)
	StickKit.sketch_button(head, "强制结算一次", _force_market_tick)
	StickKit.sketch_button(head, "+50 全资源", _market_add_all.bind(true))
	StickKit.sketch_button(head, "-50 全资源", _market_add_all.bind(false))

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 3)
	parent.add_child(rows)
	_rebuild_market_rows()


func _collect_regions() -> Array:
	var regions := {"test_region": true}
	if _res_api != null:
		var stocks: Dictionary = _res_api.get_all_stocks()
		for res_id in stocks.keys():
			for region_id in stocks[res_id].keys():
				regions[region_id] = true
	return regions.keys()


func _rebuild_market_rows() -> void:
	if not visible or _active_tab != "市场":
		return
	var rows: VBoxContainer = _tabs["市场"].get_node("Rows")
	var info: Label = _tabs["市场"].get_node("Info")
	for child in rows.get_children():
		child.queue_free()
	if _res_api == null:
		rows.add_child(_sys_label("ResourcesApi"))
		return
	info.text = "税率 %.0f%% · tick 周期 5s · 强制结算即广播 price_changed" % (_res_api.debug_tax_rate() * 100.0)
	var regions: Array = _collect_regions()
	for row_def in _res_api.debug_resource_rows():
		var res_id: String = str(row_def.get("id", ""))
		var res_name: String = str(row_def.get("name_zh", res_id))
		for region_id in regions:
			rows.add_child(_market_row(res_id, res_name, region_id,
					float(row_def.get("initial_price", 1.0))))


func _market_row(res_id: String, res_name: String, region_id: String, base_price: float) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var stock: float = _res_api.get_stock(res_id, region_id)
	var price: float = _res_api.get_price(res_id, region_id)
	var drift := "—" if price <= 0.0 else ("%+.0f%%" % ((price / base_price - 1.0) * 100.0))
	var l := StickKit.label(row,
			"%s[%s] 库存%.0f 价%.2f (%s)" % [res_name, region_id, stock, price, drift],
			StickKit.LabelKind.BODY)
	l.custom_minimum_size = Vector2(320, 0)
	l.tooltip_text = "基准价 %.2f · 相对基准偏离 %s" % [base_price, drift]
	StickKit.sketch_button(row, "+50", _adjust_stock.bind(res_id, region_id, MARKET_ADJUST_AMOUNT))
	StickKit.sketch_button(row, "-50", _adjust_stock.bind(res_id, region_id, -MARKET_ADJUST_AMOUNT))
	return row


func _adjust_stock(res_id: String, region_id: String, amount: float) -> void:
	if _res_api == null:
		return
	if amount > 0.0:
		_res_api.produce(res_id, amount, region_id, "调试注入")
	else:
		_res_api.consume(res_id, -amount, region_id, "调试抽取")
	_res_api.debug_force_market_tick()
	_rebuild_market_rows()


func _force_market_tick() -> void:
	if _res_api == null:
		return
	var n: int = _res_api.debug_force_market_tick()
	EventBus.ui_notification.emit("市场结算", "已结算 %d 个价格条目" % n, "info")
	_rebuild_market_rows()


func _market_add_all(produce: bool) -> void:
	if _res_api == null:
		return
	for row_def in _res_api.debug_resource_rows():
		var res_id: String = str(row_def.get("id", ""))
		if produce:
			_res_api.produce(res_id, MARKET_ADJUST_AMOUNT, "test_region", "调试注入")
		else:
			_res_api.consume(res_id, MARKET_ADJUST_AMOUNT, "test_region", "调试抽取")
	_res_api.debug_force_market_tick()
	_rebuild_market_rows()


# ─────────────────────────────── 页签：环境 ────────────────────────────────

func _build_env_tab(parent: VBoxContainer) -> void:
	var time_label := Label.new()
	time_label.name = "TimeLabel"
	parent.add_child(time_label)

	var slider := SketchHSlider.new()
	slider.name = "TimeSlider"
	slider.min_value = 0.0
	slider.max_value = 24.0
	slider.step = 0.1
	slider.custom_minimum_size = Vector2(400, 16)
	slider.drag_started.connect(func(_v: float) -> void: _time_slider_held = true)
	slider.drag_ended.connect(func(_changed: bool) -> void: _time_slider_held = false)
	slider.value_changed.connect(func(v: float) -> void:
		if _env != null and _env.has_method("set_time_of_day"):
			_env.set_time_of_day(v))
	parent.add_child(slider)

	var readout := Label.new()
	readout.name = "Readout"
	readout.custom_minimum_size = Vector2(400, 0)
	readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(readout)


func _update_env_readout() -> void:
	if not visible or _active_tab != "环境":
		return
	var time_label: Label = _tabs["环境"].get_node("TimeLabel")
	var readout: Label = _tabs["环境"].get_node("Readout")
	var slider: HSlider = _tabs["环境"].get_node("TimeSlider")
	if _env == null:
		time_label.text = ""
		readout.text = "⚠ EnvironmentSystem 未找到"
		return
	var hour: float = _env.get_time_of_day()
	if not _time_slider_held:
		slider.set_value_no_signal(hour)
	time_label.text = "时间轴（拖动改时刻；建议先暂停再观察光照）"
	readout.text = "当前 %.1f 时 · CanvasModulate %s" % [hour, str(_env.get_current_light_color())]
	var camp := get_tree().root.get_node_or_null(
			"GameRoot/EnvironmentSystem/CampLight") as PointLight2D
	if camp != null:
		readout.text += "\nCampLight energy %.2f（夜间渐亮 · 替换项 P2）" % camp.energy


# ─────────────────────────────── 页签：建筑 ────────────────────────────────

func _build_building_tab(parent: VBoxContainer) -> void:
	var hint := Label.new()
	hint.text = "升级=半价+20%血上限+等级；修理=缺损比例×30%成本回满。列表 0.5s 自动刷新。"
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(400, 0)
	parent.add_child(hint)
	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 3)
	parent.add_child(rows)
	_rebuild_building_rows()


func _rebuild_building_rows() -> void:
	if not visible or _active_tab != "建筑":
		return
	var rows: VBoxContainer = _tabs["建筑"].get_node("Rows")
	for child in rows.get_children():
		child.queue_free()
	if _construction == null:
		rows.add_child(_sys_label("ConstructionManager"))
		return
	var state_names := ["PLANNED", "建造中", "运营中", "受损", "已拆除"]
	for b in _construction.get_all_buildings():
		var level: int = b.upgrade_level if "upgrade_level" in b else 0
		var state_idx: int = int(b.state) if "state" in b else 0
		var state_text: String = state_names[state_idx] if state_idx < state_names.size() else str(state_idx)
		var building_id: String = b.building_id if "building_id" in b else ""
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := StickKit.label(row,
				"%s Lv%d %s 血%.0f/%.0f" % [b.def_id, level, state_text, b.health, b.max_health],
				StickKit.LabelKind.BODY)
		l.custom_minimum_size = Vector2(280, 0)
		StickKit.sketch_button(row, "升级", func() -> void:
			var r: Dictionary = _construction.upgrade_building(building_id)
			EventBus.ui_notification.emit("升级建筑", str(r), "info"))
		StickKit.sketch_button(row, "修理", func() -> void:
			var r: Dictionary = _construction.repair_building(building_id, "")
			EventBus.ui_notification.emit("修理建筑", str(r), "info"))
		rows.add_child(row)
