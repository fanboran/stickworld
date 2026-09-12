## 构件库：正面立面建筑构件，全部经 Painter 落笔（1x 图内局部坐标，y 向下）。
## 风格基线对齐 assets/_raw/建筑/smithy.png：干净深褐墨线、块面阴影、实材质质感。
extends RefCounted

const Painter := preload("res://tools/building_pipeline/draw/painter.gd")
const Ink := preload("res://tools/building_pipeline/draw/ink.gd")

const DARK_HOLE := Color(0.145, 0.11, 0.07)     # 门洞/窗洞深色
const GLOW := Color(0.94, 0.55, 0.16)           # 炉火暖光
const GLOW_HI := Color(0.99, 0.78, 0.3)
const SHADE := Color(0.1, 0.08, 0.06)           # 叠加阴影基色


# ---------- 基础 ----------

static func _rect_pts(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y),
	])


static func wall_plane(p: Painter, rect: Rect2, mat: String, face: String = "base", stroke_w: float = 2.4) -> void:
	p.face(rect, mat, face)
	eave_shade(p, Rect2(rect.position, Vector2(rect.size.x, 7.0)), 0.13)
	p.rect_stroke(rect, stroke_w)


## 檐下/顶缘阴影带（块面叠压）。
static func eave_shade(p: Painter, band: Rect2, alpha: float = 0.16) -> void:
	if band.size.y <= 0.0:
		return
	p.poly(_rect_pts(band), Color(SHADE.r, SHADE.g, SHADE.b, alpha))


## 墙基（勒脚）：暗一档的窄横带。
static func plinth(p: Painter, body: Rect2, mat: String, h: float, rng: RandomNumberGenerator) -> void:
	var r := Rect2(Vector2(body.position.x - 1.0, body.end.y - h), Vector2(body.size.x + 2.0, h))
	p.face(r, mat, "shadow")
	p.rect_stroke(r, 2.0, {"rng": rng, "amp": 0.6})


## 层间腰线（木梁带）。
static func belt_course(p: Painter, body: Rect2, y: float, mat: String, rng: RandomNumberGenerator) -> void:
	var r := Rect2(Vector2(body.position.x - 2.0, y), Vector2(body.size.x + 4.0, 6.0))
	p.face(r, mat, "base")
	p.rect_stroke(r, 2.0, {"rng": rng, "amp": 0.6})
	eave_shade(p, Rect2(Vector2(r.position.x, r.end.y), Vector2(r.size.x, 4.0)), 0.18)


## 悬挑梁托（二层出挑下的短梁排）。
static func jetty_beams(p: Painter, x0: float, x1: float, y: float, mat: String, rng: RandomNumberGenerator) -> void:
	var x := x0 + 6.0
	while x < x1 - 6.0:
		var pts := PackedVector2Array([Vector2(x, y), Vector2(x + 5.0, y + 9.0)])
		p.stroke(pts, 3.2, {"rng": rng, "amp": 0.4, "overshoot": 1.0})
		x += rng.randf_range(16.0, 26.0)


# ---------- 屋顶 ----------

## 人字顶（山墙朝前）：三角面铺主材质 + 两侧檐带 + 檐底线；可选山墙窗。
static func gable_roof(p: Painter, body: Rect2, roof: Dictionary, rng: RandomNumberGenerator, gable_window: bool = false) -> void:
	var rise := float(roof["rise"])
	var oh := float(roof["overhang"])
	var mat := String(roof["mat"])
	var apex := Vector2(body.get_center().x + rng.randf_range(-2.0, 2.0), body.position.y - rise)
	var bl := Vector2(body.position.x - oh, body.position.y + 2.0)
	var br := Vector2(body.end.x + oh, body.position.y + 2.0)
	var tri := PackedVector2Array([bl, br, apex])
	p.poly(tri, p.mat_color(mat, "base"))
	p.hatch(tri, 8.0, -46.0, 1.2, 0.2)
	# 屋面纵向板条/瓦垄：从底边向 apex 收敛的线
	var n := maxi(3, int(body.size.x / 40.0))
	for i in range(1, n):
		var t := float(i) / float(n)
		var b := bl.lerp(br, t)
		p.stroke(PackedVector2Array([b, b.lerp(apex, 0.92)]), 1.3, {"rng": rng, "amp": 0.5, "overshoot": 0.0, "taper": false})
	if gable_window:
		var wrect := Rect2(apex.x - 8.0, apex.y + rise * 0.42, 16.0, 15.0)
		window(p, wrect, rng)
	_eave_band(p, bl, apex, 14.0, mat, -1, rng)
	_eave_band(p, br, apex, 14.0, mat, 1, rng)
	p.stroke(PackedVector2Array([bl + Vector2(-3.0, 1.0), apex + Vector2(-2.0, -2.0)]), 2.6, {"rng": rng})
	p.stroke(PackedVector2Array([br + Vector2(3.0, 1.0), apex + Vector2(2.0, -2.0)]), 2.6, {"rng": rng})
	p.stroke(PackedVector2Array([bl, br]), 3.4, {"rng": rng})
	# 脊顶压瓦帽
	p.circle(apex, 2.8, p.mat_color(mat, "shadow"))
	p.stroke(PackedVector2Array([apex + Vector2(-8, -1), apex + Vector2(8, -1)]), 2.4, {"rng": rng, "amp": 0.4, "overshoot": 2.0})


