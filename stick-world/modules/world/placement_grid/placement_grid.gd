class_name PlacementGrid
extends Node
## 1D 竖向条带占地网格。
##
## 横向卷轴游戏中，世界按 32px 宽切分为竖向条带，每个条带无限向上下延伸。
## 建筑只占宽度（N 个条带），不关心垂直方向占地。
##
## 每张 Map 持有一个 PlacementGrid，用于：
##   - 建筑选址（can_place）
##   - 占地登记（occupy）
##   - 冲突检测（is_occupied）
##   - 世界坐标↔条带坐标互转

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发
const ScriptGridCell := preload("res://modules/world/placement_grid/grid_cell.gd")

## 单元格尺寸（像素，即每个竖向条带的宽度）
const CELL_SIZE: int = 32

## 信号：条带被占用
signal cell_occupied(cell_x: int, occupant: Variant)
## 信号：条带被释放
signal cell_released(cell_x: int)

## 网格宽度（条带数）
@export var grid_width: int = 64

## 内部存储：cell_x -> GridCell
var _cells: Dictionary = {}

## BuildMask 不可放建筑区域掩码（1=不可放建筑）
## 1D 数组，与 grid_width 同长度
var blockage_mask: PackedByteArray = PackedByteArray()


func _ready() -> void:
	_init_cells()
	_init_blockage_mask()


func _init_cells() -> void:
	_cells.clear()
	for x in range(grid_width):
		_cells[x] = ScriptGridCell.new(x)


func _init_blockage_mask() -> void:
	blockage_mask.resize(grid_width)
	blockage_mask.fill(0)


# ─────────────────────────────── 坐标转换 ────────────────────────────────

## 世界坐标 X -> 条带坐标
func world_to_cell(world_pos: Vector2) -> int:
	return int(world_pos.x / CELL_SIZE)


## 条带坐标 -> 世界坐标 X（条带中心点）
func cell_to_world(cell_x: int) -> float:
	return cell_x * CELL_SIZE + CELL_SIZE * 0.5


# ─────────────────────────────── 边界检查 ────────────────────────────────

## 条带坐标是否在网格范围内
func is_in_bounds(cell_x: int) -> bool:
	return cell_x >= 0 and cell_x < grid_width


# ─────────────────────────────── 查询 ────────────────────────────────

## 条带是否被占用。越界返回 true（视为不可建）。
## 注意：建筑占用 OR BuildMask 标记 = 不可放
func is_occupied(cell_x: int) -> bool:
	if not is_in_bounds(cell_x):
		return true
	var cell: ScriptGridCell = _cells.get(cell_x)
	if cell == null:
		return true
	return cell.occupied or is_blocked(cell_x)


## 条带是否被 BuildMask 标记为不可放建筑（地形限制）
func is_blocked(cell_x: int) -> bool:
	if not is_in_bounds(cell_x):
		return true
	return blockage_mask[cell_x] == 1


## 连续 N 个条带是否全部空闲（可建）
func can_place(cell_x: int, w: int) -> bool:
	if w <= 0:
		return false
	for x in range(cell_x, cell_x + w):
		if is_occupied(x):
			return false
	return true


## 获取条带占用者
func get_occupant(cell_x: int) -> Variant:
	var cell: ScriptGridCell = _cells.get(cell_x)
	if cell == null:
		return null
	return cell.occupant


# ─────────────────────────────── 占用/释放 ────────────────────────────────

## 占用连续 N 个条带。成功返回 true，失败（部分越界或冲突）返回 false。
func occupy(cell_x: int, w: int, occupant: Variant) -> bool:
	if not can_place(cell_x, w):
		return false
	for x in range(cell_x, cell_x + w):
		var cell: ScriptGridCell = _cells[x]
		cell.set_occupied(occupant)
		cell_occupied.emit(x, occupant)
	return true


## 按占用者释放所有相关条带
func release(occupant: Variant) -> void:
	for key: int in _cells.keys():
		var cell: ScriptGridCell = _cells[key]
		if cell.occupied and cell.occupant == occupant:
			cell.release()
			cell_released.emit(key)


## 释放连续区域
func release_area(cell_x: int, w: int) -> void:
	for x in range(cell_x, cell_x + w):
		var cell: ScriptGridCell = _cells.get(x)
		if cell != null and cell.occupied:
			cell.release()
			cell_released.emit(x)


## 清空所有占用
func clear() -> void:
	for key: int in _cells.keys():
		var cell: ScriptGridCell = _cells[key]
		if cell.occupied:
			cell.release()
			cell_released.emit(key)


# ─────────────────────────────── BuildMask ────────────────────────────────

## 标记单个条带为不可放建筑（地形限制）
func set_blocked(cell_x: int, blocked: bool = true) -> void:
	if not is_in_bounds(cell_x):
		return
	blockage_mask[cell_x] = 1 if blocked else 0


## 标记连续区域为不可放建筑
func set_blocked_area(cell_x: int, w: int, blocked: bool = true) -> void:
	for x in range(cell_x, cell_x + w):
		set_blocked(x, blocked)


## 清空所有 BuildMask 标记
func clear_blockage() -> void:
	blockage_mask.fill(0)


## 获取被 BuildMask 标记的条带数
func get_blocked_count() -> int:
	var count: int = 0
	for i in range(blockage_mask.size()):
		if blockage_mask[i] == 1:
			count += 1
	return count


# ─────────────────────────────── 统计 ────────────────────────────────

## 已占用条带数
func get_occupied_count() -> int:
	var count: int = 0
	for key: int in _cells.keys():
		var cell: ScriptGridCell = _cells[key]
		if cell.occupied:
			count += 1
	return count


## 总条带数
func get_total_count() -> int:
	return grid_width
