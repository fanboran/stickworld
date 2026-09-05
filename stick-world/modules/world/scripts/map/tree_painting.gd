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
var _bark_offsets: Array = []  # {frac, alpha, w}
var _branches: Array = []      # {y, side, ang, r_cluster}
var _yarns: Array = []         # 子节点引用（冠 + 侧簇）


## 在 add_child 进树之前调用：种子决定全部结构（读档同树同貌）
func setup(tree_seed: int) -> void:
	_seed = tree_seed
	var rng := RandomNumberGenerator.new()
	rng.seed = tree_seed
	_bend_phase = rng.randf_range(0.0, TAU)
	_flare_l = rng.randf_range(7.0, 14.0)
	_flare_r = rng.randf_range(7.0, 14.0)
	# 树皮线：10-14 条，横偏 + 深浅 + 宽各随机（全部顺干方向）
	var n_bark := rng.randi_range(10, 14)
	for i in n_bark:
		_bark_offsets.append({
			"frac": rng.randf_range(-0.72, 0.72),
			"alpha": rng.randf_range(0.24, 0.42),
			"w": rng.randf_range(3.0, 4.6),
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
		# 硬要求：侧簇不与冠重叠（波浪轮廓最大半径 ≈ envelope，按 0.97 收紧校验）
		var cc: Vector2 = tip + dir * rc * 0.25
		var need := CROWN_ENVELOPE * 0.97 + rc + 10.0
		var dist := cc.distance_to(crown_top)
		if dist < need:
			cc += (cc - crown_top).normalized() * (need - dist)
		var cl := TreeYarnBall.new()
		cl.radius = rc
		cl.base_seed = _seed + 211 + i * 37
		cl.palette_idx = pal_idx
		cl.position = cc
		add_child(cl)
		_yarns.append(cl)


## 干中轴随高度的水平偏移（双频叠加：顶部摆动大、根部钉死；种子决定相位）
func _axis_x(t: float) -> float:
	return sin(t * 2.2 + _bend_phase) * 6.0 * t + sin(t * 5.3 + _bend_phase * 1.7) * 2.5 * t


## 干半宽：下粗上细（50→30）+ 底部根展（指数衰减的喇叭展开）
func _half_w(t: float, side: float) -> float:
	var base := lerpf(TRUNK_W_BASE * 0.5, TRUNK_W_TOP * 0.5, pow(t, 0.85))
	var flare := (_flare_r if side > 0.0 else _flare_l) * exp(-t * 16.0)
	return base + flare + sin(t * 9.0 + _bend_phase * 2.3) * 0.8


func _draw() -> void:
	# 侧枝先画（根部埋进干后），再画干盖住枝根
	for br: Dictionary in _branches:
		_draw_branch(br)
	_draw_trunk()
	for b: Dictionary in _bark_offsets:
		_draw_bark_line(b)


## 干：左右轮廓点合成的多边形（直绘，不走笔触拟合）
func _draw_trunk() -> void:
	var n := 14
	var right := PackedVector2Array()
	var left := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / float(n)
		var y := -TRUNK_H * t
		var xc := _axis_x(t)
		right.append(Vector2(xc + _half_w(t, 1.0), y))
		left.append(Vector2(xc - _half_w(t, -1.0), y))
	var poly := PackedVector2Array()
	poly.append_array(right)
	left.reverse()
	poly.append_array(left)
	var col := TRUNK_COL
	col.a = 1.0
	draw_colored_polygon(poly, col)


## 树皮线：一条 = 顺干方向的折线（红线：干上线条必须顺干方向）
func _draw_bark_line(b: Dictionary) -> void:
	var frac: float = b["frac"]
	var pts := PackedVector2Array()
	var n := 7
	for i in n + 1:
		var t := 0.02 + (float(i) / float(n)) * 0.95
		var x := _axis_x(t) + frac * _half_w(t, signf(frac)) * 0.82
		pts.append(Vector2(x, -TRUNK_H * t))
	var col := BARK_COL
	col.a = float(b["alpha"])
	draw_polyline(pts, col, float(b["w"]))


## 侧枝：水平 ±15° 的上拱曲线，锥形主线 + 上缘高光 = 双线体积感（用户规格）
func _draw_branch(br: Dictionary) -> void:
	var side: float = br["side"]
	var origin := Vector2(side * 8.0, br["y"])
	var dir := Vector2(side * cos(br["ang"]), -sin(br["ang"]))
	var tip := origin + dir * BRANCH_LEN
	var ctrl := origin.lerp(tip, 0.5) + Vector2(0.0, -9.0)
	var pts := PackedVector2Array()
	var n := 8
	for i in n + 1:
		var t := float(i) / float(n)
		pts.append(origin.lerp(ctrl, t).lerp(ctrl.lerp(tip, t), t))
	# 锥形主线：分段画，宽 18 → 12（用户要求：起码主干 1/3 粗，主干 50 → 18 起）
	for i in pts.size() - 1:
		draw_line(pts[i], pts[i + 1], BRANCH_COL, lerpf(18.0, 12.0, float(i) / float(n)))
	# 上缘高光（第二根线，根部粗往梢部淡出）
	var hi := PackedVector2Array()
	for i in pts.size():
		hi.append(pts[i] + Vector2(0.0, -4.0))
	var hc := BRANCH_HI_COL
	hc.a = 0.55
	draw_polyline(hi, hc, 4.0)
