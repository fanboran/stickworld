extends Node
## 集成测试：战略图 UI 三件套（粒度指示器 / 聚落 tooltip / 视图切换一致性）
## 验证：
##   - L1/L2/L3 三视图各挂 GranularityIndicator，open 后层级指示与当前状态一致
##     （L1 直开 vs 下钻的 ESC 语义、L2 地区号、L3 静态文案）
##   - SettlementTooltip 悬停内容：名称/级别/政权；map_id 非空显示双击提示（P6 起按
##     快速旅行可达性分文案：SELF=当前位置 / 可达=出发 / 不可达=走过去+原因），为空
##     显示"未开放进入"不误导（69 包外圈聚落）
##   - 视图互斥：L1（Tab）打开时 L3（含下钻 L2）自动收起（L1 层号低会被整个盖住）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const L1_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map.tscn")
const L2_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l2.tscn")
const L3_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l3.tscn")
const _Geo := preload("res://modules/world_map/scripts/map_renderer_geo.gd")

const L1_JSON_PATH := "res://config/strategic_map/l1_world.json"
const L1_BASE_DIR := "res://config/strategic_map"
## 出生 L1 的三个相邻老 L1 块（l1_world.json neighbors）
const BIRTH_NEIGHBORS := [18, 67, 68]
const L2_REGION := "region_001"
const L2_BASE_DIR := "res://config/strategic_map/l2_packs"
const ExpansionApiScript := preload("res://modules/expansion/api.gd")

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
	_runner.add_test("L1 名牌 + 图例：地块名/聚落数/图层开关驱动图例（政治/城市/交通/资源）", _test_l1_title_legend, true)
	_runner.add_test("tooltip 聚落内容：名称/级别/政权/双击进入", _test_tooltip_content, true)
	_runner.add_test("tooltip map_id 为空：未开放进入", _test_tooltip_enterable, true)
	_runner.add_test("tooltip 空聚落/无数据：隐藏不误导", _test_tooltip_hidden, true)
	_runner.add_test("据点归属面：tooltip 归属行读真值（两态 + 非据点隐藏）", _test_territory_tooltip_line, true)
	_runner.add_test("据点面板：空态隐藏 / 逐据点一行 / 行点击回调", _test_territory_panel, true)
	_runner.add_test("P4 染色：政治填充按已占地块逐格覆盖（占多少染多少）", _test_owned_tile_dyeing, true)
	_runner.add_test("P4 染色：政治图例含「我方疆域」条目（无则不空留）", _test_legend_player_entry, true)
	_runner.add_test("邻省上下文：政权色暗一阶 + 水体矢量 + 切省箭头环", _test_province_context, true)
	_runner.add_test("水体矢量：政治模式河湖数据就绪（湖多边形界内 / 河宽 EDT）", _test_water_vector, true)
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
	# B4 图层开关系统：Content 挂 MapModeManager + HUD 政治/城市/交通/资源四联 toggle 按钮
	var mode_mgr: Node = _l1_content.get_node_or_null("MapModeManager")
	_runner.assert_true(mode_mgr != null, "L1 Content 下应挂 MapModeManager（B4）")
	var hud: Control = _l1_scene.get_node_or_null("ZoomIndicator")
	if hud != null:
		var n_layer_btns := 0
		for ch in hud.get_children():
			if ch is Button and ch.toggle_mode:
				n_layer_btns += 1
		# 层级 3 联（本省 L1/地区 L2/世界 L3，需求 8）+ 图层 4 联（政治/城市/交通/资源，B4）
		_runner.assert_true(n_layer_btns == 7,
			"L1 HUD 应有层级 3 联 + 图层 4 联共 7 个 toggle 按钮（实测 %d）" % n_layer_btns)
		var level_btns: Dictionary = hud.get("_level_btns")
		_runner.assert_true(level_btns.size() == 3 and level_btns.has("L1") \
				and level_btns.has("L2") and level_btns.has("L3"),
			"HUD 层级按钮组 = 本省 L1/地区 L2/世界 L3（实测 %s）" % str(level_btns.keys()))
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
	# 图例（B4 开关层机制；默认 = 政治层开 + 城市层开）：条目 = 政治层 10 条
	# （R7 文化圈聚合代表性子集 9 圈 + 城邦聚合 1 条）+ 城市层建成区 1 条 = 11 条；
	# 标题 = 最上层（渲染叠放序最上的开启层 = 城市层）
	_runner.assert_true(_l1_legend.visible, "open 后图例可见")
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 城市",
		"默认（政治+城市）图例标题 = 城市层（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 11,
		"默认 11 条目 = 政治 10 + 建成区 1（实测 %d）" % _l1_legend._entries_box.get_child_count())
	var blob_text: Label = (_l1_legend._entries_box.get_child(10) as HBoxContainer).get_child(1)
	_runner.assert_true(blob_text.text == "城镇建成区",
		"末条目 = 城市层建成区（实测 %s）" % blob_text.text)
	# 关城市层 → 只剩政治层条目。R7 80 国：图例 = 文化圈聚合代表性子集
	# （9 圈各一条 + 城邦聚合一条 = 10 条），不塞 80 条；
	# 色源 = PoliticalLut（与 L2/L3 政治模式同一份运行时 LUT）
	MapModeManager.set_layer_on(MapModeManager.Layer.CITY, false)
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 政治",
		"仅政治层图例标题（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 10,
		"仅政治层 10 条目 = 9 文化圈聚合 + 城邦聚合（R7，实测 %d）" % _l1_legend._entries_box.get_child_count())
	var last_entry: HBoxContainer = _l1_legend._entries_box.get_child(9)
	var last_text: Label = last_entry.get_child(1)
	_runner.assert_true(last_text.text == "自由城邦 ×8",
		"末条目 = 城邦聚合（实测 %s）" % last_text.text)
	# 首条目 = 规模最大文化圈（「族标签 ×N 国」），色块 = 该圈最大国的 LUT 政权色
	var first_entry: HBoxContainer = _l1_legend._entries_box.get_child(0)
	var swatch: ColorRect = first_entry.get_child(0)
	var text_label: Label = first_entry.get_child(1)
	_runner.assert_true("×" in text_label.text and text_label.text.ends_with("国"),
		"首条目 = 文化圈聚合（实测 %s）" % text_label.text)
	var lut := PoliticalLut.load_shared()
	_runner.assert_true(lut != null, "PoliticalLut 可用")
	if lut != null:
		# 首条目 = 新国数最多的文化圈；色块 = 该圈最大国的 LUT 政权色
		var cnt := {}
		for sid in lut.states:
			var info: Dictionary = lut.states[sid]
			if bool(info.get("is_city_state", false)):
				continue
			var cu := str(info.get("culture", ""))
			cnt[cu] = int(cnt.get(cu, 0)) + 1
		var top_cu := ""
		var top_cn := -1
		for cu in cnt:
			if int(cnt[cu]) > top_cn:
				top_cn = int(cnt[cu])
				top_cu = cu
		var top_n := -1
		var top_id := ""
		for sid in lut.states:
			var info: Dictionary = lut.states[sid]
			if bool(info.get("is_city_state", false)):
				continue
			if str(info.get("culture", "")) != top_cu:
				continue
			if int(info.get("n_cities", 0)) > top_n:
				top_n = int(info.get("n_cities", 0))
				top_id = sid
		_runner.assert_true(text_label.text == "%s ×%d 国"
				% [str(lut.states[top_id].get("culture_label", top_cu)), top_cn],
				"首条目 = 最大文化圈聚合（实测 %s）" % text_label.text)
		_runner.assert_true(swatch.color.is_equal_approx(lut.color_of(top_id)),
			"首条目色块 = 该圈最大国 LUT 政权色（%s，%d 城）" % [top_id, top_n])
	# 开交通层（政治 + 交通）：条目 = 政治 10 + 土路/官道 2 = 12；标题 = 交通（最上层）
	MapModeManager.set_layer_on(MapModeManager.Layer.TRAFFIC, true)
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 交通",
		"政治+交通图例标题 = 交通层（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 12,
		"12 条目 = 政治 10 + 道路 2（实测 %d）" % _l1_legend._entries_box.get_child_count())
	var road_text: Label = (_l1_legend._entries_box.get_child(10) as HBoxContainer).get_child(1)
	_runner.assert_true(road_text.text == "土路",
		"交通条目文字 =「土路」（R6 废虚线标注，实测 %s）" % road_text.text)
	# 关政治层（仅交通）：条目 = 土路/官道 2（R6 废虚线——文字不得再带线型标注）
	MapModeManager.set_layer_on(MapModeManager.Layer.POLITICAL, false)
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 交通",
		"仅交通层图例标题（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 2,
		"仅交通层 2 条目：土路/官道（实测 %d）" % _l1_legend._entries_box.get_child_count())
	var only_road: Label = (_l1_legend._entries_box.get_child(0) as HBoxContainer).get_child(1)
	_runner.assert_true(only_road.text == "土路",
		"交通条目文字 =「土路」（实测 %s）" % only_road.text)
	# 再开城市层 + 资源层（城市 + 交通 + 资源，政治关）：条目 = 建成区 1 + 道路 2 + 资源 6 = 9；
	# 标题 = 资源（最上层）。资源条目色点与地图资源点同源（MapRenderer.RESOURCE_COLORS）
	MapModeManager.set_layer_on(MapModeManager.Layer.CITY, true)
	MapModeManager.set_layer_on(MapModeManager.Layer.RESOURCE, true)
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 资源",
		"城市+交通+资源图例标题 = 资源层（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 9,
		"9 条目 = 建成区 1 + 道路 2 + 资源 6（实测 %d）" % _l1_legend._entries_box.get_child_count())
	var wood_row: HBoxContainer = _l1_legend._entries_box.get_child(3)
	_runner.assert_true((wood_row.get_child(1) as Label).text == "木材",
		"资源条目 = 六种资源 id 色点+名（实测首条 %s）" % (wood_row.get_child(1) as Label).text)
	_runner.assert_true((wood_row.get_child(0) as ColorRect).color.is_equal_approx(
			MapRenderer.RESOURCE_COLORS["res_wood"]), "资源条目色点与地图资源点同源")
	# 全关：仍给底图说明（海洋/湖泊 + 6 群系 = 8 条），标题回退底图
	_reset_layers(true)
	_runner.assert_true(_l1_legend._title_label.text == "图例 · 地形",
		"全关图例标题 = 底图（实测 %s）" % _l1_legend._title_label.text)
	_runner.assert_true(_l1_legend._entries_box.get_child_count() == 8,
		"全关 8 条目 = 海洋/湖泊 + 6 群系（实测 %d）" % _l1_legend._entries_box.get_child_count())
	# 复位默认开关态（开关表全局静态，防污染本文件后续用例）
	_reset_layers()
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
	# P6 旅行弹窗语义：进入状态行按可达性分文案，恒含「双击」（SELF=当前位置
	# / 可达=双击出发 / 不可达=双击走过去+原因）
	_runner.assert_true(not s.map_id.is_empty(), "前置：出生聚落 map_id 已回填")
	_runner.assert_true(_tooltip._enter_label.text.contains("双击"),
			"非空 map_id 显示双击提示（实测 %s）" % _tooltip._enter_label.text)
	_runner.assert_true(_tooltip._enter_label.visible, "进入状态行可见")


