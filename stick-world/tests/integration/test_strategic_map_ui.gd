extends Node
## 集成测试：战略图 UI 三件套（粒度指示器 / 聚落 tooltip / 视图切换一致性）
## 验证：
##   - L1/L2/L3 三视图各挂 GranularityIndicator，open 后层级指示与当前状态一致
##     （L1 直开 vs 下钻的 ESC 语义、L2 地区号、L3 静态文案）
##   - SettlementTooltip 悬停内容：名称/级别/政权；map_id 为空显示"未开放进入"不误导
##   - 视图互斥：L1（Tab）打开时 L3（含下钻 L2）自动收起（L1 层号低会被整个盖住）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const L1_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map.tscn")
const L2_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l2.tscn")
const L3_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l3.tscn")

const L1_JSON_PATH := "res://config/strategic_map/l1_world.json"
const L1_BASE_DIR := "res://config/strategic_map"
const L2_REGION := "region_001"
const L2_BASE_DIR := "res://config/strategic_map/l2_packs"

var _runner: TestRunner
var _l1_scene: Node = null
var _l1_content: Node = null
var _l1_api: Node = null
var _l1_indicator: GranularityIndicator = null
var _tooltip: SettlementTooltip = null
var _l1_title_bar: MapTitleBar = null
var _l1_legend: MapLegend = null

var _l2_scene: Node = null
var _l2_content: Node = null
var _l2_indicator: GranularityIndicator = null
var _l2_title_bar: MapTitleBar = null

