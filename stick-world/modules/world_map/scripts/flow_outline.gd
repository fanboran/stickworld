class_name FlowOutline
extends RefCounted
## 蓝光流动描边 —— 闭合折线沿线的**色调**流动（两种蓝色调往返过渡，均不透明）。
##
## 用法：几何不变，先 resample_closed 缓存等弧长分段点列（避免每帧重采样），
## 之后每帧把时间传给 draw_flow（相位沿线移动，色调呈正弦波往返）。
## 消费：L1Thumbnail（出生 L1 轮廓）、L3MapRenderer（所在 L2 地区）、
## MapRenderer（当前城市地块）——"你在这里"标记统一视觉语言。
##
## 定标（创始人 2026-09-05）：不透明、靠两种蓝色调区分层级，不用透明度闪烁。

## 自适应分段的目标段长（地图/窗口单位）；段数 clamp 24..192
const SEG_LEN_HINT := 8.0
## 色调波流速（圈/秒）——约 5.5s 绕轮廓一周，温和不抢注意力
const FLOW_SPEED := 0.18
## 波谷混合占比（1=无波动纯 A 色，0.35=谷底仍有 35% 向 B 色过渡）
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


## 流动光描边：色调在 color_a ↔ color_b 间正弦往返（相位随时间前移 → 色带沿线
## 流动）。两色按调用方给定值原样绘制（A3 定标：不透明双色，无透明度衰减）
static func draw_flow(canvas: CanvasItem, pts: PackedVector2Array, color_a: Color,
		color_b: Color, t: float, width: float) -> void:
	var n := pts.size()
	if n < 3:
		return
	for i in n:
		var k := float(i) / float(n)
		var wave: float = FLOW_FLOOR + (1.0 - FLOW_FLOOR) \
				* (0.5 + 0.5 * sin(TAU * (k - t * FLOW_SPEED)))
		canvas.draw_line(pts[i], pts[(i + 1) % n], color_a.lerp(color_b, wave), width, true)
