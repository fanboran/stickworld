class_name SketchCloud
extends Node2D
## 手绘涂鸦云 —— 大世界天空云的手绘渲染器（Terraria 贴图云的手绘替换皮肤）。
##
## 与血条/SketchPanel 同语言：wobble 扰动 + 粗马克笔。云是世界级大元素，
## 节拍比 UI 控件（0.12s）慢一档：boiling ~0.45s 重掷、毛线团 ~0.7s 换姿态。
##
## 画法全部规避自交多边形（血条三角化失败的教训）：
## PUFFY/EXTRUDE 用「独立圆团填充 + 上缘弧描边 + 波浪底线」（先画团再勾线，
## 手绘卡通云的经典笔序，天然无自交）；YARN/STROKES 全线段/弧线组合。
##
## 尺寸语义与原贴图云对齐：cloud_size ≈ 贴图尺寸（260×110 基准），
## scale_f 深度档（远小近大）由 sky_decor 继续管理。


enum Style {
	PUFFY,    ## A 实心鼓包云：圆团填充 + 上缘弧描边 + 波浪底线（简笔画系）
	YARN,     ## B 毛线团缠绕：几条手绘弧线缠绕云体，姿态变体间翻动（简笔画系）
	STROKES,  ## C 马克笔笔触堆叠：粗圆头短笔横向堆出体积（简笔画系）
	EXTRUDE,  ## D 双层挤出剪影：暗底 + 亮顶面错位（简笔画系）
	IMPASTO,  ## E 油画厚涂：弧形粗笔触三层铺（阴影/主体/高光），叠而不匀
	ANIME,    ## F 动漫体积：白剪影 + 鼓包下缘月牙阴影（错位双层）+ 顶部高光
}

@export var style: Style = Style.IMPASTO
## 云体基准尺寸（世界 px；对应原贴图云的纹理尺寸量级）
@export var cloud_size := Vector2(260.0, 110.0)
## 填充不透明度（白）
@export var fill_alpha := 0.72
## 描边不透明度（墨色）
@export var outline_alpha := 0.85
## 油画厚涂：笔触密度倍率（E2 浓郁 >1 / E3 干笔 <1）
@export var impasto_density := 1.0
## 油画厚涂：笔宽倍率
@export var impasto_thick := 1.0
## 动漫体积：下缘月牙阴影深度（0 无阴影 ~ 0.5 重阴影）
@export var anime_shadow := 0.3

## boiling 重掷节拍（PUFFY/STROKES/EXTRUDE）
const RESHUFFLE_INTERVAL := 0.45
## 毛线团换姿态节拍（"几个动画间变换"的翻动感）
const YARN_SWAP_INTERVAL := 0.7
## 动漫云受光缘短笔重掷节拍（慢翻动：一秒一动，重了会闪）
const ANIME_EDGE_INTERVAL := 1.2
## 毛线团姿态变体数
const YARN_VARIANTS := 4

const INK := Color(0.16, 0.15, 0.18)

var _seed := 0
var _timer := 0.0
var _variant := 0


func _ready() -> void:
	_seed = randi()
	_base_seed = _seed
	_edge_seed = randi()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_timer += delta
	if style == Style.YARN:
		if _timer >= YARN_SWAP_INTERVAL:
			_timer = 0.0
			_variant = (_variant + 1) % YARN_VARIANTS
			_seed = randi()
			queue_redraw()
	elif style == Style.ANIME:
		# 基底剪影不动，只翻受光缘短笔（1.2s 一换）
		if _timer >= ANIME_EDGE_INTERVAL:
			_timer = 0.0
			_edge_seed = randi()
			queue_redraw()
	else:
		if _timer >= RESHUFFLE_INTERVAL:
			_timer = 0.0
			_seed = randi()
			queue_redraw()


func _wob(i: int, mul: float = 1.0) -> float:
	return SketchDraw.wobble(i, _seed) * 2.2 * mul


