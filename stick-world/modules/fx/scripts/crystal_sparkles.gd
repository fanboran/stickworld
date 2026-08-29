class_name CrystalSparkles
extends CPUParticles2D
## 水晶/岩壁连续闪光 —— 《药剂工艺》CrystalSparks 逐字段复刻。
##
## 数据来源（解包实证，详见 docs/技术/特效系统/药剂工艺特效复刻参考.md）：
##   多子系统   一个矿石宿主 = 基础层 + 5 个强度子系统（CrystalSparks -1..-5），
##              areaFactor 6.0/4.5/2.25/1.5/0.75（ParticleSystemsGroup 运行时启用）
##   速率公式   rateOverTime = areaFactor × 发射 mesh 面积 × SpawnRate × 抖动(0.5~2)
##   startLifetime 档位绑定 {8:0.72s, 6:0.96s, 3:1.08s, 2:1.6s, 1:1.72s}；基础层 1.0s
##   帧序列动画  UVModule mode=1 (Sprites)：每颗粒子一生播放精灵序列
##              "圆点放大→微星→十字星→缩回圆点"（frameOverTime 0→1 线性，cycles=1）。
##              各子系统帧深度不同（6/8/9/10/12 帧，最高到 5-1=24px 大星），
##              速率/寿命/深度互异 → 圆点相与星芒相异步并存（原版实机观察）
##   startColor minMaxState=4 RandomColor + maxGradient.mode=Fixed：
##              每颗粒子出生从调色盘随机抽一个纯色（离散，不插值）。
##              矿石变体=2~4 键同色系窄盘（单色观感）；通用变体 CrystalSparksBase
##              =8 键彩虹盘（岩壁五彩观感）。原版部分盘含 a=0 隐形键（已知差异，未复刻）
##   混合模式   AlphaBlend（Default-ParticleSystem = Particles/Standard Unlit，
##              _SrcBlend=5/_DstBlend=10）；扁平无泛光。UNSHADED 不受昼夜压暗
##   位移/重力/旋转 全零；looping=true；prewarm=true（tier20 除外）且按层错相
##
## 为什么用 CPUParticles2D：点集发射（emission_points 直接数组）；每宿主在世仅
## 2~30 颗，CPU 成本可忽略。GPUParticles2D 在 Godot 4.4+ 点集已纹理化，语义晦涩。
##
## Godot 语义换算：连续速率 = amount/lifetime；发射区 = 宿主轮廓采样点集
## （EMISSION_SHAPE_POINTS；空点集回退矩形）。

# ─────────────────────────── 原版出土常量 ───────────────────────────

## 速率档位(/s) → 寿命(s)：出土绑定
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

## 5 个强度子系统的 areaFactor（原版 ParticleSystemsGroup 出土）
const AREA_FACTORS := [6.0, 4.5, 2.25, 1.5, 0.75]

## 基础层（CrystalSparksBase 本体）：预制体里 active，rate/lifetime/size 出土
const BASE_LAYER_RATE := 10.0
const BASE_LAYER_LIFETIME := 1.0
const BASE_LAYER_SIZE := 0.05

## 原版全局 SpawnRate 与抖动区间（UpdateGroupEmission）
const SPAWN_RATE := 1.0
const JITTER_MIN := 0.5
const JITTER_MAX := 2.0

## 宿主轮廓面积（单位²）→ 发射 mesh 面积标定：按烘焙实例速率 0.008~0.62/s 反推
const AREA_TO_MESH := 0.12
const MESH_AREA_MIN := 0.008
const MESH_AREA_MAX := 0.013

## 单子系统速率上限（0.62/s × 抖动 2 留余量）
const MAX_RATE_PER_SYSTEM := 2.0

## 100PPU：0.13 单位 → 像素换算基数
const PX_PER_UNIT := 100.0
## 子系统 startSize（单位）；基础层见 BASE_LAYER_SIZE
const START_SIZE_UNITS := 0.13
## 帧序列单帧像素尺寸（图集 CrystalSpark 精灵 8×8）
const FRAME_PX := 8