## 坡面朝前屋顶：平行四边形坡面 + 受光带 + 檐口。
static func slope_roof(p: Painter, body: Rect2, roof: Dictionary, rng: RandomNumberGenerator) -> void:
	var rise := float(roof["rise"])
	var drop := float(roof["eave_drop"]) if roof.has("eave_drop") else 8.0
	var skew := float(roof["skew"]) if roof.has("skew") else 6.0
	var oh := float(roof["overhang"])
	var mat := String(roof["mat"])
	var eave_l := Vector2(body.position.x - oh, body.position.y + drop)
	var eave_r := Vector2(body.end.x + oh, body.position.y + drop)
	var ridge_l := Vector2(body.position.x - oh + skew, body.position.y - rise)
	var ridge_r := Vector2(body.end.x + oh + skew, body.position.y - rise)
	p.quad_face([eave_l, eave_r, ridge_r, ridge_l], mat, "shadow")
	var lit_l := eave_l.lerp(ridge_l, 0.5)
	var lit_r := eave_r.lerp(ridge_r, 0.5)
	var mid_l := eave_l.lerp(ridge_l, 0.34)
	var mid_r := eave_r.lerp(ridge_r, 0.34)
	p.poly(PackedVector2Array([mid_l, mid_r, lit_r, lit_l]), Color(p.mat_color(mat, "lit").r, p.mat_color(mat, "lit").g, p.mat_color(mat, "lit").b, 0.25))
	p.stroke(PackedVector2Array([eave_l, eave_r]), 3.4, {"rng": rng})
	eave_shade(p, Rect2(Vector2(body.position.x, body.position.y + drop), Vector2(body.size.x + oh * 2.0, 7.0)), 0.22)
	p.stroke(PackedVector2Array([ridge_l, ridge_r]), 2.4, {"rng": rng, "amp": 0.6})
	var n := maxi(2, int(body.size.x / 48.0))
	for i in range(1, n):
		var t := float(i) / float(n)
		p.stroke(PackedVector2Array([eave_l.lerp(eave_r, t).lerp(ridge_l.lerp(ridge_r, t), 0.1), ridge_l.lerp(ridge_r, t)]), 1.4, {"rng": rng, "amp": 0.5, "overshoot": 1.0, "taper": false})


## 四坡顶（正面看到梯形坡面 + 两侧收进的三角）。
static func hip_roof(p: Painter, body: Rect2, roof: Dictionary, rng: RandomNumberGenerator) -> void:
	var rise := float(roof["rise"])
	var oh := float(roof["overhang"])
	var inset := float(roof["hip_inset"]) if roof.has("hip_inset") else 12.0
	var mat := String(roof["mat"])
	var eave_l := Vector2(body.position.x - oh, body.position.y + 2.0)
	var eave_r := Vector2(body.end.x + oh, body.position.y + 2.0)
	var ridge_l := Vector2(body.position.x + inset, body.position.y - rise)
	var ridge_r := Vector2(body.end.x - inset, body.position.y - rise)
	p.quad_face([eave_l, eave_r, ridge_r, ridge_l], mat, "base")
	p.stroke(PackedVector2Array([eave_l, eave_r]), 3.4, {"rng": rng})
	p.stroke(PackedVector2Array([ridge_l, ridge_r]), 2.4, {"rng": rng, "amp": 0.6})
	p.stroke(PackedVector2Array([eave_l, ridge_l]), 2.4, {"rng": rng})
	p.stroke(PackedVector2Array([eave_r, ridge_r]), 2.4, {"rng": rng})
	eave_shade(p, Rect2(Vector2(body.position.x, body.position.y + 2.0), Vector2(body.size.x + oh * 2.0, 7.0)), 0.2)


## 尖顶（教堂/钟楼）：细长三角锥 + 顶部十字。
static func spire(p: Painter, base_rect: Rect2, roof: Dictionary, rng: RandomNumberGenerator) -> void:
	var h := float(roof["spire_h"])
	var mat := String(roof["mat"])
	var apex := Vector2(base_rect.get_center().x, base_rect.position.y - h)
	var bl := Vector2(base_rect.position.x - 4.0, base_rect.position.y + 2.0)
	var br := Vector2(base_rect.end.x + 4.0, base_rect.position.y + 2.0)
	var tri := PackedVector2Array([bl, br, apex])
	p.poly(tri, p.mat_color(mat, "base"))
	p.hatch(tri, 7.0, -60.0, 1.1, 0.22)
	p.stroke(PackedVector2Array([bl, br]), 3.2, {"rng": rng})
	p.stroke(PackedVector2Array([bl, apex]), 2.6, {"rng": rng})
	p.stroke(PackedVector2Array([br, apex]), 2.6, {"rng": rng})
	# 十字风标
	var c := Vector2(apex.x, apex.y - 9.0)
	p.stroke(PackedVector2Array([c + Vector2(0, 10), c]), 2.4, {"rng": rng, "amp": 0.2, "overshoot": 0.0})
	p.stroke(PackedVector2Array([c + Vector2(-5, 2), c + Vector2(5, 2)]), 2.4, {"rng": rng, "amp": 0.2, "overshoot": 1.0})


