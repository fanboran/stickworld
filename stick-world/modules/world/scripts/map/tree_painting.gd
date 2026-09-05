class_name TreePainting
extends Node2D
## 程序化手绘树 —— 终版架构（用户 2026-09-05 定稿）：树干放弃笔触拟合改算法直绘，
## 侧枝算法生成，树叶 = 毛线团球实时动态渲染（TreeYarnBall）。
##
## 局部坐标：原点 = 树根（地面接触点），y 向上为负。
## 全部规格数值来自用户数值规格书（2026-09-05 下午原话）：
##   干宽 50、高 700（下粗上细：顶部 0.6×）、冠圆心 = 干顶、半径 180、
##   侧枝长 100 水平 ±15°、0-5 个全随机、侧簇半径 15-30、
##   簇只出现在根部往上至少 200 像素且不与树冠叶重叠（硬要求）。
## 种子确定性：setup(seed) 后同种子同树（侧枝数/位置/弯相/色板全由种子决定）。
## 审美红线落实：干上线条全部顺干方向（竖直）；树皮/枝统一粗细档，无细笔。

const TRUNK_H := 700.0
const TRUNK_W_BASE := 50.0
const TRUNK_W_TOP := 30.0
## 冠整体包络半径（用户规格 r180；波浪轮廓由 TreeYarnBall 内部生成）
const CROWN_ENVELOPE := 180.0
## 侧枝规格（2026-09-06 修正：水平±15° → 斜向上 45° 左右；左右交替均衡分布；
## 侧簇直径翻倍：半径 15-30 → 30-60）
const BRANCH_LEN := 100.0
const BRANCH_ANG_MIN := 30.0
const BRANCH_ANG_MAX := 60.0
const CLUSTER_R_MIN := 30.0
const CLUSTER_R_MAX := 60.0
## 侧簇 y 带（局部 y 向上为负）：冠底 -520 再留 40 间隙 ~ 离地 350
const CLUSTER_Y_TOP := -480.0
const CLUSTER_Y_BOT := -350.0
const CLUSTER_Y_GAP := 50.0

## 干色三层（tree_pipeline.TRUNK_COLORS 同系：主色 / 树皮深色 / 枝深色）
const TRUNK_COL := Color8(116, 72, 34)
const BARK_COL := Color8(74, 44, 22)
const BRANCH_COL := Color8(88, 52, 26)
const BRANCH_HI_COL := Color8(140, 96, 52)

var _seed := 0
var _bend_phase := 0.0
var _flare_l := 10.0
var _flare_r := 10.0
var _root_arc := true    # 根脚形状：true=半圆弧（默认），false=浅波浪（偶尔变化）
var _bark_p1 := 0.0      # 树皮噪声场相位（setup 定值）
var _bark_p2 := 0.0
var _root_drop := 30.0   # 根脚下垂深度（setup 定值，绘制不可随机）
var _wob_phase_l := 0.0
var _wob_phase_r := 0.0
var _scars: Array = []        # {type, frac, x_off, r/len}
var _branches: Array = []     # {y, side, ang, r_cluster, cluster_c}
var _yarns: Array = []        # 子节点引用（冠 + 侧簇）


