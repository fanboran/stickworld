extends Node
## 集成测试：P0 新 0.9 基础战略图（L1 单层）
## 验证：L1 数据加载（出生 L1 城市划分）/ 城市点命中查询 / 双击进入（城市暂无 map_id 不可进）/ 打开关闭输入暂停恢复

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
@warning_ignore("shadowed_global_identifier")
const TestHelpers := preload("res://tests/core/test_helpers.gd")
const STRATEGIC_MAP_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map.tscn")

const L1_JSON_PATH := "res://config/strategic_map/l1_world.json"
const L1_BASE_DIR := "res://config/strategic_map"

var _runner: TestRunner
var _map: Node = null
var _content: Node = null
var _api: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L1 数据加载：出生 L1 城市划分", _test_load, true)
	_runner.add_test("索引图命中查询（P 社机制）", _test_query, true)
	_runner.add_test("悬停坐标换算（open 后 offset/zoom 非零）", _test_hover_mapping, true)
	_runner.add_test("城市聚落暂无 map_id：双击不可进入", _test_enter, true)
	_runner.add_test("无 map_id 聚落不可进入", _test_empty_enter, true)
	_runner.add_test("打开/关闭暂停恢复场景图输入", _test_pause_resume, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_load() -> void:
	_map = STRATEGIC_MAP_SCENE.instantiate()
	add_child(_map)
	# 战略图是 CanvasLayer，控制器/组件在 Content 子节点下
	_content = _map.get_node_or_null("Content")
	_api = _content.get_node_or_null("Api") if _content != null else null
	_runner.assert_true(_api != null, "战略图应含 Api 节点（Content/Api）")
	if _api == null:
		return
	_runner.assert_true(_api.has_method("initialize"), "api 应有 initialize 方法")
	_api.initialize(L1_JSON_PATH, L1_BASE_DIR)
	_runner.assert_true(_api.is_initialized(), "L1 数据应初始化成功（含底图）")
	var data: RefCounted = _api.get_data()
	_runner.assert_true(data != null, "data 非空")
	if data == null:
		return
	# 出生 L1 城市划分：每城市 = 1 地块 1 聚落（暂无 map_id），每城市独立政权，MST 道路
	_runner.assert_true(data.tiles.size() >= 2, "地块数应 >= 2（出生 L1 城市数，实测 %d）" % data.tiles.size())
	var settled: int = 0
	var no_map: int = 0
	for tile in data.tiles:
		if tile.settlement != null:
			settled += 1
			if tile.settlement.map_id.is_empty():
				no_map += 1
	_runner.assert_true(settled == data.tiles.size(), "每个城市地块都应有聚落（实测 %d/%d）" % [settled, data.tiles.size()])
	_runner.assert_true(no_map == data.tiles.size(),
		"城市聚落暂无 map_id（不可进入，实测 %d/%d）" % [no_map, data.tiles.size()])
	_runner.assert_true(data.roads.size() >= data.tiles.size() - 1,
		"道路数应 >= 城市数-1（MST 连通，实测 %d/%d）" % [data.roads.size(), data.tiles.size()])
	_runner.assert_true(data.states.size() == data.tiles.size(),
		"每城市独立政权（实测 %d/%d）" % [data.states.size(), data.tiles.size()])
	_runner.assert_true(not data.spawn_settlement_id.is_empty(), "应有出生城市")
	_runner.assert_true(data.l1_polygon.size() >= 3, "应含出生 L1 权威轮廓（实测 %d 点）" % data.l1_polygon.size())
	_runner.assert_true(data.base_texture != null, "底图已加载")
	_runner.assert_true(data.mask_image != null, "边界索引图已加载")


func _test_query() -> void:
	if _api == null or not _api.is_initialized():
		_runner.assert_true(false, "前置数据加载失败，跳过")
		return
	var data: RefCounted = _api.get_data()
	# 对每个聚落位置，模拟 query（用 camera 坐标系：初始 zoom=1 时 map == screen）
	for tile in data.tiles:
		if tile.settlement == null:
			continue
		var pos: Vector2 = tile.settlement.position
		var query: Dictionary = _api.query_at_screen(pos)
		var hit: RefCounted = query.get("settlement", null)
		_runner.assert_true(hit != null and hit.settlement_id == tile.settlement.settlement_id,
			"索引图命中 %s（实测 %s）" % [tile.settlement.settlement_id, hit.settlement_id if hit else "null"])
	# 空聚落地块：查询应命中 tile 但 settlement 为 null
	for tile in data.tiles:
		if tile.settlement != null:
			continue
		if tile.polygon.size() < 3:
			continue
		var centroid: Vector2 = tile.get_centroid()
		var query: Dictionary = _api.query_at_screen(centroid)
		_runner.assert_true(query.get("tile", null) != null, "空聚落地块应可命中 tile（%s）" % tile.tile_id)
		break


func _test_hover_mapping() -> void:
	# 悬停坐标换算：相机 offset/zoom 非零时，屏幕坐标经 screen_to_map
	# 应命中同一聚落（渲染器悬停检测与 api.query_at_screen 同路径）
	if _api == null or not _api.is_initialized():
		_runner.assert_true(false, "前置数据加载失败，跳过")
		return
	var camera: Node = _content.get_node_or_null("MapCamera")
	_runner.assert_true(camera != null and camera.has_method("map_to_screen"),
		"应有 MapCamera（map_to_screen）")
	if camera == null:
		return
	var data: RefCounted = _api.get_data()
	# 模拟悬浮居中：offset/zoom 非零（不 open，隔离 UI 副作用）
	if camera.has_method("set_zoom") and camera.has_method("set_offset"):
		camera.set_zoom(1.5)
		camera.set_offset(Vector2(300, 200))
	var checked: int = 0
	for tile in data.tiles:
		if tile.settlement == null:
			continue
		var map_pos: Vector2 = tile.settlement.position
		var screen_pos: Vector2 = camera.map_to_screen(map_pos)
		var back: Vector2 = camera.screen_to_map(screen_pos)
		# api 路径：内部经 camera 换算
		var query: Dictionary = _api.query_at_screen(screen_pos)
		var hit: RefCounted = query.get("settlement", null)
		var ok: bool = hit != null and hit.settlement_id == tile.settlement.settlement_id
		if not ok:
			# 直查路径（隔离 camera）：确认是换算问题还是索引图问题
			var direct: Dictionary = data.query_at_map_pos(back)
			var direct_hit: RefCounted = direct.get("settlement", null)
			print("[debug] %s screen=%s back=%s api_hit=%s direct=%s" % [
				tile.settlement.settlement_id, screen_pos, back,
				hit.settlement_id if hit else "null",
				direct_hit.settlement_id if direct_hit else "null"])
		_runner.assert_true(ok,
			"屏幕坐标 %s 应命中 %s（实测 %s）" % [
				screen_pos, tile.settlement.settlement_id,
				hit.settlement_id if hit else "null"
			])
		checked += 1
	# 渲染器悬停换算已装配
	var renderer: Node = _content.get_node_or_null("MapRenderer")
	_runner.assert_true(renderer != null and renderer.has_method("set_camera"),
		"渲染器应有 set_camera（悬停换算已装配）")
	_runner.assert_true(checked >= 3, "至少验证 3 个聚落的坐标往返（实测 %d）" % checked)
	# 恢复相机
	camera.set_zoom(1.0)
	camera.set_offset(Vector2.ZERO)


func _test_enter() -> void:
	if _api == null or not _api.is_initialized():
		_runner.assert_true(false, "前置数据加载失败，跳过")
		return
		_runner.assert_true(false, "前置数据加载失败，跳过")
		return
	var data: RefCounted = _api.get_data()
	# 找带 map_id 的聚落（城市层暂无可玩地图 -> 应没有；将来接入后自动恢复进入验证）
	var target_id: String = ""
	var expected_map: String = ""
	for tile in data.tiles:
		if tile.settlement != null and not tile.settlement.map_id.is_empty():
			target_id = tile.settlement.settlement_id
			expected_map = tile.settlement.map_id
			break
	var emitted: Array = []
	if EventBus != null:
		EventBus.travel_requested.connect(func(m: String): emitted.append(m))
	if target_id.is_empty():
		# 城市层现状：全部城市无 map_id -> 双击/enter 不应触发旅行
		_api.enter_settlement(data.spawn_settlement_id)
		await get_tree().process_frame
		_runner.assert_true(emitted.is_empty(),
			"城市聚落无 map_id：enter_settlement 不应发射 travel_requested")
		_runner.assert_true(true, "（城市层暂无 map_id，进入验证待可玩地图接入后恢复）")
		return
	_api.enter_settlement(target_id)
	await get_tree().process_frame
	_runner.assert_true(emitted.size() >= 1, "enter_settlement 应发射 EventBus.travel_requested（收到 %d）" % emitted.size())
	if emitted.size() > 0:
		_runner.assert_true(emitted[0] == expected_map,
			"travel 参数应为该聚落的 map_id（%s，实测 %s）" % [expected_map, emitted[0]])


func _test_empty_enter() -> void:
	if _api == null or not _api.is_initialized():
		_runner.assert_true(false, "前置数据加载失败，跳过")
		return
	var data: RefCounted = _api.get_data()
	var empty_id: String = ""
	for tile in data.tiles:
		if tile.settlement != null and tile.settlement.map_id.is_empty() \
				and tile.settlement.settlement_id != data.spawn_settlement_id:
			empty_id = tile.settlement.settlement_id
			break
	if empty_id.is_empty():
		_runner.assert_true(true, "（无 map_id 非出生聚落可测，跳过）")
		return
	var emitted: Array = []
	if EventBus != null:
		EventBus.travel_requested.connect(func(m: String): emitted.append(m))
	_api.enter_settlement(empty_id)
	await get_tree().process_frame
	_runner.assert_true(emitted.is_empty(), "无 map_id 聚落不应发射 travel_requested")


func _test_pause_resume() -> void:
	if _api == null or _content == null:
		_runner.assert_true(false, "前置失败，跳过")
		return
	# 打开：控制器 visible + strategic_map_opened 信号
	var opened: Array = []
	if EventBus != null:
		EventBus.strategic_map_opened.connect(func(): opened.append(true))
	if _content.has_method("open"):
		_content.open()
	await get_tree().process_frame
	_runner.assert_true(_content.visible, "打开后战略图内容可见")
	_runner.assert_true(opened.size() >= 1, "打开应发射 strategic_map_opened")
	# 关闭：strategic_map_closed 信号
	var closed: Array = []
	if EventBus != null:
		EventBus.strategic_map_closed.connect(func(): closed.append(true))
	if _content.has_method("close"):
		_content.close()
	await get_tree().process_frame
	_runner.assert_true(not _content.visible, "关闭后战略图内容不可见")
	_runner.assert_true(closed.size() >= 1, "关闭应发射 strategic_map_closed")