## 城墙垛口（墙顶齿列）。
static func battlement(p: Painter, x0: float, x1: float, y_top: float, h: float, mat: String, rng: RandomNumberGenerator) -> void:
	var merlon := 12.0
	var x := x0
	while x < x1:
		var w := minf(merlon, x1 - x)
		var r := Rect2(x, y_top - h, w, h)
		p.face(r, mat, "base")
		p.stroke(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y)]), 2.0, {"rng": rng, "amp": 0.5})
		p.stroke(PackedVector2Array([Vector2(r.position.x, r.position.y), Vector2(r.position.x, r.end.y)]), 1.8, {"rng": rng, "amp": 0.4, "taper": false})
		x += merlon + 8.0
	p.stroke(PackedVector2Array([Vector2(x0, y_top), Vector2(x1, y_top)]), 2.4, {"rng": rng, "amp": 0.5})


## 沿 a→b 的屋檐厚带（草檐/板檐），side=-1 取左法向外侧。实底色 + 质感纹理。
static func _eave_band(p: Painter, a: Vector2, b: Vector2, band_w: float, mat: String, side: int, rng: RandomNumberGenerator) -> void:
	var dir := (b - a).normalized()
	var nrm := Vector2(-dir.y, dir.x) * float(side)
	var m: Dictionary = Painter.MATS[mat]
	var quad := [a, b, b + nrm * band_w, a + nrm * band_w]
	var pts := PackedVector2Array()
	for q in quad:
		pts.push_back(q)
	p.poly(pts, m["base"])
	p.quad_tex(String(m["tex"]), quad, float(m["tex_a"]) * 0.8, m["base"])
	p.stroke(PackedVector2Array([a, b]), 2.2, {"rng": rng, "amp": 0.6})
	p.stroke(PackedVector2Array([a + nrm * band_w, b + nrm * band_w]), 1.8, {"rng": rng, "amp": 0.6})


# ---------- 开口 ----------

static func door(p: Painter, rect: Rect2, mat: String, rng: RandomNumberGenerator, wide: bool = false, arch: bool = false) -> void:
	if arch:
		arch_door(p, rect, mat, rng)
		return
	p.face(rect, mat, "shadow")
	var splits := 2 if wide else 1
	for i in range(1, splits + 1):
		var x := rect.position.x + rect.size.x * float(i) / float(splits + 1)
		p.stroke(PackedVector2Array([Vector2(x, rect.position.y + 2), Vector2(x, rect.end.y - 1)]), 1.4, {"rng": rng, "amp": 0.4, "taper": false})
	if wide:
		p.stroke(PackedVector2Array([rect.position + Vector2(2, rect.size.y * 0.72), rect.end - Vector2(2, rect.size.y * 0.18)]), 1.6, {"rng": rng, "amp": 0.5})
	p.rect_stroke(rect, 2.0, {"rng": rng})
	var lintel := Rect2(rect.position - Vector2(4, 6), Vector2(rect.size.x + 8, 6))
	p.face(lintel, mat, "shadow")
	p.rect_stroke(lintel, 1.8, {"rng": rng, "amp": 0.6})
	p.circle(Vector2(rect.end.x - rect.size.x * 0.22, rect.get_center().y + 2.0), 1.8, Ink.INK)


## 拱形门洞（石/砖拱圈）。
static func arch_door(p: Painter, rect: Rect2, mat: String, rng: RandomNumberGenerator) -> void:
	var arch_h := rect.size.x * 0.5
	var body_r := Rect2(rect.position.x, rect.position.y + arch_h, rect.size.x, rect.size.y - arch_h)
	p.poly(_rect_pts(body_r), DARK_HOLE)
	# 拱腔（半圆）
	var segs := 10
	var pts := PackedVector2Array()
	pts.push_back(Vector2(rect.position.x, rect.position.y + arch_h))
	for i in range(1, segs):
		var a := PI * float(i) / float(segs)
		pts.push_back(Vector2(rect.get_center().x - cos(a) * rect.size.x * 0.5, rect.position.y + arch_h - sin(a) * arch_h))
	pts.push_back(Vector2(rect.end.x, rect.position.y + arch_h))
	p.poly(pts, DARK_HOLE)
	# 拱圈石（沿拱的楔形块）
	for i in range(segs):
		var a0 := PI * float(i) / float(segs)
		var a1 := PI * float(i + 1) / float(segs)
		var p0 := Vector2(rect.get_center().x - cos(a0) * rect.size.x * 0.5, rect.position.y + arch_h - sin(a0) * arch_h)
		var p1 := Vector2(rect.get_center().x - cos(a1) * rect.size.x * 0.5, rect.position.y + arch_h - sin(a1) * arch_h)
		p.stroke(PackedVector2Array([p0, p1]), 3.4, {"rng": rng, "amp": 0.3, "overshoot": 1.0, "taper": false})
	p.stroke(PackedVector2Array([rect.position + Vector2(0, arch_h), rect.end - Vector2(0, rect.size.y - arch_h)]), 2.0, {"rng": rng, "amp": 0.5, "taper": false})
	p.stroke(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[4], pts[5], pts[6], pts[7], pts[8], pts[9]]), 2.4, {"rng": rng, "amp": 0.5, "taper": false})