## 在 add_child 进树之前调用：种子决定全部结构（读档同树同貌）
func setup(tree_seed: int) -> void:
	_seed = tree_seed
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
	_bend_phase = rng.randf_range(0.0, TAU)
	_flare_l = rng.randf_range(4.0, 8.0)
	_flare_r = rng.randf_range(4.0, 8.0)
	_bark_p1 = rng.randf_range(0.0, TAU)
	_bark_p2 = rng.randf_range(0.0, TAU)
	_root_arc = rng.randf() > 0.15  # 85% 半圆弧俯视底，15% 浅波浪破单调
	# 下垂深度：半圆弧 ≈ 底半宽（俯视圆底面），波浪版浅
	var hw0 := TRUNK_W_BASE * 0.5 + (_flare_l + _flare_r) * 0.5
	_root_drop = hw0 * (rng.randf_range(0.70, 0.90) if _root_arc else rng.randf_range(0.22, 0.32))
	_wob_phase_l = rng.randf_range(0.0, TAU)
	_wob_phase_r = rng.randf_range(0.0, TAU)
	# 伤痕（生活常识频率：约 1/4 的树有一处，一棵最多 1 个）：
	# 圆形节疤直径≈树干粗细，或纵向长条裂纹 30-70
	if rng.randf() < 0.25:
		_scars.append({
			"type": "circle" if rng.randf() < 0.6 else "stripe",
			"frac": rng.randf_range(0.15, 0.85),
			"x_off": rng.randf_range(-0.35, 0.35),
			"r": TRUNK_W_BASE * rng.randf_range(0.42, 0.55),
			"len": rng.randf_range(30.0, 70.0),
		})
	# 侧枝：0-5 个全随机，y 带内间距 ≥50（用户规格）；左右交替分配保证均衡
	var n_br := rng.randi_range(0, 5)
	var flip := 1.0 if rng.randf() < 0.5 else -1.0
	var used_y: Array = []
	for i in n_br:
		var y := 0.0
		var ok := false
		for _try in 8:
			y = rng.randf_range(CLUSTER_Y_TOP, CLUSTER_Y_BOT)
			ok = true
			for uy in used_y:
				if absf(y - uy) < CLUSTER_Y_GAP:
					ok = false
					break
			if ok:
				break
		if not ok:
			continue
		used_y.append(y)
		_branches.append({
			"y": y,
			"side": flip if i % 2 == 0 else -flip,
			"ang": deg_to_rad(rng.randf_range(BRANCH_ANG_MIN, BRANCH_ANG_MAX)),
			"r_cluster": rng.randf_range(CLUSTER_R_MIN, CLUSTER_R_MAX),
		})
	# 冠 = 单个波浪轮廓毛线团（TreeYarnBall 内部生成连续鼓包轮廓，一笔画云式；
	## v4 的"主团+外圈独立圆团"拼贴已废弃——团间凹口深=米老鼠耳朵感）
	var crown_top := Vector2(0.0, -TRUNK_H)
	var pal_idx: int = rng.randi() % TreeYarnBall.PALETTES.size()
	var crown := TreeYarnBall.new()
	crown.radius = CROWN_ENVELOPE
	crown.base_seed = _seed + 101
	crown.palette_idx = pal_idx
	crown.position = crown_top
	add_child(crown)
	_yarns.append(crown)
	for i in _branches.size():
		var br: Dictionary = _branches[i]
		var side: float = br["side"]
		var dir := Vector2(side * cos(br["ang"]), -sin(br["ang"]))
		var rc: float = br["r_cluster"]
		var tip := Vector2(side * 8.0, br["y"]) + dir * BRANCH_LEN
		# 硬要求：侧簇不与冠重叠（波浪轮廓最大半径 ≈ envelope，按 0.97 收紧校验）；
		# 推挤后的最终簇位存回枝数据——枝绘制时伸到簇边（叶动枝跟，不分离）
		var cc: Vector2 = tip + dir * rc * 0.25
		var need := CROWN_ENVELOPE * 0.97 + rc + 24.0
		var dist := cc.distance_to(crown_top)
		if dist < need:
			cc += (cc - crown_top).normalized() * (need - dist)
		br["cluster_c"] = cc
		var cl := TreeYarnBall.new()
		cl.radius = rc
		cl.base_seed = _seed + 211 + i * 37
		cl.palette_idx = pal_idx
		cl.position = cc
		add_child(cl)
		_yarns.append(cl)


