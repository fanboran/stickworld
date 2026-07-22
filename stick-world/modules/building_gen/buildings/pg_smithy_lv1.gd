@tool
extends Building
## 铁匠铺 Lv1 — 程序化纹理版
##
## 自包含建筑场景：拖入场景即可使用。
## 纹理由 procedural_materials.gd 在 _ready() 时生成，不依赖外部贴图文件。

const PM = preload("res://modules/building_gen/scripts/materials/procedural_materials.gd")

# 材质颜色
const C_THATCH_BACK = Color(0.62, 0.50, 0.20)
const C_THATCH_MAIN = Color(0.78, 0.62, 0.28)
const C_THATCH_LEFT = Color(0.70, 0.55, 0.25)
const C_WOOD_FRONT   = Color(0.48, 0.30, 0.15)
const C_WOOD_BACK    = Color(0.38, 0.22, 0.11)
const C_WOOD_BEAM    = Color(0.40, 0.24, 0.12)
const C_WOOD_STRUT   = Color(0.42, 0.26, 0.13)

# 纹理尺寸
const BW_TEX_W = 222; const BW_TEX_H = 102
const BP_TEX_W = 20;  const BP_TEX_H = 197
const FP_TEX_W = 21;  const FP_TEX_H = 246
const BM_TEX_W = 292; const BM_TEX_H = 16
const VS_TEX_W = 23;  const VS_TEX_H = 117
const SS_TEX_W = 144; const SS_TEX_H = 20

func _ready() -> void:
	super()
	_build_exterior()
	_apply_state_visual()


func _build_exterior() -> void:
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	# 只在首次构建（避免编辑器反复重建）
	if ext.get_child_count() > 0:
		return
	# 生成纹理
	var tex_bw   = PM.make_straw_thatch(BW_TEX_W, BW_TEX_H, C_THATCH_BACK)
	var tex_bp   = PM.make_wood_pillar(BP_TEX_W, BP_TEX_H, C_WOOD_BACK)
	var tex_fp   = PM.make_wood_pillar(FP_TEX_W, FP_TEX_H, C_WOOD_FRONT)
	var tex_bm   = PM.make_wood_pillar(BM_TEX_W, BM_TEX_H, C_WOOD_BEAM)
	var tex_vs   = PM.make_wood_pillar(VS_TEX_W, VS_TEX_H, C_WOOD_BEAM)
	var tex_ss   = PM.make_wood_pillar(SS_TEX_W, SS_TEX_H, C_WOOD_STRUT)
	var tex_sb   = _make_slanted_beam_tex(C_WOOD_BEAM)
	var tex_th_main  = PM.make_straw_thatch(64, 64, C_THATCH_MAIN)
	var tex_th_left  = PM.make_straw_thatch(64, 64, C_THATCH_LEFT)

	# ── L1 后景墙壁 ──
	var l1 := _nc("L1_BackWall", ext)
	_a(l1, _poly4("BackWallTop", Vector2(227, -210), Vector2(-53, -210), Vector2(13, -330), Vector2(150, -330), tex_bw))
	_a(l1, _sprite2d("BackPillarL", Vector2(-166, -124), tex_bp))
	_a(l1, _sprite2d("BackPillarR", Vector2(166, -122.5), tex_bp))

	# ── L2 / L3 空层（预留内部物品）──
	_nc("L2_BackItems", ext)
	_nc("L3_FrontItems", ext)

	# ── L4 前景柱 ──
	var l4 := _nc("L4_FrontWall", ext)
	_a(l4, _sprite2d("FrontPillarL", Vector2(-205, -123), tex_fp))
	_a(l4, _sprite2d("FrontPillarM", Vector2(-0.5, -123), tex_fp))
	_a(l4, _sprite2d("FrontPillarR", Vector2(204, -123), tex_fp))

	# ── L5 屋顶 ──
	var l5 := _nc("L5_Roof", ext)
	_a(l5, _sprite2d("SlantedBeam", Vector2(60, -258), tex_sb, 0.712094, Vector2(1, 0.491)))
	_a(l5, _sprite2d("VerticalStrut", Vector2(37.5, -281.5), tex_vs))
	_a(l5, _sprite2d("Beam", Vector2(81, -229), tex_bm))

	var rm_poly: PackedVector2Array = [
		Vector2(59.796,  -346),
		Vector2(164.909, -346),
		Vector2(245.909, -206),
		Vector2(209.909, -206),
		Vector2(194.957, -232),
		Vector2(125.844, -232),
	]
	var rm_uv: PackedVector2Array = [
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(0.75, 1), Vector2(0.65, 0.35), Vector2(0.2, 0.35),
	]
	_a(l5, _poly("RoofMain", rm_poly, rm_uv, tex_th_main))

	_a(l5, _sprite2d("SlantedStrut", Vector2(80.34, -290.65), tex_ss, 1.047))

	var rl1_poly: PackedVector2Array = [
		Vector2(-182, -361), Vector2(59, -361),
		Vector2(-44, -182), Vector2(-285, -182),
	]
	var rl1 := _poly("RoofLeftGroup1", rl1_poly, _full_uv(4), tex_th_left)
	rl1.position = Vector2(-6, 3)
	_a(l5, rl1)


# ── helpers ──

func _nc(name: String, parent: Node2D) -> Node2D:
	var n := Node2D.new()
	n.name = name
	parent.add_child(n)
	return n

func _a(parent: Node, child: Node) -> void:
	parent.add_child(child)

func _sprite2d(name: String, pos: Vector2, tex, rot: float = 0.0, sc: Vector2 = Vector2(1, 1)) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = name; s.centered = true
	s.position = pos; s.texture = tex; s.rotation = rot; s.scale = sc
	return s

func _poly4(name: String, tl: Vector2, tr: Vector2, br: Vector2, bl: Vector2, tex) -> Polygon2D:
	return _poly(name, PackedVector2Array([tl, tr, br, bl]), _full_uv(4), tex)

func _poly(name: String, pts: PackedVector2Array, uvs: PackedVector2Array, tex) -> Polygon2D:
	var p := Polygon2D.new()
	p.name = name; p.polygon = pts; p.uv = uvs; p.texture = tex
	return p

func _full_uv(n: int) -> PackedVector2Array:
	match n:
		4: return PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		6: return PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0.75, 1), Vector2(0.65, 0.35), Vector2(0.2, 0.35)])
	return PackedVector2Array()

func _make_slanted_beam_tex(color: Color):
	var slant  := 64.0
	var height := 110.0
	var length := sqrt(slant * slant + height * height)
	return PM.make_wood_pillar(23, ceili(length), color)
