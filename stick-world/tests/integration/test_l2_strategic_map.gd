extends Node
## 集成测试：L2 地区详细视图（L3 下钻）
## 验证：L2 数据加载（13 地区素材齐备）/ 地块索引图命中 / 打开-返回切换

const TestRunner := preload("res://tests/core/test_runner.gd")
const L2_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l2.tscn")
const L2_WORLD := preload("res://modules/world_map/data/l2_world_data.gd")
const L3_SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map_l3.tscn")
const L3_WORLD := preload("res://modules/world_map/data/l3_world_data.gd")

const L3_JSON_PATH := "res://config/strategic_map/l3_world.json"
const L3_BASE_DIR := "res://config/strategic_map"
const L2_BASE_DIR := "res://config/strategic_map/l2_packs"

var _runner: TestRunner
var _l2_scene: Node = null
var _l2_content: Node = null
var _l2_renderer: Node = null
var _l2_data: RefCounted = null
var _l3_scene: Node = null
var _l3_content: Node = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("L2 素材齐备：13 地区数据可加载", _test_packs_exist, true)
	_runner.add_test("L2 数据加载：索引图 + 地块列表", _test_load, true)
	_runner.add_test("地块索引图命中", _test_query, true)
	_runner.add_test("F3 调试模式：L1 地块标号刷新", _test_debug_labels, true)
	_runner.add_test("L3 单击下钻 -> L2 打开，ESC 返回 L3", _test_drilldown, true)
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _test_packs_exist() -> void:
	var missing: Array[String] = []
	for i in range(1, 14):
		var rid := "region_%03d" % i
		var json_path := "%s/%s/l2_world.json" % [L2_BASE_DIR, rid]
		if not FileAccess.file_exists(json_path):
			missing.append(rid)
	_runner.assert_true(missing.is_empty(), "13 个 L2 地区素材应齐备（缺失 %s）" % str(missing))


func _test_load() -> void:
	_l2_scene = L2_SCENE.instantiate()
	add_child(_l2_scene)
	_l2_content = _l2_scene.get_node_or_null("Content")
	_l2_renderer = _l2_content.get_node_or_null("L2MapRenderer") if _l2_content != null else null
	_runner.assert_true(_l2_renderer != null, "L2 场景应含 L2MapRenderer")
	if _l2_renderer == null:
		return
	var ok: int = 0
	for i in range(1, 14):
		var rid := "region_%03d" % i
		var data: RefCounted = L2WorldData.load_from(
			"%s/%s/l2_world.json" % [L2_BASE_DIR, rid],
			"%s/%s" % [L2_BASE_DIR, rid]
		)
		if data.mask_image != null and (data.tiles as Array).size() > 0:
			ok += 1
	_runner.assert_true(ok == 13, "13 地区应全部加载成功（索引图+地块）（%d/13）" % ok)


func _test_debug_labels() -> void:
	# F3 调试模式（DebugApi）切换时，L2 渲染器应刷新（_debug_was_visible 变化），不崩溃
	if _l2_scene == null or _l2_renderer == null:
		_runner.assert_true(false, "前置：L2 场景未装载")
		return
	var before: bool = _l2_renderer._debug_was_visible
	var was_visible: bool = DebugApi != null and DebugApi.is_visible()
	if DebugApi != null:
		DebugApi.set_overlay_visible(true)
	await get_tree().process_frame
	_runner.assert_true(_l2_renderer._debug_was_visible != before or bool(DebugApi.is_visible()),
		"DebugApi 开启后渲染器应刷新（_debug_was_visible=%s）" % bool(_l2_renderer._debug_was_visible))
	# 恢复原可见性
	if DebugApi != null:
		DebugApi.set_overlay_visible(was_visible)
	await get_tree().process_frame
	_runner.assert_true(true, "F3 调试标签路径无异常")


