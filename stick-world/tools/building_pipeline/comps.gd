## 构件库：正面立面建筑构件，全部经 Painter 落笔（1x 图内局部坐标，y 向下）。
## 构件不持有状态；随机性一律走传入 rng 或 p.branch(tag)。
extends RefCounted

const Painter := preload("res://tools/building_pipeline/draw/painter.gd")
const Ink := preload("res://tools/building_pipeline/draw/ink.gd")

const DARK_HOLE := Color(0.145, 0.11, 0.07)     # 门洞/窗洞深色
const GLOW := Color(0.91, 0.58, 0.29)           # 炉火暖光
const SHADE := Color(0.1, 0.08, 0.06)           # 叠加阴影基色


# ---------- 墙体 ----------

static func wall_plane(p: Painter, rect: Rect2, mat: String, face: String = "base", stroke_w: float = 2.4) -> void:
	p.face(rect, mat, face)
	p.tex("dry_brush", rect, 0.22)
	eave_shade(p, Rect2(rect.position, Vector2(rect.size.x, 7.0)), 0.14)
	p.rect_stroke(rect, stroke_w)


## 檐下/顶缘阴影带（水彩叠压感）。
static func eave_shade(p: Painter, band: Rect2, alpha: float = 0.16) -> void:
	if band.size.y <= 0.0:
		return
	p.poly(_rect_pts(band), Color(SHADE.r, SHADE.g, SHADE.b, alpha))


static func _rect_pts(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y),
	])


# ---------- 屋顶 ----------

## 山墙朝前人字顶：三角山墙铺主屋面材质 + 两侧草檐厚带 + 檐底线。
static func gable_roof(p: Painter, body: Rect2, roof: Dictionary, rng: RandomNumberGenerator) -> void:
	var rise := float(roof["rise"])
	var oh := float(roof["overhang"])
	var mat := String(roof["mat"])
	var apex := Vector2(body.get_center().x + rng.randf_range(-2.0, 2.0), body.position.y - rise)
	var bl := Vector2(body.position.x - oh, body.position.y + 2.0)
	var br := Vector2(body.end.x + oh, body.position.y + 2.0)
	# 山墙三角：整体按屋面材质（三角在正面视角下读作"屋顶"）
	var tri := PackedVector2Array([bl, br, apex])
	p.poly(tri, p.mat_color(mat, "base"))
	p.hatch(tri, 9.0, -46.0, 1.2, 0.2)
	# 两侧草檐厚带（沿斜边外側）
	_eave_band(p, bl, apex, 14.0, mat, -1, rng)
	_eave_band(p, br, apex, 14.0, mat, 1, rng)
	# 斜檐外缘线 + 檐底线
	p.stroke(PackedVector2Array([bl + Vector2(-3.0, 1.0), apex + Vector2(-2.0, -2.0)]), 2.6, {"rng": rng})
	p.stroke(PackedVector2Array([br + Vector2(3.0, 1.0), apex + Vector2(2.0, -2.0)]), 2.6, {"rng": rng})
	p.stroke(PackedVector2Array([bl, br]), 3.4, {"rng": rng})
	# 脊顶草束小帽
	p.circle(apex, 2.8, p.mat_color(mat, "shadow"))
	p.stroke(PackedVector2Array([apex + Vector2(-7, -1), apex + Vector2(7, -1)]), 2.2, {"rng": rng, "amp": 0.5, "overshoot": 2.0})


