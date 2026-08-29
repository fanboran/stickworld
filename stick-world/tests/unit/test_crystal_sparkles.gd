extends Node
## 单元测试：CrystalSparkles.attach_to —— 对齐药工 GlobalMeshParticleSystem 的核心行为
## 关键断言：
##   1. 挂载成功、one_shot=false（持续发射 = 布灵布灵的关键）
##   2. 一个宿主挂 5 个并发子系统（原版 CrystalSparks - 1..-5），areaFactor 递减
##   3. 速率公式 = 档位速率 × areaFactor × mesh面积 × SpawnRate（面积/areaFactor 单调递增）
##   4. 档位→寿命绑定表与出土值一致
##   5. 宿主轮廓测量支持 Sprite2D / Polygon2D(shoelace) / ColorRect
## 运行：
##   godot --headless --path stick-world res://tests/unit/test_crystal_sparkles.tscn

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptCrystalSparkles := preload("res://modules/fx/scripts/crystal_sparkles.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("attach: 持续发射（one_shot=false）", _test_attach_persistent)
	_runner.add_test("attach: 一个宿主挂 5 个并发子系统（areaFactor 递减）", _test_five_subsystems)
	_runner.add_test("rate: 原版公式 档位×areaFactor×面积×SpawnRate", _test_rate_formula)
	_runner.add_test("rate: 大面积速率 > 小面积速率（面积驱动）", _test_area_scales_emission)
	_runner.add_test("tier: 档位表与原版一致（8档=0.72s）", _test_tier_table)
	_runner.add_test("palette: 5 子系统配色 = 主色+白+3 点缀，无重复", _test_palette)
	_runner.add_test("measure: 轮廓面积支持 Sprite/Polygon/ColorRect", _test_measure_host)
	_runner.add_test("emission: 不透明精灵采样为 POINTS（点落在轮廓内）", _test_emission_points_sprite)
	_runner.add_test("emission: 全透明精灵回退 BOX", _test_emission_fallback_box)
	_runner.add_test("emission: ColorRect 网格点集在矩形内", _test_emission_points_rect)
	_runner.add_test("emission: Polygon2D 三角化采样点在多边形内", _test_emission_points_polygon)
	_runner.run()
	print(_runner.summary())
	# 兼容批量模式：batch 下发完成信号而非退出进程
	if Engine.has_meta("test_batch"):
		TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)
	else:
		get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────── 测试夹具 ───────────────────────────

func _host_with_sprite(size: Vector2) -> Node2D:
	var host := Node2D.new()
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(Image.create(int(size.x), int(size.y), false, Image.FORMAT_RGBA8))
	host.add_child(spr)
	add_child(host)
	return host


func _host_with_color_rect(size: float) -> Node2D:
	var host := Node2D.new()
	var rect := ColorRect.new()
	rect.size = Vector2(size, size)
	rect.position = Vector2(-size * 0.5, -size * 0.5)
	host.add_child(rect)
	add_child(host)
	return host


func _host_with_polygon(pts: PackedVector2Array) -> Node2D:
	var host := Node2D.new()
	var poly := Polygon2D.new()
	poly.polygon = pts
	host.add_child(poly)
	add_child(host)
	return host


func _subsystems(host: Node2D) -> Array:
	var out: Array = []
	for child in host.get_children():
		if child is CrystalSparkles:
			out.append(child)
	return out


# ─────────────────────────── 用例 ───────────────────────────

func _test_attach_persistent() -> void:
	var host: Node2D = _host_with_sprite(Vector2(40, 40))
	var cs: CrystalSparkles = ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 3)
	_runner.assert_not_null(cs, "attach 应返回主子系统")
	if cs == null:
		return
	_runner.assert_true(not cs.one_shot, "持续发射：one_shot 必须为 false")
	_runner.assert_true(cs.emitting, "attach 后应立即 emitting")
	_runner.assert_true(cs.lifetime == 1.08, "tier3 寿命应为原版 1.08s")
	_runner.assert_true(cs.amount >= 1, "amount 至少 1（rate×lifetime 不足 1 时兜底单颗闪烁）")


func _test_five_subsystems() -> void:
	var host: Node2D = _host_with_sprite(Vector2(40, 40))
	ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 8)
	var subs := _subsystems(host)
	_runner.assert_equal(subs.size(), ScriptCrystalSparkles.AREA_FACTORS.size(),
			"一个宿主应挂 5 个并发子系统（原版 CrystalSparks - 1..-5）")
	# areaFactor 递减 → amount 非严格递减（随机抖动 ×0.5~2 可能打平，只校验总量关系）
	if subs.size() == 5:
		var first: CrystalSparkles = subs[0]
		var last: CrystalSparkles = subs[4]
		_runner.assert_true(first.name == "CrystalSparkles", "主子系统沿用原名（debug 面板按名查找）")
		_runner.assert_true(first.amount >= last.amount,
				"areaFactor 最大(6.0)的子系统 amount 应 ≥ 最小(0.75)者")
		_runner.assert_true(last.name == "CrystalSparkles_5", "第五个子系统命名")