func _draw() -> void:
	match style:
		Style.PUFFY:
			_draw_puffy(false)
		Style.EXTRUDE:
			_draw_puffy(true)
		Style.YARN:
			_draw_yarn()
		Style.STROKES:
			_draw_strokes()
		Style.IMPASTO:
			_draw_impasto()
		Style.ANIME:
			_draw_anime()


# ───────────────────────── E：油画厚涂 ─────────────────────────

## 油画风云的色板：白略暖、阴影蓝紫（天光反射）、高光近纯白
const IMPASTO_LIGHT := Color(1.0, 0.985, 0.955)
const IMPASTO_SHADOW := Color(0.60, 0.66, 0.80)
const IMPASTO_HIGHLIGHT := Color(1.0, 1.0, 0.99)


## 一笔油画：左→右的上弯弧（二次贝塞尔）+ 逐点 wobble（湿润手抖），
## 圆头粗线。返回采样点供 _draw_line_strip 画。
func _impasto_brush(rng: RandomNumberGenerator, center: Vector2,
		length: float, curve: float, brush_w: float) -> PackedVector2Array:
	var half := length * 0.5
	var from := center + Vector2(-half, curve * 0.35)
	var to := center + Vector2(half, -curve * 0.35)
	var ctrl := center + Vector2(rng.randf_range(-length * 0.15, length * 0.15), -curve)
	var pts := PackedVector2Array()
	var segs := 9
	for j in segs + 1:
		var t := float(j) / float(segs)
		var p: Vector2 = from.lerp(ctrl, t).lerp(ctrl.lerp(to, t), t)
		p += Vector2(_wob(j * 5, 1.6), _wob(j * 5 + 70, 1.6))
		pts.append(p)
	return pts


func _draw_impasto() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var w := cloud_size.x
	var h := cloud_size.y
	var brush_base: float = clampf(h * 0.22, 14.0, 34.0) * impasto_thick
	# 笔触行：顶短底长（云的体积轮廓），行数随密度
	var rows: int = maxi(3, roundi(4.0 * impasto_density))
	for row in rows:
		var t := float(row) / float(rows - 1)  # 0=顶 1=底
		var row_w: float = w * (0.34 + 0.62 * t) * rng.randf_range(0.92, 1.05)
		var y := -h * 0.42 + h * 0.8 * t
		var curve: float = h * (0.32 - 0.2 * t) + rng.randf_range(-3.0, 3.0)
		# 底部 1/3 行画在阴影层（先画，被上面白笔部分覆盖 = 厚涂叠色）
		var is_shadow_row: bool = t >= 0.66
		var col: Color
		if is_shadow_row:
			col = Color(IMPASTO_SHADOW.r, IMPASTO_SHADOW.g, IMPASTO_SHADOW.b, 0.38 * impasto_density)
		elif t <= 0.2:
			col = Color(IMPASTO_HIGHLIGHT.r, IMPASTO_HIGHLIGHT.g, IMPASTO_HIGHLIGHT.b, 0.55)
		else:
			col = Color(IMPASTO_LIGHT.r, IMPASTO_LIGHT.g, IMPASTO_LIGHT.b, 0.62)
		var strokes_in_row: int = maxi(1, roundi(2.0 * impasto_density)) if t > 0.2 else 1
		for k in strokes_in_row:
			var cx := rng.randf_range(-w * 0.1, w * 0.1) * (1.0 - t * 0.3)
			var len_f: float = rng.randf_range(0.8, 1.0)
			var pts := _impasto_brush(rng, Vector2(cx, y + rng.randf_range(-3.0, 3.0)),
					row_w * len_f, curve, brush_base)
			_draw_line_strip(pts, col, brush_base * rng.randf_range(0.85, 1.1))
	# 顶部高光：1-2 笔最亮的短弧（只扫顶鼓包）
	for k in rng.randi_range(1, 2):
		var pts := _impasto_brush(rng,
				Vector2(rng.randf_range(-w * 0.15, w * 0.15), -h * 0.36),
				w * rng.randf_range(0.2, 0.3), h * 0.3, brush_base * 0.8)
		_draw_line_strip(pts, Color(IMPASTO_HIGHLIGHT.r, IMPASTO_HIGHLIGHT.g,
				IMPASTO_HIGHLIGHT.b, 0.5), brush_base * 0.7)