func _test_tooltip_enterable() -> void:
	if _tooltip == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	# 构造 map_id 为空的聚落（未开放形态：69 包外圈聚落/未来地图未挂）
	var tile := L1TileDef.new()
	tile.tile_id = "test_tile"
	tile.owner_state_id = "state_test"
	var s := SettlementRef.new()
	s.settlement_id = "settlement_test"
	s.name = "测试城"
	s.level = 3
	s.map_id = ""
	tile.settlement = s
	_tooltip.update_for_tile(tile)
	_runner.assert_true(_tooltip.visible, "空 map_id 聚落仍显示 tooltip")
	_runner.assert_true(_tooltip._enter_label.text == "未开放进入", "空 map_id 显示未开放进入（实测 %s）" % _tooltip._enter_label.text)


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


## 图层开关复位：默认态 = 政治/城市开、交通/资源关；all_off = 四层全关（只余底图）
func _reset_layers(all_off: bool = false) -> void:
	MapModeManager.set_layer_on(MapModeManager.Layer.POLITICAL, not all_off)
	MapModeManager.set_layer_on(MapModeManager.Layer.CITY, not all_off)
	MapModeManager.set_layer_on(MapModeManager.Layer.TRAFFIC, false)
	MapModeManager.set_layer_on(MapModeManager.Layer.RESOURCE, false)