var _l3_scene: Node = null
var _l3_content: Node = null
var _l3_indicator: GranularityIndicator = null
var _l3_title_bar: MapTitleBar = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L1 场景装配：粒度指示器 + 聚落 tooltip", _test_l1_assembly, true)
	_runner.add_test("L1 直开（Tab）：层级指示 + 关闭提示", _test_l1_indicator_direct, true)
	_runner.add_test("L1 下钻：地块号切换 + ESC 返回地区提示", _test_l1_indicator_drill, true)
	_runner.add_test("L1 名牌 + 图例：地块名/聚落数/模式驱动图例（地形↔政权）", _test_l1_title_legend, true)
	_runner.add_test("tooltip 聚落内容：名称/级别/政权/未开放进入", _test_tooltip_content, true)
	_runner.add_test("tooltip map_id 非空：双击进入", _test_tooltip_enterable, true)
	_runner.add_test("tooltip 空聚落/无数据：隐藏不误导", _test_tooltip_hidden, true)
	_runner.add_test("L2 打开：层级指示 + 当前地区号", _test_l2_indicator, true)
	_runner.add_test("L3 打开：层级指示 + 关闭提示", _test_l3_indicator, true)
	_runner.add_test("L2/L3 名牌：地区序号/大世界 + 概览副标题", _test_l2_l3_title, true)
	_runner.add_test("视图互斥：L1 打开时 L3（含 L2）自动收起", _test_view_exclusion, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_l1_assembly() -> void:
	_l1_scene = L1_SCENE.instantiate()
	add_child(_l1_scene)
	_l1_content = _l1_scene.get_node_or_null("Content")
	if _l1_content == null:
		_runner.assert_true(false, "L1 场景应含 Content")
		return
	_l1_api = _l1_content.get_node_or_null("Api")
	_l1_indicator = _l1_scene.get_node_or_null("GranularityIndicator") as GranularityIndicator
	_tooltip = _l1_scene.get_node_or_null("SettlementTooltip") as SettlementTooltip
	_l1_title_bar = _l1_scene.get_node_or_null("MapTitleBar") as MapTitleBar
	_l1_legend = _l1_scene.get_node_or_null("MapLegend") as MapLegend
	_runner.assert_true(_l1_api != null, "L1 场景应含 Api")
	# B4 模式系统：Content 挂 MapModeManager + HUD 地形/政治双模式按钮
	var mode_mgr: Node = _l1_content.get_node_or_null("MapModeManager")
	_runner.assert_true(mode_mgr != null, "L1 Content 下应挂 MapModeManager（B4）")
	var hud: Control = _l1_scene.get_node_or_null("ZoomIndicator")
	if hud != null:
		var n_mode_btns := 0
		for ch in hud.get_children():
			if ch is Button and ch.toggle_mode:
				n_mode_btns += 1
		_runner.assert_true(n_mode_btns == 2,
			"L1 HUD 应有地形/政治双模式按钮（实测 %d）" % n_mode_btns)
	_runner.assert_true(_l1_indicator != null, "L1 Content 下应挂 GranularityIndicator")
	_runner.assert_true(_tooltip != null, "L1 Content 下应挂 SettlementTooltip")
	_runner.assert_true(_l1_title_bar != null, "L1 应挂 MapTitleBar")
	_runner.assert_true(_l1_legend != null, "L1 应挂 MapLegend")
	if _l1_indicator != null:
		_runner.assert_true(_l1_indicator.view_level == "L1", "L1 指示器 view_level=L1（实测 %s）" % _l1_indicator.view_level)
	# 挂 CanvasLayer 直下（Control 挂 Node2D 下 anchor 参照矩形为 0 会跑位），显隐由控制器同步
	_runner.assert_true(_l1_indicator.get_parent() == _l1_scene, "指示器应挂 CanvasLayer 直下")
	_runner.assert_true(_tooltip.get_parent() == _l1_scene, "tooltip 应挂 CanvasLayer 直下")
	_runner.assert_true(not _l1_indicator.visible, "初始（地图未开）指示器隐藏")


func _test_l1_indicator_direct() -> void:
	if _l1_api == null or _l1_indicator == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	_l1_api.initialize(L1_JSON_PATH, L1_BASE_DIR)
	var content: Node = _l1_content
	content.visible = true
	content.call("open")
	_runner.assert_true(_l1_indicator.visible, "open 后指示器可见（控制器同步显隐）")
	# 指示器文案与状态一致（headless 下树可见性不可测，可见性用 visible 属性断言）
	var title: Label = _l1_indicator._title_label
	var subtitle: Label = _l1_indicator._subtitle_label
	var hint: Label = _l1_indicator._hint_label
	_runner.assert_true(title != null and title.text == "L1 · 地块", "层级标题 = L1 · 地块（实测 %s）" % (title.text if title else "null"))
	_runner.assert_true(subtitle != null and subtitle.text == "#69", "Tab 直开 = 玩家所在出生 L1（实测 %s）" % (subtitle.text if subtitle else "null"))
	_runner.assert_true(hint != null and hint.text.contains("Tab/ESC 关闭"), "直开提示含 Tab/ESC 关闭（实测 %s）" % (hint.text if hint else "null"))
	_runner.assert_true(hint != null and hint.text.contains("M 大世界"), "直开提示含 M 大世界（实测 %s）" % (hint.text if hint else "null"))
	content.visible = false
	content.call("close")
	_runner.assert_true(not _l1_indicator.visible, "close 后指示器隐藏")


func _test_l1_indicator_drill() -> void:
	if _l1_api == null or _l1_indicator == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	# L2 点击 L1 下钻链路：controller.open_l1(41)（内部置 drill 状态后 open）
	var opened: bool = _l1_content.call("open_l1", 41)
	_runner.assert_true(opened, "controller.open_l1 成功")
	var subtitle: Label = _l1_indicator._subtitle_label
	var hint: Label = _l1_indicator._hint_label
	# 状态一致性：open() 内 Tab 跟随语义会把数据切回玩家所在 L1（ensure_player_l1(69)），
	# 指示器如实显示实际加载的 label，不显示"以为在看的"41
	_runner.assert_true(subtitle.text == "#69", "指示器如实显示实际加载的 L1（实测 %s）" % subtitle.text)
	_runner.assert_true(hint.text.contains("ESC 返回地区视图"), "下钻提示 ESC 返回地区视图（实测 %s）" % hint.text)
	# 提示与 ESC 实际行为一致：drill 状态下 ESC 走 back 分支（返回 L2）而非关闭
	var back_count := {"n": 0}
	_l1_content.back_requested.connect(func() -> void: back_count.n += 1)
	_l1_content._input(_esc_event())
	_runner.assert_true(back_count.n == 1, "drill 状态 ESC 应发 back_requested（实测 %d）" % back_count.n)
	# ESC back 分支已消费 drill 标志：Tab 关闭重开后恢复直开语义，提示与 ESC 行为保持一致
	_l1_content.call("close")
	_l1_content.call("open")
	_runner.assert_true(_l1_indicator._hint_label.text.contains("Tab/ESC 关闭"),
		"重开后恢复直开提示（实测 %s）" % _l1_indicator._hint_label.text)
	_l1_content._input(_esc_event())
	_runner.assert_true(back_count.n == 1, "重开后 ESC 走关闭分支（back 不再发射，实测 %d）" % back_count.n)
	_l1_content.call("close")


func _test_l1_title_legend() -> void:
	if _l1_api == null or _l1_title_bar == null or _l1_legend == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	_l1_content.visible = true
	_l1_content.call("open")
	# 名牌：徽标 / 地块名（Tab 直开 = 玩家所在出生 L1）/ 聚落数概览
	_runner.assert_true(_l1_title_bar.visible, "open 后名牌可见")
	_runner.assert_true(_l1_title_bar._badge_label.text == "L1", "徽标 L1（实测 %s）" % _l1_title_bar._badge_label.text)
	_runner.assert_true(_l1_title_bar._title_label.text == "地块 #69",
		"名牌显示玩家所在 L1（实测 %s）" % _l1_title_bar._title_label.text)
	_runner.assert_true(_l1_title_bar._subtitle_label.text == "8 聚落",
		"副标题聚落数（实测 %s）" % _l1_title_bar._subtitle_label.text)
	# 图例（B4 默认 TERRAIN 地形模式）：地物水系 + B2 群系色条目 + C2 建成区
	# （共 9：海洋/湖泊/平原/森林/荒漠/冰原/水源带/火山/城镇建成区）
	_runner.assert_true(_l1_legend.visible, "open 后图例可见")
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 地形",
		"地形模式图例标题（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 9,
		"地形模式 9 条目（实测 %d）" % _l1_legend._entries_box.get_child_count())
	# 切政治模式：8 城邦政权色条目，色块与地图填充同色源（get_state_color）
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 政权",
		"政治模式图例标题（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 9,
		"8 城邦 + 建成区条目（实测 %d）" % _l1_legend._entries_box.get_child_count())
	var states: Dictionary = _l1_api.get_states()
	var first_id: String = states.keys()[0]
	var first_entry: HBoxContainer = _l1_legend._entries_box.get_child(0)
	var swatch: ColorRect = first_entry.get_child(0)
	_runner.assert_true(swatch.color == _l1_api.get_data().get_state_color(first_id),
		"首条目色块 = 地图政权填充色")
	var text_label: Label = first_entry.get_child(1)
	_runner.assert_true(text_label.text == str(states[first_id].get("name", first_id)),
		"首条目文字 = 政权名（实测 %s）" % text_label.text)
	# 复位地形模式（模式是全局静态，防污染本文件后续用例）
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	# 空态：清空条目后 set_shown 不再显示（Phase B 模式无图例内容的语义）
	_l1_legend.set_entries([])
	_l1_legend.set_shown(true)
	_runner.assert_true(not _l1_legend.visible, "空条目时 set_shown(true) 保持隐藏")
	# 关闭同步隐藏
	_l1_content.call("close")
	_runner.assert_true(not _l1_title_bar.visible, "close 后名牌隐藏")


