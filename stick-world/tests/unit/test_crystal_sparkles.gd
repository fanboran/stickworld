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
	_runner.add_test("attach: 基础层+5 子系统共 6 层（areaFactor 递减）", _test_five_subsystems)
	_runner.add_test("frames: 帧序列动画（UVModule Sprites 复刻）", _test_frame_anim)
	_runner.add_test("palette: RandomColor 离散调色盘（矿石窄盘/rainbow 彩虹盘）", _test_single_theme)
	_runner.add_test("rate: 原版公式 档位×areaFactor×面积×SpawnRate", _test_rate_formula)
	_runner.add_test("rate: 大面积速率 > 小面积速率（面积驱动）", _test_area_scales_emission)
	_runner.add_test("tier: 档位表与原版一致（8档=0.72s）", _test_tier_table)
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
	# 原版结构：CrystalSparksBase 基础层 + 5 个强度子系统 = 6 个并发系统
	var host: Node2D = _host_with_sprite(Vector2(40, 40))
	ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 8)
	var subs := _subsystems(host)
	_runner.assert_equal(subs.size(), 6, "一个宿主应挂 6 层（基础层 + 5 强度子系统）")
	var by_name := {}
	for s in subs:
		by_name[(s as CrystalSparkles).name] = s
	_runner.assert_true(by_name.has("CrystalSparklesBase"), "应有基础层 CrystalSparklesBase")
	_runner.assert_true(by_name.has("CrystalSparkles"), "主子系统（-1 层）沿用原名")
	_runner.assert_true(by_name.has("CrystalSparkles_5"), "第五子系统命名")
	# 基础层：出土 rate=10 / lifetime=1.0 / 静态柔点（UVModule 关闭）
	var base: CrystalSparkles = by_name.get("CrystalSparklesBase")
	if base == null:
		_runner.assert_true(false, "未找到基础层")
		return
	_runner.assert_true(base.lifetime == 1.0, "基础层寿命 1.0s（出土）")
	_runner.assert_true(base.texture.get_width() == 64, "基础层应为 64px 静态柔点")
	_runner.assert_true(not (base.material as CanvasItemMaterial).particles_animation,
			"基础层无帧动画")


func _test_frame_anim() -> void:
	# UVModule mode=1 Sprites：每层帧深度不同（-1=6 帧 … -5=12 帧），一生播一遍
	var host: Node2D = _host_with_sprite(Vector2(40, 40))
	ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "sky", 8)
	var by_name := {}
	for s in _subsystems(host):
		by_name[(s as CrystalSparkles).name] = s
	var expect_frames := {"CrystalSparkles": 6, "CrystalSparkles_2": 8,
			"CrystalSparkles_3": 9, "CrystalSparkles_4": 10, "CrystalSparkles_5": 12}
	for nm in expect_frames:
		var cs: CrystalSparkles = by_name.get(nm)
		_runner.assert_not_null(cs, "存在 %s" % nm)
		if cs == null:
			continue
		var mat: CanvasItemMaterial = cs.material
		_runner.assert_true(mat.particles_animation, "%s 应启用帧序列动画" % nm)
		_runner.assert_equal(mat.particles_anim_h_frames, expect_frames[nm],
				"%s 帧深度 %d（出土序列）" % [nm, expect_frames[nm]])
		_runner.assert_equal(mat.particles_anim_v_frames, 1, "单行帧网格")
		_runner.assert_true(not mat.particles_anim_loop, "一生播一遍不循环（cycles=1）")
		_runner.assert_approx(cs.anim_speed_max, 1.0, 0.001, "anim_speed=1：一寿命走完序列")
		_runner.assert_true(cs.texture.get_width() == int(expect_frames[nm]) * 24,
				"%s 贴图宽 = 帧数×24px 画布" % nm)