## 采集反馈：树冠+侧簇闪各色绿光（随机绿色相位的快脉冲 ×2——
## 用户 2026-09-06："闪光别是树根闪光，是树冠闪各色绿光"）
func flash_leaves() -> void:
	for y in _yarns:
		var ball: Node2D = y
		if not is_instance_valid(ball):
			continue
		var flash := Color.from_hsv(randf_range(0.24, 0.40), 0.85, 1.45)
		var tw := ball.create_tween()
		tw.tween_property(ball, "modulate", flash, 0.07)
		tw.tween_property(ball, "modulate", Color.WHITE, 0.10)
		tw.tween_property(ball, "modulate", Color.from_hsv(randf_range(0.24, 0.40), 0.85, 1.4), 0.07)
		tw.tween_property(ball, "modulate", Color.WHITE, 0.16)


## 干中轴随高度的水平偏移（双频叠加：顶部摆动大、根部钉死；种子决定相位）
func _axis_x(t: float) -> float:
	return sin(t * 2.2 + _bend_phase) * 6.0 * t + sin(t * 5.3 + _bend_phase * 1.7) * 2.5 * t


## 干半宽：下粗上细（50→30）+ 底部根展（指数衰减的喇叭展开）+ 每侧独立
## 双频扰动（种子相位——粗细的多样性）
func _half_w(t: float, side: float) -> float:
	var base := lerpf(TRUNK_W_BASE * 0.5, TRUNK_W_TOP * 0.5, pow(t, 0.85))
	var flare := (_flare_r if side > 0.0 else _flare_l) * exp(-t * 16.0)
	var ph := _wob_phase_r if side > 0.0 else _wob_phase_l
	return base + flare + (sin(t * 9.0 + ph) + sin(t * 17.3 + ph * 1.6) * 0.5) * 0.9


func _draw() -> void:
	# 侧枝先画（根部埋进干后），再画干盖住枝根
	for br: Dictionary in _branches:
		_draw_branch(br)
	_draw_trunk()
	for s: Dictionary in _scars:
		_draw_scar(s)


## 根脚下垂深度：setup 定值（半圆弧版 ≈ 底半宽，波浪版浅）
func _root_arc_drop(_half_w0: float) -> float:
	return _root_drop


## 根脚弧线在 x 处的下垂量：半圆（椭圆下半，sqrt 圆弧）或浅波浪（偶尔）
func _root_arc_y(x: float, cx: float, half_w0: float) -> float:
	var u: float = clampf((x - cx) / half_w0, -1.0, 1.0)
	if _root_arc:
		return _root_arc_drop(half_w0) * sqrt(maxf(1.0 - u * u, 0.0))
	return _root_arc_drop(half_w0) * sin((u + 1.0) * PI * 0.5)


## 竖条光照色：圆柱体横向连续渐变（两侧暗中心亮，sqrt 圆柱光照），
## 沿高度缓慢提亮（t 0→1 明度 0.94→1.03）；
## + 树皮质感：**竖纹**噪声场（u 方向多周期=干身多条竖纹、t 方向低频漂移=
## 纹路随高度缓慢弯——真实木纹流；u/t 均连续 → 条带间无断层）
func _trunk_band_color(u_mid: float, t: float) -> Color:
	var light := 0.80 + 0.36 * sqrt(maxf(1.0 - u_mid * u_mid, 0.0))
	var v := 0.94 + 0.09 * t
	var ripple: float = 0.065 * sin(u_mid * 16.0 - t * 2.5 + _bark_p1) \
		+ 0.040 * sin(u_mid * 29.0 + t * 1.7 + _bark_p2)
	light += ripple
	var c := Color(TRUNK_COL.r * light * v, TRUNK_COL.g * light * v, TRUNK_COL.b * light * v)
	c.a = 1.0
	return c


