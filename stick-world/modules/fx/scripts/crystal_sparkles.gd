class_name CrystalSparkles
extends CPUParticles2D
## 水晶/岩壁连续闪光 —— 《药剂工艺》CrystalSparks 逐字段复刻（2026-08-26 解包终版 + 2026-08-29 多子系统对齐）
##
## 全部数值与行为来自资源包反序列化的 ParticleSystem typetree
## （283 个变体，详见 docs/技术/特效系统/药剂工艺特效复刻参考.md §5 / 附录 A）：
##
##   多子系统   一个宿主挂 5 个并发粒子系统（原版 CrystalSparks - 1 ~ - 5 强度变体），
##              areaFactor 依次 6.0 / 4.5 / 2.25 / 1.5 / 0.75（Σ=15）——密度是单系统的 15 倍
##   速率公式   rateOverTime = areaFactor × 发射 mesh 表面积(单位²) × 全局 SpawnRate(1)
##              每次更新再随机 ×0.5~2（此处按子系统在构建时各取一次随机，等价抖动）
##   startLifetime 按速率档位绑定：{1:1.72s, 2:1.60s, 3:1.08s, 6:0.96s, 8:0.72s, 20:0.10s}
##                注意：rate × lifetime ≈ 2~6，即每个子系统稳定维持 2~6 颗粒子在世
##   startSize  = 0.13 单位恒定；SizeModule(启用) 曲线让尺寸
##                0 → 峰值(≈0.97×0.13≈13px @t80%) → 收缩(0.42×) → 寿命尽硬切
##                （Hermite 权重切线还原：端点斜率 -4.6633 造成的"长出→缩回→啪没"脉冲）
##   startColor minMaxState=4（RandomBetweenTwoGradients）：每颗粒子在
##                纯白 ramp 与主题色 ramp 之间随机取色 → CPUParticles2D color_initial_ramp 精确等价
##   alpha      全程不透明（ColorModule 关、渐变两键 a=1）—— 无渐隐！
##   位移/重力/旋转 全零；looping=true；prewarm=true（tier20 除外）
##   材质贴图   = Unity 默认粒子软点（已提取原版 PNG 直接使用，见 assets/）
##   混合模式   = Additive 发光叠加（Unity 新建 ParticleSystem 的默认材质即
##                Additive）——暗色岩壁上粒子是"发光"而非"贴白点"，亮晶晶的关键
##
## 为什么用 CPUParticles2D 而不是 GPUParticles2D：
##   1. 发射区需要"精灵轮廓点集"（原版 Mesh 发射）。GPUParticles2D 在 Godot 4.4+
##      把点集改为 emission_point_texture（位置编码进纹理像素 RGB），语义晦涩；
##      CPUParticles2D 的 emission_points 仍是 PackedVector2Array，一一对应。
##   2. 每子系统稳定在世粒子仅 2~6 颗（5 子系统 ≤30 颗/宿主），CPU 模拟成本可忽略。
##
## Godot 语义换算：连续速率 = amount / lifetime；发射区 = 宿主轮廓采样点集
## （EMISSION_SHAPE_POINTS，对应药工"精灵轮廓 Mesh"；Sprite2D 按 alpha 采样、
## Polygon2D 三角化内采样、ColorRect 网格采样；采不到点时回退 RECTANGLE）。

## 原版贴图（从药剂工艺资源包提取的 Default-ParticleSystem 粒子贴图，64px 软点）
## ⚠️ PLACEHOLDER（P1）：替换为自制贴图时直接换此文件即可，参数不动。
const SPARKLE_TEX_PATH := "res://modules/fx/assets/sparkle_dot_default_particle.png"
static var _sparkle_tex: Texture2D = null

