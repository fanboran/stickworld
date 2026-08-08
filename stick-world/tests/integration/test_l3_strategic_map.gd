extends Node
## 集成测试：L3 大世界战略图（M 键）
## 验证：L3 数据加载（13 地区）/ 分区索引图命中（含海洋归边）/ 陆地边界多边形 / 隔海直线链接

const TestRunner := preload("res://tests/core/test_runner.gd")
const L3_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l3.tscn")
const L3_WORLD := preload("res://modules/world_map/data/l3_world_data.gd")

const L3_JSON_PATH := "res://config/strategic_map/l3_world.json"
const L3_BASE_DIR := "res://config/strategic_map"

var _runner: TestRunner
var _scene: Node = null
var _content: Node = null
var _renderer: Node = null
var _data: RefCounted = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L3 数据加载：13 地区 + 底图 + 索引图", _test_load, true)
	_runner.add_test("分区索引图命中（含海洋归边）", _test_query, true)
	_runner.add_test("完整分区轮廓即分界（含海上延长，连续无突变）", _test_links, true)
	_runner.add_test("M 键视图打开/关闭", _test_toggle, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_load() -> void:
	_scene = L3_SCENE.instantiate()
	add_child(_scene)
	_content = _scene.get_node_or_null("Content")
	_renderer = _content.get_node_or_null("L3MapRenderer") if _content != null else null
	_runner.assert_true(_renderer != null, "L3 场景应含 L3MapRenderer")
	if _renderer == null:
		return
	_data = L3WorldData.load_from(L3_JSON_PATH, L3_BASE_DIR)
	_renderer.set_data(_data)
	_runner.assert_true(_data.mask_image != null, "L3 分区索引图已加载")
	_runner.assert_true(_data.regions.size() == 13, "应有 13 个地区（实测 %d）" % _data.regions.size())
	# 每个地区应有陆地轮廓
	var no_poly: int = 0
	for r in _data.regions:
		if (r.get("land_polygon", []) as Array).size() < 3:
			no_poly += 1
	_runner.assert_true(no_poly == 0, "所有地区应有陆地轮廓（缺失 %d）" % no_poly)


func _test_query() -> void:
	if _data == null:
		_runner.assert_true(false, "前置数据加载失败")
		return
	# 分区图解码验证：每地区取陆地轮廓内一点，query 应命中该地区
	var hit: int = 0
	var checked: int = 0
	for r in _data.regions:
		var lab: int = r.get("label", 0)
		var land_poly: Array = r.get("land_polygon", [])
		if land_poly.size() < 3:
			continue
		# 轮廓点是 (y,x) 顺序（find_contours），转为 (x,y) 并内移取陆地像素
		var pt := Vector2(land_poly[0][1], land_poly[0][0]) + Vector2(4, 4)
		var q: Dictionary = _data.query_at_map_pos(pt)
		var region: Variant = q.get("region", {})
		checked += 1
		if region != null and int((region as Dictionary).get("label", -1)) == lab:
			hit += 1
	print("[debug] query 检查 %d 个地区, 命中 %d" % [checked, hit])
	_runner.assert_true(checked >= 13, "应检查全部 13 地区（实测 %d）" % checked)
	_runner.assert_true(hit >= 10, "至少 10 个地区分区命中（实测 %d）" % hit)
	# 海洋归边：北部海域像素应命中某地区（分区含海洋）
	var q2: Dictionary = _data.query_at_map_pos(Vector2(1500, 100))
	_runner.assert_true(not q2.get("region", {}).is_empty(), "海洋像素应归边到某地区")


func _test_links() -> void:
	# 分界验证：完整分区轮廓（full_polygon）即"地面+海洋一起分"的分界线，
	# 与 hover 高光边缘一致（海上延长线由海洋归边产生，不额外画线）
	if _data == null:
		_runner.assert_true(false, "前置数据加载失败")
		return
	var with_full: int = 0
	var valid_full: int = 0
	for r in _data.regions:
		var full: Array = r.get("full_polygon", [])
		if full.size() >= 3:
			with_full += 1
			# 非边缘段应连续（允许沿地图边缘的大跳变，渲染时断段处理）
			var jumps: int = 0
			for i in range(full.size()):
				var a: Array = full[i]
				var b: Array = full[(i + 1) % full.size()]
				var d := Vector2(a[0], a[1]).distance_to(Vector2(b[0], b[1]))
				if d > 60.0:
					jumps += 1
			if jumps <= 2:
				valid_full += 1
	_runner.assert_true(with_full == 13, "所有地区应有完整分区轮廓（%d/13）" % with_full)
	_runner.assert_true(valid_full == 13, "所有完整轮廓应连续（边缘跳变<=2）（%d/13）" % valid_full)


func _test_toggle() -> void:
	if _content == null:
		_runner.assert_true(false, "前置失败")
		return
	_runner.assert_true(not _content.visible, "初始 L3 视图隐藏")
	if _content.has_method("open"):
		_content.open()
	await get_tree().process_frame
	_runner.assert_true(_content.visible, "open() 后 L3 视图可见")
	if _content.has_method("close"):
		_content.close()
	await get_tree().process_frame
	_runner.assert_true(not _content.visible, "close() 后 L3 视图隐藏")
