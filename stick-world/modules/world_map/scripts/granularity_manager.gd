extends Node2D
class_name GranularityManager
## 三级粒度切换 + 懒加载管理器
##
## 详见 docs/技术/架构/战略图架构.md §四 渲染架构
## 负责 L3↔L2↔L1 切换时的数据加载/卸载和渲染刷新

## 关联的数据容器
@export var data: StrategicMapData

## 关联的渲染器
@export var renderer: MapRenderer

## 关联的相机
@export var camera: MapCamera

## 关联的 API（用于发射 granularity_changed 信号）
@export var api: Node


## 设置粒度级别
## level: 0=L3, 1=L2, 2=L1
## [P] level=1 时 parent_id 是合法 region_id；level=2 时是合法 tile_id
## [Q] 触发懒加载，发射 granularity_changed
func set_granularity(level: int, parent_id: String = "") -> void:
	# TODO: SM-1/SM-2/SM-3 实现
	# 1. 校验 level 和 parent_id
	# 2. 按目标粒度调用 data.load_continent/load_region/load_tile
	# 3. data.current_granularity = level, focused_parent_id = parent_id
	# 4. renderer.refresh()
	# 5. camera.focus_on(parent_id, true)
	# 6. api.granularity_changed.emit(old, new, parent_id)
	match level:
		0: _switch_to_l3()
		1: _switch_to_l2(parent_id)
		2: _switch_to_l1(parent_id)


func _switch_to_l3() -> void:
	# TODO: SM-1
	# data.unload_all_regions_and_tiles()
	# data.load_continent()
	pass


func _switch_to_l2(region_id: String) -> void:
	# TODO: SM-2
	# data.load_region(region_id)
	pass


func _switch_to_l1(tile_id: String) -> void:
	# TODO: SM-3
	# data.load_tile(tile_id)
	pass


## 返回上一级粒度（ESC 键）
func go_back() -> void:
	# TODO: SM-2 实现
	# L1 → L2（聚焦当前 tile 的 parent_region_id）
	# L2 → L3
	# L3 → 无操作（或关闭战略图）
	pass


## 获取当前粒度
func get_granularity() -> int:
	if data:
		return data.current_granularity
	return 0


## 获取当前聚焦的父级 ID
func get_focused_parent_id() -> String:
	if data:
		return data.focused_parent_id
	return ""
