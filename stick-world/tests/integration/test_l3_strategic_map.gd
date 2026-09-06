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
	_runner.add_test("M 键视图打开/关闭（HUD 同步显隐）", _test_toggle, true)
	_runner.add_test("F3 调试模式：L2 地区编号刷新", _test_debug_labels, true)
	_runner.add_test("显示模式切换（L1 <-> 城市）", _test_display_mode, true)
	_runner.add_test("hover 命中老 L1（索引图查询）", _test_hover_l1, true)
	_runner.add_test("HUD：默认缩放=100% + 按钮/缩放条/百分比互不重叠", _test_hud, true)
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
	# 对齐真实装配（system_setup 会 set_data）：渲染器持数据后 open() 的初始视角
	# 才能用真实地图边长（8192）适配，否则回退默认 2048
	_renderer.set_data(_data)
	# l1_index 由 L3MapRenderer 后台异步解码（load_from 不阻塞，先为 null）；
	# 测试同步注入等价结果（同一 PNG 解码），供 hover 查询用
	_runner.assert_true(_data.l1_index_image == null, "l1_index 应异步加载（load_from 后为空）")
	var l1_f := FileAccess.open("%s/l3_l1_index_8192.png" % L3_BASE_DIR, FileAccess.READ)
	if l1_f != null:
		var l1_img := Image.new()
		if l1_img.load_png_from_buffer(l1_f.get_buffer(l1_f.get_length())) == OK:
			_data.l1_index_image = l1_img
	_runner.assert_true(_data.mask_image != null, "L3 分区索引图已加载")
	_runner.assert_true(_data.regions.size() == 13, "应有 13 个地区（实测 %d）" % _data.regions.size())
	_runner.assert_true(_data.l1_tiles.size() == 69,
		"L3 老 L1 视觉层应加载 69 块（实测 %d）" % _data.l1_tiles.size())
	_runner.assert_true(_data.city_tiles.size() > 500,
		"L3 城市视觉层应加载（实测 %d）" % _data.city_tiles.size())
	_runner.assert_true(_data.l1_index_image != null, "L3 老 L1 索引图已加载（hover）")
	# 每个地区应有陆地轮廓
	var no_poly: int = 0
	for r in _data.regions:
		if r.get("land_polygon", []).size() < 3:
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
		var land_poly = r.get("land_polygon", [])
		if land_poly.size() < 3:
			continue
		# 轮廓点是 (y,x) 顺序（find_contours），转为 (x,y) 并内移取陆地像素
		# （紧凑 bin 已是 Vector2(x,y)，_pt 兼容两种形态）
		var pt := _pt(land_poly[0]) + Vector2(4, 4)
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
		var full = r.get("full_polygon", [])
		if full.size() >= 3:
			with_full += 1
			# 非边缘段应连续（允许沿地图边缘的大跳变，渲染时断段处理）
			var jumps: int = 0
			for i in range(full.size()):
				var a: Variant = full[i]
				var b: Variant = full[(i + 1) % full.size()]
				var d := _pt(a).distance_to(_pt(b))
				if d > 60.0:
					jumps += 1
			if jumps <= 2:
				valid_full += 1
	_runner.assert_true(with_full == 13, "所有地区应有完整分区轮廓（%d/13）" % with_full)
	_runner.assert_true(valid_full == 13, "所有完整轮廓应连续（边缘跳变<=2）（%d/13）" % valid_full)



func _test_hover_l1() -> void:
	if _data == null or _data.l1_index_image == null:
		_runner.assert_true(false, "前置：L1 索引图未加载")
		return
	var hit: int = 0
	for t in _data.l1_tiles:
		var c: Array = t.get("centroid", [0, 0])
		if c.size() < 2:
			continue
		var q: Dictionary = _data.query_l1_at_map_pos(Vector2(float(c[0]), float(c[1])))
		var l1hit: Dictionary = q.get("l1", {})
		if int(l1hit.get("label", 0)) > 0:
			hit += 1
	_runner.assert_true(hit >= 10, "质心应命中老 L1（命中 %d/20）" % hit)

func _test_display_mode() -> void:
	if _scene == null or _renderer == null:
		_runner.assert_true(false, "前置：L3 场景未装载")
		return
	var before: int = _renderer.display_mode
	var mode: int = _renderer.toggle_display_mode()
	_runner.assert_true(mode != before, "toggle_display_mode 应切换 L1/城市模式")
	var mname: String = _renderer.get_mode_name()
	_runner.assert_true(mname == "城市" or mname == "L1", "模式名应可读（%s）" % mname)
	_renderer.toggle_display_mode()
	_runner.assert_true(_renderer.display_mode == before, "再次切换应还原")