func _test_rate_formula() -> void:
	# 原版：rateOverTime = 档位速率 × areaFactor × mesh表面积 × SpawnRate（jitter=1 时为基值）
	var area := 1.0
	var spawn: float = ScriptCrystalSparkles.SPAWN_RATE
	var to_mesh: float = ScriptCrystalSparkles.AREA_TO_MESH
	var expect: float = 8.0 * 6.0 * (area * to_mesh) * spawn
	_runner.assert_approx(ScriptCrystalSparkles.compute_rate(8, area, 6.0), expect, 0.001,
			"tier8 × areaFactor6 × 面积1 → %f" % expect)
	# areaFactor 单调递增
	var r_small: float = ScriptCrystalSparkles.compute_rate(8, area, 0.75)
	var r_big: float = ScriptCrystalSparkles.compute_rate(8, area, 6.0)
	_runner.assert_gt(r_big, r_small, "areaFactor 越大速率越大")
	# 抖动：0.5~2 区间缩小/放大
	_runner.assert_approx(ScriptCrystalSparkles.compute_rate(8, area, 6.0, 2.0), expect * 2.0, 0.001,
			"jitter=2 应为基值两倍")
	# 上限安全网
	_runner.assert_true(
			ScriptCrystalSparkles.compute_rate(20, 1e6, 6.0) <= ScriptCrystalSparkles.MAX_RATE_PER_SYSTEM,
			"异常巨大宿主应被速率上限截断")


func _test_area_scales_emission() -> void:
	var small_host: Node2D = _host_with_sprite(Vector2(16, 16))
	var large_host: Node2D = _host_with_sprite(Vector2(160, 128))
	var small: CrystalSparkles = ScriptCrystalSparkles.attach_to(small_host, WorldZ.OVERLAY_HINT, "sky", 3)
	var large: CrystalSparkles = ScriptCrystalSparkles.attach_to(large_host, WorldZ.OVERLAY_HINT, "sky", 6)
	if small == null or large == null:
		_runner.assert_true(false, "attach 失败")
		return
	# 原版速率 = 档位 × areaFactor × 面积；大精灵面积缩放应更大
	var small_area: float = (16.0 / 100.0) * (16.0 / 100.0)
	var large_area: float = (160.0 / 100.0) * (128.0 / 100.0)
	var small_rate: float = ScriptCrystalSparkles.compute_rate(6, small_area, 6.0)
	var large_rate: float = ScriptCrystalSparkles.compute_rate(6, large_area, 6.0)
	_runner.assert_gt(large_rate, small_rate,
			"大面积精灵速率应更大（药工：面积驱动），small=%f large=%f" % [small_rate, large_rate])
	_runner.assert_true(large.amount >= small.amount, "大面积宿主的在世粒子数应更多")


func _test_tier_table() -> void:
	var t: Dictionary = ScriptCrystalSparkles.TIER_TABLE
	_runner.assert_true(float(t.get(8, 0)) == 0.72, "tier8 寿命 0.72s（出土值）")
	_runner.assert_true(float(t.get(1, 0)) == 1.72, "tier1 寿命 1.72s（出土值）")
	_runner.assert_true(float(t.get(20, 0)) == 0.10, "tier20 寿命 0.10s（出土值）")
	# 未知档位兜底为默认档寿命，不能把 8.0 当成寿命
	var host: Node2D = _host_with_sprite(Vector2(40, 40))
	var unknown: CrystalSparkles = ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 5)
	_runner.assert_true(unknown != null and unknown.lifetime == 0.72,
			"未知档位应兜底为默认档(tier8)寿命 0.72s")


func _test_palette() -> void:
	var pal := ScriptCrystalSparkles.variant_palette("mint")
	_runner.assert_equal(pal.size(), 5, "配色槽位数 = 子系统数")
	_runner.assert_equal(String(pal[0]), "mint", "第一槽 = 宿主主色（每材料一色）")
	_runner.assert_equal(String(pal[1]), "white", "第二槽 = 白（RandomBetweenTwoGradients 另一端）")
	# 前 4 个互不重复（第五个可能回退为白）
	var seen := {}
	for i in 4:
		var k := String(pal[i])
		_runner.assert_true(not seen.has(k), "配色前 4 槽不应重复：%s" % k)
		seen[k] = true
	# 主色本身是点缀色时应自动去重（gold 不会连出两个）
	var pal_gold := ScriptCrystalSparkles.variant_palette("gold")
	_runner.assert_true(String(pal_gold[2]) != "gold", "主色为 gold 时点缀槽应换成其它色")