# ───────────────────────── F：动漫体积（融合版：剪影+逐鼓包月牙+受光缘短笔）─────────────────────────

const ANIME_WHITE := Color(0.957, 0.949, 0.918, 0.97)   # 暖灰白（压暗让高光有空间）
const ANIME_WHITE_LOWER := Color(0.90, 0.905, 0.925, 0.97)  # 底部略冷白（纵向渐变近似）
const ANIME_SHADOW := Color(0.66, 0.71, 0.85)             # 月牙冷灰蓝（不透明画死）
const ANIME_EDGE_BRUSH := Color(1.0, 1.0, 1.0, 0.9)      # 受光缘纯白短笔（比体色亮一档）

## 基底鼓包 seed：固定不重掷——鼓包布局持久，重画只动表层笔触/边缘，
## 否则每次重掷整个布局硬切 = 闪烁（评审教训）
var _base_seed := 0
## 受光缘短笔 seed：独立慢节拍重掷（1.2s「一秒一动」的翻动感，不闪）
var _edge_seed := 0


## 动漫云鼓包布局：1-2 大 + 侧肩中鼓包 + 聚顶小鼓包（避免「等大圆叠罗汉」）
func _puffs_anime() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _base_seed
	var w := cloud_size.x
	var h := cloud_size.y
	var out: Array = []
	# 主鼓包（1-2 个大）
	var big_n: int = rng.randi_range(1, 2)
	for i in big_n:
		var cx := w * rng.randf_range(-0.22, 0.22) if big_n == 1 \
				else w * (-0.18 + 0.36 * float(i))
		out.append({"c": Vector2(cx, -h * rng.randf_range(0.3, 0.42)),
				"r": h * rng.randf_range(0.5, 0.62)})
	# 侧肩中鼓包 ×2
	out.append({"c": Vector2(-w * rng.randf_range(0.3, 0.4), -h * rng.randf_range(0.12, 0.22)),
			"r": h * rng.randf_range(0.36, 0.44)})
	out.append({"c": Vector2(w * rng.randf_range(0.3, 0.4), -h * rng.randf_range(0.1, 0.2)),
			"r": h * rng.randf_range(0.34, 0.42)})
	# 聚顶小鼓包 1-2
	for i in rng.randi_range(1, 2):
		out.append({"c": Vector2(w * rng.randf_range(-0.25, 0.25), -h * rng.randf_range(0.45, 0.58)),
				"r": h * rng.randf_range(0.24, 0.32)})
	return out