## 干：12×2 网格四边形拼合 → 横向圆柱光照连续渐变 + 高度缓慢渐变；
## 顶点全部按真实轮廓（中轴弯曲/宽度锥度）取样，底部沿半圆弧收边
func _draw_trunk() -> void:
	var bands := 12
	var rows := 2
	# 轮廓点：t 高度（0=根 1=顶）、u 横向（-1..1）；根行 y 用弧线下垂
	var cx := _axis_x(0.0)
	var hw0 := _half_w(0.0, 1.0)
	for row in rows:
		var t0 := float(row) / float(rows)
		var t1 := float(row + 1) / float(rows)
		for i in bands:
			var u0 := -1.0 + 2.0 * float(i) / float(bands)
			var u1 := -1.0 + 2.0 * float(i + 1) / float(bands)
			var col := _trunk_band_color((u0 + u1) * 0.5, (t0 + t1) * 0.5)
			var quad := PackedVector2Array([
				_trunk_pt(t0, u0, cx, hw0), _trunk_pt(t0, u1, cx, hw0),
				_trunk_pt(t1, u1, cx, hw0), _trunk_pt(t1, u0, cx, hw0)])
			draw_colored_polygon(quad, col)


func _trunk_pt(t: float, u: float, cx: float, hw0: float) -> Vector2:
	var x := _axis_x(t) + u * _half_w(t, u)
	var y := -TRUNK_H * t
	if t <= 0.0:
		y += _root_arc_y(x, cx, hw0)
	return Vector2(x, y)


## 伤痕（较少见）：圆圈节疤（深色环）或纵向长条裂纹（深色粗线）
func _draw_scar(s: Dictionary) -> void:
	var t: float = s["frac"]
	var y := -TRUNK_H * t
	var half := _half_w(t, 1.0)
	var c := Vector2(_axis_x(t) + float(s["x_off"]) * half * 0.9, y)
	var col := BARK_COL.darkened(0.25)
	col.a = 0.85
	if s["type"] == "circle":
		var n := 12
		var pts := PackedVector2Array()
		for j in n:
			var a := TAU * float(j) / float(n)
			pts.append(c + Vector2(cos(a), sin(a) * 0.85) * float(s["r"]))
		pts.append(pts[0])
		draw_polyline(pts, col, 5.0)
		draw_circle(c, float(s["r"]) * 0.28, col)
	else:
		var pts := PackedVector2Array()
		for j in 3:
			var tt := float(j) / 2.0
			var y2 := y - float(s["len"]) * 0.5 + float(s["len"]) * tt
			var t2: float = clampf(-y2 / TRUNK_H, 0.0, 1.0)
			pts.append(Vector2(_axis_x(t2) + float(s["x_off"]) * _half_w(t2, 1.0) * 0.9, y2))
		draw_polyline(pts, col, 5.0)


## 侧枝：斜向上 45° 档的上拱曲线，锥形主线 + 上缘高光 = 双线体积感（用户规格）；
## 终点伸到侧簇边缘（叶被防重叠推挤后枝跟过去，不分离）
func _draw_branch(br: Dictionary) -> void:
	var side: float = br["side"]
	var origin := Vector2(side * 8.0, br["y"])
	var dir := Vector2(side * cos(br["ang"]), -sin(br["ang"]))
	var rc: float = br["r_cluster"]
	var tip: Vector2 = br.get("cluster_c", origin + dir * BRANCH_LEN) - dir * rc * 0.25
	var ctrl := origin.lerp(tip, 0.5) + Vector2(0.0, -9.0)
	var pts := PackedVector2Array()
	var n := 8
	for i in n + 1:
		var t := float(i) / float(n)
		pts.append(origin.lerp(ctrl, t).lerp(ctrl.lerp(tip, t), t))
	# 锥形主线：分段画，宽 20 → 13（用户要求：起码主干 1/3 粗，主干 50 → 20 起）
	for i in pts.size() - 1:
		draw_line(pts[i], pts[i + 1], BRANCH_COL, lerpf(20.0, 13.0, float(i) / float(n)))
	# 上缘高光（第二根线，根部粗往梢部淡出）
	var hi := PackedVector2Array()
	for i in pts.size():
		hi.append(pts[i] + Vector2(0.0, -4.0))
	var hc := BRANCH_HI_COL
	hc.a = 0.55
	draw_polyline(hi, hc, 4.0)