func _esc_event() -> InputEvent:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	return ev


# ───────────────────── P4：据点归属面（tooltip 归属行 / 据点面板）─────────────────────

## tooltip 归属行读归属真值（WorldState.territories 的 owner/faction）：
## 未易手 / 我方已占两态；非本模块据点的聚落隐藏该行；expansion 未装配也不炸。
func _test_territory_tooltip_line() -> void:
	if _tooltip == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	# 未装配 expansion：归属行隐藏（不误显"未易手"）
	var tile := L1TileDef.new()
	tile.tile_id = "probe_tile"
	tile.owner_state_id = "state_probe"
	var s := SettlementRef.new()
	s.settlement_id = "settlement_probe"
	s.name = "探针城"
	s.level = 1
	s.map_id = "probe_map"
	tile.settlement = s
	_tooltip.update_for_tile(tile)
	_runner.assert_false(_tooltip._territory_label.visible, "expansion 未装配时隐藏归属行")
	# 装配 expansion：据点聚落显示归属行
	var api := Node.new()
	api.set_script(ExpansionApiScript)
	add_child(api)
	var targets: Array = api.list_targets()
	_runner.assert_gt(targets.size(), 0, "前置：据点配置可载入")
	var first: Dictionary = targets[0]
	var key := String(first.get("settlement_key", ""))
	var id := String(first.get("id", ""))
	var t_tile := L1TileDef.new()
	t_tile.tile_id = "probe_territory_tile"
	t_tile.owner_state_id = "state_probe"
	var t_ref := SettlementRef.new()
	t_ref.settlement_id = key
	t_ref.name = "探针据点城"
	t_ref.level = 1
	t_ref.map_id = "probe_map"
	t_tile.settlement = t_ref
	_tooltip.update_for_tile(t_tile)
	_runner.assert_true(_tooltip._territory_label.visible, "据点聚落显示归属行")
	_runner.assert_true(_tooltip._territory_label.text.contains("未易手"),
			"未易手据点归属行（实测 %s）" % _tooltip._territory_label.text)
	# 非据点聚落：归属行隐藏（世界地图上的普通聚落没有归属真值）
	_tooltip.update_for_tile(tile)
	_runner.assert_false(_tooltip._territory_label.visible, "非据点聚落隐藏归属行")
	# 占领（写真值 owner=player）→ 同一行变"我方已占"
	var backup: Variant = WorldState.territories.get(id, null)
	WorldState.territories[id] = {
		"state": 1, "garrison_losses": 0, "control_progress": 100.0,
		"owner": "player", "faction": "fac_player",
	}
	_tooltip.update_for_tile(t_tile)
	_runner.assert_true(_tooltip._territory_label.text.contains("我方已占"),
			"占领后归属行读真值（实测 %s）" % _tooltip._territory_label.text)
	if backup == null:
		WorldState.territories.erase(id)
	else:
		WorldState.territories[id] = backup
	# 归属行两态都在（清理展示态，不影响后续用例）
	_runner.assert_true(_tooltip.visible, "tooltip 整体仍显示")
	api.queue_free()
	_tooltip.reset()