func _draw_anime() -> void:
	var w := cloud_size.x
	var h := cloud_size.y
	var puffs := _puffs_anime()
	var dip: float = clampf(anime_shadow, 0.0, 0.5)
	# 1. 阴影层：不透明冷灰蓝画死（硬边是动漫风的加分项）；
	#    带体左右内收 0.03w——横向探出白剪影外读作溢出（评审教训，只许向下露）
	var base_r: float = h * 0.22
	var inset: float = w * 0.03
	var band := Rect2(Vector2(-w * 0.36 + inset, -base_r), Vector2(w * 0.72 - inset * 2.0, base_r * 2.0))
	draw_rect(band, ANIME_SHADOW)
	draw_circle(Vector2(band.position.x, 0.0), base_r, ANIME_SHADOW)
	draw_circle(Vector2(band.end.x, 0.0), base_r, ANIME_SHADOW)
	for p in puffs:
		draw_circle(p["c"], p["r"], ANIME_SHADOW)
	# 2. 白色主体：底盘白先画、鼓包白后画（顺序反了底带会盖掉鼓包下缘月牙）；
	#    每鼓包白圆上移 dip 比例 → 下缘露出月牙阴影；顶部鼓包纯白、底盘略冷白
	for p in puffs:
		var r: float = p["r"]
		var up := r * lerpf(0.12, 0.18, dip / 0.5)
		draw_circle(p["c"] + Vector2(0.0, -up), r * (1.0 - dip * 0.06), ANIME_WHITE)
	var band_w := Rect2(band.position + Vector2(0.0, -base_r * dip * 0.8), band.size)
	draw_rect(band_w, ANIME_WHITE_LOWER)
	draw_circle(Vector2(band_w.position.x, band_w.position.y + base_r), base_r, ANIME_WHITE_LOWER)
	draw_circle(Vector2(band_w.end.x, band_w.position.y + base_r), base_r, ANIME_WHITE_LOWER)
	# 3. 受光缘奶油短笔：沿顶部鼓包上缘 3-6 条收尖弧笔（油画笔触质感，
	#    只重掷这一层 = 「缓慢重画」的动态，基底剪影不动）
	var rng := RandomNumberGenerator.new()
	rng.seed = _edge_seed  # 独立慢节拍重掷；基底 _base_seed 永不动
	var n_edge := 4
	for k in n_edge:
		var p: Dictionary = puffs[(k * 7 + _edge_seed) % puffs.size()]
		var r: float = p["r"]
		# 上半弧（0=右 π=左），弧宽 0.5~1.1 rad，位置随变体散布
		var a0: float = rng.randf_range(0.25, PI - 0.25)
		var arc: float = rng.randf_range(0.5, 1.1)
		var pts := PackedVector2Array()
		var segs := 7
		for j in segs + 1:
			var t := float(j) / float(segs)
			var a := a0 + arc * (t - 0.5)
			var rr: float = r * rng.randf_range(0.92, 1.02)
			var pt: Vector2 = p["c"] + Vector2(cos(a), -sin(a)) * rr
			pt += Vector2(0.0, -r * lerpf(0.12, 0.18, dip / 0.5))  # 跟随白层上移
			pt += Vector2(_wob(k * 17 + j * 3, 0.8), _wob(k * 17 + j * 3 + 40, 0.8))
			pts.append(pt)
		_tapered_stroke(pts, ANIME_EDGE_BRUSH, 5.0, 1.2)


## 收尖笔：逐段宽度渐变（起笔粗收笔细）+ 两端圆帽——等宽胶囊读作「药丸」的教训
func _tapered_stroke(pts: PackedVector2Array, color: Color, w0: float, w1: float) -> void:
	if pts.size() < 2:
		return
	var n := pts.size() - 1
	for i in n:
		var t := float(i) / float(n)
		draw_line(pts[i], pts[i + 1], color, lerpf(w0, w1, t), true)
	draw_circle(pts[0], w0 * 0.5, color)
	draw_circle(pts[n], w1 * 0.5, color)


# ───────────────────────── A/D：鼓包云（圆团 + 勾线）─────────────────────────

