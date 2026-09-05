class_name RockPainting
extends Node2D
## 程序化手绘岩块 —— 石头/黄金/钻石的程序化视觉（2026-09-06 用户定调）。
##
## 形状：不规则棱角多边形轮廓（9-12 顶点，半径/角度双抖动 → 岩块的棱角感，
## 非圆形毛线团——那是树叶语言），底部压平坐地。
## 填充：树叶同款粗细的弧线笔触（密实不四处漏风），锚点按轮廓极坐标半径收紧。
## 矿脉：1-2 条从内向外伸出的分叉枝干（主脉+岔脉，亮色，端点露头到轮廓边）
## ——用户："这么大的石头里面透露出各种矿物的枝干"。
## 动态：填充笔每秒翻 40%（同树叶节拍语言），轮廓与矿脉固定（形状稳定）。

## 翻动节拍（与 TreeYarnBall 同语言）
const SWAP_INTERVAL := 1.0
const VARIANTS := 4
const SWAP_FRACTION := 0.4

## 岩块基准半径（px；y 再压 0.75 → 成块不圆）
var radius := 64.0
## 确定性种子
var base_seed := 0
## 色板 [浅/中/深]
var palette: Array = [Color8(150, 154, 160), Color8(114, 120, 128), Color8(80, 86, 94)]
## 矿脉色（null = 无脉纯石）
var vein_color: Color = Color8(196, 200, 206)
var vein_ratio := 0.0

var _timer := 0.0
var _variant := 0
var _interval := SWAP_INTERVAL
var _reenter_redraw := false
var _verts: Array = []   # 轮廓顶点（极坐标 → 直角坐标，绘制缓存）


func _ready() -> void:
	var rng := _rng(1)
	_interval = SWAP_INTERVAL * (0.88 + 0.24 * rng.randf())
	_gen_outline()
	queue_redraw()


func _process(delta: float) -> void:
	if not _in_view():
		_reenter_redraw = true
		return
	if _reenter_redraw:
		_reenter_redraw = false
		queue_redraw()
	_timer += delta
	if _timer >= _interval:
		_timer = fmod(_timer, _interval)
		_variant = (_variant + 1) % VARIANTS
		queue_redraw()


func _in_view() -> bool:
	var vp := get_viewport()
	if vp == null:
		return true
	var xform := vp.get_canvas_transform()
	var screen := Rect2(Vector2.ZERO, vp.get_visible_rect().size).grow(
		radius * absf(global_scale.x) + 80.0)
	return screen.has_point(xform * global_position)


