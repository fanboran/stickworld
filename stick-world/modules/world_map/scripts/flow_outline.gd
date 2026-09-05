class_name FlowOutline
extends RefCounted
## 蓝光流动描边 —— 闭合折线沿线的亮度波流动（"你在这里"当前位置高亮动画）。
##
## 用法：几何不变，先 resample_closed 缓存等弧长分段点列（避免每帧重采样），
## 之后每帧把时间传给 draw_flow（相位沿线移动，亮度呈正弦波）。
## 两处消费：L1Thumbnail（出生 L1 轮廓，窗口像素坐标）与 L3MapRenderer
## （玩家所在老 L1 轮廓，8192 渲染坐标）。

## 自适应分段的目标段长（地图/窗口单位）；段数 clamp 24..192
const SEG_LEN_HINT := 8.0
## 亮度波流速（圈/秒）——约 5.5s 绕轮廓一周，温和不抢注意力
const FLOW_SPEED := 0.18
## 波谷亮度占比（1=无波动，0.35=谷底仍保留 35% 亮度）
const FLOW_FLOOR := 0.35


## 闭合折线均匀弧长重采样（返回 n 点，首尾不重复，绘制用 (i+1)%n 闭合）。
## segments<0 时按周长/SEG_LEN_HINT 自适应。
static func resample_closed(pts: PackedVector2Array, segments: int = -1) -> PackedVector2Array:
	var n_in := pts.size()
	if n_in < 3:
		return PackedVector2Array()
	# 累计弧长（含闭合段）
	var total := 0.0
	var lens := PackedFloat32Array()
	lens.resize(n_in)
	for i in n_in:
		var nxt: Vector2 = pts[(i + 1) % n_in]
		var l: float = pts[i].distance_to(nxt)
		lens[i] = l
		total += l
	if total <= 0.0:
		return PackedVector2Array()
	var n_seg: int = segments if segments > 0 else int(clampf(total / SEG_LEN_HINT, 24.0, 192.0))
	var out := PackedVector2Array()
	out.resize(n_seg)
	var seg := 0
	var acc: float = 0.0  # 已走过的源段累计弧长
	var target: float = 0.0
	for k in n_seg:
		target = total * float(k) / float(n_seg)
		while seg < n_in and acc + lens[seg] < target:
			acc += lens[seg]
			seg += 1
		if seg >= n_in:  # 浮点末端保护
			seg = n_in - 1
		var l: float = maxf(lens[seg], 0.000001)
		var t: float = clampf((target - acc) / l, 0.0, 1.0)
		out[k] = pts[seg].lerp(pts[(seg + 1) % n_in], t)
	return out


## 流动光描边：亮度 = FLOOR + (1-FLOOR) × (0.5+0.5·sin(TAU·(k − t·speed)))，
## 相位随时间前移 → 亮波沿线流动。base.a 作为峰值 alpha。
static func draw_flow(canvas: CanvasItem, pts: PackedVector2Array, base: Color,
		t: float, width: float) -> void:
	var n := pts.size()
	if n < 3:
		return
	for i in n:
		var k := float(i) / float(n)
		var wave: float = FLOW_FLOOR + (1.0 - FLOW_FLOOR) \
				* (0.5 + 0.5 * sin(TAU * (k - t * FLOW_SPEED)))
		canvas.draw_line(pts[i], pts[(i + 1) % n], Color(base, base.a * wave), width, true)
