## 数学工具类
## 提供常用的数学辅助方法，不依赖 Godot 场景树
class_name MathUtils


## 钳制浮点数，确保 value 落在 [min_val, max_val] 范围内
static func clamp_float(value: float, min_val: float, max_val: float) -> float:
	return clampf(value, min_val, max_val)


## 平滑插值：从 current 向 target 靠近，带有平滑系数
## @param smoothing: 平滑系数，越大越接近目标（典型值 1.0 ~ 20.0）
static func lerp_smooth(current: float, target: float, delta: float, smoothing: float) -> float:
	return lerpf(current, target, 1.0 - exp(-smoothing * delta))


## 在 [min_val, max_val] 范围内生成随机整数（含两端）
static func random_range_int(min_val: int, max_val: int) -> int:
	return randi_range(min_val, max_val)


## 逐步逼近：从 from 向 to 移动 step 距离，不超过目标
static func approach(from: float, to: float, step: float) -> float:
	var diff: float = to - from
	if absf(diff) <= step:
		return to
	return from + signf(diff) * step