## 据点面板：无数据源空态隐藏；注入数据源后逐据点一行、标题带已占计数；
## 行点击回调收到整条 target（控制器据此定位 + 激活）。
func _test_territory_panel() -> void:
	if _l1_scene == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	var panel: TerritoryPanel = _l1_scene.get_node_or_null("TerritoryPanel") as TerritoryPanel
	_runner.assert_true(panel != null, "L1 场景应挂 TerritoryPanel")
	if panel == null:
		return
	_runner.assert_true(panel.get_parent() == _l1_scene, "据点面板应挂 CanvasLayer 直下")
	# 无数据源（expansion 未装配）→ 空态：set_shown(true) 也保持隐藏
	panel.targets_fn = Callable()
	panel.refresh()
	panel.set_shown(true)
	_runner.assert_false(panel.visible, "无据点数据时空态隐藏")
	var api := Node.new()
	api.set_script(ExpansionApiScript)
	add_child(api)
	var fired: Array = []
	panel.targets_fn = api.list_targets
	panel.activate_fn = func(t: Dictionary) -> void: fired.append(String(t.get("id", "")))
	panel.refresh()
	panel.set_shown(true)
	var targets: Array = api.list_targets()
	_runner.assert_true(panel.visible, "有据点数据时显示")
	_runner.assert_equal(panel._rows.size(), targets.size(), "逐据点一行（实测 %d）" % panel._rows.size())
	_runner.assert_true(panel._rows[0].text.contains(String((targets[0] as Dictionary).get("name_zh", ""))),
			"行文案含据点名（实测 %s）" % panel._rows[0].text)
	panel._rows[0].pressed.emit()
	_runner.assert_equal(fired.size(), 1, "行点击触发回调一次")
	_runner.assert_equal(fired[0], String((targets[0] as Dictionary).get("id", "")),
			"回调收到该行据点 id")
	# 清理：回空态（本场景实例后续用例还要用）
	api.queue_free()
	panel.targets_fn = Callable()
	panel.activate_fn = Callable()
	panel.refresh()
	panel.set_shown(false)


