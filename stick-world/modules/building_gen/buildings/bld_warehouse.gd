@tool
extends BuildingExterior
## 仓库 - 程序化纹理版（棕黄木色调，区别于兵营的红色调）。
##
## 作为搬运系统的取货点：工人从此仓库取建材运往工地。
## 节点装配/纹理生成逻辑见 BuildingExterior 基类，本文件只提供调色板。


func _get_palette() -> Dictionary:
	return {
		"C_THATCH_BACK": Color(0.50, 0.35, 0.18),
		"C_THATCH_MAIN": Color(0.65, 0.48, 0.25),
		"C_THATCH_LEFT": Color(0.58, 0.42, 0.22),
		"C_WOOD_FRONT": Color(0.38, 0.25, 0.14),
		"C_WOOD_BACK": Color(0.28, 0.18, 0.10),
		"C_WOOD_BEAM": Color(0.32, 0.22, 0.13),
		"C_WOOD_STRUT": Color(0.34, 0.24, 0.14),
	}