func _test_tooltip_content() -> void:
	if _tooltip == null or _l1_api == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	var data: L1WorldData = _l1_api.get_data()
	_runner.assert_true(data != null and data.tiles.size() > 0, "L1 数据已加载")
	if data == null or data.tiles.is_empty():
		return
	# 出生数据第一个有聚落地块（当前 8 城 map_id 全空）
	var tile: L1TileDef = null
	for t in data.tiles:
		if t.settlement != null:
			tile = t
			break
	_runner.assert_true(tile != null, "应有带聚落的地块")
	if tile == null:
		return
	_tooltip.update_for_tile(tile)
	_runner.assert_true(_tooltip.visible, "悬停有聚落的地块时 tooltip 显示")
	var s: SettlementRef = tile.settlement
	var expected_name: String = s.name if not s.name.is_empty() else s.settlement_id
	_runner.assert_true(_tooltip._name_label.text == expected_name, "显示聚落名称（实测 %s）" % _tooltip._name_label.text)
	_runner.assert_true(_tooltip._level_label.text.contains("T%d" % s.level), "显示级别 T%d（实测 %s）" % [s.level, _tooltip._level_label.text])
	# 政权名（出生数据 8 城邦）
	var states: Dictionary = _l1_api.get_states()
	var info: Dictionary = states.get(tile.owner_state_id, {})
	var owner_name: String = info.get("name", "")
	_runner.assert_true(not owner_name.is_empty(), "tile 应有归属政权")
	_runner.assert_true(_tooltip._owner_label.text.contains(owner_name), "显示政权名 %s（实测 %s）" % [owner_name, _tooltip._owner_label.text])
	# map_id 为空 → 明确"未开放进入"
	_runner.assert_true(s.map_id.is_empty(), "前置：出生聚落 map_id 为空")
	_runner.assert_true(_tooltip._enter_label.text == "未开放进入", "空 map_id 显示未开放进入（实测 %s）" % _tooltip._enter_label.text)
	_runner.assert_true(_tooltip._enter_label.visible, "进入状态行可见")


