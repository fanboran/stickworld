class_name PlacementGrid
extends Node
## 32px 高精度占地网格。
##
## 详见 docs/技术/架构/场景与战斗架构.md §4.2。
## 每张 Map 持有一个 PlacementGrid，用于：
##   - 建筑选址（can_place）
##   - 占地登记（occupy）
##   - 冲突检测（is_occupied）
##   - 世界坐标↔格子坐标互转
##
## 网格原点对齐 MapInstance 原点（0,0）。Y 轴向下为正。

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发
const ScriptGridCell := preload("res://modules/world/placement_grid/grid_cell.gd")

## 单元格尺寸（像素）
const CELL_SIZE: int = 32

## 信号：单元格被占用
signal cell_occupied(cell_x: int, cell_y: int, occupant: Variant)
## 信号：单元格被释放
signal cell_released(cell_x: int, cell_y: int)

## 网格宽度（格数）
@export var grid_width: int = 64
## 网格高度（格数）
@export var grid_height: int = 32

## 内部存储：cell_x, cell_y -> GridCell
var _cells: Dictionary = {}

## BuildMask 不可放建筑区域掩码（1=不可放建筑，详见 §4.2）
## 与 grid 同尺寸，标记地形限制不可放建筑的格子
var blockage_mask: PackedByteArray = PackedByteArray()


func _ready() -> void:
	_init_cells()
	_init_blockage_mask()


func _init_cells() -> void:
	_cells.clear()
	for x in range(grid_width):
		for y in range(grid_height):
			_cells[Vector2i(x, y)] = ScriptGridCell.new(x, y)


func _init_blockage_mask() -> void:
	# 初始化 blockage_mask 为全 0（全部可放建筑）
	blockage_mask.resize(grid_width * grid_height)
	blockage_mask.fill(0)


# ─────────────────────────────── 坐标转换 ────────────────────────────────

## 世界坐标 → 格子坐标
func world_to_cell(world_pos: Vector2) -> Vector2i:
	var cx: int = int(world_pos.x / CELL_SIZE)
	var cy: int = int(world_pos.y / CELL_SIZE)
	return Vector2i(cx, cy)


## 格子坐标 → 世界坐标（格子中心点）
func cell_to_world(cell_x: int, cell_y: int) -> Vector2:
	return Vector2(
		cell_x * CELL_SIZE + CELL_SIZE * 0.5,
		cell_y * CELL_SIZE + CELL_SIZE * 0.5
	)


# ─────────────────────────────── 边界检查 ────────────────────────────────

## 格子坐标是否在网格范围内
func is_in_bounds(cell_x: int, cell_y: int) -> bool:
	return cell_x >= 0 and cell_x < grid_width and cell_y >= 0 and cell_y < grid_height


# ─────────────────────────────── 查询 ────────────────────────────────

## 单格是否被占用。越界返回 true（视为不可建）。
## 注意：建筑占用 OR BuildMask 标记 = 不可放（详见 §4.2）
func is_occupied(cell_x: int, cell_y: int) -> bool:
	if not is_in_bounds(cell_x, cell_y):
		return true
	var key := Vector2i(cell_x, cell_y)
	var cell: ScriptGridCell = _cells.get(key)
	if cell == null:
		return true
	return cell.occupied or is_blocked(cell_x, cell_y)


## 单格是否被 BuildMask 标记为不可放建筑（地形限制，详见 §4.2）
func is_blocked(cell_x: int, cell_y: int) -> bool:
	if not is_in_bounds(cell_x, cell_y):
		return true
	return blockage_mask[cell_y * grid_width + cell_x] == 1


## 矩形区域是否全部空闲（可建）
func can_place(cell_x: int, cell_y: int, w: int, h: int) -> bool:
	if w <= 0 or h <= 0:
		return false
	for x in range(cell_x, cell_x + w):
		for y in range(cell_y, cell_y + h):
			if is_occupied(x, y):
				return false
	return true


## 获取单格占用者
func get_occupant(cell_x: int, cell_y: int) -> Variant:
	var key := Vector2i(cell_x, cell_y)
	var cell: ScriptGridCell = _cells.get(key)
	if cell == null:
		return null
	return cell.occupant


# ─────────────────────────────── 占用/释放 ────────────────────────────────

## 占用矩形区域。成功返回 true，失败（部分越界或冲突）返回 false。
## 注意：失败时不会留下半占用状态（全成功才写入）。
func occupy(cell_x: int, cell_y: int, w: int, h: int, occupant: Variant) -> bool:
	if not can_place(cell_x, cell_y, w, h):
		return false
	for x in range(cell_x, cell_x + w):
		for y in range(cell_y, cell_y + h):
			var cell: ScriptGridCell = _cells[Vector2i(x, y)]
			cell.set_occupied(occupant)
			cell_occupied.emit(x, y, occupant)
	return true


## 按占用者释放所有相关格子
func release(occupant: Variant) -> void:
	for key: Vector2i in _cells.keys():
		var cell: ScriptGridCell = _cells[key]
		if cell.occupied and cell.occupant == occupant:
			cell.release()
			cell_released.emit(key.x, key.y)


## 释放矩形区域
func release_area(cell_x: int, cell_y: int, w: int, h: int) -> void:
	for x in range(cell_x, cell_x + w):
		for y in range(cell_y, cell_y + h):
			var key := Vector2i(x, y)
			var cell: ScriptGridCell = _cells.get(key)
			if cell != null and cell.occupied:
				cell.release()
				cell_released.emit(x, y)


## 清空所有占用
func clear() -> void:
	for key: Vector2i in _cells.keys():
		var cell: ScriptGridCell = _cells[key]
		if cell.occupied:
			cell.release()
			cell_released.emit(key.x, key.y)


# ─────────────────────────────── BuildMask（§4.2）────────────────────────────────

## 标记单格为不可放建筑（地形限制）
func set_blocked(cell_x: int, cell_y: int, blocked: bool = true) -> void:
	if not is_in_bounds(cell_x, cell_y):
		return
	blockage_mask[cell_y * grid_width + cell_x] = 1 if blocked else 0


## 标记矩形区域为不可放建筑
func set_blocked_area(cell_x: int, cell_y: int, w: int, h: int, blocked: bool = true) -> void:
	for x in range(cell_x, cell_x + w):
		for y in range(cell_y, cell_y + h):
			set_blocked(x, y, blocked)


## 清空所有 BuildMask 标记
func clear_blockage() -> void:
	blockage_mask.fill(0)


## 获取被 BuildMask 标记的格子数
func get_blocked_count() -> int:
	var count: int = 0
	for i in range(blockage_mask.size()):
		if blockage_mask[i] == 1:
			count += 1
	return count


# ─────────────────────────────── 统计 ────────────────────────────────

## 已占用格子数
func get_occupied_count() -> int:
	var count: int = 0
	for key: Vector2i in _cells.keys():
		var cell: ScriptGridCell = _cells[key]
		if cell.occupied:
			count += 1
	return count


## 总格子数
func get_total_count() -> int:
	return grid_width * grid_height