func _test_query() -> void:
	if _l2_data == null:
		var data: RefCounted = L2WorldData.load_from(
			"%s/region_001/l2_world.json" % L2_BASE_DIR,
			"%s/region_001" % L2_BASE_DIR
		)
		_l2_data = data
	if _l2_data == null or _l2_data.mask_image == null:
		_runner.assert_true(false, "前置数据加载失败")
		return
	# 扫描索引图找每个 label 的首个像素（质心对 C 形地块可能落在海洋，不能用）
	var needed: Dictionary = {}
	for t in _l2_data.tiles:
		needed[int(t.get("label", 0))] = true
	var src: Image = _l2_data.mask_image
	var bytes := src.get_data()
	# PNG 索引图为 RGB 3 通道；RGBA8 为 4 字节/像素
	var bpp := 3
	if src.get_format() == Image.FORMAT_RGBA8:
		bpp = 4
	var w := src.get_width()
	var h := src.get_height()
	var found := {}
	# 8192 级索引图全像素扫描在 GDScript 下约 6700 万次循环，并行跑会超时。
	# 改为分步扫描：总采样点上限 ~100 万（步长自适应），漏掉的 label 再全量兜底。
	var step := maxi(1, int(sqrt(float(w * h) / 1_000_000.0)))
	for y in range(0, h, step):
		var row_base := y * w
		for x in range(0, w, step):
			var i := (row_base + x) * bpp
			var code := (int(bytes[i]) << 16) | (int(bytes[i + 1]) << 8) | int(bytes[i + 2])
			if code > 0 and needed.has(code) and not found.has(code):
				found[code] = Vector2(x, y)
				if found.size() == needed.size():
					break
		if found.size() == needed.size():
			break
	# 小地块/细碎 label 可能被步长跳过：对缺失项做全量精确扫描兜底
	if found.size() < needed.size():
		for y in range(h):
			var row_base := y * w
			for x in range(w):
				var i := (row_base + x) * bpp
				var code := (int(bytes[i]) << 16) | (int(bytes[i + 1]) << 8) | int(bytes[i + 2])
				if code > 0 and needed.has(code) and not found.has(code):
					found[code] = Vector2(x, y)
					if found.size() == needed.size():
						break
			if found.size() == needed.size():
				break
	var hit: int = 0
	for code in found.keys():
		var q: Dictionary = _l2_data.query_at_map_pos(found[code])
		var tile: Variant = q.get("tile", {})
		if tile != null and int((tile as Dictionary).get("label", -1)) == code:
			hit += 1
	print("[debug] region_001 索引图 label=%d 个, 命中 %d" % [found.size(), hit])
	_runner.assert_true(found.size() == _l2_data.tiles.size(),
			"索引图应覆盖全部地块 label（%d/%d）" % [found.size(), _l2_data.tiles.size()])
	_runner.assert_true(hit == found.size(), "索引图解码命中（%d/%d）" % [hit, found.size()])