func _test_tooltip_enterable() -> void:
	if _tooltip == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	# 构造 map_id 非空的聚落（未来可进入形态）
	var tile := L1TileDef.new()
	tile.tile_id = "test_tile"
	tile.owner_state_id = "state_test"
	var s := SettlementRef.new()
	s.settlement_id = "settlement_test"
	s.name = "测试城"
	s.level = 3
	s.map_id = "some_map"
	tile.settlement = s
	_tooltip.update_for_tile(tile)
	_runner.assert_true(_tooltip.visible, "map_id 非空聚落显示 tooltip")
	_runner.assert_true(_tooltip._enter_label.text == "双击进入", "map_id 非空显示双击进入（实测 %s）" % _tooltip._enter_label.text)


func _test_tooltip_hidden() -> void:
	if _tooltip == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	# 空聚落地块（无 settlement）：不显示 tooltip
	var tile := L1TileDef.new()
	tile.tile_id = "empty_tile"
	_tooltip.update_for_tile(tile)
	_runner.assert_true(not _tooltip.visible, "空聚落不显示 tooltip")
	_tooltip.update_for_tile(null)
	_runner.assert_true(not _tooltip.visible, "null 地块不显示 tooltip")
	# 清理展示态
	_tooltip.reset()


func _test_l2_indicator() -> void:
	_l2_scene = L2_SCENE.instantiate()
	add_child(_l2_scene)
	_l2_content = _l2_scene.get_node_or_null("Content")
	_l2_indicator = _l2_scene.get_node_or_null("GranularityIndicator") as GranularityIndicator if _l2_scene != null else null
	_runner.assert_true(_l2_indicator != null, "L2 场景应挂 GranularityIndicator")
	if _l2_indicator == null or _l2_content == null:
		return
	_runner.assert_true(_l2_indicator.view_level == "L2", "L2 指示器 view_level=L2（实测 %s）" % _l2_indicator.view_level)
	_l2_content.call("open", L2_REGION)
	_runner.assert_true(_l2_indicator.visible, "L2 open 后指示器可见（控制器同步显隐）")
	_runner.assert_true(_l2_indicator._title_label.text == "L2 · 地区", "层级标题 = L2 · 地区（实测 %s）" % _l2_indicator._title_label.text)
	_runner.assert_true(_l2_indicator._subtitle_label.text == L2_REGION, "显示当前地区号（实测 %s）" % _l2_indicator._subtitle_label.text)
	_runner.assert_true(_l2_indicator._hint_label.text.contains("ESC 返回大世界"), "L2 提示 ESC 返回大世界（实测 %s）" % _l2_indicator._hint_label.text)
	_l2_content.call("set_view_visible", false)
	_runner.assert_true(not _l2_indicator.visible, "L2 隐藏后指示器隐藏")


func _test_l3_indicator() -> void:
	_l3_scene = L3_SCENE.instantiate()
	add_child(_l3_scene)
	_l3_content = _l3_scene.get_node_or_null("Content")
	_l3_indicator = _l3_scene.get_node_or_null("GranularityIndicator") as GranularityIndicator if _l3_scene != null else null
	_runner.assert_true(_l3_indicator != null, "L3 场景应挂 GranularityIndicator")
	if _l3_indicator == null or _l3_content == null:
		return
	_runner.assert_true(_l3_indicator.view_level == "L3", "L3 指示器 view_level=L3（实测 %s）" % _l3_indicator.view_level)
	_l3_content.call("open")
	_runner.assert_true(_l3_content.visible, "L3 open 后可见")
	_runner.assert_true(_l3_indicator.visible, "L3 open 后指示器可见（控制器同步显隐）")
	_runner.assert_true(_l3_indicator._title_label.text == "L3 · 大世界", "层级标题 = L3 · 大世界（实测 %s）" % _l3_indicator._title_label.text)
	_runner.assert_true(_l3_indicator._hint_label.text.contains("ESC/M 关闭"), "L3 提示 ESC/M 关闭（实测 %s）" % _l3_indicator._hint_label.text)
	_runner.assert_true(_l3_indicator._hint_label.text.contains("Tab 地块视图"), "L3 提示 Tab 切地块视图（实测 %s）" % _l3_indicator._hint_label.text)