## P4 染色：政治模式的填充按已占地块**逐格**覆盖——占多少染多少，不整国变色。
## 取色唯一出口 = MapRenderer.tile_fill_color（填充 mesh 烘焙与矢量回退同源）。
func _test_owned_tile_dyeing() -> void:
	if _l1_content == null or _l1_api == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	var renderer: MapRenderer = _l1_content.get_node_or_null("MapRenderer") as MapRenderer
	_runner.assert_true(renderer != null, "前置：L1 Content 应挂 MapRenderer")
	if renderer == null:
		return
	var data: L1WorldData = _l1_api.get_data()
	if data == null or data.tiles.size() < 2:
		_runner.assert_true(false, "前置：L1 数据至少两块地（实测 %d）" % (data.tiles.size() if data != null else -1))
		return
	var t0: L1TileDef = data.tiles[0]
	var t1: L1TileDef = data.tiles[1]
	var baseline0: Color = data.get_state_color(t0.owner_state_id)
	# 未占领：按所属政权色（原样）
	renderer.set_owned_tiles([])
	_runner.assert_equal(renderer.tile_fill_color(t0), baseline0, "未占地块按所属政权色填充")
	# 占一块：这一格变玩家疆域色，邻格不动（逐格覆盖的语义核心）
	renderer.set_owned_tiles([t0.tile_id])
	_runner.assert_equal(renderer.tile_fill_color(t0), MapTokens.L1_PLAYER_TERRITORY_COLOR,
			"已占地块染玩家疆域色")
	_runner.assert_equal(renderer.tile_fill_color(t1), data.get_state_color(t1.owner_state_id),
			"未占邻格不变色（占多少染多少，非整国变色）")
	# 再占一格：两格都染（占多少染多少）
	renderer.set_owned_tiles([t0.tile_id, t1.tile_id])
	_runner.assert_equal(renderer.tile_fill_color(t1), MapTokens.L1_PLAYER_TERRITORY_COLOR,
			"第二块已占后同样染色")
	# 清空：回政权色（读档/开局无归属时不留染色残留）
	renderer.set_owned_tiles([])
	_runner.assert_equal(renderer.tile_fill_color(t0), baseline0, "清空已占地块表后回政权色")
	# WorldBox 式政治图（创始人 2026-09-22）：地形打底 + 半透明国色覆盖 + 国色描边
	_runner.assert_true(MapRenderer.BASE_TEXTURE == "l1_terrain.png",
			"底图恒为 l1_terrain.png（政治层叠在其上，不是全平涂）")
	_runner.assert_true(MapRenderer.POLITICAL_FILL_ALPHA > 0.0
			and MapRenderer.POLITICAL_FILL_ALPHA < 1.0, "政治覆盖层为半透明（实测 %.2f）"
			% MapRenderer.POLITICAL_FILL_ALPHA)
	var bc: Color = renderer.tile_border_color(t0)
	_runner.assert_equal(bc.a, 1.0, "地块描边用不透明国色")
	_runner.assert_equal(Color(bc.r, bc.g, bc.b), baseline0, "描边色与所属政权填充同源")


