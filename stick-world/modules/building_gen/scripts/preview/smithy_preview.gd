@tool
extends Node2D

## 铁匠铺参数化构建器 — smithy_reference.tscn 精确参数版
##
## 约束：
## 1. 所有屋顶平行四边形斜边 60°（slant ≈ height / tan60）
## 2. 只拉伸 RoofMain(dw)、BackWall(宽度)、Beam(长度) 三片
## 3. 左堵头固定：RL1, BP_L, FP_left, @Sprite2D@48784, SlantedStrut, SlantedBeam, VerticalStrut, BackWallTop
## 4. 右堵头位置跟随 RR：BP_R, FP_right

const PM = preload("res://modules/building_gen/scripts/materials/procedural_materials.gd")

const REF_CELLS  = 7
const META_WIDTH = "_bw"

# --- 材质 ---
const M_THATCH_BACK  = Color(0.62, 0.50, 0.20)
const M_THATCH_RIGHT = Color(0.68, 0.55, 0.23)
const M_THATCH_MAIN  = Color(0.78, 0.62, 0.28)
const M_THATCH_LEFT  = Color(0.70, 0.55, 0.25)
const M_WOOD_FRONT_P = Color(0.48, 0.30, 0.15)
const M_WOOD_BACK_P  = Color(0.38, 0.22, 0.11)
const M_WOOD_BEAM    = Color(0.40, 0.24, 0.12)

# --- 建筑参数 ---
@export var width_cells: int = 7

func _set(property: StringName, value) -> bool:
	if property == &"width_cells":
		var v = clampi(value, 3, 18)
		if width_cells == v: return true
		width_cells = v
		if is_node_ready() and Engine.is_editor_hint():
			_clear_building()
			_build()
		return true
	return false

# ============================================================
# 参考几何（来自 smithy_reference.tscn）
# ============================================================

# RoofLeftGroup1 — 左侧端盖（完全固定）
const RL1_BL     = Vector2(-285, -182)
const RL1_SLANT  = 103.0
const RL1_DW     = 241.0
const RL1_TY     = -361.0
const RL1_POS    = Vector2(-6, 3)

# RoofMain — 中间可拉伸（只拉伸 dw）
const RM_BL_X    = 103.0
const RM_BL_Y    = -232.0        # 下边缘略下延 4px
const RM_SLANT   = 64.0          # 60°: 110 / tan60 ≈ 63.5
const RM_TY      = -346.0
const RM_REF_DW  = 87.17         # 参考底边宽
const RM_POS     = Vector2(-1.258, 0)
const RM_SCALE   = Vector2(1.032, 1)
# RM.tr(world) 参考值: ((39+87.17-1.258)*1.032, -346) = (128.91, -346)
const RM_TR_WORLD_REF_X = 128.91

# RoofRightEnd — 右侧端盖（形状固定，位置跟随 RM 右端）
const RR_SLANT   = 81.0          # 60°: 140 / tan60 ≈ 80.8
const RR_DW      = 36.0
const RR_TY      = -346.0
const RR_BL_Y    = -206.0

# ============================================================
# 左堵头（固定不动）
# ============================================================

# BackPillarL
const BP_LEFT  = Vector2(-166, -124)
const BP_TEX_W = 20
const BP_TEX_H = 197

# 斜梁 SlantedBeam
const SB_POS     = Vector2(60, -258)
const SB_ROT     = 0.712094
const SB_SCALE_Y = 0.491

# 竖支柱
const VS_POS   = Vector2(37.5, -281.5)
const VS_TEX_W = 23
const VS_TEX_H = 117

# 斜支柱 SlantedStrut — 左上角锚定 RL1 右上角 (53,-358)，下延至触及 Beam
# 144px @60°: 左上偏移 (-27.34,-67.35), 中心 = (80.34, -290.65)
const SS_POS   = Vector2(80.34, -290.65)
const SS_ROT   = 1.047
const SS_TEX_W = 144
const SS_TEX_H = 20