## 强度子系统帧序列贴图（从 SpriteAtlas "CrystalSparks" 出土展开，
## 每层深度不同：-1 只到微星 6 帧 … -5 到大星 12 帧）
const LAYER_SEQ_TEXTURES := {
	1: "res://modules/fx/assets/sparkle_seq_CrystalSparks1_6.png",
	2: "res://modules/fx/assets/sparkle_seq_CrystalSparks2_8.png",
	3: "res://modules/fx/assets/sparkle_seq_CrystalSparks3_9.png",
	4: "res://modules/fx/assets/sparkle_seq_CrystalSparks4_10.png",
	5: "res://modules/fx/assets/sparkle_seq_CrystalSparks5_12.png",
}

## 基础层静态柔点（原版 Default-ParticleSystem 64px，UVModule 关闭）
const SPARKLE_TEX_PATH := "res://modules/fx/assets/sparkle_dot_default_particle.png"
static var _sparkle_tex: Texture2D = null
static var _seq_tex_cache := {}

static func _get_sparkle_tex() -> Texture2D:
	if _sparkle_tex != null:
		return _sparkle_tex
	if ResourceLoader.exists(SPARKLE_TEX_PATH):
		_sparkle_tex = load(SPARKLE_TEX_PATH)
	if _sparkle_tex != null:
		return _sparkle_tex
	# 回退：64px 高斯软点
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


static func _get_seq_tex(layer: int) -> Texture2D:
	## 帧序列网格贴图（一行 N 帧 × 8px）；缺失时返回 null → 该层退化为静态柔点
	if _seq_tex_cache.has(layer):
		return _seq_tex_cache[layer]
	var tex: Texture2D = null
	var path: String = LAYER_SEQ_TEXTURES.get(layer, "")
	if path != "" and ResourceLoader.exists(path):
		tex = load(path)
	_seq_tex_cache[layer] = tex
	return tex


# ─────────────────────────── 调色盘（RandomColor Fixed 离散抽色）───────────────────────────

## 矿石主题基色（每材料一色 → 运行时展开为同色系窄盘）
## 原版窄盘示例 FrostSapphire：#94BEFC→#B9E9FF（浅蓝两键）
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

## 通用/岩壁彩虹盘：CrystalSparksBase 出土 8 键（每颗粒子随机抽一色）
const RAINBOW_KEYS := [
	"CAD6DC", "EFF1D0", "FEE17B", "FEC27B",
	"E295F7", "95DBF7", "FF8F87", "AAEBA3",
]


## 主题 → 调色盘（Color 数组）。"rainbow" = 原版通用盘；其余 = 同色系窄盘 3 键
static func palette_for(theme_key: String) -> Array:
	if theme_key == "rainbow":
		var rb: Array = []
		for hex in RAINBOW_KEYS:
			rb.append(Color(hex))
		return rb
	var base: Array = THEMES.get(theme_key, THEMES["sky"])
	var c := Color(base[0], base[1], base[2])
	return [c.lightened(0.25), c, c.darkened(0.05)]


## 调色盘 → 离散平台渐变（每色占 1/n 区间，键间零宽接缝 = 无插值，
## 等价 Unity maxGradient.mode=Fixed 的随机抽纯色）
static func _build_color_ramp(theme_key: String) -> Gradient:
	var cols := palette_for(theme_key)
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var ramp := PackedColorArray()
	var n := cols.size()
	for i in n:
		offs.append(float(i) / float(n))
		ramp.append(cols[i])
		offs.append(float(i + 1) / float(n))
		ramp.append(cols[i])
	g.offsets = offs
	g.colors = ramp
	return g


# ─────────────────────────── 速率 / 面积 ───────────────────────────