static func _get_sparkle_tex() -> Texture2D:
	if _sparkle_tex != null:
		return _sparkle_tex
	# 提取的原版贴图（需 Godot 导入后可用；导入前回退程序化软点）
	if ResourceLoader.exists(SPARKLE_TEX_PATH):
		_sparkle_tex = load(SPARKLE_TEX_PATH)
	if _sparkle_tex != null:
		return _sparkle_tex
	# 回退：64px 高斯软点（按原版贴图像素分布重绘）
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	for y in size:
		for x in size:
			var dx := (x - c + 0.5) / c
			var dy := (y - c + 0.5) / c
			var r := sqrt(dx * dx + dy * dy)
			var core: float = exp(-r * r * 9.0)
			var halo: float = exp(-r * r * 2.2) * 0.55
			img.set_pixel(x, y, Color(1, 1, 1, clampf(core + halo, 0.0, 1.0)))
	_sparkle_tex = ImageTexture.create_from_image(img)
	return _sparkle_tex

# ─────────────────────────── 原版出土常量 ───────────────────────────

## 速率档位(/s) → 寿命(s)：出土的绑定关系。键即原版该组的 rateOverTime。
const TIER_TABLE := {
	1: 1.72,
	2: 1.60,
	3: 1.08,
	6: 0.96,
	8: 0.72,
	20: 0.10,
}
## 未知档位时的兜底寿命（对应 tier 8）
const DEFAULT_TIER := 8

## 一个宿主上 5 个并发子系统的 areaFactor（原版 CrystalSparks - 1 ~ - 5 强度变体）
## 顺序即强度降序：最亮最密 → 最弱最疏
const AREA_FACTORS := [6.0, 4.5, 2.25, 1.5, 0.75]

## 原版全局 SpawnRate（GlobalMeshParticleSystemSettings.particlesSpawnRate），默认 1
const SPAWN_RATE := 1.0

## 原版 UpdateGroupEmission 每次更新的随机抖动区间
const JITTER_MIN := 0.5
const JITTER_MAX := 2.0

## 宿主可见轮廓面积（单位²）→ 药工美术手绘发射 mesh 表面积（单位²）的标定系数。
## 两组数值原版均未直接出土，合并标定：按烘焙实例实测有效速率 0.008~0.62/s 反推量级。
const AREA_TO_MESH := 0.12

## 药工的发射 mesh 是美术手绘的若干"小块"（典型 0.01~0.1 单位²，烘焙实例反推），
## 大面积宿主在原版里是"多挂几个小块"，而不是"把小块摊成一大块"。
## 因此这里对换算后的 mesh 面积做上下限截断，避免巨型宿主把速率顶到失控
## （实测：420px 水晶 11.6 单位² 不截断会算出 149 颗在世粒子，糊成一团）。
const MESH_AREA_MIN := 0.008
const MESH_AREA_MAX := 0.35

## 单子系统速率上限（安全网：异常巨大的宿主不会拖垮帧率）
const MAX_RATE_PER_SYSTEM := 60.0

## 100PPU：0.13 单位 → 像素换算基数（贴图 64px 时的 scale 峰值系数）
const PX_PER_UNIT := 100.0

## startSize 0.13 单位 → 贴图 scale（贴图 64px）
const START_SIZE_UNITS := 0.13

## 颜色主题（16 色相桶代表性出土色；每材料一色）
## 每项 = [主题色 RGB]，出生随机白↔主题色
const THEMES := {
	"white":    [1.00, 1.00, 1.00],
	"rose":     [1.00, 0.58, 0.76],
	"pink":     [1.00, 0.74, 0.79],
	"salmon":   [1.00, 0.54, 0.54],
	"violet":   [0.86, 0.65, 1.00],
	"lavender": [0.78, 0.73, 0.90],
	"orange":   [0.90, 0.72, 0.63],
	"gold":     [1.00, 0.82, 0.00],
	"olive":    [0.69, 0.77, 0.24],
	"green":    [0.64, 0.80, 0.55],
	"mint":     [0.55, 0.93, 0.59],
	"cyan":     [0.58, 0.86, 0.97],
	"sky":      [0.77, 0.88, 0.91],
	"blue":     [0.62, 0.77, 1.00],
	"indigo":   [0.79, 0.84, 0.99],
	"magenta":  [1.00, 0.58, 0.76],
}

