class_name ArrowBallistics
extends RefCounted
## 抛物线箭矢弹道解算 —— 从 weapon_mount 拆出的纯函数簇（无状态）。
##
## SWL AimAngle 语义：飞行时间 T 按全距离取（基准速 vx），初速 = 直线分量(d/T)
## + 抛物线补偿(−½GT)——T 秒后恰好落到目标点，方向自洽。

## 弹道解算：出射点 from → 瞄准点 aim_point（可带目标速度预判迭代）。
## 返回 { "vel": Vector2 出射速度, "t": float 飞行时间, "aim_point": Vector2 解算用瞄准点 }。
static func solve(from: Vector2, aim_point: Vector2, target_velocity: Vector2,
		vx: float, lead_factor: float, gravity: float) -> Dictionary:
	var dist := from.distance_to(aim_point)
	var t := clampf(dist / vx, 0.12, 2.2)
	# 移动预判：先按 T 平移目标点，再对**新目标点**解算（保证弹道自洽）
	if target_velocity != Vector2.ZERO:
		aim_point += target_velocity * t * lead_factor
		dist = from.distance_to(aim_point)
		t = clampf(dist / vx, 0.12, 2.2)
	var aim := aim_point - from
	var vel := Vector2(aim.x / t, aim.y / t - 0.5 * gravity * t)
	return { "vel": vel, "t": t, "aim_point": aim_point }


## 高斯随机数（dump ArcherAi.NextGaussian 三参/四参版直译，11d）：
## Box-Muller 采样 + [min, max] 截断——先重掷 4 次取落区间值，仍不中则钳制
## （原版截断策略无真值，重掷为等价近似）。std ≤ 0 直接返回均值。
static func next_gaussian(mean: float = 0.0, standard_deviation: float = 1.0, min_v: float = NAN, max_v: float = NAN) -> float:
	if standard_deviation <= 0.0:
		return mean
	var g: float = 0.0
	var v: float = mean
	for i in range(4):
		var u1: float = maxf(randf(), 0.0001)
		g = sqrt(-2.0 * log(u1)) * cos(TAU * randf())
		v = mean + g * standard_deviation
		if (is_nan(min_v) or v >= min_v) and (is_nan(max_v) or v <= max_v):
			return v
	if not is_nan(min_v):
		v = maxf(v, min_v)
	if not is_nan(max_v):
		v = minf(v, max_v)
	return v