func _rng(slot: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = absi((base_seed * 73856093) ^ (slot * 19349663) ^ 0x5F356495)
	return rng


## 岩块轮廓：极坐标顶点（半径 0.72-1.08 × 基准），角度=均匀格+小幅抖动
## （抖动不超过半格间隔 → 顶点保持角度单调，多边形不自交——三角化打底依赖），
## y 压 0.75；底部顶点压到统一底边线 → 平底坐地
func _gen_outline() -> void:
	var rng := _rng(2)
	_verts.clear()
	var n := rng.randi_range(9, 12)
	var max_y := -1e9
	var raw: Array = []
	for k in n:
		var th := TAU * float(k) / float(n) + rng.randf_range(-0.45, 0.45) * TAU / float(n)
		var r := radius * rng.randf_range(0.72, 1.08)
		var v := Vector2(cos(th) * r, sin(th) * r * 0.75)
		raw.append(v)
		max_y = maxf(max_y, v.y)
	# 底部压平：y 超过底线（max_y×0.86）的顶点拉回底线（岩块坐地的平面）
	var flat: float = max_y * 0.86
	for v: Vector2 in raw:
		if v.y > flat:
			v.y = flat
		_verts.append(v)


## 角度 θ 方向的轮廓半径：从原点沿 θ 的射线与轮廓各边求交，取交点距
## （精确版——顶点插值近似低估半径会让笔触缩在中心漏风）
func _r_at(theta: float) -> float:
	var dir := Vector2(cos(theta), sin(theta))
	var best := radius * 1.05
	var n := _verts.size()
	for k in n:
		var a: Vector2 = _verts[k]
		var b: Vector2 = _verts[(k + 1) % n]
		var ab := b - a
		var den := dir.x * ab.y - dir.y * ab.x
		if absf(den) < 1e-6:
			continue
		# 解 dir*s = a + ab*u（0≤u≤1, s>0）
		var s := (a.x * ab.y - a.y * ab.x) / den
		var u := (dir.x * a.y - dir.y * a.x) / -den
		if s > 0.0 and u >= 0.0 and u <= 1.0:
			best = minf(best, s)
	return maxf(best, radius * 0.3)


func _draw() -> void:
	var lw := clampf(radius * 0.07, 5.5, 9.0)
	# 底色打底（中档色填充整块）：石头要"贴图感不四处漏风"，
	# 笔触叠在底色上=密度保险（树叶不打底是"线条自己成形状"，石头反之）
	var fill := PackedVector2Array()
	for v: Vector2 in _verts:
		fill.append(v)
	var base_col: Color = palette[1]
	base_col.a = 1.0
	draw_colored_polygon(fill, base_col)
	# 填充笔触：块内随机弦（弦心距按该方向轮廓半径收紧，无截断不出界）
	var n_total := clampi(roundi(13.0 * radius / lw), 46, 320)
	for i in n_total:
		var is_base := (i % 10) >= int(SWAP_FRACTION * 10.0)
		var rng := _rng(10 * (0 if is_base else _variant) + i)
		_fill_strand(rng, lw)
	# 矿脉枝干（固定形状）：主脉 + 1-2 岔
	if vein_ratio > 0.0:
		_draw_veins(lw)
	# 轮廓线（闭合，深色档，粗一档）——岩块的笔触收边
	var poly := PackedVector2Array()
	for v: Vector2 in _verts:
		poly.append(v)
	poly.append(_verts[0])
	var edge: Color = (palette[2] as Color).darkened(0.15)
	edge.a = 1.0
	draw_polyline(poly, edge, lw * 1.25)


## 一根填充笔：随机方向的短弯弧（弦心距算好不出界；密实堆叠盖满块体）
func _fill_strand(rng: RandomNumberGenerator, lw: float) -> void:
	var th := rng.randf() * TAU
	var d := rng.randf_range(-0.80, 0.80) * radius
	var mid := Vector2(-sin(th), cos(th)) * d
	var r_in: float = _r_at(atan2(mid.y, mid.x)) * 0.92
	var half := sqrt(maxf(r_in * r_in - d * d, 0.0)) * rng.randf_range(0.5, 0.9)
	if half < lw * 1.5:
		return
	var dir := Vector2(cos(th), sin(th))
	var nrm := Vector2(-dir.y, dir.x)
	var p0 := mid - dir * half
	var p1 := mid + dir * half
	var ctrl := mid + nrm * rng.randf_range(-1.0, 1.0) * half * 0.3
	var pts := PackedVector2Array()
	for j in 5:
		var t := float(j) / 5.0
		pts.append(p0.lerp(ctrl, t).lerp(ctrl.lerp(p1, t), t))
	# 三档色按高度（上亮下暗），少量笔用矿脉亮色
	var col: Color
	if vein_ratio > 0.0 and rng.randf() < vein_ratio * 0.35:
		col = vein_color.lightened(rng.randf_range(-0.05, 0.15))
	else:
		var band := 1
		if mid.y < -radius * 0.2:
			band = 0
		elif mid.y > radius * 0.25:
			band = 2
		col = (palette[band] as Color).lightened(rng.randf_range(-0.04, 0.04))
	col.a = 1.0
	var wide := 1.3 if rng.randf() < 0.12 else 1.0
	draw_polyline(pts, col, lw * rng.randf_range(0.85, 1.12) * wide)


## 矿脉枝干：1-2 条主脉从块心附近向外生长（3-4 段折线，逐段偏折 ±35°），
## 各带 1 条岔脉；端点推进到轮廓半径附近=露头（"透露出矿物的枝干"）
func _draw_veins(lw: float) -> void:
	var rng := _rng(3)
	for _v in rng.randi_range(1, 2):
		var p := Vector2(rng.randf_range(-0.2, 0.2), rng.randf_range(-0.2, 0.1)) * radius
		var ang := rng.randf() * TAU
		var main := PackedVector2Array()
		main.append(p)
		for seg in rng.randi_range(3, 4):
			ang += rng.randf_range(-0.6, 0.6)
			var step: float = radius * rng.randf_range(0.22, 0.38)
			p += Vector2(cos(ang), sin(ang) * 0.8) * step
			# 露头：段点推进到该方向轮廓半径 ×1.02 为止
			var max_r: float = _r_at(atan2(p.y, p.x)) * 1.02
			if p.length() > max_r:
				p = p.normalized() * max_r
			main.append(p)
			# 岔脉（60% 概率，短 2 段）
			if rng.randf() < 0.6:
				var bp := p
				var bang := ang + rng.randf_range(0.8, 1.6) * (1.0 if rng.randf() < 0.5 else -1.0)
				var branch := PackedVector2Array()
				branch.append(bp)
				for _b in 2:
					bang += rng.randf_range(-0.5, 0.5)
					bp += Vector2(cos(bang), sin(bang) * 0.8) * radius * rng.randf_range(0.14, 0.24)
					var bmax: float = _r_at(atan2(bp.y, bp.x)) * 1.02
					if bp.length() > bmax:
						bp = bp.normalized() * bmax
					branch.append(bp)
				var bcol: Color = vein_color.darkened(0.1)
				bcol.a = 1.0
				draw_polyline(branch, bcol, lw * 0.7)
		var vcol: Color = vein_color
		vcol.a = 1.0
		draw_polyline(main, vcol, lw * 0.85)