static func window(p: Painter, rect: Rect2, rng: RandomNumberGenerator, warm: bool = false, arch: bool = false, shutters: bool = false) -> void:
	if arch:
		arch_window(p, rect, rng, warm)
		return
	p.poly(_rect_pts(rect), GLOW if warm else DARK_HOLE)
	if warm:
		var inner := Rect2(rect.position + rect.size * 0.18, rect.size * 0.5)
		p.poly(_rect_pts(inner), Color(GLOW_HI.r, GLOW_HI.g, GLOW_HI.b, 0.6))
	p.rect_stroke(rect, 1.8, {"rng": rng, "amp": 0.6})
	p.stroke(PackedVector2Array([Vector2(rect.get_center().x, rect.position.y + 1), Vector2(rect.get_center().x, rect.end.y - 1)]), 1.2, {"rng": rng, "amp": 0.25, "taper": false})
	p.stroke(PackedVector2Array([Vector2(rect.position.x + 1, rect.get_center().y), Vector2(rect.end.x - 1, rect.get_center().y)]), 1.2, {"rng": rng, "amp": 0.25, "taper": false})
	if shutters:
		for side in [-1, 1]:
			var sx := rect.position.x - 6.0 if side < 0 else rect.end.x
			var sr := Rect2(sx, rect.position.y, 6.0, rect.size.y)
			p.face(sr, "wood_dark", "base")
			p.rect_stroke(sr, 1.6, {"rng": rng, "amp": 0.4})
	# 窗台
	var sill := Rect2(rect.position.x - 3, rect.end.y, rect.size.x + 6, 3.5)
	p.face(sill, "trim_white", "shadow")
	p.stroke(PackedVector2Array([sill.position, Vector2(sill.end.x, sill.position.y)]), 1.6, {"rng": rng, "amp": 0.4})


## 拱窗（石/砖拱 + 窗棂）。
static func arch_window(p: Painter, rect: Rect2, rng: RandomNumberGenerator, warm: bool = false) -> void:
	var arch_h := rect.size.x * 0.5
	var body_r := Rect2(rect.position.x, rect.position.y + arch_h, rect.size.x, rect.size.y - arch_h)
	p.poly(_rect_pts(body_r), GLOW if warm else DARK_HOLE)
	var segs := 8
	var pts := PackedVector2Array()
	pts.push_back(Vector2(rect.position.x, rect.position.y + arch_h))
	for i in range(1, segs):
		var a := PI * float(i) / float(segs)
		pts.push_back(Vector2(rect.get_center().x - cos(a) * rect.size.x * 0.5, rect.position.y + arch_h - sin(a) * arch_h))
	pts.push_back(Vector2(rect.end.x, rect.position.y + arch_h))
	p.poly(pts, GLOW if warm else DARK_HOLE)
	p.stroke(pts, 2.6, {"rng": rng, "amp": 0.4, "taper": false})
	p.stroke(PackedVector2Array([Vector2(rect.position.x, rect.position.y + arch_h), Vector2(rect.position.x, rect.end.y)]), 2.0, {"rng": rng, "amp": 0.4, "taper": false})
	p.stroke(PackedVector2Array([Vector2(rect.end.x, rect.position.y + arch_h), Vector2(rect.end.x, rect.end.y)]), 2.0, {"rng": rng, "amp": 0.4, "taper": false})
	# 十字棂
	p.stroke(PackedVector2Array([Vector2(rect.get_center().x, rect.position.y + arch_h - arch_h * 0.6), Vector2(rect.get_center().x, rect.end.y - 1)]), 1.3, {"rng": rng, "amp": 0.2, "taper": false})
	p.stroke(PackedVector2Array([Vector2(rect.position.x + 1, rect.get_center().y + arch_h * 0.3), Vector2(rect.end.x - 1, rect.get_center().y + arch_h * 0.3)]), 1.3, {"rng": rng, "amp": 0.2, "taper": false})


## 玫瑰窗（教堂正立面圆形窗，放射窗棂）。
static func rose_window(p: Painter, center: Vector2, radius: float, rng: RandomNumberGenerator) -> void:
	p.circle(center, radius, DARK_HOLE)
	var rim := 16
	for i in rim:
		var a := TAU * float(i) / float(rim)
		var a2 := TAU * float(i + 1) / float(rim)
		p.stroke(PackedVector2Array([center + Vector2(cos(a), sin(a)) * radius * 0.25, center + Vector2(cos(a), sin(a)) * radius * 0.95]), 1.4, {"rng": rng, "amp": 0.2, "overshoot": 0.0, "taper": false})
		p.stroke(PackedVector2Array([center + Vector2(cos(a), sin(a)) * radius * 0.95, center + Vector2(cos(a2), sin(a2)) * radius * 0.95]), 1.2, {"rng": rng, "amp": 0.2, "overshoot": 0.0, "taper": false})
	p.circle(center, radius * 0.22, p.mat_color("trim_white", "base"))
	p.circle(center, radius, Color(0, 0, 0, 0))
	# 外圈石框
	var ring := PackedVector2Array()
	for i in 26:
		var a := TAU * float(i) / 26.0
		ring.push_back(center + Vector2(cos(a), sin(a)) * (radius + 2.5))
	var ring2 := PackedVector2Array()
	for i in 26:
		var a := TAU * float(i) / 26.0
		ring2.push_back(center + Vector2(cos(a), sin(a)) * (radius - 1.5))
	p.stroke(ring, 2.2, {"rng": rng, "amp": 0.3, "overshoot": 0.0, "taper": false})
	p.stroke(ring2, 1.6, {"rng": rng, "amp": 0.3, "overshoot": 0.0, "taper": false})


