class_name MapSketch
extends RefCounted
## 地图手绘线条工具（观感返工 §R8 层2）——与 SketchDraw（ui_global 手绘库）同源的
## 地图空间适配层。地图线条 = 手绘马克笔，与游戏 UI 边框同一套笔触语言。
##
## 同源三要素（直接复用 SketchDraw 实现，不复制公式）：
## 1. wobble 扰动 = SketchDraw.wobble（sin(i*127.1+seed*0.3117)*43758.5453 同一函数）
## 2. 采样密度 = 线宽 × MapTokens.SEG_LEN_RATIO（≈UI 的 SEG_LEN 18 / 1.6 密度）
## 3. boiling 节拍 = SketchDraw.WOBBLE_INTERVAL 0.12s（与血条同拍）
##
## 地图适配差异（相对 UI 控件）：
## - 线条在**地图空间**固定（笔触烙在地图上，缩放时观感一致）——UI 线是屏幕空间，
##   地图线放大后笔触跟着放大，像真实手绘地图；缓存构建一次，不随 zoom 重建
## - 静态线**固定 seed**（几何 id / 顶点坐标派生）不沸腾——地图大线沸腾会闹；
##   动态线（hover/路由高亮/玩家脉冲）seed = boiling_seed(t) 重掷，与血条同节拍
## - 顶点拖拽式扰动：偏移由「顶点坐标 hash」决定 → 相邻段共享端点扰动一致，
##   折线连续无缝（分段的界线描边不会裂开）
## - seed 混合用 DJB2 整型版（与 blob 跨端同源先例同族；几何 id 走 String.hash()，
##   与 SettlementRef.jitter_population_score 同款内置）

## 折线 wobble：顶点拖拽（两端 offset 插值，共享顶点无缝）+ 边内法向波动。
## closed=true 时返回点列首尾不重复（绘制方自行闭合）；closed=false 补末点。
static func wobble_polyline(pts: PackedVector2Array, seed: int, width: float,
		closed: bool) -> PackedVector2Array:
	var n_in := pts.size()
	if n_in < 2 or width <= 0.0:
		return pts
	var amp := width * MapTokens.AMP_RATIO
	var seg_len := maxf(width * MapTokens.SEG_LEN_RATIO, 2.0)
	var out := PackedVector2Array()
	var edge_count := n_in if closed else n_in - 1
	for e in edge_count:
		var a := pts[e]
		var b := pts[(e + 1) % n_in]
		var eseed := edge_seed(a, b, seed)
		var oa := vertex_offset(a, seed, amp)
		var ob := vertex_offset(b, seed, amp)
		var seg_len_px := a.distance_to(b)
		if seg_len_px <= 0.0001:
			continue
		var steps := maxi(1, roundi(seg_len_px / seg_len))
		var dir := (b - a) / seg_len_px
		var nrm := Vector2(-dir.y, dir.x)
		for i in steps:
			var t := float(i) / float(steps)
			var drag := oa.lerp(ob, t)
			var wav := SketchDraw.wobble(i, eseed) * amp
			out.append(a.lerp(b, t) + drag + nrm * wav)
	if not closed:
		var last := pts[n_in - 1]
		out.append(last + vertex_offset(last, seed, amp))
	return out


## 手绘闭合环（圆）：SEG_LEN 密度圆周采样 + 径向扰动，首尾不重复（绘制方闭合）。
## 玩家脉冲环/静态细环用（R2 draw_arc 圆环的手绘化）。
static func wobble_ring(center: Vector2, radius: float, seed: int,
		width: float) -> PackedVector2Array:
	var amp := width * MapTokens.AMP_RATIO
	var seg_len := maxf(width * MapTokens.SEG_LEN_RATIO, 2.0)
	var n := maxi(8, roundi(TAU * radius / seg_len))
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var a := TAU * float(i) / float(n)
		var rr := radius + SketchDraw.wobble(i, seed) * amp
		pts[i] = center + Vector2(cos(a), sin(a)) * rr
	return pts


## 顶点拖拽偏移：由「顶点坐标 hash + 线 seed」决定——同一几何里共享顶点的段
## 得到相同偏移（连续无缝），不同线（seed 不同）同顶点偏移不同（笔触独立）
static func vertex_offset(p: Vector2, seed: int, amp: float) -> Vector2:
	var s := vertex_seed(p) + seed
	return Vector2(SketchDraw.wobble(1, s), SketchDraw.wobble(2, s)) * amp


## boiling 重掷 seed：t 秒时钟 → 每 WOBBLE_INTERVAL 0.12s 换一个 seed（与血条同拍）。
## 动态线每帧传累计时间，seed 变化时才需重建扰动缓存。
static func boiling_seed(t: float) -> int:
	return int(t / SketchDraw.WOBBLE_INTERVAL)


## 顶点坐标 seed：量化坐标（0.25px 格）DJB2 混合——同坐标必同 seed
static func vertex_seed(p: Vector2) -> int:
	var q := _quant(p)
	var h := 5381
	h = _mix(h, q.x)
	h = _mix(h, q.y)
	return h


## 无向边 seed：两端量化坐标按字典序规范化后 DJB2 混合 + salt（线 seed）——
## 同一条物理边无论从哪个方向遍历得到相同 seed（两侧共享边扰动一致）
static func edge_seed(a: Vector2, b: Vector2, salt: int) -> int:
	var qa := _quant(a)
	var qb := _quant(b)
	if qb.x < qa.x or (qb.x == qa.x and qb.y < qa.y):
		var tmp := qa
		qa = qb
		qb = tmp
	var h := _mix(5381, salt)
	h = _mix(h, qa.x)
	h = _mix(h, qa.y)
	h = _mix(h, qb.x)
	h = _mix(h, qb.y)
	return h


## 无向边去重 key：两端量化坐标（0.25px 格）按字典序规范化——同一条物理边
## 无论从哪个方向遍历得到相同 key（L1 城界共享边去重 / L3 国界邻接提取共用）
static func edge_key(a: Vector2, b: Vector2) -> String:
	var ka := "%d,%d" % [roundf(a.x * 4.0), roundf(a.y * 4.0)]
	var kb := "%d,%d" % [roundf(b.x * 4.0), roundf(b.y * 4.0)]
	return ("%s|%s" % [ka, kb]) if ka < kb else ("%s|%s" % [kb, ka])


## 几何 id seed：String.hash()（GDScript 内置、跨端稳定；与
## SettlementRef.jitter_population_score 的 hash(id) 同款取法）+ salt 区分同 id 不同线
static func id_seed(id: String, salt: int = 0) -> int:
	return id.hash() + salt * 2654435761


## 折线按 dash/gap 交替弧长切段：实段点对 append 到 segs（draw_multiline 消费）。
## 相位沿折线连续（跨顶点不断火），末尾残段按剩余长度截断。
## （原 map_renderer._append_dashed 迁此通用化：路由高亮 + 政治模式虚线界线共用）
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


## 量化到 0.25px 格（防浮点抖动破坏 hash 一致性；R3 平滑几何顶点亚像素对齐余量内）
static func _quant(p: Vector2) -> Vector2i:
	return Vector2i(int(roundf(p.x * 4.0)), int(roundf(p.y * 4.0)))


## DJB2 整型混合一步（与 blob 跨端同源先例同族）
static func _mix(h: int, v: int) -> int:
	return ((h << 5) + h + v) & 0x7FFFFFFF
