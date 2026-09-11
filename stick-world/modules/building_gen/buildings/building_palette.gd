class_name BuildingPalette
extends Resource
## 建筑调色板数据 —— BuildingExterior 程序化外观的色板注入（.tres）。
##
## 键名与 BuildingExterior 的纹理生成约定一致（茅草 3 色 + 木作 4 色 + 石作 3 色）；
## 各建筑以独立 .tres 提供（barracks/warehouse/thatch_hut/smithy 调色板）。
## 石色三键（批次 2）：旧 .tres 未存这些键时按脚本默认值取色（向后兼容）。

@export var C_THATCH_BACK: Color = Color(0.52, 0.38, 0.20)
@export var C_THATCH_MAIN: Color = Color(0.68, 0.50, 0.28)
@export var C_THATCH_LEFT: Color = Color(0.60, 0.44, 0.24)
@export var C_WOOD_FRONT: Color = Color(0.40, 0.27, 0.15)
@export var C_WOOD_BACK: Color = Color(0.30, 0.20, 0.12)
@export var C_WOOD_BEAM: Color = Color(0.34, 0.24, 0.14)
@export var C_WOOD_STRUT: Color = Color(0.36, 0.26, 0.15)
# ── 石作（批次 2）：暖中灰石面，与现有暖棕木作协调 ──
@export var C_STONE_MAIN: Color = Color(0.62, 0.585, 0.52)  # 石面主色（受光面提亮自它）
@export var C_STONE_DARK: Color = Color(0.45, 0.42, 0.37)   # 石块落影/暗面
@export var C_STONE_JOINT: Color = Color(0.33, 0.30, 0.26)  # 砌缝填浆色