## 钟（钟楼内悬挂）。
static func bell(p: Painter, center: Vector2, size: float, rng: RandomNumberGenerator) -> void:
	var pts := PackedVector2Array([
		center + Vector2(-size * 0.16, -size * 0.5),
		center + Vector2(-size * 0.42, size * 0.5),
		center + Vector2(size * 0.42, size * 0.5),
		center + Vector2(size * 0.16, -size * 0.5),
	])
	p.poly(pts, p.mat_color("gold", "base"))
	p.stroke(PackedVector2Array([pts[0], pts[1], pts[2], pts[3]]), 2.0, {"rng": rng, "amp": 0.4})
	p.circle(center + Vector2(0, size * 0.36), size * 0.16, p.mat_color("gold", "shadow"))
	p.stroke(PackedVector2Array([center + Vector2(0, -size * 0.6), center + Vector2(0, -size * 0.42)]), 1.8, {"rng": rng, "amp": 0.2, "overshoot": 0.0, "taper": false})


## 木骨填充开间：抹灰面 + 竖骨/斜撑/横梁。
static func timber_bay(p: Painter, rect: Rect2, mat_trim: String, rng: RandomNumberGenerator) -> void:
	p.face(rect, "daub", "base")
	for fx_v in [0.08, 0.5, 0.92]:
		var fx: float = fx_v
		var x: float = rect.position.x + rect.size.x * fx
		p.stroke(PackedVector2Array([Vector2(x, rect.position.y + 1), Vector2(x + rng.randf_range(-1.5, 1.5), rect.end.y - 1)]), 3.2, {"rng": rng, "amp": 0.5})
	var cy := rect.get_center().y
	p.stroke(PackedVector2Array([Vector2(rect.position.x + rect.size.x * 0.08, cy + rect.size.y * 0.18), Vector2(rect.position.x + rect.size.x * 0.5, cy - rect.size.y * 0.16)]), 2.4, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([Vector2(rect.end.x - rect.size.x * 0.08, cy + rect.size.y * 0.18), Vector2(rect.position.x + rect.size.x * 0.5, cy - rect.size.y * 0.16)]), 2.4, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([Vector2(rect.position.x, rect.position.y + 1.5), Vector2(rect.end.x, rect.position.y + 1.5)]), 3.0, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([Vector2(rect.position.x, rect.end.y - 1.5), Vector2(rect.end.x, rect.end.y - 1.5)]), 3.0, {"rng": rng, "amp": 0.5})


static func blind_bay(p: Painter, rect: Rect2, rng: RandomNumberGenerator) -> void:
	p.stroke(PackedVector2Array([Vector2(rect.position.x, rect.position.y + 2), Vector2(rect.position.x, rect.end.y - 2)]), 1.6, {"rng": rng, "amp": 0.5, "taper": false})
	if rng.randf() < 0.5:
		var s := Rect2(rect.position.x + rng.randf_range(4, maxf(5.0, rect.size.x - 10)), rect.position.y + rng.randf_range(6, maxf(7.0, rect.size.y - 14)), 6, 4)
		p.poly(_rect_pts(s), Color(SHADE.r, SHADE.g, SHADE.b, 0.1))


# ---------- 立面装饰 ----------

static func chimney(p: Painter, body: Rect2, top_y: float, mat: String, rng: RandomNumberGenerator) -> void:
	p.face(body, mat, "base")
	p.rect_stroke(body, 2.0, {"rng": rng, "amp": 0.7})
	var cap := Rect2(body.position - Vector2(3, 4), Vector2(body.size.x + 6, 4))
	p.face(cap, mat, "shadow")
	p.rect_stroke(cap, 1.6, {"rng": rng, "amp": 0.5})
	var cx := body.get_center().x
	p.stroke(PackedVector2Array([Vector2(cx, top_y - 4), Vector2(cx + 4, top_y - 12), Vector2(cx + 1, top_y - 20)]), 1.4, {"rng": rng, "amp": 1.0, "overshoot": 0.0, "color": Color(Ink.INK.r, Ink.INK.g, Ink.INK.b, 0.45), "taper": false})
	eave_shade(p, Rect2(Vector2(body.position.x, top_y), Vector2(body.size.x, 5.0)), 0.12)


## 招牌（横杆 + 木板 + 花纹）。
static func sign_board(p: Painter, anchor: Vector2, side: int, rng: RandomNumberGenerator) -> void:
	var arm := 14.0
	p.stroke(PackedVector2Array([anchor, anchor + Vector2(arm * float(side), 0)]), 2.6, {"rng": rng, "amp": 0.3, "overshoot": 1.0, "taper": false})
	var br := Rect2(anchor + Vector2(arm * float(side) - (10.0 if side > 0 else -4.0), 2.0), Vector2(14.0, 12.0))
	p.face(br, "cloth_red", "base")
	p.rect_stroke(br, 1.8, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([br.position + Vector2(3, 4), br.position + Vector2(11, 4)]), 1.4, {"rng": rng, "amp": 0.3, "taper": false, "color": Ink.INK})
	p.stroke(PackedVector2Array([br.position + Vector2(3, 8), br.position + Vector2(8, 8)]), 1.4, {"rng": rng, "amp": 0.3, "taper": false, "color": Ink.INK})


