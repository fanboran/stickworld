class_name BuildProgressIndicator
extends Node2D
## 建造中建筑头顶双进度条 -- 阶段 E 任务 E4。
##
## 详见 docs/项目/P0收口执行计划.md §七.5 E.5。
## 上方材料条（蓝色），下方建造条（绿色），约束：建造 ≤ 材料。
## 由 ConstructionManager 在创建项目时实例化，挂到 map.BuildMaskLayer。
## 完工/取消时由 ConstructionManager 移除。

## 进度条宽度（像素）= 建筑占地宽度 * 32
var _bar_width: float = 64.0
## 材料进度 [0,1]
var _material_progress: float = 0.0
## 建造进度 [0,1]
var _build_progress: float = 0.0

## 进度条高度
const _BAR_HEIGHT: float = 6.0
## 两进度条间距
const _BAR_GAP: float = 3.0
## 颜色
const _COLOR_MATERIAL_BG := Color(0, 0, 0, 0.6)
const _COLOR_MATERIAL := Color(0.25, 0.5, 0.95, 1.0)
const _COLOR_BUILD_BG := Color(0, 0, 0, 0.6)
const _COLOR_BUILD := Color(0.3, 0.85, 0.35, 1.0)


## 初始化：设置位置和宽度
func setup(cell_x: int, width: int, ground_y: float) -> void:
	var center_x: float = (float(cell_x) + float(width) * 0.5) * 32.0
	position = Vector2(center_x, ground_y - 220.0)
	_bar_width = maxf(float(width) * 32.0, 48.0)
	z_index = WorldZ.OVERLAY_PROGRESS


## 更新进度并重绘
func update_progress(material_amount: float, build: float) -> void:
	_material_progress = clampf(material_amount, 0.0, 1.0)
	_build_progress = clampf(build, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var half_w: float = _bar_width * 0.5
	# 上方材料条（蓝）
	var mat_y: float = -_BAR_HEIGHT - _BAR_GAP * 0.5
	_draw_bar(-half_w, mat_y, _bar_width, _BAR_HEIGHT, _material_progress, _COLOR_MATERIAL_BG, _COLOR_MATERIAL)
	# 下方建造条（绿）
	var build_y: float = _BAR_GAP * 0.5
	_draw_bar(-half_w, build_y, _bar_width, _BAR_HEIGHT, _build_progress, _COLOR_BUILD_BG, _COLOR_BUILD)


func _draw_bar(x: float, y: float, w: float, h: float, progress: float, bg_color: Color, fg_color: Color) -> void:
	# 背景
	draw_rect(Rect2(x, y, w, h), bg_color, true)
	# 前景（按进度）
	var fg_w: float = w * clampf(progress, 0.0, 1.0)
	if fg_w > 0.0:
		draw_rect(Rect2(x, y, fg_w, h), fg_color, true)
	# 边框
	draw_rect(Rect2(x, y, w, h), Color(0, 0, 0, 0.8), false, 1.0)