## 原版 ParticleSystemsGroup.UpdateGroupEmission 速率公式（jitter=1 为确定性基值）
static func compute_rate(tier: int, area_units: float, area_factor: float = 1.0,
		jitter: float = 1.0) -> float:
	var rate: float = float(tier) * area_factor * mesh_area(area_units) * SPAWN_RATE * jitter
	return minf(rate, MAX_RATE_PER_SYSTEM)


static func mesh_area(area_units: float) -> float:
	return clampf(maxf(area_units, 0.0) * AREA_TO_MESH, MESH_AREA_MIN, MESH_AREA_MAX)


# ─────────────────────────── 宿主轮廓测量 ───────────────────────────

## 测量宿主可见轮廓：{extents, center, area_units}（多边形取 shoelace 真实面积）
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

## 采样宿主可见轮廓为发射点集（对齐药工"精灵轮廓 Mesh"发射形状）。
## Sprite2D 按 alpha 采样 / Polygon2D 三角化内采样 / ColorRect 网格采样；
## 采不到点返回空数组 → 调用方回退矩形。
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


static func _sample_image_alpha(img: Image, spr: Sprite2D, max_points: int) -> PackedVector2Array:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return PackedVector2Array()
	var step := maxi(1, mini(w, h) / 24)
	var raw := PackedVector2Array()
	for y in range(0, h, step):
		for x in range(0, w, step):
			if img.get_pixel(x, y).a > 0.1:
				raw.append(Vector2(x + 0.5, y + 0.5))
	if raw.is_empty():
		return PackedVector2Array()
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


## 多边形内部采样：三角化按面积加权（确定性 seed）。失败返回空 → 回退矩形。
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


# ─────────────────────────── 曲线 ───────────────────────────

## SizeModule 曲线：Hermite (0,0)→(1,0.4154, 出土斜率 -4.6633) 七点采样
## 与帧序列叠加：序列给形态（点↔星），曲线给尺寸脉冲（长出→缩回→硬切）
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


## 尺寸曲线 × startSize → 贴图 scale 系数曲线（tex_px：贴图/帧像素尺寸）
static func _build_scale_curve(tex_px: float) -> Curve:
	var c := _build_size_curve()
	var base: float = START_SIZE_UNITS * PX_PER_UNIT / tex_px
	var scaled := Curve.new()
	for i in c.get_point_count():
		var pt := c.get_point_position(i)
		scaled.add_point(Vector2(pt.x, pt.y * base))
	return scaled


# ─────────────────────────── 挂载 ───────────────────────────

## 附加到宿主：基础层（微尘柔点）+ 5 个强度子系统（帧序列动画），一簇一色。
## theme_key：THEMES 键或 "rainbow"（岩壁/通用彩虹盘）；tier：TIER_TABLE 档位键。
## area_units < 0 时自动测量宿主轮廓。返回主子系统（-1 层，areaFactor 最大）。
static func attach_to(host: Node2D, sorting_z: int = WorldZ.OVERLAY_HINT,
		theme_key: String = "sky", tier: int = DEFAULT_TIER,
		area_units: float = -1.0) -> CrystalSparkles:
	if host == null:
		return null
	var lifetime: float = float(TIER_TABLE.get(tier, TIER_TABLE[DEFAULT_TIER]))
	var meas := measure_host(host)
	if area_units >= 0.0:
		meas["area_units"] = area_units

	# 原版 6 层共享同一发射 mesh → 采样一次点集，转为相对轮廓中心的坐标
	var center: Vector2 = meas["center"]
	var points := sample_host_points(host)
	if not points.is_empty():
		var rel := PackedVector2Array()
		for pt in points:
			rel.append(pt - center)
		points = rel

	# 5 个强度子系统（-1..-5）：帧深度 6/8/9/10/12 递增，areaFactor 递减
	var primary: CrystalSparkles = null
	for i in AREA_FACTORS.size():
		var layer := i + 1
		var seq_tex := _get_seq_tex(layer)
		var frames := 1
		if seq_tex != null:
			frames = maxi(1, seq_tex.get_width() / FRAME_PX)
		var sys := _make_system(host, meas, lifetime, tier, float(AREA_FACTORS[i]),
				theme_key, sorting_z, layer, seq_tex, frames, START_SIZE_UNITS, points)
		if primary == null:
			primary = sys
	# 基础层（CrystalSparksBase 本体）：静态柔点微尘，rate 恒定不受 areaFactor
	_make_system(host, meas, BASE_LAYER_LIFETIME, 0, 1.0, theme_key, sorting_z, 0,
			null, 1, BASE_LAYER_SIZE, points, BASE_LAYER_RATE)
	return primary


