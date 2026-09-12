## 手绘墨线原语：抖动 + 变宽 + 出头 + 圆头。
## 只提供"线"的质感，不含建筑知识。在渲染域 Node2D 的 _draw() 回调内使用（draw_* 只能在该回调里调）。
extends RefCounted

const INK := Color(0.169, 0.125, 0.094)  # 暖墨黑 #2b2018


## 主入口：把 pts 折线画成抖动变宽墨线。
## opts: amp(抖幅px,默认1.1) wave(波长px,默认32) overshoot(出头px,默认3.0)
##       taper(变宽bool,默认true) color(默认INK) closed(闭合环bool)
static func stroke(ci: CanvasItem, pts: PackedVector2Array, width: float, rng: RandomNumberGenerator, opts: Dictionary = {}) -> void:
	if pts.size() < 2:
		return
	var path := _prepare_path(pts, rng, opts)
	_draw_variable_width(ci, path, width, rng, opts)


## 矩形四边一条闭合环（角部连续抖动 + 角部出头）。
static func rect(ci: CanvasItem, r: Rect2, width: float, rng: RandomNumberGenerator, opts: Dictionary = {}) -> void:
	opts["closed"] = true
	var pts := PackedVector2Array([
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
		r.position,
	])
	stroke(ci, pts, width, rng, opts)


## 凸多边形内排线（阴影/质感线），线段自动裁剪到多边形内。
static func hatch_in_poly(ci: CanvasItem, poly: PackedVector2Array, spacing: float, angle_deg: float, width: float, rng: RandomNumberGenerator, alpha: float = 0.22) -> void:
	if poly.size() < 3:
		return
	var aabb := _poly_aabb(poly)
	var dir := Vector2.RIGHT.rotated(deg_to_rad(angle_deg))
	var nrm := Vector2(-dir.y, dir.x)
	var center := (aabb.position + aabb.end) * 0.5
	var half := aabb.size.length() * 0.5
	var t := rng.randf_range(-half, half)
	while t < half:
		var origin := center + nrm * t - dir * half
		var seg := _clip_seg_poly(origin, dir, half * 2.0, poly)
		if seg.size() == 2 and seg[0].distance_to(seg[1]) > 3.0:
			var pts := PackedVector2Array([seg[0], seg[1]])
			var jitter := rng.randf_range(0.4, 1.0)
			var path := _prepare_path(pts, rng, {"amp": 0.5 * jitter, "overshoot": 1.5})
			for i in path.size() - 1:
				ci.draw_line(path[i], path[i + 1], Color(INK.r, INK.g, INK.b, alpha * jitter), width)
		t += spacing * rng.randf_range(0.85, 1.15)


static func _prepare_path(pts: PackedVector2Array, rng: RandomNumberGenerator, opts: Dictionary) -> PackedVector2Array:
	var closed: bool = opts.get("closed", false)
	var step := 5.0
	var path := _resample(pts, step)
	path = _wobble(path, opts.get("amp", 1.1), opts.get("wave", 32.0), rng, closed)
	if not closed:
		var ov: float = opts.get("overshoot", 3.0)
		if ov > 0.0 and path.size() >= 2:
			var head_dir := (path[0] - path[1]).normalized()
			var tail_dir := (path[path.size() - 1] - path[path.size() - 2]).normalized()
			path.insert(0, path[0] + head_dir * ov * rng.randf_range(0.6, 1.2))
			path.push_back(path[path.size() - 1] + tail_dir * ov * rng.randf_range(0.6, 1.2))
	return path


static func _resample(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var d := a.distance_to(b)
		var n := maxi(1, ceili(d / step))
		for k in n:
			out.push_back(a.lerp(b, float(k) / float(n)))
	out.push_back(pts[pts.size() - 1])
	return out


## 环形锚点插值抖动（闭合时首尾天然连续）。
static func _wobble(path: PackedVector2Array, amp: float, wave: float, rng: RandomNumberGenerator, closed: bool) -> PackedVector2Array:
	var n_anchors := maxi(2, ceili(float(path.size()) * 5.0 / max(wave, 8.0)))
	var offs: Array[float] = []
	for i in n_anchors:
		offs.append(rng.randf_range(-amp, amp))
	var phase := rng.randf_range(0.0, TAU)
	var denom := float(path.size() - 1) if path.size() > 1 else 1.0
	var out := PackedVector2Array()
	for i in path.size():
		var af: float = float(i) / maxf(denom, 1.0) * float(n_anchors)
		var ia := int(af) % n_anchors
		var ib := (int(af) + 1) % n_anchors
		var o := lerpf(offs[ia], offs[ib], fmod(af, 1.0))
		var hf := 0.18 * amp * sin(float(i) * 0.55 + phase)
		var nrm := _normal_at(path, i)
		if closed:
			out.push_back(path[i] + nrm * (o + hf))
		else:
			# 开放路径端点抖动减半，避免与相邻构件错位过大
			var scale := 0.5 if (i == 0 or i == path.size() - 1) else 1.0
			out.push_back(path[i] + nrm * (o + hf) * scale)
	return out


static func _normal_at(path: PackedVector2Array, i: int) -> Vector2:
	var prev := path[maxi(i - 1, 0)]
	var next := path[mini(i + 1, path.size() - 1)]
	var d := next - prev
	if d.length() < 0.0001:
		return Vector2.ZERO
	return Vector2(-d.y, d.x).normalized()


static func _draw_variable_width(ci: CanvasItem, path: PackedVector2Array, width: float, rng: RandomNumberGenerator, opts: Dictionary) -> void:
	var taper: bool = opts.get("taper", true)
	var color: Color = opts.get("color", INK)
	var phase := rng.randf_range(0.0, TAU)
	var freq := rng.randf_range(1.3, 2.6)
	var denom := float(path.size() - 1)
	for i in path.size() - 1:
		var t: float = float(i) / maxf(denom, 1.0)
		var w := width
		if taper:
			w = width * (1.0 + 0.32 * sin(t * TAU * freq + phase))
		w = maxf(w, 0.6)
		ci.draw_line(path[i], path[i + 1], color, w)
		ci.draw_circle(path[i + 1], w * 0.5, color)


static func _poly_aabb(poly: PackedVector2Array) -> Rect2:
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)


## 线段（origin 出发 dir 方向 len 长）与凸多边形求交，返回裁剪后 [a, b] 或 []。
static func _clip_seg_poly(origin: Vector2, dir: Vector2, len: float, poly: PackedVector2Array) -> PackedVector2Array:
	var ts: Array[float] = []
	var a := poly[poly.size() - 1]
	for i in poly.size():
		var b := poly[i]
		var hit := _seg_seg_t(origin, dir, len, a, b - a)
		if not is_nan(hit):
			ts.append(hit)
		a = b
	if ts.size() < 2:
		return PackedVector2Array()
	ts.sort()
	return PackedVector2Array([origin + dir * ts[0], origin + dir * ts[ts.size() - 1]])


static func _seg_seg_t(o: Vector2, d: Vector2, len: float, e0: Vector2, e: Vector2) -> float:
	var denom := d.cross(e)
	if absf(denom) < 0.000001:
		return NAN
	var t: float = (e0 - o).cross(e) / denom
	var u := (e0 - o).cross(d) / denom
	if t < 0.0 or t > len or u < 0.0 or u > 1.0:
		return NAN
	return t