# BackWallTop
const BW_TOP_POS   = Vector2(36.375, -312.375)
const BW_TOP_SCALE = Vector2(0.492, 0.537)
const BW_TOP_TEX_W = 222
const BW_TOP_TEX_H = 102

# 前景柱（左侧两个固定）
const FP_LEFT_POS  = Vector2(-205, -123)
const FP_MID_POS   = Vector2(-0.5, -123)   # @Sprite2D@48784
const FP_TEX_W     = 21
const FP_TEX_H     = 246

# ============================================================
# 右堵头（参考位置，随宽度平移）
# ============================================================
const BP_RIGHT_REF_X = 166.0
const BP_RIGHT_Y     = -122.5
const FP_RIGHT_REF_X = 204.0
const FP_Y           = -123.0

# ============================================================
# 可拉伸元素 — 参考值
# ============================================================

# BackWall: 左边缘 = 83 - 222*1.027/2 ≈ -31
const BW_LEFT_EDGE    = -31.0
const BW_REF_HALF_W   = 114.0     # 222 * 1.027 / 2
const BW_Y             = -250.5
const BW_SCALE_Y       = 0.755

# Beam: 右端不超出 RR 右侧边。RR 右边界在 y=-237 处 x≈228，Beam 右端 ≤228
const BEAM_LEFT_EDGE   = -65.0
const BEAM_REF_HALF_W  = 146.0        # (-65 + 2*146 = 227 < 228)
const BEAM_Y           = -229.0
const BEAM_TEX_H       = 16

# 辅助线
const GUIDE_COLORS  = [Color(0.85,0.65,0.35), Color(0.55,0.85,0.55), Color(0.35,0.55,0.85), Color(0.85,0.35,0.35)]
const GUIDE_LEFT     = -248
const GUIDE_BASE_Y   = -24.0


func _ready():
	if Engine.is_editor_hint():
		if not has_node("L1_BackWall") or get_meta(META_WIDTH, -1) != width_cells:
			_clear_building()
			_build()
		return
	var cam = Camera2D.new()
	cam.name = "Camera"; cam.position = Vector2(0, -200); cam.enabled = true
	add_child(cam)


func _clear_building():
	for child in get_children():
		if child is Camera2D: continue
		remove_child(child)
		child.queue_free()


func _ss(ref_w: float) -> float:
	return ref_w * float(width_cells) / REF_CELLS


