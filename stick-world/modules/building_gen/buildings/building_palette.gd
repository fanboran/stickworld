class_name BuildingPalette
extends Resource
## 建筑调色板数据 —— BuildingExterior 程序化外观的 7 色注入（.tres）。
##
## 键名与 BuildingExterior 的纹理生成约定一致（茅草 3 色 + 木作 4 色）；
## 各建筑以独立 .tres 提供（barracks/warehouse/thatch_hut 调色板）。

@export var C_THATCH_BACK: Color = Color(0.52, 0.38, 0.20)
@export var C_THATCH_MAIN: Color = Color(0.68, 0.50, 0.28)
@export var C_THATCH_LEFT: Color = Color(0.60, 0.44, 0.24)
@export var C_WOOD_FRONT: Color = Color(0.40, 0.27, 0.15)
@export var C_WOOD_BACK: Color = Color(0.30, 0.20, 0.12)
@export var C_WOOD_BEAM: Color = Color(0.34, 0.24, 0.14)
@export var C_WOOD_STRUT: Color = Color(0.36, 0.26, 0.15)