func _test_measure_host() -> void:
	# Sprite2D：40×40px → 0.16 单位²
	var m_spr := ScriptCrystalSparkles.measure_host(_host_with_sprite(Vector2(40, 40)))
	_runner.assert_approx(float(m_spr["area_units"]), 0.16, 0.001, "Sprite2D 40px → 0.16 单位²")

	# ColorRect：资源点当前是色块占位（32px）→ 0.1024 单位²
	var m_cr := ScriptCrystalSparkles.measure_host(_host_with_color_rect(32.0))
	_runner.assert_approx(float(m_cr["area_units"]), 0.1024, 0.001, "ColorRect 32px → 0.1024 单位²")

	# Polygon2D：shoelace 真实面积（100×100 正方形 → 1.0 单位²，非包围盒虚高）
	var m_poly := ScriptCrystalSparkles.measure_host(_host_with_polygon(PackedVector2Array([
			Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(0, 100)])))
	_runner.assert_approx(float(m_poly["area_units"]), 1.0, 0.001, "Polygon2D shoelace 面积")

	# 空宿主：兜底不至于崩
	var m_none := ScriptCrystalSparkles.measure_host(Node2D.new())
	_runner.assert_gt(float(m_none["area_units"]), 0.0, "无可视化子节点时应有兜底面积")


# ─────────────────────────── B5：发射区点集 ───────────────────────────

func _test_emission_points_sprite() -> void:
	# 不透明 48×48 纹理 → POINTS 发射（对齐药工"精灵轮廓 Mesh"），点集以轮廓中心为原点
	var host := Node2D.new()
	var spr := Sprite2D.new()
	var img := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	spr.texture = ImageTexture.create_from_image(img)
	host.add_child(spr)
	add_child(host)
	var cs: CrystalSparkles = ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 3)
	_runner.assert_not_null(cs, "attach 应成功")
	if cs == null:
		return
	var m: CrystalSparkles = cs
	_runner.assert_equal(m.emission_shape, CrystalSparkles.EMISSION_SHAPE_POINTS,
			"不透明精灵应采样为 POINTS 发射")
	var pts: PackedVector2Array = m.emission_points
	_runner.assert_gt(pts.size(), 0, "点集非空")
	var inside := true
	for p in pts:
		if absf(p.x) > 24.0 + 0.5 or absf(p.y) > 24.0 + 0.5:
			inside = false
			break
	_runner.assert_true(inside, "采样点应落在精灵轮廓内（局部 ±24px）")


func _test_emission_fallback_box() -> void:
	# 全透明纹理（Image.create 默认 a=0）→ 无有效采样点 → 回退 BOX（既有行为不回归）
	var host: Node2D = _host_with_sprite(Vector2(40, 40))
	var cs: CrystalSparkles = ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 3)
	_runner.assert_not_null(cs, "attach 应成功")
	if cs == null:
		return
	_runner.assert_equal(cs.emission_shape,
			CrystalSparkles.EMISSION_SHAPE_RECTANGLE, "全透明精灵应回退矩形发射")


func _test_emission_points_rect() -> void:
	# ColorRect（资源点占位）→ 网格点集，都在矩形内（以中心为原点 ±16px）
	var host: Node2D = _host_with_color_rect(32.0)
	var cs: CrystalSparkles = ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 2)
	_runner.assert_not_null(cs, "attach 应成功")
	if cs == null:
		return
	var m: CrystalSparkles = cs
	_runner.assert_equal(m.emission_shape, CrystalSparkles.EMISSION_SHAPE_POINTS,
			"ColorRect 应生成网格点集")
	var inside := true
	for p in m.emission_points:
		if p.x < -16.0 or p.x > 16.0 or p.y < -16.0 or p.y > 16.0:
			inside = false
			break
	_runner.assert_true(inside, "ColorRect 点集应落在矩形内（±16px）")


func _test_emission_points_polygon() -> void:
	# 直角三角形 (0,0)(100,0)(0,100)：内部 ⇔ x≥0 且 y≥0 且 x+y≤100
	var host: Node2D = _host_with_polygon(PackedVector2Array([
			Vector2(0, 0), Vector2(100, 0), Vector2(0, 100)]))
	var cs: CrystalSparkles = ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 2)
	_runner.assert_not_null(cs, "attach 应成功")
	if cs == null:
		return
	var m: CrystalSparkles = cs
	_runner.assert_equal(m.emission_shape, CrystalSparkles.EMISSION_SHAPE_POINTS,
			"Polygon2D 应三角化采样为 POINTS 发射")
	# 轮廓中心 = poly.position + 包围盒中心 = (0,0)+(50,50)；点集应已转为相对中心
	var inside := true
	var count := 0
	for p in m.emission_points:
		var local: Vector2 = p + Vector2(50, 50)  # 还原宿主局部坐标
		count += 1
		if local.x < -0.5 or local.y < -0.5 or local.x + local.y > 100.0 + 0.5:
			inside = false
			break
	_runner.assert_gt(count, 0, "点集非空")
	_runner.assert_true(inside, "采样点应全部落在三角形内部（含 0.5px 容差）")