func _build():
	set_meta(META_WIDTH, width_cells)
	var s = float(width_cells) / REF_CELLS

	# ── 屋顶几何 ──
	var rm_dw = _ss(RM_REF_DW)

	# RM 局部坐标（匹配参考：bl=(103,-236), tl=(39,-346)）
	var rm_tl = Vector2(RM_BL_X - RM_SLANT, RM_TY)
	var rm_tr = Vector2(RM_BL_X - RM_SLANT + rm_dw, RM_TY)
	var rm_br = Vector2(RM_BL_X + rm_dw, RM_BL_Y)
	var rm_bl = Vector2(RM_BL_X, RM_BL_Y)

	# RM 右端世界坐标
	var rm_tr_wx = (rm_tr.x + RM_POS.x) * RM_SCALE.x

	# 右堵头平移量
	var shift = rm_tr_wx - RM_TR_WORLD_REF_X

	# RoofRightEnd — tl 贴合 RM.tr(world)
	var rr_tl = Vector2(rm_tr_wx, RR_TY)
	var rr_bl = Vector2(rr_tl.x + RR_SLANT, RR_BL_Y)
	var rr_tr = Vector2(rr_tl.x + RR_DW, RR_TY)
	var rr_br = Vector2(rr_bl.x + RR_DW, RR_BL_Y)

	# ── 纹理 ──
	var bw_tex_w   = ceili(BW_REF_HALF_W * 2 + shift)
	var beam_tex_w = ceili(BEAM_REF_HALF_W * 2 + shift)
	var tex_fp     = PM.make_wood_pillar(FP_TEX_W, FP_TEX_H, M_WOOD_FRONT_P)
	var tex_bp     = PM.make_wood_pillar(BP_TEX_W, BP_TEX_H, M_WOOD_BACK_P)
	var tex_bm     = PM.make_wood_pillar(beam_tex_w, BEAM_TEX_H, M_WOOD_BEAM)
	var tex_vs     = PM.make_wood_pillar(VS_TEX_W, VS_TEX_H, M_WOOD_BEAM)
	var tex_ss     = PM.make_wood_pillar(SS_TEX_W, SS_TEX_H, Color(0.42, 0.26, 0.13))
	var tex_th_main  = PM.make_straw_thatch(64, 64, M_THATCH_MAIN)
	var tex_th_right = PM.make_straw_thatch(64, 64, M_THATCH_RIGHT)
	var tex_th_left  = PM.make_straw_thatch(64, 64, M_THATCH_LEFT)
	var tex_th_back  = PM.make_straw_thatch(bw_tex_w, BW_TOP_TEX_H, M_THATCH_BACK)

	# ── L1 后景墙壁 ──
	var l1 = _c("L1_BackWall")

	# BackWall — 左边缘固定，与右堵头同步平移
	var bw_half_w = BW_REF_HALF_W + shift * 0.5
	_a(l1, _sprite("BackWall",
		Vector2(BW_LEFT_EDGE + bw_half_w, BW_Y),
		tex_th_back,
		Vector2(1, BW_SCALE_Y)))

	# BackWallTop — 左堵头，固定
	var tex_th_top = PM.make_straw_thatch(BW_TOP_TEX_W, BW_TOP_TEX_H, M_THATCH_BACK)
	_a(l1, _sprite("BackWallTop", BW_TOP_POS, tex_th_top, BW_TOP_SCALE))

	# 后景柱（左固定，右跟随，宽度增加时自动加柱）
	_a(l1, _sprite("BackPillarL", BP_LEFT, tex_bp))
	var nbp = maxi(2, ceili(width_cells / 12.0) + 1)
	for i in range(1, nbp - 1):
		var bx = lerpf(BP_LEFT.x, BP_RIGHT_REF_X + shift, float(i) / float(nbp - 1))
		_a(l1, _sprite("BackPillar", Vector2(bx, BP_RIGHT_Y), tex_bp))
	if nbp > 1:
		_a(l1, _sprite("BackPillarR", Vector2(BP_RIGHT_REF_X + shift, BP_RIGHT_Y), tex_bp))

	# ── L2 / L3 ──
	_c("L2_BackItems")
	_c("L3_FrontItems")

	# ── L4 前景柱 ──
	# 左侧两柱固定（左堵头），右侧柱跟随平移，中间加柱
	var l4  = _c("L4_FrontWall")
	var nfp = maxi(2, ceili(width_cells / 12.0) + 1)
	_a(l4, _sprite("FrontPillar", FP_LEFT_POS, tex_fp))          # 左堵头 第1根
	_a(l4, _sprite("FrontPillar", FP_MID_POS, tex_fp))           # @Sprite2D@48784 第2根固定
	var fr  = FP_RIGHT_REF_X + shift                              # 最右柱跟随右堵头
	for i in range(1, nfp - 2):                                    # 中间柱（nfp=3 时跳过）
		var fx = lerpf(FP_MID_POS.x, fr, float(i) / float(nfp - 2))
		_a(l4, _sprite("FrontPillar", Vector2(fx, FP_Y), tex_fp))
	if nfp > 2:
		_a(l4, _sprite("FrontPillar", Vector2(fr, FP_Y), tex_fp))  # 最右柱

	# ── L5 屋顶（渲染顺序匹配参考场景）──
	var l5 = _c("L5_Roof")
	var beam_half_w = BEAM_REF_HALF_W + shift * 0.5
	_a(l5, _slanted_beam(SB_POS, SB_ROT, SB_SCALE_Y, RM_SLANT, RM_BL_Y, RM_TY, M_WOOD_BEAM))  # 1. SlantedBeam
	_a(l5, _sprite("VerticalStrut", VS_POS, tex_vs))          # 2. VerticalStrut
	_a(l5, _sprite("Beam", Vector2(BEAM_LEFT_EDGE + beam_half_w, BEAM_Y), tex_bm))  # 3. Beam

	var sub = _sc(l5, "MainRoofGroup")                         # 4. MainRoofGroup
	_a(sub, _poly("RoofRightEnd", rr_tl, rr_tr, rr_br, rr_bl, tex_th_right))
	var rm = _poly("RoofMain", rm_tl, rm_tr, rm_br, rm_bl, tex_th_main)
	rm.position = RM_POS; rm.scale = RM_SCALE
	_a(sub, rm)

	_a(l5, _sprite("SlantedStrut", SS_POS, tex_ss, null, SS_ROT))  # 5. SlantedStrut

	var rl1 = _poly("RoofLeftGroup1",                             # 6. RoofLeftGroup1
		Vector2(RL1_BL.x + RL1_SLANT, RL1_TY),
		Vector2(RL1_BL.x + RL1_DW + RL1_SLANT, RL1_TY),
		Vector2(RL1_BL.x + RL1_DW, RL1_BL.y),
		RL1_BL, tex_th_left)
	rl1.position = RL1_POS
	_a(l5, rl1)

	print("[SmithyPreview] width_cells=%d  rm_dw=%.1f  shift=%.1f" % [width_cells, rm_dw, shift])


