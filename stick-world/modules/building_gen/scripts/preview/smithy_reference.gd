@tool
extends Node2D

## 铁匠铺参考场景 — 程序化纹理版
## 所有纹理由 procedural_materials.gd 生成，不嵌入 PNG 二进制
## 节点位置/多边形坐标由 Godot 编辑器手动调整后持久化在 tscn 中

const PM = preload("res://modules/building_gen/scripts/materials/procedural_materials.gd")

# 材质颜色（与 smithy_preview.gd 保持一致）
const C_THATCH_BACK  = Color(0.62, 0.50, 0.20)
const C_THATCH_RIGHT = Color(0.68, 0.55, 0.23)
const C_THATCH_MAIN  = Color(0.78, 0.62, 0.28)
const C_THATCH_LEFT  = Color(0.70, 0.55, 0.25)
const C_WOOD_FRONT   = Color(0.48, 0.30, 0.15)
const C_WOOD_BACK    = Color(0.38, 0.22, 0.11)
const C_WOOD_BEAM    = Color(0.40, 0.24, 0.12)
const C_WOOD_STRUT   = Color(0.42, 0.26, 0.13)

# 纹理尺寸（从现有节点提取）
const BW_TEX_W   = 222
const BW_TEX_H   = 102
const BP_TEX_W   = 20
const BP_TEX_H   = 197
const FP_TEX_W   = 21
const FP_TEX_H   = 246
const BEAM_TEX_W = 238
const BEAM_TEX_H = 16
const SB_TEX_W   = 23
const SB_TEX_H   = 117   # 斜梁纹理高度（实际长度由代码算）
const VS_TEX_W   = 23
const VS_TEX_H   = 117
const SS_TEX_W   = 133
const SS_TEX_H   = 20
const THATCH_W   = 64
const THATCH_H   = 64


func _ready():
	if not Engine.is_editor_hint():
		return
	_apply_textures()


func _apply_textures():
	# 预生成纹理
	# 三块屋顶共用一张 512×512 横向 tileable 程序化茅草贴图
	var tex_thatch_roof  = PM.make_thatch_layered(512, 512, 0)
	var tex_thatch_back  = PM.make_straw_thatch(BW_TEX_W, BW_TEX_H, C_THATCH_BACK)
	var tex_thatch_main  = tex_thatch_roof
	var tex_thatch_right = tex_thatch_roof
	var tex_thatch_left  = tex_thatch_roof
	var tex_bp           = PM.make_wood_pillar(BP_TEX_W, BP_TEX_H, C_WOOD_BACK)
	var tex_fp           = PM.make_wood_pillar(FP_TEX_W, FP_TEX_H, C_WOOD_FRONT)
	var tex_beam         = PM.make_wood_pillar(BEAM_TEX_W, BEAM_TEX_H, C_WOOD_BEAM)
	var tex_vs           = PM.make_wood_pillar(VS_TEX_W, VS_TEX_H, C_WOOD_BEAM)
	var tex_ss           = PM.make_wood_pillar(SS_TEX_W, SS_TEX_H, C_WOOD_STRUT)

	# L1 后景墙壁
	_set_tex("L1_BackWall/BackWall",     tex_thatch_back)
	_set_tex("L1_BackWall/BackWallTop",  tex_thatch_back)
	_set_tex("L1_BackWall/BackPillarL",  tex_bp)
	_set_tex("L1_BackWall/BackPillarR",  tex_bp)

	# L4 前景柱
	for c in get_node("L4_FrontWall").get_children():
		if c is Sprite2D:
			c.texture = tex_fp

	# L5 屋顶
	_set_tex("L5_Roof/SlantedBeam",   _make_slanted_beam_tex(C_WOOD_BEAM))
	_set_tex("L5_Roof/VerticalStrut", tex_vs)
	_set_tex("L5_Roof/Beam",          tex_beam)
	_set_tex("L5_Roof/SlantedStrut",  tex_ss)

	# 屋顶多边形
	_set_tex("L5_Roof/MainRoofGroup/RoofRightEnd", tex_thatch_right)
	_set_tex("L5_Roof/MainRoofGroup/RoofMain",     tex_thatch_main)
	_set_tex("L5_Roof/RoofLeftGroup1",             tex_thatch_left)
	# RoofLeftGroup1 是容器节点，需把贴图同步给它内部所有 Polygon2D
	var rl1 = get_node_or_null("L5_Roof/RoofLeftGroup1")
	if rl1:
		for c in rl1.get_children():
			if c is Polygon2D:
				c.texture = tex_thatch_left
				c.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func _set_tex(path: String, tex):
	var n = get_node_or_null(path)
	if n:
		if n is Sprite2D or n is Polygon2D:
			n.texture = tex
			# 屋顶多边形 uv.x > 1 产生横向循环——需启用 texture_repeat 才不会边缘截断
			if n is Polygon2D:
				n.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func _make_slanted_beam_tex(color: Color):
	# 斜梁长度：从 RM 几何推算 (slant=64, height=110)
	var slant  = 64.0
	var height = 110.0
	var length = sqrt(slant * slant + height * height)
	return PM.make_wood_pillar(23, ceili(length), color)