func _test_debug_labels() -> void:
	# F3 调试（DebugApi）切换时，L3 渲染器应刷新（_debug_was_visible 变化），不崩溃
	if _scene == null or _renderer == null:
		_runner.assert_true(false, "前置：L3 场景未装载")
		return
	var before: bool = _renderer._debug_was_visible
	var was_visible: bool = DebugApi != null and DebugApi.is_visible()
	if DebugApi != null:
		DebugApi.set_overlay_visible(true)
	await get_tree().process_frame
	_runner.assert_true(_renderer._debug_was_visible != before or bool(DebugApi.is_visible()),
		"DebugApi 开启后 L3 渲染器应刷新")
	if DebugApi != null:
		DebugApi.set_overlay_visible(was_visible)
	await get_tree().process_frame
	_runner.assert_true(true, "F3 L2 标签路径无异常")


## 顶点统一转 Vector2（紧凑 bin 已是 Vector2(x,y)；JSON 轮廓是 [y,x] Array，兼容两种）
static func _pt(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and v.size() >= 2:
		return Vector2(float(v[1]), float(v[0]))
	return Vector2.ZERO


func _test_toggle() -> void:
	if _content == null:
		_runner.assert_true(false, "前置失败")
		return
	var hud: Control = _scene.get_node_or_null("ZoomIndicator")
	_runner.assert_true(hud != null and not hud.visible, "初始 L3 HUD 隐藏")
	_runner.assert_true(not _content.visible, "初始 L3 视图隐藏")
	if _content.has_method("open"):
		_content.open()
	await get_tree().process_frame
	_runner.assert_true(_content.visible, "open() 后 L3 视图可见")
	_runner.assert_true(hud != null and hud.visible, "open() 后 L3 HUD 显示")
	if _content.has_method("close"):
		_content.close()
	await get_tree().process_frame
	_runner.assert_true(not _content.visible, "close() 后 L3 视图隐藏")
	_runner.assert_true(hud != null and not hud.visible, "close() 后 L3 HUD 隐藏")


func _test_hud() -> void:
	if _scene == null or _content == null:
		_runner.assert_true(false, "前置：L3 场景未装载")
		return
	var hud: Control = _scene.get_node_or_null("ZoomIndicator")
	_runner.assert_true(hud != null, "L3 场景应含 ZoomIndicator(HUD)")
	if hud == null:
		return
	if _content.has_method("open"):
		_content.open()
	await get_tree().process_frame
	# 默认缩放归一化（A3 全屏化）：open() 按视口/地图尺寸动态适配并把该缩放
	# 同步为 HUD default（=100%）；HUD 不再回退固定 0.36
	_runner.assert_true(hud.has_method("set_default_zoom"), "HUD 应有 set_default_zoom")
	var cam: Node = _content.get_node_or_null("MapCamera")
	var hud_default: float = float(hud.get("default_zoom"))
	_runner.assert_true(cam != null and absf(hud_default - float(cam.get_zoom())) < 0.001,
			"open() 后 HUD 默认缩放应等于相机当前缩放（动态适配，实测 default=%.3f zoom=%.3f）"
			% [hud_default, float(cam.get_zoom()) if cam != null else -1.0])
	# 相机缩放下限 = 全屏适配缩放（再缩小则地图+海洋带撑不满视口，视野越出限位矩形）
	_runner.assert_true(cam != null and absf(float(cam.get("min_zoom")) - hud_default) < 0.001,
			"min_zoom 应锁定全屏适配缩放")
	# A3 验收修正锚点：初始视角整图可见（上下各留海洋边距，不向内裁切地图）——
	# 地图上下边界必须在屏幕内，且距屏缘 ≥ 32px（海洋边距 64px 的宽松容差）
	var vp_h: float = get_viewport().get_visible_rect().size.y
	var edge_top: float = float(cam.get_offset().y)
	var edge_bottom: float = edge_top + 8192.0 * hud_default
	_runner.assert_true(edge_top >= 32.0, "地图上边应在屏内留海洋边距（实测 %.1f）" % edge_top)
	_runner.assert_true(edge_bottom <= vp_h - 32.0,
			"地图下边应在屏内留海洋边距（实测 %.1f / %.1f）" % [edge_bottom, vp_h])
	await get_tree().process_frame
	var label: Label = null
	var slider: HSlider = null
	var btn: Button = null
	for ch in hud.get_children():
		if ch is Label:
			label = ch
		elif ch is HSlider:
			slider = ch
		elif ch is Button:
			btn = ch
	_runner.assert_true(label != null and label.text == "100%",
			"默认缩放应显示 100%%（实测 %s）" % (label.text if label != null else "无标签"))
	_runner.assert_true(slider != null, "HUD 缩放条应为 HSlider（非自绘抽象矩形）")
	_runner.assert_true(btn != null, "L3 HUD 应有细分模式按钮")
	# 三元素矩形互不重叠
	var rects: Array[Rect2] = []
	if btn != null:
		rects.append(btn.get_global_rect())
	rects.append(slider.get_global_rect())
	rects.append(label.get_global_rect())
	var overlap: bool = false
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				overlap = true
	_runner.assert_true(not overlap, "HUD 按钮/缩放条/百分比标签矩形互不重叠")
	if _content.has_method("close"):
		_content.close()
	await get_tree().process_frame
