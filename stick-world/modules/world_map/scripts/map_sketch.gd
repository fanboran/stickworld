class_name MapSketch
extends RefCounted
## 地图线条结构工具（观感返工 §R8 层2 建，feedback1 去抖动后职能收缩）。
##
## wobble 扰动 / boiling 重掷已按创始人反馈（线条要平滑、严丝合缝，不要抖动）
## 全部退役——三渲染器回 draw_polyline/draw_multiline/draw_arc 平滑直绘。
## 本类保留与「线条几何正确性」相关的三个工具：
## 1. edge_key：无向边去重（L1 城界共享边只描一次 / L3 国界 states 邻接提取）——
##    共享边一份描边、端点与邻边共点，交界处严丝合缝
## 2. dash_segments：折线按 dash/gap 弧长切段（相位跨顶点连续）——路由高亮虚线 +
##    政治模式地区/地块虚线界线共用
## 3. id_seed：稳定几何 seed（当前仅标注层都城星标固定微转角用）

## 几何 id seed：String.hash()（GDScript 内置、跨端稳定；与
## SettlementRef.jitter_population_score 的 hash(id) 同款取法）+ salt 区分同 id 不同线
static func id_seed(id: String, salt: int = 0) -> int:
	return id.hash() + salt * 2654435761


## 无向边去重 key：两端量化坐标（0.25px 格）按字典序规范化——同一条物理边
## 无论从哪个方向遍历得到相同 key（L1 城界共享边去重 / L3 国界邻接提取共用）
static func edge_key(a: Vector2, b: Vector2) -> String:
	var ka := "%d,%d" % [roundf(a.x * 4.0), roundf(a.y * 4.0)]
	var kb := "%d,%d" % [roundf(b.x * 4.0), roundf(b.y * 4.0)]
	return ("%s|%s" % [ka, kb]) if ka < kb else ("%s|%s" % [kb, ka])


## 折线按 dash/gap 交替弧长切段：实段点对 append 到 segs（draw_multiline 消费）。
## 相位沿折线连续（跨顶点不断火），末尾残段按剩余长度截断。
static func dash_segments(segs: PackedVector2Array, pts: PackedVector2Array,
		dash: float, gap: float) -> void:
	var drawing := true
	var remain := dash
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len <= 0.0001:
			continue
		var walked := 0.0
		while walked < seg_len - 0.0001:
			var step := minf(remain, seg_len - walked)
			if drawing:
				segs.append(a.lerp(b, walked / seg_len))
				segs.append(a.lerp(b, (walked + step) / seg_len))
			walked += step
			remain -= step
			if remain <= 0.0001:
				drawing = not drawing
				remain = dash if drawing else gap