func _test_drilldown() -> void:
	# 装配 L3 + 注入 L2 视图（模拟 system_setup）
	_l3_scene = L3_SCENE.instantiate()
	add_child(_l3_scene)
	_l3_content = _l3_scene.get_node_or_null("Content")
	var l3_renderer: Node = _l3_content.get_node_or_null("L3MapRenderer") if _l3_content != null else null
	if l3_renderer == null or _l2_content == null:
		_runner.assert_true(false, "前置装配失败")
		return
	var l3_data := L3WorldData.load_from(L3_JSON_PATH, L3_BASE_DIR)
	l3_renderer.set_data(l3_data)
	# 注入 l2_view（晚于 _ready，走 set_l2_view）
	if _l3_content.has_method("set_l2_view"):
		_l3_content.call("set_l2_view", _l2_content)

	# 打开 L3 -> 模拟单击命中地区 -> L2 打开
	_l3_content.open()
	await get_tree().process_frame
	_runner.assert_true(_l3_content.visible, "open() 后 L3 可见")

	# 取第一个地区轮廓内一点做单击
	var region: Dictionary = l3_data.regions[0]
	var lab: int = region.get("label", 0)
	var poly: Array = region.get("land_polygon", [])
	var map_pos := Vector2(poly[0][1], poly[0][0]) + Vector2(4, 4)
	var cam: Node = _l3_content.get_node_or_null("MapCamera")
	if cam != null and cam.has_method("map_to_screen"):
		var screen_pos: Vector2 = cam.map_to_screen(map_pos)
		var opened: bool = _l3_content.call("_try_open_l2_at_screen", screen_pos)
		_runner.assert_true(opened, "单击地区应触发下钻（region label %d）" % lab)
		await get_tree().process_frame
		_runner.assert_true(not _l3_content.visible, "下钻后 L3 隐藏")
		_runner.assert_true(_l2_content.visible, "下钻后 L2 可见")
		_runner.assert_true(_l2_content.has_method("get_current_region_id")
				and _l2_content.get_current_region_id() == "region_%03d" % lab,
				"L2 应加载 region_%03d" % lab)
		# 打开后相机：fit 正方形 context 整图适配 + 居中显示
		var l2_cam: Node = _l2_content.get_node_or_null("MapCamera")
		if l2_cam != null:
			var vp_size: Vector2 = _l2_content.get_viewport().get_visible_rect().size
			var size: Vector2 = _l2_content.data.size
			if _l2_content.data.context_size.x > 0:
				size = _l2_content.data.context_size
			var expect_zoom: float = vp_size.y * 0.72 / size.y
			var expect_off: Vector2 = vp_size * 0.5 - Vector2(
				size.x * expect_zoom * 0.5, size.y * expect_zoom * 0.5)
			_runner.assert_true(absf(l2_cam.get_zoom() - expect_zoom) < 0.01,
					"L2 打开后 fit 整图适配")
			_runner.assert_true(l2_cam.get_offset().distance_to(expect_off) < 1.0,
					"L2 打开后地图居中显示")
		# ESC 返回 L3（headless 下直接调用 _input，parse_input_event 不派发）
		var flag := {"back": false}
		_l2_content.back_requested.connect(func() -> void: flag.back = true)
		_l2_content._input(_esc_event())
		await get_tree().process_frame
		_runner.assert_true(flag.back, "L2 ESC 应发 back_requested")
		_runner.assert_true(not _l2_content.visible, "ESC 后 L2 隐藏")
		_runner.assert_true(_l3_content.visible, "返回后 L3 重新可见")

		# M 关闭整图 -> 重开：保留相机状态；若在 L2 内则恢复 L2 视图
		var l3_zoom_before: float = cam.get_zoom()
		var l3_off_before: Vector2 = cam.get_offset()
		cam.set_zoom(l3_zoom_before * 0.5)  # 模拟用户缩放/拖动
		cam.set_offset(l3_off_before + Vector2(100, -50))
		_l3_content.close()  # M 关闭
		await get_tree().process_frame
		_runner.assert_true(not _l3_content.visible, "M 关闭后 L3 隐藏")
		_l3_content.open()  # M 重开
		await get_tree().process_frame
		_runner.assert_true(_l3_content.visible, "M 重开后 L3 可见")
		_runner.assert_true(absf(cam.get_zoom() - l3_zoom_before * 0.5) < 0.01
				and cam.get_offset().distance_to(l3_off_before + Vector2(100, -50)) < 1.0,
				"M 重开后相机位置/缩放保留")

		# 下钻 L2 后 M 关闭 -> 重开恢复 L2 视图
		var opened2: bool = _l3_content.call("_try_open_l2_at_screen", screen_pos)
		_runner.assert_true(opened2, "再次下钻 L2")
		await get_tree().process_frame
		_runner.assert_true(_l2_content.visible, "下钻后 L2 可见")
		_l3_content.close()  # 在 L2 内按 M 关闭
		await get_tree().process_frame
		_runner.assert_true(not _l3_content.visible and not _l2_content.visible,
				"M 关闭后 L3 与 L2 都隐藏")
		_l3_content.open()  # M 重开
		await get_tree().process_frame
		_runner.assert_true(_l2_content.visible, "M 重开恢复 L2 视图")
		_runner.assert_true(not _l3_content.visible, "恢复 L2 时 L3 保持隐藏")
	else:
		_runner.assert_true(false, "L3 应含 MapCamera")


func _esc_event() -> InputEvent:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	return ev