## P4 染色：政治图例在有已占地块时补一条「我方疆域」，无已占地块时不留空条目
func _test_legend_player_entry() -> void:
	if _l1_content == null or _l1_legend == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	var api := Node.new()
	api.set_script(ExpansionApiScript)
	add_child(api)
	var targets: Array = api.list_targets()
	_runner.assert_gt(targets.size(), 0, "前置：据点配置可载入")
	var id := String((targets[0] as Dictionary).get("id", ""))
	var backup: Variant = WorldState.territories.get(id, null)
	WorldState.territories[id] = {
		"state": 1, "garrison_losses": 0, "control_progress": 100.0,
		"owner": "player", "faction": "fac_player",
	}
	MapModeManager.set_layer_on(MapModeManager.Layer.POLITICAL, true)
	_l1_content.call("_fill_legend")
	_runner.assert_true(_legend_has_text("我方疆域"), "政治图例含「我方疆域」条目")
	if backup == null:
		WorldState.territories.erase(id)
	else:
		WorldState.territories[id] = backup
	_l1_content.call("_fill_legend")
	_runner.assert_false(_legend_has_text("我方疆域"), "无已占地块时不留空条目")
	_reset_layers()
	api.queue_free()


## 图例内是否存在含指定文字的标签（图例条目 = 色块 + 文字，逐层找 Label）
func _legend_has_text(needle: String) -> bool:
	if _l1_legend == null:
		return false
	return _find_label_text(_l1_legend, needle)


func _find_label_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	for child in node.get_children():
		if _find_label_text(child, needle):
			return true
	return false