## 5 个子系统各自的配色槽位：[主色, 白, 金, 青, 粉]
## 出土 maxGradient 后段含橙金/紫/青/粉（a=0 的变体储备色），取金/青/粉作点缀。
## 前两槽 areaFactor 最高（6.0/4.5）→ 主色与白占约 70% 粒子，维持"每材料一色"的识别度，
## 后三槽稀疏点缀出多彩闪烁。
const VARIANT_ACCENTS := ["gold", "cyan", "rose"]
const VARIANT_RESERVE := ["mint", "violet", "orange", "pink", "lavender", "blue"]


# ─────────────────────────── 速率 / 配色 ───────────────────────────

## 原版 ParticleSystemsGroup.UpdateGroupEmission 速率公式（暴露给测试/调试）。
##   rateOverTime = tier档位速率 × areaFactor × mesh表面积(单位²) × SpawnRate × 抖动
## jitter=1.0 时为确定性基值，便于测试断言。
static func compute_rate(tier: int, area_units: float, area_factor: float = 1.0,
		jitter: float = 1.0) -> float:
	var rate: float = float(tier) * area_factor * mesh_area(area_units) * SPAWN_RATE * jitter
	return minf(rate, MAX_RATE_PER_SYSTEM)


## 宿主轮廓面积（单位²）→ 药工发射 mesh 表面积（单位²）：线性标定 + 上下限截断
static func mesh_area(area_units: float) -> float:
	return clampf(maxf(area_units, 0.0) * AREA_TO_MESH, MESH_AREA_MIN, MESH_AREA_MAX)


## 生成 5 个子系统的配色（主色 + 白 + 3 个点缀色，去重）
static func variant_palette(theme_key: String) -> PackedStringArray:
	var pal: Array[String] = [theme_key, "white"]
	var pool: Array[String] = []
	pool.append_array(VARIANT_ACCENTS)
	pool.append_array(VARIANT_RESERVE)
	for k in pool:
		if pal.size() >= AREA_FACTORS.size():
			break
		if pal.has(k):
			continue
		pal.append(k)
	while pal.size() < AREA_FACTORS.size():
		pal.append("white")
	return PackedStringArray(pal)


# ─────────────────────────── 宿主轮廓测量 ───────────────────────────

## 测量宿主的可见轮廓：返回 {extents: Vector2, center: Vector2, area_units: float}
## area_units = 轮廓面积 / PX_PER_UNIT² （多边形取 shoelace 真实面积，非包围盒）
## 公开给 AmbientSparkleSpawner 复用，避免两处各写一套测量逻辑。
static func measure_host(host: Node2D) -> Dictionary:
	var out := {"extents": Vector2(22, 16), "center": Vector2.ZERO, "area_units": 0.1}
	if host == null:
		return out
	for child in host.get_children():
		if child is Sprite2D:
			var spr := child as Sprite2D
			if spr.texture == null:
				continue
			var s := spr.texture.get_size() * spr.scale
			out["extents"] = Vector2(maxf(s.x, 6.0), maxf(s.y, 6.0)) * 0.5
			out["center"] = spr.position
			out["area_units"] = (absf(s.x) / PX_PER_UNIT) * (absf(s.y) / PX_PER_UNIT)
			return out
		if child is Polygon2D:
			var poly := (child as Polygon2D).polygon
			if poly.is_empty():
				continue
			var sc := (child as Polygon2D).scale
			var min_v := Vector2(INF, INF)
			var max_v := Vector2(-INF, -INF)
			var area2 := 0.0
			var n := poly.size()
			for i in n:
				var p1 := poly[i] * sc
				var p2 := poly[(i + 1) % n] * sc
				min_v = min_v.min(p1)
				max_v = max_v.max(p1)
				area2 += p1.x * p2.y - p2.x * p1.y
			var size_v := Vector2(maxf(max_v.x - min_v.x, 6.0), maxf(max_v.y - min_v.y, 6.0))
			out["extents"] = size_v * 0.5
			out["center"] = (child as Polygon2D).position + (min_v + max_v) * 0.5
			out["area_units"] = absf(area2) * 0.5 / (PX_PER_UNIT * PX_PER_UNIT)
			return out
		if child is ColorRect:
			var cr := child as ColorRect
			var cr_size := cr.size * cr.scale
			out["extents"] = Vector2(maxf(cr_size.x, 6.0), maxf(cr_size.y, 6.0)) * 0.5
			out["center"] = cr.position + cr_size * 0.5
			out["area_units"] = (absf(cr_size.x) / PX_PER_UNIT) * (absf(cr_size.y) / PX_PER_UNIT)
			return out
	return out