## 坡面朝前屋顶：平行四边形坡面（脊线带水平 skew 的微轴测）+ 檐口。
static func slope_roof(p: Painter, body: Rect2, roof: Dictionary, rng: RandomNumberGenerator) -> void:
	var rise := float(roof["rise"])
	var drop := float(roof["eave_drop"])
	var skew := float(roof["skew"])
	var oh := float(roof["overhang"])
	var mat := String(roof["mat"])
	var eave_l := Vector2(body.position.x - oh, body.position.y + drop)
	var eave_r := Vector2(body.end.x + oh, body.position.y + drop)
	var ridge_l := Vector2(body.position.x - oh + skew, body.position.y - rise)
	var ridge_r := Vector2(body.end.x + oh + skew, body.position.y - rise)
	var quad := [eave_l, eave_r, ridge_r, ridge_l]
	p.quad_face(quad, mat, "shadow")
	# 受光带（坡面中上部横向亮带，打破平板感）
	var lit_l := eave_l.lerp(ridge_l, 0.5)
	var lit_r := eave_r.lerp(ridge_r, 0.5)
	var mid_l := eave_l.lerp(ridge_l, 0.34)
	var mid_r := eave_r.lerp(ridge_r, 0.34)
	var lit_pts := PackedVector2Array([mid_l, mid_r, lit_r, lit_l])
	p.poly(lit_pts, Color(p.mat_color(mat, "lit").r, p.mat_color(mat, "lit").g, p.mat_color(mat, "lit").b, 0.25))
	# 檐口厚线 + 檐口下阴影 + 脊线
	p.stroke(PackedVector2Array([eave_l, eave_r]), 3.4, {"rng": rng})
	eave_shade(p, Rect2(Vector2(body.position.x, body.position.y + drop), Vector2(body.size.x + oh * 2.0, 7.0)), 0.22)
	p.stroke(PackedVector2Array([ridge_l, ridge_r]), 2.4, {"rng": rng, "amp": 0.8})
	# 坡面竖向纹理分割（薄板缝笔触）
	var n := maxi(2, int(body.size.x / 56.0))
	for i in range(1, n):
		var t := float(i) / float(n)
		var a := eave_l.lerp(eave_r, t)
		var b := ridge_l.lerp(ridge_r, t)
		p.stroke(PackedVector2Array([a.lerp(b, 0.12), b]), 1.4, {"rng": rng, "amp": 0.5, "overshoot": 1.0, "taper": false})


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
	p.stroke(PackedVector2Array([a, b]), 2.2, {"rng": rng, "amp": 0.7})
	p.stroke(PackedVector2Array([a + nrm * band_w, b + nrm * band_w]), 1.8, {"rng": rng, "amp": 0.7})


# ---------- 开口 ----------

static func door(p: Painter, rect: Rect2, mat: String, rng: RandomNumberGenerator, wide: bool = false) -> void:
	p.face(rect, mat, "shadow")
	# 门板竖缝
	var splits := 1 if wide else 1
	if wide:
		splits = 2
	for i in range(1, splits + 1):
		var x := rect.position.x + rect.size.x * float(i) / float(splits + 1)
		p.stroke(PackedVector2Array([Vector2(x, rect.position.y + 2), Vector2(x, rect.end.y - 1)]), 1.4, {"rng": rng, "amp": 0.4, "taper": false})
	# 斜撑（大门）
	if wide:
		p.stroke(PackedVector2Array([rect.position + Vector2(2, rect.size.y * 0.72), rect.end - Vector2(2, rect.size.y * 0.18)]), 1.6, {"rng": rng, "amp": 0.5})
	# 框线 + 门楣 + 把手
	p.rect_stroke(rect, 2.0, {"rng": rng})
	var lintel := Rect2(rect.position - Vector2(4, 6), Vector2(rect.size.x + 8, 6))
	p.face(lintel, mat, "shadow")
	p.rect_stroke(lintel, 1.8, {"rng": rng, "amp": 0.6})
	p.circle(Vector2(rect.end.x - rect.size.x * 0.22, rect.get_center().y + 2.0), 1.8, Ink.INK)