## 吊灯笼。
static func lantern(p: Painter, anchor: Vector2, rng: RandomNumberGenerator) -> void:
	var y := anchor.y + 14.0
	p.stroke(PackedVector2Array([anchor, Vector2(anchor.x, y)]), 1.4, {"rng": rng, "amp": 0.2, "overshoot": 0.0, "taper": false})
	var body := Rect2(anchor.x - 4.5, y, 9.0, 11.0)
	p.face(body, "iron", "base")
	p.poly(_rect_pts(Rect2(body.position + Vector2(1.5, 2.0), Vector2(6.0, 6.5))), Color(GLOW_HI.r, GLOW_HI.g, GLOW_HI.b, 0.85))
	p.rect_stroke(body, 1.6, {"rng": rng, "amp": 0.3})


## 旗帜（杆 + 三角旗）。
static func flag(p: Painter, base: Vector2, h: float, mat: String, rng: RandomNumberGenerator) -> void:
	p.stroke(PackedVector2Array([base, base + Vector2(0, -h)]), 2.2, {"rng": rng, "amp": 0.3, "overshoot": 1.0, "taper": false})
	var f := PackedVector2Array([
		base + Vector2(0, -h),
		base + Vector2(16.0, -h + 5.0),
		base + Vector2(0, -h + 11.0),
	])
	p.poly(f, p.mat_color(mat, "base"))
	p.stroke(f, 1.8, {"rng": rng, "amp": 0.4})


# ---------- 道具 ----------

## 铁匠炉（参考图核心道具：黑色铁炉 + 橙火 + 顶烟囱）。
static func forge_stove(p: Painter, base: Vector2, s: float, rng: RandomNumberGenerator, chimney_h: float = 0.0) -> void:
	var w := s * 0.62
	# 基座 + 炉身（上收）
	var body := PackedVector2Array([
		Vector2(base.x - w * 0.5, base.y),
		Vector2(base.x - w * 0.42, base.y - s * 0.72),
		Vector2(base.x - w * 0.3, base.y - s),
		Vector2(base.x + w * 0.3, base.y - s),
		Vector2(base.x + w * 0.42, base.y - s * 0.72),
		Vector2(base.x + w * 0.5, base.y),
	])
	p.poly(body, p.mat_color("iron", "base"))
	p.hatch(body, 6.0, 0.0, 0.8, 0.16)
	p.stroke(PackedVector2Array([body[0], body[1], body[2], body[3], body[4], body[5]]), 2.2, {"rng": rng, "amp": 0.4})
	# 拱形炉口 + 火焰
	var mouth := Rect2(base.x - w * 0.24, base.y - s * 0.62, w * 0.48, s * 0.42)
	arch_window(p, mouth, rng, false)
	var flame := PackedVector2Array([
		Vector2(mouth.position.x + 1.0, mouth.end.y - 1.0),
		Vector2(mouth.get_center().x - 2.0, mouth.position.y + 2.0),
		Vector2(mouth.get_center().x + 1.0, mouth.position.y + 1.0),
		Vector2(mouth.end.x - 1.0, mouth.end.y - 1.0),
	])
	p.poly(flame, Color(GLOW.r, GLOW.g, GLOW.b, 0.9))
	p.poly(PackedVector2Array([
		Vector2(mouth.get_center().x - 2.0, mouth.end.y - 1.0),
		Vector2(mouth.get_center().x, mouth.position.y + 3.0),
		Vector2(mouth.get_center().x + 2.5, mouth.end.y - 1.0),
	]), Color(GLOW_HI.r, GLOW_HI.g, GLOW_HI.b, 0.85))
	# 底部炉栅线
	p.stroke(PackedVector2Array([Vector2(base.x - w * 0.5, base.y - 3.0), Vector2(base.x + w * 0.5, base.y - 3.0)]), 1.6, {"rng": rng, "amp": 0.2, "taper": false})
	# 顶烟囱
	var neck := Rect2(base.x - w * 0.12, base.y - s - chimney_h, w * 0.24, chimney_h + 2.0)
	if chimney_h > 0.0:
		p.face(neck, "iron", "shadow")
		p.rect_stroke(neck, 1.8, {"rng": rng, "amp": 0.4})


## 铁砧（黑铁砧 + 木墩）。
static func anvil(p: Painter, base: Vector2, s: float, rng: RandomNumberGenerator) -> void:
	var stump := Rect2(base.x - s * 0.3, base.y - s * 0.5, s * 0.6, s * 0.5)
	p.face(stump, "wood_dark", "base")
	p.rect_stroke(stump, 1.6, {"rng": rng, "amp": 0.4})
	var body_r := Rect2(base.x - s * 0.42, base.y - s * 0.76, s * 0.84, s * 0.26)
	p.face(body_r, "iron", "base")
	p.rect_stroke(body_r, 1.8, {"rng": rng, "amp": 0.4})
	var horn := PackedVector2Array([Vector2(body_r.position.x, body_r.position.y + 2.0), Vector2(body_r.position.x - s * 0.26, body_r.position.y + s * 0.1)])
	p.stroke(horn, 2.4, {"rng": rng, "amp": 0.2, "taper": false})
	p.stroke(PackedVector2Array([body_r.position + Vector2(0, 2), Vector2(body_r.end.x, body_r.position.y + 2)]), 1.4, {"rng": rng, "amp": 0.3, "taper": false, "color": Color(0.75, 0.76, 0.8, 0.5)})


