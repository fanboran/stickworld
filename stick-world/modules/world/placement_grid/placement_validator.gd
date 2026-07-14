class_name PlacementValidator
extends RefCounted
## 占地校验器 -- 在 PlacementGrid 之上提供更高层语义校验（1D 竖向条带）。
##
## PlacementGrid 只回答"条带是否空闲"，PlacementValidator 还会检查：
##   - 是否在地图边界内
##   - 尺寸是否合法
##
## 用法：
##   var validator := PlacementValidator.new()
##   var result := validator.validate_placement(grid, cell_x, w)
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
func validate_placement(grid: Node, cell_x: int, w: int) -> ValidationResult:
	if grid == null:
		return ValidationResult.fail("grid 为 null")
	if w <= 0:
		return ValidationResult.fail("宽度非正: %d" % w)
	# 边界
	if not grid.is_in_bounds(cell_x):
		return ValidationResult.fail("起点越界: %d" % cell_x)
	if not grid.is_in_bounds(cell_x + w - 1):
		return ValidationResult.fail("终点越界: %d 宽 %d" % [cell_x, w])
	# 冲突
	if not grid.can_place(cell_x, w):
		return ValidationResult.fail("区域已被占用: %d 宽 %d" % [cell_x, w])
	return ValidationResult.pass_()


## 便捷方法：尝试占用，失败返回 false
func try_occupy(grid: Node, cell_x: int, w: int, occupant: Variant) -> bool:
	var result := validate_placement(grid, cell_x, w)
	if not result.ok:
		return false
	return grid.occupy(cell_x, w, occupant)