static func window(p: Painter, rect: Rect2, rng: RandomNumberGenerator, warm_light: bool = false) -> void:
	p.poly(_rect_pts(rect), GLOW if warm_light else DARK_HOLE)
	if warm_light:
		var inner := Rect2(rect.position + rect.size * 0.18, rect.size * 0.5)
		p.poly(_rect_pts(inner), Color(0.97, 0.78, 0.42, 0.55))
	p.rect_stroke(rect, 1.8, {"rng": rng, "amp": 0.7})
	# 十字棂
	p.stroke(PackedVector2Array([Vector2(rect.get_center().x, rect.position.y + 1), Vector2(rect.get_center().x, rect.end.y - 1)]), 1.2, {"rng": rng, "amp": 0.3, "taper": false})
	p.stroke(PackedVector2Array([Vector2(rect.position.x + 1, rect.get_center().y), Vector2(rect.end.x - 1, rect.get_center().y)]), 1.2, {"rng": rng, "amp": 0.3, "taper": false})
	# 窗台
	var sill := Rect2(rect.position.x - 3, rect.end.y, rect.size.x + 6, 3.5)
	p.face(sill, "timber", "shadow")
	p.stroke(PackedVector2Array([sill.position, Vector2(sill.end.x, sill.position.y)]), 1.6, {"rng": rng, "amp": 0.4})


## 木骨填充开间：抹灰面 + 竖骨/斜撑/横梁。
static func timber_bay(p: Painter, rect: Rect2, mat_trim: String, rng: RandomNumberGenerator) -> void:
	p.face(rect, "daub", "base")
	# 竖骨
	for fx_v in [0.08, 0.5, 0.92]:
		var fx: float = fx_v
		var x: float = rect.position.x + rect.size.x * fx
		p.stroke(PackedVector2Array([Vector2(x, rect.position.y + 1), Vector2(x + rng.randf_range(-1.5, 1.5), rect.end.y - 1)]), 3.2, {"rng": rng, "amp": 0.5})
	# 斜撑（人字）
	var cy := rect.get_center().y
	p.stroke(PackedVector2Array([Vector2(rect.position.x + rect.size.x * 0.08, cy + rect.size.y * 0.18), Vector2(rect.position.x + rect.size.x * 0.5, cy - rect.size.y * 0.16)]), 2.4, {"rng": rng, "amp": 0.6})
	p.stroke(PackedVector2Array([Vector2(rect.end.x - rect.size.x * 0.08, cy + rect.size.y * 0.18), Vector2(rect.position.x + rect.size.x * 0.5, cy - rect.size.y * 0.16)]), 2.4, {"rng": rng, "amp": 0.6})
	# 顶底横梁
	p.stroke(PackedVector2Array([Vector2(rect.position.x, rect.position.y + 1.5), Vector2(rect.end.x, rect.position.y + 1.5)]), 3.0, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([Vector2(rect.position.x, rect.end.y - 1.5), Vector2(rect.end.x, rect.end.y - 1.5)]), 3.0, {"rng": rng, "amp": 0.5})


## 盲开间（实墙）：仅一道分隔缝 + 少量斑点。
static func blind_bay(p: Painter, rect: Rect2, rng: RandomNumberGenerator) -> void:
	p.stroke(PackedVector2Array([Vector2(rect.position.x, rect.position.y + 2), Vector2(rect.position.x, rect.end.y - 2)]), 1.6, {"rng": rng, "amp": 0.5, "taper": false})
	if rng.randf() < 0.5:
		var s := Rect2(rect.position.x + rng.randf_range(4, rect.size.x - 10), rect.position.y + rng.randf_range(6, rect.size.y - 14), 6, 4)
		p.poly(_rect_pts(s), Color(SHADE.r, SHADE.g, SHADE.b, 0.1))


# ---------- 立面道具 ----------