## 邻省上下文 + 切省箭头环（本批：灰色邻块 → 地形 + 暗一阶政权色；每个相邻省份一个
## 箭头排在地图内虚拟圆环上、背离圆心指向该省）。
## 断言走真实数据与真实链路：ProvincePolitics 侧表 → 邻块取色；控制器 _arrow_ring_config
## → 箭头环；switch_province → api 实际换包且不改 ESC 语义。
func _test_province_context() -> void:
	if _l1_api == null or _l1_content == null:
		_runner.assert_true(false, "前置装配缺失")
		return
	_l1_api.initialize(L1_JSON_PATH, L1_BASE_DIR)
	_l1_content.visible = true
	_l1_content.call("open")
	var arrows: ProvinceSwitchArrows = _l1_scene.get_node_or_null("ProvinceSwitchArrows") as ProvinceSwitchArrows
	_runner.assert_true(arrows != null, "L1 场景应挂 ProvinceSwitchArrows")
	if arrows == null:
		return
	_runner.assert_true(arrows.get_parent() == _l1_scene,
			"箭头挂 CanvasLayer 直下（Control 挂 Node2D 下 anchor 参照为 0 会跑位）")
	_runner.assert_true(arrows.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"箭头根不吃鼠标（不挡地图拖拽/点选）")
	_runner.assert_true(arrows.targets_fn.is_valid() and arrows.activate_fn.is_valid()
			and arrows.screen_pos_fn.is_valid(), "控制器已注入 targets_fn / activate_fn / screen_pos_fn")
	# 箭头环：出生省三个邻省 → 三个箭头，方位与全球地理一致（#18 东北 / #67 西北 / #68 正西）
	var cfg: Dictionary = _l1_content.call("_arrow_ring_config")
	var ring_arrows: Array = cfg.get("arrows", [])
	_runner.assert_eq(ring_arrows.size(), BIRTH_NEIGHBORS.size(),
			"每个相邻省份一个箭头（实测 %d 个）" % ring_arrows.size())
	var got_labels: Array = []
	var by_label := {}
	for a in ring_arrows:
		var label := int((a as Dictionary).get("label", 0))
		got_labels.append(label)
		by_label[label] = a
		_runner.assert_true(BIRTH_NEIGHBORS.has(label), "箭头目标取自相邻省（实测 #%d）" % label)
		_runner.assert_true(((a as Dictionary).get("color", Color(0, 0, 0, 0)) as Color).a > 0.0,
				"箭头 #%d 取到政权色（填充=目标省省色）" % label)
	for nb in BIRTH_NEIGHBORS:
		_runner.assert_true(got_labels.has(nb), "邻省 #%d 有对应箭头" % nb)
	# 方位角（背离圆心 = 指向该省）：#68 正西 ≈ ±π、#67 西北 ≈ -3π/4、#18 东北 ≈ -π/4
	var ang68: float = float((by_label.get(68, {}) as Dictionary).get("angle", 99.0))
	var ang18: float = float((by_label.get(18, {}) as Dictionary).get("angle", 99.0))
	_runner.assert_true(absf(absf(ang68) - PI) < 0.25,
			"#68 正西（angle=%.2f rad）" % ang68)
	_runner.assert_true(absf(ang18 + PI * 0.25) < 0.4,
			"#18 东北（angle=%.2f rad）" % ang18)
	# 圆环锚在地图内：圆心 = context 中心、半径 < 中心到边的距离
	var center: Vector2 = cfg.get("center", Vector2.ZERO)
	var radius: float = float(cfg.get("radius", 0.0))
	var side := float(maxi((_l1_api.get_data() as L1WorldData).context_size.x,
			(_l1_api.get_data() as L1WorldData).context_size.y))
	_runner.assert_true(center.distance_to(Vector2(side, side) * 0.5) < 1.0,
			"圆环圆心 = context 中心（实测 %s）" % center)
	_runner.assert_true(radius > 0.0 and radius < minf(center.x, center.y),
			"圆环半径落在图内（r=%.0f 中心距边 %.0f）" % [radius, minf(center.x, center.y)])
	# 邻块取色 = 侧表政权色暗一阶（不是旧平灰）
	var pol := ProvincePolitics.load_shared()
	_runner.assert_true(pol != null, "省份政治面侧表装载成功")
	var renderer: MapRenderer = _l1_content.get_node_or_null("MapRenderer") as MapRenderer
	if pol != null and renderer != null:
		var nb: Dictionary = (_l1_api.get_data() as L1WorldData).neighbors[0]
		var nb_label := int(nb.get("label", 0))
		var got: Color = _Geo.neighbor_block_color(renderer, nb)
		var want: Color = pol.color_of(nb_label).darkened(MapTokens.L1_NEIGHBOR_DIM)
		_runner.assert_true(got.a > 0.0 and got.is_equal_approx(want),
				"邻省块色 = 政权色暗一阶（#%d 实测 %s / 期望 %s）" % [nb_label, got, want])
		_runner.assert_true(not got.is_equal_approx(MapTokens.L1_NEIGHBOR_COLOR),
				"邻省不再是平灰")
		# 邻块多边形轴序回归：邻块必须与会块一样是 [x,y]（曾被漏转 to_xy → 沿对角轴翻转）
		var ext := _ring_extent(nb.get("polygons", []))
		_runner.assert_true(ext.x > 0.0 and ext.x > ext.y,
				"邻块 #%d 形状横向为主（轴序未翻转；实测 bbox %.0f×%.0f）" % [nb_label, ext.x, ext.y])
	# 切省：api 实际换包 + 指示器跟随 + ESC 语义不变（仍为直开关闭）
	var probe: int = int(BIRTH_NEIGHBORS[BIRTH_NEIGHBORS.size() - 1])
	var switched: bool = _l1_content.call("switch_province", probe)
	_runner.assert_true(switched, "switch_province(#%d) 成功" % probe)
	_runner.assert_eq(_l1_api.get_current_l1_label(), probe, "当前 L1 已切到 #%d" % probe)
	if _l1_indicator != null:
		_runner.assert_eq(_l1_indicator._subtitle_label.text, "#%d" % probe,
				"指示器跟随切省（实测 %s）" % _l1_indicator._subtitle_label.text)
	_runner.assert_true(not bool(_l1_content._drill_from_l2),
			"切省不改下钻标志（ESC 仍关闭地图，不误返回 L2）")
	_runner.assert_true(not _l1_content.call("switch_province", probe),
			"重复切同一省返回 false（幂等）")
	# 切省后箭头环随新省重算（邻省集合变了，箭头数量随数据走）
	var cfg2: Dictionary = _l1_content.call("_arrow_ring_config")
	_runner.assert_true((cfg2.get("arrows", []) as Array).size() > 0,
			"切省后箭头环重算（新省邻省集）")
	_l1_content.call("close")