## 长木凳。
static func bench(p: Painter, base: Vector2, w: float, rng: RandomNumberGenerator) -> void:
	var h := w * 0.42
	var top := Rect2(base.x - w * 0.5, base.y - h, w, 4.0)
	p.face(top, "wood", "base")
	p.rect_stroke(top, 1.6, {"rng": rng, "amp": 0.4})
	for sx in [-w * 0.36, w * 0.36]:
		p.stroke(PackedVector2Array([Vector2(base.x + sx, top.end.y), Vector2(base.x + sx + 1.0, base.y)]), 2.6, {"rng": rng, "amp": 0.3, "taper": false})


static func barrel(p: Painter, base: Vector2, h: float, rng: RandomNumberGenerator) -> void:
	var w := h * 0.62
	var b_l := Vector2(base.x - w * 0.5, base.y)
	var t_l := Vector2(base.x - w * 0.38, base.y - h)
	var b_r := Vector2(base.x + w * 0.5, base.y)
	var t_r := Vector2(base.x + w * 0.38, base.y - h)
	var belly_l := Vector2(base.x - w * 0.56, base.y - h * 0.5)
	var belly_r := Vector2(base.x + w * 0.56, base.y - h * 0.5)
	var pts := PackedVector2Array([b_l, belly_l, t_l, t_r, belly_r, b_r])
	p.poly(pts, p.mat_color("wood", "base"))
	p.hatch(pts, 6.0, 90.0, 0.8, 0.14)
	p.stroke(PackedVector2Array([b_l, belly_l, t_l]), 1.8, {"rng": rng, "amp": 0.5, "overshoot": 2.0})
	p.stroke(PackedVector2Array([t_r, belly_r, b_r]), 1.8, {"rng": rng, "amp": 0.5, "overshoot": 2.0})
	p.stroke(PackedVector2Array([t_l, t_r]), 1.6, {"rng": rng, "amp": 0.4, "overshoot": 1.5})
	for fy in [0.32, 0.68]:
		var y: float = base.y - h * float(fy)
		p.stroke(PackedVector2Array([Vector2(base.x - w * 0.47, y), Vector2(base.x + w * 0.47, y)]), 1.5, {"rng": rng, "amp": 0.4, "taper": false})


static func crate(p: Painter, rect: Rect2, rng: RandomNumberGenerator) -> void:
	p.face(rect, "wood", "base")
	p.rect_stroke(rect, 1.8, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([rect.position, rect.end]), 1.4, {"rng": rng, "amp": 0.4})
	p.stroke(PackedVector2Array([Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y)]), 1.4, {"rng": rng, "amp": 0.4})


## 风车叶（四叶十字，格栅面）。
static func windmill_blades(p: Painter, hub: Vector2, length: float, rng: RandomNumberGenerator) -> void:
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var dir := Vector2(cos(a), sin(a))
		var tip := hub + dir * length
		var perp := Vector2(-dir.y, dir.x) * length * 0.19
		var quad := PackedVector2Array([hub + perp * 0.5, tip + perp, tip - perp, hub - perp * 0.5])
		p.poly(quad, p.mat_color("wood", "base"))
		p.stroke(PackedVector2Array([quad[0], quad[1], quad[2], quad[3], quad[0]]), 2.4, {"rng": rng, "amp": 0.4})
		# 叶片格栅（横档 + 纵梁）
		var seg := 4
		for k in range(1, seg + 1):
			var t := float(k) / float(seg + 1)
			var c0 := hub.lerp(tip, t) + perp * (1.0 - t * 0.45)
			var c1 := hub.lerp(tip, t) - perp * (1.0 - t * 0.45)
			p.stroke(PackedVector2Array([c0, c1]), 1.6, {"rng": rng, "amp": 0.3, "overshoot": 0.0, "taper": false})
		p.stroke(PackedVector2Array([hub.lerp(tip, 0.15), hub.lerp(tip, 0.98)]), 1.8, {"rng": rng, "amp": 0.3, "overshoot": 0.0, "taper": false})
	p.circle(hub, 4.5, p.mat_color("iron", "base"))
	p.circle(hub, 2.2, p.mat_color("iron", "shadow"))


## 水井（石圈 + 双柱 + 小顶棚 + 吊桶）。
static func well(p: Painter, base: Vector2, s: float, rng: RandomNumberGenerator) -> void:
	var w := s * 1.1
	var rim := Rect2(base.x - w * 0.5, base.y - s * 0.34, w, s * 0.34)
	p.face(rim, "stone", "base")
	p.rect_stroke(rim, 2.0, {"rng": rng, "amp": 0.5})
	p.poly(_rect_pts(Rect2(rim.position + Vector2(6, 3), Vector2(rim.size.x - 12, rim.size.y - 6))), DARK_HOLE)
	for sx in [-w * 0.4, w * 0.4]:
		p.stroke(PackedVector2Array([Vector2(base.x + sx, rim.position.y + 2), Vector2(base.x + sx, rim.position.y - s * 0.62)]), 2.8, {"rng": rng, "amp": 0.3, "taper": false})
	var roof_q := [Vector2(base.x - w * 0.68, rim.position.y - s * 0.58), Vector2(base.x + w * 0.68, rim.position.y - s * 0.58), Vector2(base.x + w * 0.4, rim.position.y - s * 0.92), Vector2(base.x - w * 0.4, rim.position.y - s * 0.92)]
	p.quad_face([roof_q[0], roof_q[1], roof_q[2], roof_q[3]], "thatch_dry", "base")
	p.stroke(PackedVector2Array([roof_q[0], roof_q[1]]), 2.6, {"rng": rng, "amp": 0.4})
	p.stroke(PackedVector2Array([roof_q[0], roof_q[3]]), 2.0, {"rng": rng, "amp": 0.3, "taper": false})
	p.stroke(PackedVector2Array([roof_q[1], roof_q[2]]), 2.0, {"rng": rng, "amp": 0.3, "taper": false})
	p.stroke(PackedVector2Array([Vector2(base.x, rim.position.y - s * 0.58), Vector2(base.x, rim.position.y - s * 0.24)]), 1.2, {"rng": rng, "amp": 0.2, "overshoot": 0.0, "taper": false})
	var bucket := Rect2(base.x - 4.0, rim.position.y - s * 0.3, 8.0, 8.0)
	p.face(bucket, "wood_dark", "base")
	p.rect_stroke(bucket, 1.4, {"rng": rng, "amp": 0.3})