## 构建单个子系统。layer 0 = 基础层（命名 CrystalSparklesBase）；
## rate_override >= 0 时直接用（基础层恒定速率），否则按 tier×areaFactor×面积。
static func _make_system(host: Node2D, meas: Dictionary, lifetime: float, tier: int,
		area_factor: float, theme_key: String, sorting_z: int, layer: int,
		seq_tex: Texture2D, frames: int, size_units: float,
		points: PackedVector2Array, rate_override: float = -1.0) -> CrystalSparkles:
	var area: float = float(meas["area_units"])
	# 原版每次 UpdateGroupEmission 随机 ×0.5~2；按层各取一次，等价持续抖动
	var rate: float = rate_override if rate_override >= 0.0 \
			else compute_rate(tier, area, area_factor, randf_range(JITTER_MIN, JITTER_MAX))

	var p := CrystalSparkles.new()
	p.name = "CrystalSparkles" if layer == 1 else \
			("CrystalSparklesBase" if layer == 0 else "CrystalSparkles_%d" % layer)
	p.one_shot = false
	p.local_coords = true
	p.z_index = sorting_z
	p.lifetime = lifetime
	# ⚠️ CPUParticles2D 连续发射密度下限 = 1/lifetime；原版极稀速率靠多对象叠加
	p.amount = maxi(int(ceilf(rate * lifetime)), 1)
	# 原版 prewarm=true（tier20 除外）；按层错相——同寿命同相位会整簇同步熄灭
	p.preprocess = 0.0 if tier == 20 else lifetime * float(layer % 6) / 6.0
	# 发射区对齐宿主轮廓中心
	p.position = meas["center"]

	# 位移/重力全零（原版 startSpeed=0 / gravityModifier=0），原地出生原地闪
	p.direction = Vector2.ZERO
	p.spread = 0.0
	p.initial_velocity_min = 0.0
	p.initial_velocity_max = 0.0
	p.gravity = Vector2.ZERO

	# 混合：AlphaBlend（出土实证）+ UNSHADED（unlit，不受昼夜压暗）
	var cam := CanvasItemMaterial.new()
	cam.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	cam.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED

	if seq_tex != null and frames > 1:
		# UVModule Sprites 帧序列：圆点→微星→十字星→缩回，一生播一遍（anim_speed=1）
		p.texture = seq_tex
		cam.particles_animation = true
		cam.particles_anim_h_frames = frames
		cam.particles_anim_v_frames = 1
		cam.particles_anim_loop = false
		p.anim_speed_min = 1.0
		p.anim_speed_max = 1.0
		p.anim_offset_min = 0.0
		p.anim_offset_max = 0.0
		p.scale_amount_curve = _build_scale_curve(float(FRAME_PX))
	else:
		# 基础层 / 帧贴图缺失：静态柔点
		p.texture = _get_sparkle_tex()
		p.scale_amount_curve = _build_scale_curve(64.0)
	p.material = cam

	# startColor RandomColor(Fixed)：离散调色盘平台渐变
	p.color_initial_ramp = _build_color_ramp(theme_key)

	# 发射形状：轮廓点集（原版 Mesh 等价）；空点集回退矩形
	if points.is_empty():
		p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
		var ext: Vector2 = meas["extents"]
		p.emission_rect_extents = ext
	else:
		p.emission_shape = CPUParticles2D.EMISSION_SHAPE_POINTS
		p.emission_points = points

	host.add_child(p)
	return p
