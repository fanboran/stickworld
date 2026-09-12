## 画笔上下文：绘制域统一 API（块面 / 墨线 / 质感纹理 / 排线）+ 全库材质表。
## 在渲染域 Node2D 的 _draw() 回调内使用；构件层只经此 API 落笔。
extends RefCounted

const Ink := preload("res://tools/building_pipeline/draw/ink.gd")
const TextureBank := preload("res://tools/building_pipeline/draw/texture_bank.gd")

## 材质四档色（shadow/base/lit/hi）+ 默认质感纹理与叠加透明度。
const MATS := {
	"thatch": {"shadow": Color("7a5c34"), "base": Color("a07c46"), "lit": Color("c2a05e"), "hi": Color("e0c88a"), "tex": "thatch", "tex_a": 0.75},
	"wood": {"shadow": Color("5a4026"), "base": Color("7d5c36"), "lit": Color("a37d4e"), "hi": Color("c8a468"), "tex": "plank", "tex_a": 0.45},
	"roof_wood": {"shadow": Color("43301b"), "base": Color("63492b"), "lit": Color("836339"), "hi": Color("a5824f"), "tex": "plank", "tex_a": 0.5},
	"dark_wood": {"shadow": Color("3d2c18"), "base": Color("56401f"), "lit": Color("74572e"), "hi": Color("937445"), "tex": "plank", "tex_a": 0.4},
	"timber": {"shadow": Color("3a2b1b"), "base": Color("54402a"), "lit": Color("71572f"), "hi": Color("8f7040"), "tex": "dry_brush", "tex_a": 0.3},
	"stone": {"shadow": Color("6a655d"), "base": Color("8c867b"), "lit": Color("aca698"), "hi": Color("cdc7b8"), "tex": "stone_courses", "tex_a": 0.55},
	"plaster": {"shadow": Color("b8ac93"), "base": Color("d3c8ae"), "lit": Color("e8dfc8"), "hi": Color("f6efdd"), "tex": "plaster_noise", "tex_a": 0.5},
	"daub": {"shadow": Color("9a8a6a"), "base": Color("b5a582"), "lit": Color("cfc09a"), "hi": Color("e2d6b2"), "tex": "plaster_noise", "tex_a": 0.4},
	"iron": {"shadow": Color("3a3a3e"), "base": Color("54545a"), "lit": Color("727279"), "hi": Color("95959c"), "tex": "dry_brush", "tex_a": 0.35},
}

var ci: CanvasItem
var rng: RandomNumberGenerator
var base_seed: int = 0


func _init(canvas_item: CanvasItem, seed_val: int) -> void:
	ci = canvas_item
	base_seed = seed_val
	rng = branch("root")


## 从 (base_seed, tag) 派生确定性子随机流——同 spec 双跑一致的关键。
func branch(tag: String) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([base_seed, tag])
	return r


# ---------- 基础原语 ----------

func poly(pts: PackedVector2Array, color: Color) -> void:
	if pts.size() >= 3:
		ci.draw_colored_polygon(pts, color)


func stroke(pts: PackedVector2Array, width: float, opts: Dictionary = {}) -> void:
	Ink.stroke(ci, pts, width, opts.get("rng", rng), opts)


func rect_stroke(r: Rect2, width: float, opts: Dictionary = {}) -> void:
	Ink.rect(ci, r, width, opts.get("rng", rng), opts)


func circle(c: Vector2, radius: float, color: Color) -> void:
	ci.draw_circle(c, radius, color)


## 凸多边形内排线。
func hatch(pts: PackedVector2Array, spacing: float, angle_deg: float, width: float = 1.0, alpha: float = 0.22, branch_tag: String = "") -> void:
	var r := branch("hatch_" + branch_tag) if branch_tag != "" else rng
	Ink.hatch_in_poly(ci, pts, spacing, angle_deg, width, r, alpha)


# ---------- 质感纹理 ----------

## 矩形区域平铺质感纹理（tile + repeat，安全采样路径）。
func tex(kind: String, rect: Rect2, alpha: float = 0.5, tint: Color = Color(1, 1, 1)) -> void:
	if rect.size.x < 2.0 or rect.size.y < 2.0:
		return
	var t := TextureBank.get_tex(kind)
	ci.draw_texture_rect(t, rect, true, Color(tint.r, tint.g, tint.b, tint.a * alpha))


## 平行四边形仿射贴纹理：quad = [p0, p1, p2, p3] 顺时针（p0 左下起），
## 要求平行四边形（p3 = p0 + p2 - p1），纹理以 64px 周期随变换平铺。
func quad_tex(kind: String, quad: Array, alpha: float = 0.5, tint: Color = Color(1, 1, 1)) -> void:
	var p0: Vector2 = quad[0]
	var p1: Vector2 = quad[1]
	var p2: Vector2 = quad[2]
	var p3: Vector2 = quad[3]
	var ex := p1 - p0
	var ey := p3 - p0
	if ex.length() < 2.0 or ey.length() < 2.0:
		return
	var w := ex.length()
	var h := ey.length()
	var xform := Transform2D(ex / w, ey / h, p0)
	var t := TextureBank.get_tex(kind)
	ci.draw_set_transform_matrix(xform)
	ci.draw_texture_rect(t, Rect2(0, 0, w, h), true, Color(tint.r, tint.g, tint.b, tint.a * alpha))
	ci.draw_set_transform_matrix(Transform2D())


# ---------- 组合面 ----------

## 材质墙面：底色块面 + 质感纹理。face ∈ "shadow"|"base"|"lit"。
## 不自动描边（构件层用 rect_stroke 决定框线层级）。
func face(rect: Rect2, mat: String, face_kind: String = "base", tex_alpha: float = -1.0) -> void:
	var m: Dictionary = MATS[mat]
	var col: Color = m[face_kind]
	poly(_rect_pts(rect), col)
	var tex_kind: String = m["tex"]
	var a: float = m["tex_a"] if tex_alpha < 0.0 else tex_alpha
	tex(tex_kind, rect, a)


## 平行四边形材质面（斜屋顶坡面）：底色用分档色横带近似 + 仿射质感纹理。
func quad_face(quad: Array, mat: String, face_kind: String = "base") -> void:
	var m: Dictionary = MATS[mat]
	var col: Color = m[face_kind]
	var pts := PackedVector2Array()
	for q in quad:
		pts.push_back(q)
	poly(pts, col)
	quad_tex(m["tex"], quad, m["tex_a"])


func mat_color(mat: String, face_kind: String) -> Color:
	return MATS[mat][face_kind]


static func _rect_pts(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	])
