## 画笔上下文：绘制域统一 API（块面 / 墨线 / 质感纹理 / 排线）+ 全库材质表。
## 在渲染域 Node2D 的 _draw() 回调内使用；构件层只经此 API 落笔。
extends RefCounted

const Ink := preload("res://tools/building_pipeline/draw/ink.gd")
const TextureBank := preload("res://tools/building_pipeline/draw/texture_bank.gd")

## 材质四档色（shadow/base/lit/hi）+ 默认质感纹理与叠加透明度。
## 取色基线：assets/_raw/建筑/smithy.png 参考图（茅草金黄 / 红棕木 / 亮灰石 / 红砖白饰）。
const MATS := {
	"thatch": {"shadow": Color("8f6520"), "base": Color("c69240"), "lit": Color("e0b45c"), "hi": Color("f2d489"), "tex": "thatch", "tex_a": 0.85},
	"thatch_dry": {"shadow": Color("6f5520"), "base": Color("9c7c34"), "lit": Color("b8964a"), "hi": Color("d0b064"), "tex": "thatch", "tex_a": 0.75},
	"straw_old": {"shadow": Color("5e4a1e"), "base": Color("876c2e"), "lit": Color("a48840"), "hi": Color("c0a458"), "tex": "straw_dark", "tex_a": 0.85},
	"wood": {"shadow": Color("4a2a12"), "base": Color("7a4a22"), "lit": Color("a06432"), "hi": Color("c08248"), "tex": "wood_grain", "tex_a": 0.7},
	"wood_dark": {"shadow": Color("331d0b"), "base": Color("523218"), "lit": Color("6e4622"), "hi": Color("8a5c30"), "tex": "wood_grain", "tex_a": 0.65},
	"dark_wood": {"shadow": Color("331d0b"), "base": Color("523218"), "lit": Color("6e4622"), "hi": Color("8a5c30"), "tex": "wood_grain", "tex_a": 0.65},
	"roof_wood": {"shadow": Color("3d2411"), "base": Color("64401e"), "lit": Color("865826"), "hi": Color("a87438"), "tex": "plank", "tex_a": 0.65},
	"timber": {"shadow": Color("2a1808"), "base": Color("422810"), "lit": Color("5c3a1a"), "hi": Color("764e24"), "tex": "wood_grain", "tex_a": 0.5},
	"plaster": {"shadow": Color("a5936c"), "base": Color("cdb98c"), "lit": Color("e6d6ac"), "hi": Color("f5eacc"), "tex": "lime", "tex_a": 0.55},
	"daub": {"shadow": Color("8d7c58"), "base": Color("b0a077"), "lit": Color("cfc094"), "hi": Color("e2d6b0"), "tex": "lime", "tex_a": 0.45},
	"stone": {"shadow": Color("5c5a54"), "base": Color("87857c"), "lit": Color("a8a598"), "hi": Color("c6c3b4"), "tex": "stone", "tex_a": 0.75},
	"stone_light": {"shadow": Color("7e7c74"), "base": Color("ada99e"), "lit": Color("cfcabc"), "hi": Color("e8e3d4"), "tex": "stone_light", "tex_a": 0.7},
	"stone_dark": {"shadow": Color("403e3a"), "base": Color("5f5d57"), "lit": Color("7c7a72"), "hi": Color("96948a"), "tex": "stone_dark", "tex_a": 0.7},
	"brick": {"shadow": Color("8c3e28"), "base": Color("c05c3e"), "lit": Color("de7a58"), "hi": Color("f0a081"), "tex": "brick", "tex_a": 0.7},
	"trim_white": {"shadow": Color("b0a894"), "base": Color("d8d0ba"), "lit": Color("eee7d4"), "hi": Color("faf6ec"), "tex": "lime", "tex_a": 0.4},
	"slate": {"shadow": Color("3a3d46"), "base": Color("565962"), "lit": Color("767a84"), "hi": Color("969aa4"), "tex": "slate", "tex_a": 0.75},
	"tile": {"shadow": Color("5e2a1c"), "base": Color("8c422a"), "lit": Color("ac5636"), "hi": Color("c8785a"), "tex": "tile", "tex_a": 0.75},
	"iron": {"shadow": Color("17171a"), "base": Color("2b2b31"), "lit": Color("42424a"), "hi": Color("5a5a64"), "tex": "dry_brush", "tex_a": 0.45},
	"hemp": {"shadow": Color("8d8268"), "base": Color("b8ab8c"), "lit": Color("d2c6a8"), "hi": Color("e6dcc2"), "tex": "hemp", "tex_a": 0.7},
	"cloth_red": {"shadow": Color("6b2620"), "base": Color("98382c"), "lit": Color("b45440"), "hi": Color("cc7460"), "tex": "hemp", "tex_a": 0.4},
	"gold": {"shadow": Color("7a5c1c"), "base": Color("b08832"), "lit": Color("d4ac50"), "hi": Color("e8ca78"), "tex": "dry_brush", "tex_a": 0.25},
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