# ─────────────────────────── 发射区点集采样 ───────────────────────────

## 采样宿主可见轮廓为发射点集（宿主局部坐标系），对齐药工"精灵轮廓 Mesh"发射形状。
## Sprite2D 按纹理 alpha 采样（粒子只落在不透明像素上，不会落在透明边角）；
## Polygon2D 三角化后按面积加权采样内部点；ColorRect 生成网格点。
## 采不到点（全透明/空子节点）返回空数组 → 调用方回退 BOX。
static func sample_host_points(host: Node2D, max_points: int = 64) -> PackedVector2Array:
	if host == null:
		return PackedVector2Array()
	for child in host.get_children():
		if child is Sprite2D:
			var spr := child as Sprite2D
			if spr.texture == null:
				continue
			var img := spr.texture.get_image()
			if img == null:
				continue
			if img.is_compressed():
				img.decompress()
			var pts := _sample_image_alpha(img, spr, max_points)
			if not pts.is_empty():
				return pts
		elif child is Polygon2D:
			var pts := _sample_polygon(child as Polygon2D, max_points)
			if not pts.is_empty():
				return pts
		elif child is ColorRect:
			var cr := child as ColorRect
			var pts := _sample_rect(cr.size, cr.position, cr.scale, max_points)
			if not pts.is_empty():
				return pts
	return PackedVector2Array()


## 纹理 alpha 网格采样：只收 alpha>0.1 的像素中心，等距下采样到 max_points。
## （flip/region 等少见变换不支持——占位与游戏内精灵均未使用）
static func _sample_image_alpha(img: Image, spr: Sprite2D, max_points: int) -> PackedVector2Array:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return PackedVector2Array()
	# 目标约 24×24 采样密度，避免逐像素扫大图
	var step := maxi(1, mini(w, h) / 24)
	var raw := PackedVector2Array()
	for y in range(0, h, step):
		for x in range(0, w, step):
			if img.get_pixel(x, y).a > 0.1:
				raw.append(Vector2(x + 0.5, y + 0.5))
	if raw.is_empty():
		return PackedVector2Array()
	# 行优先扫描顺序下等距抽取 = 空间近似均匀，不需要随机
	if raw.size() > max_points:
		var stride := float(raw.size()) / float(max_points)
		var picked := PackedVector2Array()
		for i in max_points:
			picked.append(raw[mini(int(float(i) * stride), raw.size() - 1)])
		raw = picked
	var tex_size := Vector2(w, h)
	var out := PackedVector2Array()
	for p in raw:
		var off := p - tex_size * 0.5
		if not spr.centered:
			off = p
		out.append(spr.position + off * spr.scale)
	return out


