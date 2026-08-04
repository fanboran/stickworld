@tool
extends BuildingExterior
## 铁匠铺 Lv1 — 程序化纹理版（黄色茅草色调）。
##
## 自包含建筑场景：拖入场景即可使用。
## 节点装配/纹理生成逻辑见 BuildingExterior 基类，本文件只提供调色板。


func _get_palette() -> Dictionary:
	return {
		"C_THATCH_BACK": Color(0.62, 0.50, 0.20),
		"C_THATCH_MAIN": Color(0.78, 0.62, 0.28),
		"C_THATCH_LEFT": Color(0.70, 0.55, 0.25),
		"C_WOOD_FRONT": Color(0.48, 0.30, 0.15),
		"C_WOOD_BACK": Color(0.38, 0.22, 0.11),
		"C_WOOD_BEAM": Color(0.40, 0.24, 0.12),
		"C_WOOD_STRUT": Color(0.42, 0.26, 0.13),
	}
