class_name PlacementSystem
extends RefCounted
## 选址系统 —— 在 PlacementGrid 之上提供高层语义 API。
##
## 详见 docs/技术/架构/场景与战斗架构.md §4.2 / §15 阶段 0.4。
## PlacementGrid 只回答「格子是否占用」，PlacementValidator 回答「能否放」，
## PlacementSystem 再封装一层提供：
##   1. try_place：校验 + 占用一步到位
##   2. find_nearest_free：从指定位置自动搜索最近空位（NPC 自动建造用）
##   3. release_area：释放格子
##
## P0 不实现 ghost 预览 UI（玩家点击建造 UI 留到阶段 0.6）。

const ScriptPlacementValidator := preload("res://modules/world/placement_grid/placement_validator.gd")


# ─────────────────────────────── 校验 ────────────────────────────────

## 校验是否可建（不占用）。返回 PlacementValidator.ValidationResult。
static func validate(grid: Node, cell_x: int, width: int) -> RefCounted:
	var validator := ScriptPlacementValidator.new()
	return validator.validate_placement(grid, cell_x, width)


# ─────────────────────────────── 占用 ────────────────────────────────

## 尝试占用连续 width 个条带。成功返回 {ok:true, cell_x, width}，
## 失败返回 {ok:false, error}。occupant 通常是 Building 节点或 instance_id。
static func try_place(grid: Node, cell_x: int, width: int, occupant: Variant) -> Dictionary:
	var validator := ScriptPlacementValidator.new()
	var result := validator.validate_placement(grid, cell_x, width)
	if not result.ok:
		return {"ok": false, "error": result.reason}
	var ok: bool = grid.occupy(cell_x, width, occupant)
	if not ok:
		return {"ok": false, "error": "占用失败（grid.occupy 返回 false）"}
	return {"ok": true, "cell_x": cell_x, "width": width}


# ─────────────────────────────── 自动搜索 ────────────────────────────────

## 从 start_x 开始向两侧扩展搜索最近可建位置。
##
## 搜索顺序：start_x → start_x+1 → start_x-1 → start_x+2 → start_x-2 → ...
## 直到找到连续 width 个空位或搜索范围耗尽。
##
## 返回 {ok:true, cell_x, width} 或 {ok:false, error}。
static func find_nearest_free(grid: Node, start_x: int, width: int, max_search: int = 32) -> Dictionary:
	if width <= 0:
		return {"ok": false, "error": "宽度非正: %d" % width}
	if max_search <= 0:
		max_search = 1
	# start_x 自身先试
	var self_result := validate(grid, start_x, width)
	if self_result.ok:
		return {"ok": true, "cell_x": start_x, "width": width}
	# 向两侧扩展
	for offset in range(1, max_search):
		# 向右
		var cx_right := start_x + offset
		var result_right := validate(grid, cx_right, width)
		if result_right.ok:
			return {"ok": true, "cell_x": cx_right, "width": width}
		# 向左
		var cx_left := start_x - offset
		var result_left := validate(grid, cx_left, width)
		if result_left.ok:
			return {"ok": true, "cell_x": cx_left, "width": width}
	return {"ok": false, "error": "搜索范围内未找到空位（start_x=%d width=%d）" % [start_x, width]}


# ─────────────────────────────── 释放 ────────────────────────────────

## 释放连续 width 个条带。
static func release_area(grid: Node, cell_x: int, width: int) -> void:
	if grid == null or not grid.has_method("release_area"):
		return
	grid.release_area(cell_x, width)


## 按占用者释放所有相关条带。
static func release_by_occupant(grid: Node, occupant: Variant) -> void:
	if grid == null or not grid.has_method("release"):
		return
	grid.release(occupant)