## 多边形内部采样：三角化后按面积加权随机取点（确定性 seed，同多边形每次同点集，
## 截图/预览稳定）。三角化失败返回空 → 回退 BOX。
static func _sample_polygon(poly: Polygon2D, max_points: int) -> PackedVector2Array:
	var base := poly.polygon
	if base.size() < 3:
		return PackedVector2Array()
	var tris := Geometry2D.triangulate_polygon(base)
	if tris.size() < 3:
		return PackedVector2Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for t in range(0, tris.size(), 3):
		var a0 := base[tris[t]]
		var b0 := base[tris[t + 1]]
		var c0 := base[tris[t + 2]]
		var w2 := absf((b0.x - a0.x) * (c0.y - a0.y) - (c0.x - a0.x) * (b0.y - a0.y))
		weights.append(w2)
		total += w2
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(base)
	var out := PackedVector2Array()
	for i in max_points:
		var pick := rng.randf() * total
		var idx := weights.size() - 1
		var acc := 0.0
		for j in weights.size():
			acc += weights[j]
			if pick <= acc:
				idx = j
				break
		var a := base[tris[idx * 3]]
		var b := base[tris[idx * 3 + 1]]
		var c := base[tris[idx * 3 + 2]]
		var r1 := sqrt(rng.randf())
		var r2 := rng.randf()
		out.append(poly.position + (a * (1.0 - r1) + b * (r1 * (1.0 - r2)) + c * (r1 * r2)) * poly.scale)
	return out


## 矩形网格采样（ColorRect，资源点占位用）
static func _sample_rect(rect_size: Vector2, pos: Vector2, sc: Vector2, max_points: int) -> PackedVector2Array:
	var sz := rect_size * sc
	if sz.x <= 0.0 or sz.y <= 0.0:
		return PackedVector2Array()
	var cols := maxi(2, int(sqrt(float(max_points))))
	var rows := maxi(2, max_points / cols)
	var out := PackedVector2Array()
	for iy in rows:
		for ix in cols:
			var u := (float(ix) + 0.5) / float(cols)
			var v := (float(iy) + 0.5) / float(rows)
			out.append(pos + Vector2(u * sz.x, v * sz.y))
	return out


# ─────────────────────────── 曲线 / 材质 ───────────────────────────

## SizeModule 曲线还原：Hermite (0,0,m0=0)→(1,0.4154,m1=-4.6633) 采样点
## 产生"长出→峰值→收缩→硬切"的脉冲
static func _build_size_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(0.2, 0.19))
	c.add_point(Vector2(0.4, 0.59))
	c.add_point(Vector2(0.6, 0.94))
	c.add_point(Vector2(0.8, 0.97))
	c.add_point(Vector2(0.9, 0.78))
	c.add_point(Vector2(1.0, 0.42))
	return c


## 尺寸曲线 × startSize 换算成贴图 scale（64px 贴图 → 峰值 ≈13px）
## CPUParticles2D 的 scale_amount_curve 直接吃 Curve，无需 CurveTexture 包装
static func _build_scale_curve() -> Curve:
	var c := _build_size_curve()
	var base: float = START_SIZE_UNITS * PX_PER_UNIT / 64.0
	var scaled := Curve.new()
	for i in c.get_point_count():
		var pt := c.get_point_position(i)
		scaled.add_point(Vector2(pt.x, pt.y * base))
	return scaled


## startColor：RandomBetweenTwoGradients（纯白 ↔ 主题色，每粒子随机）
## → CPUParticles2D color_initial_ramp（直接 Gradient）；全程 a=1，无生命周期渐隐
static func _build_color_ramp(theme_key: String) -> Gradient:
	var theme: Array = THEMES.get(theme_key, THEMES["sky"])
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(theme[0], theme[1], theme[2], 1))
	return g


# ─────────────────────────── 挂载 ───────────────────────────

