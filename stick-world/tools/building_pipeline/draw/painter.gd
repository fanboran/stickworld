## 画笔上下文：绘制域统一 API（块面 / 墨线 / 质感纹理 / 排线）+ 全库材质表。
## 在渲染域 Node2D 的 _draw() 回调内使用；构件层只经此 API 落笔。
extends RefCounted

const Ink := preload("res://tools/building_pipeline/draw/ink.gd")
const TextureBank := preload("res://tools/building_pipeline/draw/texture_bank.gd")

## 材质四档色（shadow/base/lit/hi）+ 默认质感纹理与叠加透明度。
## 取色基线：assets/_raw/建筑/smithy.png 参考图（茅草金黄 / 红棕木 / 亮灰石 / 红砖白饰）。
const MATS := {
	"thatch": {"shadow": Color("a8762f"), "base": Color("cf9a45"), "lit": Color("e6b95e"), "hi": Color("f5d98f"), "tex": "thatch", "tex_a": 0.8},
	"thatch_dry": {"shadow": Color("7d5c2c"), "base": Color("a07a3c"), "lit": Color("bd9552"), "hi": Color("d4b06a"), "tex": "thatch", "tex_a": 0.7},
	"wood": {"shadow": Color("5e3519"), "base": Color("87522a"), "lit": Color("a86c37"), "hi": Color("c4884b"), "tex": "wood_grain", "tex_a": 0.6},
	"wood_dark": {"shadow": Color("3f2410"), "base": Color("5c381c"), "lit": Color("7a4c26"), "hi": Color("96633a"), "tex": "wood_grain", "tex_a": 0.55},
	"dark_wood": {"shadow": Color("3f2410"), "base": Color("5c381c"), "lit": Color("7a4c26"), "hi": Color("96633a"), "tex": "wood_grain", "tex_a": 0.55},
	"roof_wood": {"shadow": Color("4b2c14"), "base": Color("6b4423"), "lit": Color("8a5a2f"), "hi": Color("a87540"), "tex": "wood_grain", "tex_a": 0.55},
	"timber": {"shadow": Color("33200f"), "base": Color("4a3116"), "lit": Color("63431f"), "hi": Color("7d5729"), "tex": "wood_grain", "tex_a": 0.4},
	"plaster": {"shadow": Color("b9a886"), "base": Color("d8c9a8"), "lit": Color("ecdfc0"), "hi": Color("f7efd9"), "tex": "plaster_noise", "tex_a": 0.5},
	"daub": {"shadow": Color("9a8a6a"), "base": Color("b5a582"), "lit": Color("cfc09a"), "hi": Color("e2d6b2"), "tex": "plaster_noise", "tex_a": 0.4},
	"stone": {"shadow": Color("6a6861"), "base": Color("918f87"), "lit": Color("b2b0a6"), "hi": Color("cdcbc0"), "tex": "stone_block", "tex_a": 0.65},
	"stone_light": {"shadow": Color("8d8b83"), "base": Color("b6b3a8"), "lit": Color("d5d2c6"), "hi": Color("eae7db"), "tex": "stone_block", "tex_a": 0.6},
	"stone_dark": {"shadow": Color("4e4c47"), "base": Color("6e6c65"), "lit": Color("8b8981"), "hi": Color("a5a39b"), "tex": "stone_block", "tex_a": 0.6},
	"brick": {"shadow": Color("8f3f2c"), "base": Color("bd5a3c"), "lit": Color("d4785a"), "hi": Color("e59a80"), "tex": "brick", "tex_a": 0.65},
	"trim_white": {"shadow": Color("bfb8a6"), "base": Color("ddd6c4"), "lit": Color("efe9da"), "hi": Color("faf6ec"), "tex": "plaster_noise", "tex_a": 0.35},
	"slate": {"shadow": Color("454852"), "base": Color("5f626c"), "lit": Color("7b7e88"), "hi": Color("969aa4"), "tex": "slate", "tex_a": 0.65},
	"tile": {"shadow": Color("6f3325"), "base": Color("934634"), "lit": Color("ae5c45"), "hi": Color("c6785e"), "tex": "tile", "tex_a": 0.65},
	"iron": {"shadow": Color("1e1e22"), "base": Color("32323a"), "lit": Color("4a4a54"), "hi": Color("62626c"), "tex": "dry_brush", "tex_a": 0.4},
	"cloth_red": {"shadow": Color("7a2f28"), "base": Color("a03f34"), "lit": Color("bd5a45"), "hi": Color("d07862"), "tex": "dry_brush", "tex_a": 0.3},
	"gold": {"shadow": Color("8a6a24"), "base": Color("b8903a"), "lit": Color("d8b054"), "hi": Color("eacd7e"), "tex": "dry_brush", "tex_a": 0.25},
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