func _draw():
	var gl = GUIDE_LEFT
	var gr = _ss(252)
	for i in 4:
		draw_line(Vector2(gl, GUIDE_BASE_Y + i * 8.0), Vector2(gr, GUIDE_BASE_Y + i * 8.0), GUIDE_COLORS[i], 1.0)


func _input(event):
	if Engine.is_editor_hint(): return
	var cam = get_node_or_null("Camera")
	if cam == null: return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:   cam.zoom -= Vector2(0.1, 0.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: cam.zoom += Vector2(0.1, 0.1)
	if event is InputEventKey and event.pressed:
		var o = 50.0 / cam.zoom.x
		match event.keycode:
			KEY_LEFT:  cam.position.x -= o
			KEY_RIGHT: cam.position.x += o
			KEY_UP:    cam.position.y -= o
			KEY_DOWN:  cam.position.y += o


# --- helpers ---

func _c(nm: String) -> Node2D:
	var n = Node2D.new(); n.name = nm; add_child(n); n.owner = self; return n

func _sc(p: Node, nm: String) -> Node2D:
	var n = Node2D.new(); n.name = nm; p.add_child(n); n.owner = self; return n

func _a(p: Node, c: Node):
	p.add_child(c); c.owner = self

func _sprite(nm: String, pos: Vector2, tex, sc = null, rot: float = 0.0) -> Sprite2D:
	var s = Sprite2D.new(); s.name = nm; s.centered = true
	s.position = pos; s.texture = tex; s.rotation = rot
	if sc != null: s.scale = sc
	return s

func _poly(nm: String, tl: Vector2, tr: Vector2, br: Vector2, bl: Vector2, tex) -> Polygon2D:
	var p = Polygon2D.new(); p.name = nm
	p.polygon = PackedVector2Array([tl, tr, br, bl])
	var tw = float(tex.get_image().get_width())
	if tw < 1: tw = 1.0
	var us = bl.distance_to(br) / tw
	p.uv = PackedVector2Array([Vector2.ZERO, Vector2(us, 0), Vector2(us, 1), Vector2(0, 1)])
	p.texture = tex
	return p

func _slanted_beam(pos: Vector2, rot: float, sc_y: float, slant: float, bl_y: float, ty: float, wood_color: Color) -> Sprite2D:
	var h = bl_y - ty
	var length = sqrt(slant * slant + h * h)
	var s = Sprite2D.new(); s.name = "SlantedBeam"; s.centered = true
	s.texture  = PM.make_wood_pillar(23, ceili(length), wood_color)
	s.position = pos; s.rotation = rot; s.scale = Vector2(1, sc_y)
	return s