func _test_l2_l3_title() -> void:
	# L2 名牌：region_001 -> 地区 1 + 地块数概览
	if _l2_scene == null or _l2_content == null:
		_runner.assert_true(false, "前置：L2 未装载")
		return
	if _l2_title_bar == null:
		_l2_title_bar = _l2_scene.get_node_or_null("MapTitleBar") as MapTitleBar
	_runner.assert_true(_l2_title_bar != null, "L2 场景应挂 MapTitleBar")
	if _l2_title_bar == null:
		return
	_l2_content.call("open", L2_REGION)
	_runner.assert_true(_l2_title_bar.visible, "L2 open 后名牌可见")
	_runner.assert_true(_l2_title_bar._badge_label.text == "L2", "L2 徽标（实测 %s）" % _l2_title_bar._badge_label.text)
	_runner.assert_true(_l2_title_bar._title_label.text == "地区 1",
		"region_001 解析为地区 1（实测 %s）" % _l2_title_bar._title_label.text)
	_runner.assert_true(_l2_title_bar._subtitle_label.text.contains("地块"),
		"副标题含地块数（实测 %s）" % _l2_title_bar._subtitle_label.text)
	_l2_content.call("set_view_visible", false)
	_runner.assert_true(not _l2_title_bar.visible, "L2 隐藏后名牌隐藏")
	# L3 名牌：大世界 + 地区数概览
	if _l3_scene == null or _l3_content == null:
		_runner.assert_true(false, "前置：L3 未装载")
		return
	if _l3_title_bar == null:
		_l3_title_bar = _l3_scene.get_node_or_null("MapTitleBar") as MapTitleBar
	_runner.assert_true(_l3_title_bar != null, "L3 场景应挂 MapTitleBar")
	if _l3_title_bar == null:
		return
	# 生产由 system_setup 注入数据；测试补注入（region 数是名牌副标题的数据源）
	var l3_renderer: Node = _l3_content.get_node_or_null("L3MapRenderer")
	if l3_renderer != null and l3_renderer.get_data() == null:
		l3_renderer.set_data(L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json", "res://config/strategic_map"))
	_l3_content.call("open")
	_runner.assert_true(_l3_title_bar.visible, "L3 open 后名牌可见")
	_runner.assert_true(_l3_title_bar._badge_label.text == "L3", "L3 徽标（实测 %s）" % _l3_title_bar._badge_label.text)
	_runner.assert_true(_l3_title_bar._title_label.text == "大世界",
		"L3 名牌 = 大世界（实测 %s）" % _l3_title_bar._title_label.text)
	_runner.assert_true(_l3_title_bar._subtitle_label.text.contains("地区"),
		"副标题含地区数（实测 %s）" % _l3_title_bar._subtitle_label.text)
	_l3_content.call("close")
	_runner.assert_true(not _l3_title_bar.visible, "L3 close 后名牌隐藏")


func _test_view_exclusion() -> void:
	if _l3_content == null:
		_runner.assert_true(false, "前置：L3 未装载")
		return
	# 注入 L2 视图（生产由 system_setup 装配；测试模拟接线）
	if _l2_content != null:
		_l3_content.call("set_l2_view", _l2_content)
	# 前置：L3 开着（上一用例遗留），模拟 Tab 打开 L1（唯一发 strategic_map_opened 的路径）
	_l3_content.call("open")
	_runner.assert_true(_l3_content.visible, "前置：L3 可见")
	EventBus.strategic_map_opened.emit()
	_runner.assert_true(not _l3_content.visible, "L1 打开后 L3 自动收起（层号 100 < 101，不收起会被整个盖住）")
	_runner.assert_true(not _l3_indicator.visible, "L3 收起后指示器隐藏")
	# 下钻中的 L2 一并收起
	_l3_content.call("open")
	var l2_view: Node = _l3_content.get("l2_view")
	_runner.assert_true(l2_view != null, "前置：L3 应持有 L2 视图引用")
	if l2_view != null:
		l2_view.call("open", L2_REGION)
		_runner.assert_true(l2_view.visible, "前置：L2 下钻视图可见")
		EventBus.strategic_map_opened.emit()
		_runner.assert_true(not _l3_content.visible, "L1 打开后 L3 收起")
		_runner.assert_true(not l2_view.visible, "L2 下钻视图一并收起（close 连带隐藏）")


func _esc_event() -> InputEvent:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	return ev
