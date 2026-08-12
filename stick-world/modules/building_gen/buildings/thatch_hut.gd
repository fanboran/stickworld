@tool
extends BuildingExterior
## 草棚 —— 标准 16 格茅草屋外壳（房屋类建筑默认外壳）。
##
## 外观由 BuildingExterior 基类程序化生成（按 width 平铺，支持任意宽度），
## 本文件只提供调色板。对应 def placeholder（建造菜单里的"草棚"）。


func _get_palette() -> Dictionary:
	return {
		"C_THATCH_BACK": Color(0.52, 0.38, 0.20),
		"C_THATCH_MAIN": Color(0.68, 0.50, 0.28),
		"C_THATCH_LEFT": Color(0.60, 0.44, 0.24),
		"C_WOOD_FRONT": Color(0.40, 0.27, 0.15),
		"C_WOOD_BACK": Color(0.30, 0.20, 0.12),
		"C_WOOD_BEAM": Color(0.34, 0.24, 0.14),
		"C_WOOD_STRUT": Color(0.36, 0.26, 0.15),
	}