## 多边形点列的包围盒尺寸（点列为 [x,y] 数组）
func _ring_extent(polys: Array) -> Vector2:
	var lo := Vector2.INF
	var hi := -Vector2.INF
	for ring in polys:
		for p in (ring as Array):
			var v := Vector2(float(p[0]), float(p[1]))
			lo = lo.min(v)
			hi = hi.max(v)
	if lo == Vector2.INF:
		return Vector2.ZERO
	return hi - lo


## 水体矢量后处理（水陆同源 D3）：政治模式水 = 河流 polyline（EDT 实测宽）+
## 湖泊 polygon，画在色块之上——运行时不再判水（旧绿-蓝差回贴已退役）。
## 数据面守门：湖多边形非空且顶点在 context 界内；河流逐条 w>0（EDT 宽纪律）。
func _test_water_vector() -> void:
	var data := L1WorldData.load_from(L1_JSON_PATH, L1_BASE_DIR)
	var ctx := data.context_size
	_runner.assert_true(data.lakes.size() > 0, "湖多边形非空（精细湖光栅同批重提）")
	var in_bounds := true
	for lake in data.lakes:
		if (lake as Array).size() < 3:
			in_bounds = false
			break
		for p in (lake as Array):
			if float(p[0]) < 0.0 or float(p[0]) > float(ctx.x) \
					or float(p[1]) < 0.0 or float(p[1]) > float(ctx.y):
				in_bounds = false
				break
		if not in_bounds:
			break
	_runner.assert_true(in_bounds, "湖多边形顶点全部在 context 界内")
	_runner.assert_true(data.rivers.size() > 0, "河流折线非空")
	var edt_width := true
	for rv in data.rivers:
		if float(rv.get("w", 0.0)) <= 0.0 or (rv.get("pts") as PackedVector2Array).size() < 2:
			edt_width = false
			break
	_runner.assert_true(edt_width, "河流逐条 w>0 且 ≥2 点（宽度取自生成端 EDT 实测）")
	var f := FileAccess.open("%s/l1_terrain.png" % L1_BASE_DIR, FileAccess.READ)
	_runner.assert_true(f != null, "地形底图在包内（矢量水画其上）")
	if f != null:
		f.close()