## 市集摊（条纹棚 + 台面 + 货物）。
static func stall(p: Painter, base: Vector2, w: float, rng: RandomNumberGenerator) -> void:
	var h := w * 0.62
	var legs_h := h * 0.34
	var table := Rect2(base.x - w * 0.5, base.y - legs_h, w, 6.0)
	p.face(table, "wood", "base")
	p.rect_stroke(table, 1.8, {"rng": rng, "amp": 0.4})
	for sx in [-w * 0.44, w * 0.44]:
		p.stroke(PackedVector2Array([Vector2(base.x + sx, table.end.y), Vector2(base.x + sx, base.y)]), 4.0, {"rng": rng, "amp": 0.3, "taper": false})
	# 条纹棚（红白相间）
	var canopy_pts := [Vector2(base.x - w * 0.62, table.position.y - 3.0), Vector2(base.x + w * 0.62, table.position.y - 3.0), Vector2(base.x + w * 0.5, table.position.y - h * 0.62), Vector2(base.x - w * 0.5, table.position.y - h * 0.62)]
	var canopy := PackedVector2Array([canopy_pts[0], canopy_pts[1], canopy_pts[2], canopy_pts[3]])
	p.poly(canopy, p.mat_color("cloth_red", "base"))
	var stripes := 6
	for i in stripes:
		if i % 2 == 1:
			continue
		var t0 := float(i) / float(stripes)
		var t1 := float(i + 1) / float(stripes)
		var a0: Vector2 = Vector2(canopy_pts[0]).lerp(canopy_pts[1], t0)
		var a1: Vector2 = Vector2(canopy_pts[0]).lerp(canopy_pts[1], t1)
		var b0: Vector2 = Vector2(canopy_pts[3]).lerp(canopy_pts[2], t0)
		var b1: Vector2 = Vector2(canopy_pts[3]).lerp(canopy_pts[2], t1)
		p.poly(PackedVector2Array([a0, a1, b1, b0]), p.mat_color("trim_white", "base"))
	p.stroke(canopy, 2.2, {"rng": rng, "amp": 0.4})
	# 货物（圆形果蔬）
	var n := maxi(3, int(w / 14.0))
	for i in n:
		var cx := table.position.x + table.size.x * (float(i) + 0.5) / float(n)
		var cy := table.position.y - 3.0
		var col := p.mat_color("gold", "base") if i % 3 == 0 else (p.mat_color("cloth_red", "base") if i % 3 == 1 else p.mat_color("thatch", "base"))
		p.circle(Vector2(cx, cy), 3.2, col)
		p.stroke(PackedVector2Array([Vector2(cx - 3.2, cy), Vector2(cx + 3.2, cy)]), 1.2, {"rng": rng, "amp": 0.2, "overshoot": 0.5, "taper": false})


## 干草堆。
static func hay_pile(p: Painter, base: Vector2, w: float, rng: RandomNumberGenerator) -> void:
	var h := w * 0.5
	var pts := PackedVector2Array([
		Vector2(base.x - w * 0.5, base.y),
		Vector2(base.x - w * 0.3, base.y - h * 0.8),
		Vector2(base.x, base.y - h),
		Vector2(base.x + w * 0.32, base.y - h * 0.78),
		Vector2(base.x + w * 0.5, base.y),
	])
	p.poly(pts, p.mat_color("thatch", "base"))
	p.hatch(pts, 6.0, -30.0, 0.9, 0.2)
	p.stroke(pts, 2.0, {"rng": rng, "amp": 0.5})


## 木栅栏（竖直桩 + 横梁）。
static func fence(p: Painter, x0: float, x1: float, base_y: float, h: float, rng: RandomNumberGenerator) -> void:
	var x := x0
	while x < x1:
		p.stroke(PackedVector2Array([Vector2(x, base_y), Vector2(x + rng.randf_range(-1.0, 1.0), base_y - h)]), 2.6, {"rng": rng, "amp": 0.4})
		x += rng.randf_range(12.0, 18.0)
	p.stroke(PackedVector2Array([Vector2(x0, base_y - h * 0.7), Vector2(x1, base_y - h * 0.7)]), 1.8, {"rng": rng, "amp": 0.5, "taper": false})


## 接地投影。
static func ground_shadow(p: Painter, cx: float, width: float, baseline: float, strength: float = 1.0) -> void:
	var w := width * 0.92
	var r := Rect2(cx - w * 0.5, baseline - 1.5, w, 4.5)
	p.poly(_rect_pts(r), Color(SHADE.r, SHADE.g, SHADE.b, 0.18 * strength))