## 圆团鼓包布局（seed 驱动，重掷即换布局）：3~5 团均布 + 抖动，底带相连
func _puffs(seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var w := cloud_size.x
	var h := cloud_size.y
	var n: int = rng.randi_range(3, 5)
	var out: Array = []
	for i in n:
		var cx := -w * 0.5 + w * (float(i) + 0.5) / n + rng.randf_range(-w * 0.05, w * 0.05)
		var r: float = h * (0.42 + 0.18 * float(i % 2)) + rng.randf_range(-h * 0.03, h * 0.05)
		var cy := -r * 0.55 - rng.randf_range(0.0, h * 0.08)
		out.append({"c": Vector2(cx, cy), "r": r})
	return out


func _draw_puffy(extrude: bool) -> void:
	var w := cloud_size.x
	var h := cloud_size.y
	var puffs := _puffs(_seed if not extrude else _seed)
	# D 双层：先画暗色底层（下移错位），再画亮顶层——挤出感来自错位露边
	if extrude:
		draw_set_transform(Vector2(0.0, 5.0), 0.0, Vector2.ONE)
		_puffy_pass(puffs, w, h, 0.30, 0.0)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		_puffy_pass(puffs, w, h, fill_alpha, outline_alpha)
	else:
		_puffy_pass(puffs, w, h, fill_alpha, outline_alpha)


## 一遍完整鼓包云：底带 + 圆团填充（先），上缘弧 + 底边波浪线（后勾线）
func _puffy_pass(puffs: Array, w: float, h: float, fa: float, oa: float) -> void:
	var fill := Color(1.0, 1.0, 1.0, fa)
	var ink := Color(INK.r, INK.g, INK.b, oa)
	var base_r: float = h * 0.24
	# 底带（圆角矩形近似：主体 rect + 两端圆）——把鼓包团连成一体
	var band := Rect2(Vector2(-w * 0.36, -base_r), Vector2(w * 0.72, base_r * 2.0))
	draw_rect(band, fill)
	draw_circle(Vector2(band.position.x, 0.0), base_r, fill)
	draw_circle(Vector2(band.end.x, 0.0), base_r, fill)
	# 圆团填充
	for p in puffs:
		draw_circle(p["c"], p["r"], fill)
	# 勾线（oa>0 才描描边；底层只铺体积不勾）
	if oa <= 0.0:
		return
	var lw := 2.6
	# 上缘弧：每团只勾上弧中段（两端沉入相邻交叠区，天然避自交）
	for pi in puffs.size():
		var p: Dictionary = puffs[pi]
		var pts := PackedVector2Array()
		var seg := 7
		for j in seg + 1:
			var t := float(j) / float(seg)
			var a := PI * 1.12 - PI * 1.24 * t  # 从左下浅端扫到右下浅端（上弧）
			var rr: float = p["r"] * (1.0 + _wob(pi * 11 + j) * 0.06)
			var pt: Vector2 = p["c"] + Vector2(cos(a), -sin(a)) * rr
			pt += Vector2(_wob(pi * 7 + j * 3, 0.7), _wob(pi * 7 + j * 3 + 40, 0.7))
			pts.append(pt)
		_draw_line_strip(pts, ink, lw)
	# 底边波浪线（手绘收底）
	var bpts := PackedVector2Array()
	var bsegs := 8
	for j in bsegs + 1:
		var t := float(j) / float(bsegs)
		var x := -w * 0.5 + w * t
		bpts.append(Vector2(x, base_r * 0.55 + _wob(j * 5, 0.8)))
	_draw_line_strip(bpts, ink, lw * 0.85)


# ───────────────────────── B：毛线团缠绕 ─────────────────────────

## 云体椭圆骨架（骨架也逐变体微变，缠绕因此"活"）
func _yarn_skeleton(seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return {"a": cloud_size.x * 0.5 * rng.randf_range(0.92, 1.05),
			"b": cloud_size.y * 0.5 * rng.randf_range(0.85, 1.05)}


## 毛线团一笔：椭圆边缘两点间的三段折弯缠绕线（采样点 wobble）
func _yarn_thread(rng: RandomNumberGenerator, sk: Dictionary,
		ink: Color) -> PackedVector2Array:
	var a0 := rng.randf() * TAU
	var a1 := a0 + PI * rng.randf_range(0.7, 1.6) * (1.0 if rng.randf() < 0.5 else -1.0)
	var from := Vector2(cos(a0), sin(a0)) * Vector2(sk["a"], sk["b"])
	var to := Vector2(cos(a1), sin(a1)) * Vector2(sk["a"], sk["b"])
	var pts := PackedVector2Array()
	var segs := 10
	# 折弯轴：中点法向大幅偏移（缠绕感），两段正弦叠加
	var mid := (from + to) * 0.5
	var nrm := (to - from).orthogonal().normalized()
	var bow: float = rng.randf_range(-1.0, 1.0) * sk["b"] * 0.7
	var ctrl := mid + nrm * bow
	for j in segs + 1:
		var t := float(j) / float(segs)
		# 二次贝塞尔（from→ctrl→to）
		var p: Vector2 = from.lerp(ctrl, t).lerp(ctrl.lerp(to, t), t)
		p += Vector2(_wob(j * 3, 1.1), _wob(j * 3 + 30, 1.1))
		pts.append(p)
	return pts


func _draw_yarn() -> void:
	var sk := _yarn_skeleton(_seed * 13 + _variant)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(_seed, "_", _variant))
	var ink := Color(1.0, 1.0, 1.0, 0.68)
	var lw := 2.8
	# 云体极淡衬底（体量感，不抢线条）
	draw_set_ellipse(sk, Color(1.0, 1.0, 1.0, 0.10))
	# 主缠绕：5~6 条
	var threads: int = rng.randi_range(5, 6)
	for i in threads:
		_draw_line_strip(_yarn_thread(rng, sk, ink), ink, lw)
	# 松脱线头：1~2 条短弧在云体外飘（毛线团的"活")
	var loose: int = rng.randi_range(1, 2)
	for i in loose:
		var a := rng.randf() * TAU
		var anchor := Vector2(cos(a), sin(a)) * Vector2(sk["a"], sk["b"]) * 0.9
		var dir := Vector2(cos(a), sin(a)).normalized()
		var pts := PackedVector2Array()
		for j in 4:
			var t := float(j) / 3.0
			var p: Vector2 = anchor + dir * (8.0 + 22.0 * t) \
					+ Vector2(0.0, sin(t * PI * 1.5 + a) * 6.0) \
					+ Vector2(_wob(j * 9 + i, 1.0), _wob(j * 9 + i + 50, 1.0))
			pts.append(p)
		_draw_line_strip(pts, ink, lw * 0.8)


func draw_set_ellipse(sk: Dictionary, color: Color) -> void:
	# 椭圆衬底用多边形（无描边纯填充；采样密防锯齿棱角）
	var pts := PackedVector2Array()
	var seg := 20
	for i in seg:
		var a := TAU * float(i) / float(seg)
		pts.append(Vector2(cos(a) * float(sk["a"]), sin(a) * float(sk["b"]))
				+ Vector2(_wob(i * 5, 0.5), _wob(i * 5 + 20, 0.5)))
	draw_colored_polygon(pts, color)


# ───────────────────────── C：马克笔笔触堆叠 ─────────────────────────

func _draw_strokes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var w := cloud_size.x
	var h := cloud_size.y
	var fill := Color(1.0, 1.0, 1.0, fill_alpha)
	var ink := Color(INK.r, INK.g, INK.b, 0.0)  # 笔触风不勾整体描边（每笔自成笔）
	var rows: int = rng.randi_range(4, 5)
	var pen_w: float = clampf(h / float(rows) * 0.8, 3.5, 6.0)
	for row in rows:
		var t := float(row) / float(rows - 1)  # 0=顶 1=底
		var row_w: float = w * (0.42 + 0.55 * t) * rng.randf_range(0.94, 1.04)
		var y := -h * 0.5 + h * 0.82 * t
		# 每笔微斜（左低右高手绘感）+ 行间错位
		var skew := rng.randf_range(1.5, 5.0) * (1.0 if rng.randf() < 0.7 else -1.0)
		var x0 := -row_w * 0.5 + rng.randf_range(-w * 0.03, w * 0.03)
		var x1 := row_w * 0.5 + rng.randf_range(-w * 0.03, w * 0.03)
		var pts := PackedVector2Array()
		var segs := 8
		for j in segs + 1:
			var tt := float(j) / float(segs)
			var p := Vector2(x0 + (x1 - x0) * tt, y + skew * tt)
			p += Vector2(_wob(row * 13 + j * 3, 0.9), _wob(row * 13 + j * 3 + 60, 0.9))
			pts.append(p)
		# 粗笔（半透明白）+ 端头圆帽（马克笔收笔）
		_draw_line_strip(pts, fill, pen_w)
		draw_circle(pts[0], pen_w * 0.5, fill)
		draw_circle(pts[pts.size() - 1], pen_w * 0.5, fill)


# ───────────────────────── 公用 ─────────────────────────

## 折线绘制（圆头连接抗锯齿）
func _draw_line_strip(pts: PackedVector2Array, color: Color, width: float) -> void:
	if pts.size() < 2:
		return
	draw_polyline(pts, color, width, true)
	draw_circle(pts[0], width * 0.5, color)
	draw_circle(pts[pts.size() - 1], width * 0.5, color)
