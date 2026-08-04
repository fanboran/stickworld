@tool
extends BuildingExterior
## 兵营 - 程序化纹理版（红色调，区别于铁匠铺的黄色茅草）。
##
## 阶段 E 任务 E5：复制 pg_smithy_lv1 换色为兵营。初期阶段不需要独特贴图。
## 节点装配/纹理生成逻辑见 BuildingExterior 基类，本文件只提供调色板。


func _get_palette() -> Dictionary:
	return {
		"C_THATCH_BACK": Color(0.55, 0.20, 0.18),
		"C_THATCH_MAIN": Color(0.72, 0.28, 0.22),
		"C_THATCH_LEFT": Color(0.62, 0.24, 0.20),
		"C_WOOD_FRONT": Color(0.42, 0.18, 0.14),
		"C_WOOD_BACK": Color(0.32, 0.12, 0.10),
		"C_WOOD_BEAM": Color(0.36, 0.16, 0.12),
		"C_WOOD_STRUT": Color(0.38, 0.18, 0.13),
	}
