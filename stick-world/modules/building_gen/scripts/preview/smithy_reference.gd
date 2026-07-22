@tool
extends Node2D

## 铁匠铺参考场景 — 材质常量
## 节点结构在 smithy_reference.tscn 中手动维护

const PM = preload("res://modules/building_gen/scripts/materials/procedural_materials.gd")

# 材质颜色
const C_THATCH_BACK  = Color(0.62, 0.50, 0.20)
const C_THATCH_RIGHT = Color(0.68, 0.55, 0.23)
const C_THATCH_MAIN  = Color(0.78, 0.62, 0.28)
const C_THATCH_LEFT  = Color(0.70, 0.55, 0.25)
const C_WOOD_FRONT   = Color(0.48, 0.30, 0.15)
const C_WOOD_BACK    = Color(0.38, 0.22, 0.11)
const C_WOOD_BEAM    = Color(0.40, 0.24, 0.12)
const C_WOOD_STRUT   = Color(0.42, 0.26, 0.13)

# 纹理尺寸
const BW_TEX_W   = 222
const BW_TEX_H   = 102
const BP_TEX_W   = 20
const BP_TEX_H   = 197
const FP_TEX_W   = 21
const FP_TEX_H   = 246
const BEAM_TEX_W = 238
const BEAM_TEX_H = 16
const VS_TEX_W   = 23
const VS_TEX_H   = 117
const SS_TEX_W   = 133
const SS_TEX_H   = 20
const THATCH_W   = 64
const THATCH_H   = 64