## 附加到宿主节点：按原版挂 AREA_FACTORS.size() 个并发粒子系统。
## theme_key：THEMES 键（药工"每材料一色"）；tier：TIER_TABLE 的速率档位键。
## area_units < 0 时自动测量宿主轮廓。
## 返回主系统（areaFactor 最大者），其余为兄弟节点 CrystalSparkles_2.._5。
static func attach_to(host: Node2D, sorting_z: int = WorldZ.OVERLAY_HINT,
		theme_key: String = "sky", tier: int = DEFAULT_TIER,
		area_units: float = -1.0) -> CrystalSparkles:
	if host == null:
		return null
	var lifetime: float = float(TIER_TABLE.get(tier, TIER_TABLE[DEFAULT_TIER]))
	var meas := measure_host(host)
	if area_units >= 0.0:
		meas["area_units"] = area_units

	var palette := variant_palette(theme_key)
	# 原版 5 个子系统共享同一发射 mesh → 此处采样一次点集，5 个子系统共用。
	# 粒子系统节点挂在轮廓中心（见 _make_system 的 position），点集转为相对中心的坐标
	var center: Vector2 = meas["center"]
	var points := sample_host_points(host)
	if not points.is_empty():
		var rel := PackedVector2Array()
		for pt in points:
			rel.append(pt - center)
		points = rel
	var primary: CrystalSparkles = null
	for i in AREA_FACTORS.size():
		var sys := _make_system(host, meas, lifetime, tier, float(AREA_FACTORS[i]),
				palette[i], sorting_z, i, points)
		if primary == null:
			primary = sys
	return primary


## 构建单个子系统（原版一个 CrystalSparks - N 粒子系统）
static func _make_system(host: Node2D, meas: Dictionary, lifetime: float, tier: int,
		area_factor: float, theme_key: String, sorting_z: int, index: int,
		points: PackedVector2Array = PackedVector2Array()) -> CrystalSparkles:
	var area: float = float(meas["area_units"])
	# 原版每次 UpdateGroupEmission 随机 ×0.5~2；此处按子系统各取一次，等价于持续抖动
	var rate: float = compute_rate(tier, area, area_factor, randf_range(JITTER_MIN, JITTER_MAX))

	var p := CrystalSparkles.new()
	p.name = "CrystalSparkles" if index == 0 else "CrystalSparkles_%d" % (index + 1)
	p.one_shot = false
	p.local_coords = true
	p.z_index = sorting_z
	p.texture = _get_sparkle_tex()
	p.amount = maxi(int(ceilf(rate * lifetime)), 1)
	p.lifetime = lifetime
	# 原版 prewarm=true（tier20 除外）：开场粒子已在半程
	p.preprocess = 0.0 if tier == 20 else lifetime
	# 发射区对齐宿主轮廓中心（多边形/色块不一定以原点为中心）
	p.position = meas["center"]

	# 原版主模块：startSpeed=0 / gravityModifier=0 / 旋转关 → 位移全零，原地出生
	p.direction = Vector2.ZERO
	p.spread = 0.0
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 0.0
	p.gravity = Vector2.ZERO
	if points.is_empty():
		# 采不到点（全透明/空宿主）→ 回退轮廓矩形发射
		p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
		var ext: Vector2 = meas["extents"]
		p.emission_rect_extents = ext
	else:
		# 原版 Mesh 发射的等价物：粒子只出生在精灵轮廓内的采样点上
		p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
		p.emission_points = points
	# startSize 0.13 单位 × SizeModule 脉冲曲线（0→峰→0.42→硬切）
	p.scale_amount_min = 1.0
	p.scale_amount_max = 1.0
	p.scale_amount_curve = _build_scale_curve()
	p.color_initial_ramp = _build_color_ramp(theme_key)
	# Additive 发光叠加（原版 Unity Default-ParticleSystem 即 Additive 混合）：
	# 暗背景上多颗粒子重叠处越来越亮，"布灵布灵"观感的另一半来源
	var cam := CanvasItemMaterial.new()
	cam.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	# UNSHADED（对齐 Unity Particles/Standard Unlit）：粒子不受 CanvasModulate
	# 昼夜压暗 / Light2D 影响。否则夜间压暗系数把主题色乘暗后，Additive 下
	# 暗色≈不可见，只剩白点幸存——"全是白点、配色丢失"的根因（B7）
	cam.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	p.material = cam

	host.add_child(p)
	return p