func _test_rate_formula() -> void:
	# 原版：rateOverTime = 档位速率 × areaFactor × mesh表面积 × SpawnRate（jitter=1 时为基值）
	# mesh 面积经 mesh_area() 标定截断（烘焙实测 0.008~0.62/s 反推 ≈ [0.008, 0.013] 单位²）
	var area := 1.0
	var spawn: float = ScriptCrystalSparkles.SPAWN_RATE
	var expect: float = 8.0 * 6.0 * ScriptCrystalSparkles.mesh_area(area) * spawn
	_runner.assert_approx(ScriptCrystalSparkles.compute_rate(8, area, 6.0), expect, 0.001,
			"tier8 × areaFactor6 × mesh_area(1.0) → %f" % expect)
	# areaFactor 单调递增
	var r_small: float = ScriptCrystalSparkles.compute_rate(8, area, 0.75)
	var r_big: float = ScriptCrystalSparkles.compute_rate(8, area, 6.0)
	_runner.assert_gt(r_big, r_small, "areaFactor 越大速率越大")
	# 抖动：0.5~2 区间缩小/放大
	_runner.assert_approx(ScriptCrystalSparkles.compute_rate(8, area, 6.0, 2.0), expect * 2.0, 0.001,
			"jitter=2 应为基值两倍")
	# 面积标定：超大宿主钉在烘焙实测反推的上限
	_runner.assert_approx(ScriptCrystalSparkles.mesh_area(1e6), ScriptCrystalSparkles.MESH_AREA_MAX,
			0.0001, "巨大宿主 mesh 面积钉在上限（0.62/s 实测反推 0.013）")
	_runner.assert_approx(ScriptCrystalSparkles.mesh_area(0.0), ScriptCrystalSparkles.MESH_AREA_MIN,
			0.0001, "极小宿主 mesh 面积兜底到下限")
	# 上限安全网（tier20 × AF6 × 0.013 × jitter2 = 3.12 > 2.0 触发截断）
	_runner.assert_approx(
			ScriptCrystalSparkles.compute_rate(20, 1e6, 6.0, 2.0),
			ScriptCrystalSparkles.MAX_RATE_PER_SYSTEM, 0.001,
			"异常速率应被单系统上限截断")


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


func _test_single_theme() -> void:
	# startColor = RandomColor(Fixed)：每颗粒子从调色盘随机抽一个纯色。
	# 矿石窄盘 = 同色系 3 键；rainbow = CrystalSparksBase 出土 8 键彩虹盘。
	# Godot 等价 = 平台渐变（每色占 1/n 区间，接缝零宽不插值）。
	var host: Node2D = _host_with_sprite(Vector2(40, 40))
	ScriptCrystalSparkles.attach_to(host, WorldZ.OVERLAY_HINT, "gold", 8)
	var gold_pal: Array = ScriptCrystalSparkles.palette_for("gold")
	_runner.assert_equal(gold_pal.size(), 3, "矿石窄盘 3 键同色系")
	for s in _subsystems(host):
		var ramp: Gradient = (s as CrystalSparkles).color_initial_ramp
		_runner.assert_not_null(ramp, "子系统应有 color_initial_ramp")
		if ramp == null:
			return
		_runner.assert_equal(ramp.get_point_count(), gold_pal.size() * 2,
				"平台渐变键数 = 色数×2")
		# 每个平台的起点色 == 调色盘对应色（离散抽色，无插值过渡）
		for i in gold_pal.size():
			_runner.assert_true(
					ramp.get_color(i * 2).is_equal_approx(gold_pal[i]) and
					ramp.get_color(i * 2 + 1).is_equal_approx(gold_pal[i]),
					"平台 %d 两键同为 %s" % [i, gold_pal[i]])
	# rainbow：出土 8 键
	var rb: Array = ScriptCrystalSparkles.palette_for("rainbow")
	_runner.assert_equal(rb.size(), 8, "彩虹盘 8 键（CrystalSparksBase 出土）")
	_runner.assert_true(rb[0].is_equal_approx(Color("CAD6DC")), "彩虹盘首色 #CAD6DC（出土）")
	# rainbow 渐变键数 = 16
	var host2: Node2D = _host_with_sprite(Vector2(40, 40))
	var cs: CrystalSparkles = ScriptCrystalSparkles.attach_to(host2, WorldZ.OVERLAY_HINT, "rainbow", 8)
	_runner.assert_equal(cs.color_initial_ramp.get_point_count(), 16, "rainbow 平台渐变 16 键")


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
