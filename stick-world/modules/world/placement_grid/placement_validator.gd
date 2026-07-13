class_name PlacementValidator
extends RefCounted
## 占地校验器 —— 在 PlacementGrid 之上提供更高层语义校验。
##
## 详见 docs/技术/架构/场景与战斗架构.md §4.2。
## PlacementGrid 只回答"格子是否空闲"，PlacementValidator 还会检查：
##   - 是否在地图边界内
##   - 是否符合建筑最小尺寸要求
##   - 是否触犯特殊禁建区（如道路、水源）
##
## 用法：
##   var validator := PlacementValidator.new()
##   var result := validator.validate_placement(grid, cell_x, cell_y, w, h)
##   if result.ok:
##       grid.occupy(...)

## 校验结果
class ValidationResult:
	extends RefCounted
	var ok: bool = false
	var reason: String = ""
	static func pass_() -> ValidationResult:
		var r := ValidationResult.new()
		r.ok = true
		return r
	static func fail(p_reason: String) -> ValidationResult:
		var r := ValidationResult.new()
		r.ok = false
		r.reason = p_reason
		return r


## 校验是否可放置
func validate_placement(grid: Node, cell_x: int, cell_y: int, w: int, h: int) -> ValidationResult:
	if grid == null:
		return ValidationResult.fail("grid 为 null")
	if w <= 0 or h <= 0:
		return ValidationResult.fail("尺寸非正: %dx%d" % [w, h])
	# 边界
	if not grid.is_in_bounds(cell_x, cell_y):
		return ValidationResult.fail("起点越界: (%d,%d)" % [cell_x, cell_y])
	if not grid.is_in_bounds(cell_x + w - 1, cell_y + h - 1):
		return ValidationResult.fail("终点越界: (%d,%d) size %dx%d" % [cell_x, cell_y, w, h])
	# 冲突
	if not grid.can_place(cell_x, cell_y, w, h):
		return ValidationResult.fail("区域已被占用: (%d,%d) size %dx%d" % [cell_x, cell_y, w, h])
	return ValidationResult.pass_()


## 便捷方法：尝试占用，失败返回 false
func try_occupy(grid: Node, cell_x: int, cell_y: int, w: int, h: int, occupant: Variant) -> bool:
	var result := validate_placement(grid, cell_x, cell_y, w, h)
	if not result.ok:
		return false
	return grid.occupy(cell_x, cell_y, w, h, occupant)