static func chimney(p: Painter, body: Rect2, top_y: float, mat: String, rng: RandomNumberGenerator) -> void:
	p.face(body, mat, "base")
	p.rect_stroke(body, 2.0, {"rng": rng, "amp": 0.8})
	# 顶帽
	var cap := Rect2(body.position - Vector2(3, 4), Vector2(body.size.x + 6, 4))
	p.face(cap, mat, "shadow")
	p.rect_stroke(cap, 1.6, {"rng": rng, "amp": 0.5})
	# 烟一缕（两笔弧线）
	var cx := body.get_center().x
	p.stroke(PackedVector2Array([Vector2(cx, top_y - 4), Vector2(cx + 4, top_y - 12), Vector2(cx + 1, top_y - 20)]), 1.4, {"rng": rng, "amp": 1.2, "overshoot": 0.0, "color": Color(Ink.INK.r, Ink.INK.g, Ink.INK.b, 0.5), "taper": false})
	# 与坡面交接的阴影
	eave_shade(p, Rect2(Vector2(body.position.x, top_y), Vector2(body.size.x, 5.0)), 0.12)


static func barrel(p: Painter, base: Vector2, h: float, rng: RandomNumberGenerator) -> void:
	var w := h * 0.62
	# 鼓形轮廓：两端内收、腹部外凸（左右侧各一段三点折线）
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
	# 顶口
	p.stroke(PackedVector2Array([t_l, t_r]), 1.6, {"rng": rng, "amp": 0.4, "overshoot": 1.5})
	for fy in [0.32, 0.68]:
		var y: float = base.y - h * fy
		p.stroke(PackedVector2Array([Vector2(base.x - w * 0.47, y), Vector2(base.x + w * 0.47, y)]), 1.5, {"rng": rng, "amp": 0.4, "taper": false})


static func crate(p: Painter, rect: Rect2, rng: RandomNumberGenerator) -> void:
	p.face(rect, "wood", "base")
	p.rect_stroke(rect, 1.8, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([rect.position, rect.end]), 1.4, {"rng": rng, "amp": 0.4})
	p.stroke(PackedVector2Array([Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y)]), 1.4, {"rng": rng, "amp": 0.4})


## 炉口：拱形深洞 + 内焰。
static func forge_mouth(p: Painter, rect: Rect2, rng: RandomNumberGenerator) -> void:
	var top := rect.position.y + rect.size.y * 0.3
	var pts := PackedVector2Array([
		rect.position,
		Vector2(rect.position.x, top),
		Vector2(rect.position.x + rect.size.x * 0.25, rect.position.y + 2),
		Vector2(rect.end.x - rect.size.x * 0.25, rect.position.y + 2),
		Vector2(rect.end.x, top),
		rect.end,
	])
	p.poly(pts, DARK_HOLE)
	var flame := Rect2(rect.position.x + rect.size.x * 0.22, rect.position.y + rect.size.y * 0.55, rect.size.x * 0.56, rect.size.y * 0.38)
	p.poly(_rect_pts(flame), Color(GLOW.r, GLOW.g, GLOW.b, 0.8))
	p.stroke(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[4], pts[5]]), 2.0, {"rng": rng, "amp": 0.6})


## 铁砧（台座 + 砧体）。
static func anvil(p: Painter, base: Vector2, s: float, rng: RandomNumberGenerator) -> void:
	var stump := Rect2(base.x - s * 0.4, base.y - s * 0.55, s * 0.8, s * 0.55)
	p.face(stump, "dark_wood", "shadow")
	p.rect_stroke(stump, 1.6, {"rng": rng, "amp": 0.4})
	var body_r := Rect2(base.x - s * 0.55, base.y - s * 0.85, s * 1.1, s * 0.34)
	p.face(body_r, "iron", "base")
	p.rect_stroke(body_r, 1.6, {"rng": rng, "amp": 0.4})
	var horn := PackedVector2Array([Vector2(base.x - s * 0.55, base.y - s * 0.8), Vector2(base.x - s * 0.85, base.y - s * 0.68)])
	p.stroke(horn, 2.6, {"rng": rng, "amp": 0.3, "taper": false})
