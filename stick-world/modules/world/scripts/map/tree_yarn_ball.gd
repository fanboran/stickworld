class_name TreeYarnBall
extends Node2D
## 毛线团树叶球 —— 终版架构的树叶实时渲染（用户 2026-09-06 二次修正版）。
##
## 轮廓（用户："小孩子画云——大圆圈小圆圈的笔迹线条应该是连续的"）：
## 一条**连续波浪弧线**围一圈（小学生一笔画云），7-10 个鼓包沿圆周融合，
## 上半圈鼓包大（云朵上缘鼓）、下半圈收平——鼓包间笔迹连续，不是独立圆拼贴。
## 轮廓由固定种子生成（跨姿态稳定），内部笔触每秒翻动。
##
## 填充："线条本身就是有着自己的规律算法"——绕心弧 + 自由弯弧，
## 锚点半径按波浪轮廓 radius_at(θ) 收紧，无蒙版无截断、不出界。
## 密度按周长线性给笔数（笔长随半径缩放，覆盖倍率恒定 ≥2.5x——
## 宁过头不不足，v4 曾因平方公式+clamp 底漏成筛子）。
## 动态：每秒 40% 笔重摇（风吹乱叶），60% 不动（连续感）。

## 翻动节拍（用户规格：每秒动态一次）
const SWAP_INTERVAL := 1.0
## 姿态变体数
const VARIANTS := 4
## 每拍重掷的线占比
const SWAP_FRACTION := 0.4
## 轮廓采样段数（连续波浪线的平滑度）
const OUTLINE_SEGS := 56

## 叶色板（tree_pipeline.LEAF_PALETTES 同款：用户审美验收过的绿）
const PALETTES: Array = [
	[Color8(158, 196, 92), Color8(108, 162, 66), Color8(70, 118, 48)],
	[Color8(140, 192, 104), Color8(92, 152, 76), Color8(58, 112, 54)],
	[Color8(152, 186, 116), Color8(102, 150, 82), Color8(66, 116, 60)],
	[Color8(172, 196, 96), Color8(122, 164, 72), Color8(82, 126, 54)],
]

## 团基准半径（波浪包络 ≈ radius×0.90 + 鼓包）
var radius := 60.0
## 确定性种子（位置哈希派生）
var base_seed := 0
## 色板下标（-1 = 按 base_seed 自选；由 TreePainting 统一指定 → 整树同色板）
var palette_idx := -1

var _timer := 0.0
var _variant := 0
var _palette: Array = PALETTES[0]
var _bumps: Array = []  # {a: 角度, amp: 幅度}——连续波浪轮廓的鼓包


func _ready() -> void:
	_palette = PALETTES[(abs(base_seed) if palette_idx < 0 else palette_idx) % PALETTES.size()]
	_gen_bumps()
	queue_redraw()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_timer += delta
	if _timer >= SWAP_INTERVAL:
		_timer = fmod(_timer, SWAP_INTERVAL)
		_variant = (_variant + 1) % VARIANTS
		queue_redraw()


## 固定来源 RNG（轮廓/结构用，跨姿态稳定）
func _stable_rng(slot: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d/stable/%d" % [base_seed, slot])
	return rng


## 姿态 RNG（内部笔触用，随 _variant 翻动）
func _strand_rng(variant: int, i: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d/%d/%d" % [base_seed, variant, i])
	return rng


## 连续波浪轮廓：7-10 个鼓包沿圆周均匀+抖动分布，高斯钟形融合成一条连续曲线；
## 上半圈（Godot y 向下，sin<0 为上）鼓包大、下半圈收平——云朵上鼓下收
func _gen_bumps() -> void:
	var rng := _stable_rng(97)
	_bumps.clear()
	var n := rng.randi_range(7, 10)
	for k in n:
		var a := TAU * float(k) / float(n) + rng.randf_range(-0.18, 0.18)
		var up := 1.0 if sin(a) < -0.05 else 0.42
		_bumps.append({
			"a": a,
			"amp": radius * rng.randf_range(0.14, 0.26) * up,
		})


func _ang_diff(a: float, b: float) -> float:
	var d := fmod(a - b, TAU)
	if d > PI:
		d -= TAU
	elif d < -PI:
		d += TAU
	return absf(d)


## 波浪轮廓在角度 θ 处的半径（基础圆 + 鼓包高斯叠加）
func _outline_radius(theta: float) -> float:
	var r := radius * 0.90
	var sig := TAU / maxf(_bumps.size(), 1.0) * 0.6
	for b: Dictionary in _bumps:
		var d := _ang_diff(theta, b["a"])
		r += float(b["amp"]) * exp(-d * d / (2.0 * sig * sig))
	return r


func _draw() -> void:
	# 线宽基准（统一粗细红线 + "优化的粗细"：±15% 手抖 + 12% 粗短笔层次）
	var lw := clampf(radius * 0.055, 5.5, 9.0)
	# 笔数按周长线性（笔长随半径缩放 → 覆盖倍率恒定；系数 14 宁过头不不足）
	var n_total := clampi(roundi(14.0 * radius / lw), 70, 520)
	for i in n_total:
		var is_base := (i % 10) >= int(SWAP_FRACTION * 10.0)
		var rng := _strand_rng(0 if is_base else _variant, i)
		if rng.randf() < 0.5:
			_draw_orbit_arc(rng, lw)
		else:
			_draw_free_arc(rng, lw)
	_draw_outline(lw)


## 三档色按落笔高度：上亮下暗（局部 y 向下为正）——球体感
func _band_color(y: float, rng: RandomNumberGenerator) -> Color:
	var band := 1
	if y < -radius * 0.2:
		band = 0
	elif y > radius * 0.2:
		band = 2
	var col: Color = _palette[band]
	col = col.lightened(rng.randf_range(-0.04, 0.04))
	col.a = 1.0
	return col


## 绕心弧：锚点距球心 a，沿圆周走一段——毛线团"绕线"的本体。
## 锚点上限按波浪轮廓收紧（无截断，位置天然合法），越靠外的弧越长贴轮廓
func _draw_orbit_arc(rng: RandomNumberGenerator, lw: float) -> void:
	var th0 := rng.randf() * TAU
	var sign := 1.0 if rng.randf() < 0.5 else -1.0
	var sweep: float = deg_to_rad(rng.randf_range(30.0, 140.0))
	# 弧中点角度的轮廓半径决定锚点带（靠外 sweep 放大成长弧）
	var th_mid := th0 + sign * sweep * 0.5
	var r_max := _outline_radius(th_mid) * 0.965
	var a := rng.randf_range(0.18, 1.0) * r_max
	sweep *= 0.4 + 0.6 * clampf(a / (radius * 0.965), 0.0, 1.0)
	var r_jit := radius * rng.randf_range(0.0, 0.03)
	var pts := PackedVector2Array()
	var n := 6
	for j in n + 1:
		var t := float(j) / float(n)
		var th := th0 + sign * sweep * t
		var r := a + sin(t * PI) * r_jit
		pts.append(Vector2(cos(th), sin(th)) * r)
	var wide := 1.35 if rng.randf() < 0.12 else 1.0
	draw_polyline(pts, _band_color((pts[0].y + pts[n].y) * 0.5, rng),
		lw * rng.randf_range(0.85, 1.15) * wide)


## 自由弧：随机方向的弯弧（二次贝塞尔），可用半径按锚点方向的波浪轮廓算——
## 各方向都有（红线：不要绕圈），弯向随机 = 毛线团的"织"
func _draw_free_arc(rng: RandomNumberGenerator, lw: float) -> void:
	var th := rng.randf() * TAU
	var d := rng.randf_range(-0.82, 0.82) * radius
	var mid := Vector2(-sin(th), cos(th)) * d
	var r_in: float = _outline_radius(atan2(mid.y, mid.x)) * 0.955
	var half := sqrt(maxf(r_in * r_in - d * d, 0.0)) * rng.randf_range(0.55, 0.95)
	if half < lw * 1.5:
		return
	var dir := Vector2(cos(th), sin(th))
	var nrm := Vector2(-dir.y, dir.x)
	var p0 := mid - dir * half
	var p1 := mid + dir * half
	var ctrl := mid + nrm * rng.randf_range(-1.0, 1.0) * half * 0.35
	var pts := PackedVector2Array()
	var n := 5
	for j in n + 1:
		var t := float(j) / float(n)
		pts.append(p0.lerp(ctrl, t).lerp(ctrl.lerp(p1, t), t))
	var wide := 1.35 if rng.randf() < 0.12 else 1.0
	draw_polyline(pts, _band_color(mid.y, rng), lw * rng.randf_range(0.85, 1.15) * wide)




## 连续波浪轮廓线（外圈圆圈，用户点名要回）：上亮下暗分两半画，
## 半径外移 lw×0.45 —— 内缘压进贴边笔触层，皮馅咬合无缝（修复
## v7"轮廓与填料之间空隙"的皮馅分离）；粗一档 + 逐点微扰（手绘抖动）
func _draw_outline(lw: float) -> void:
	var rng := _stable_rng(31)
	var jitter: Array = []
	for j in OUTLINE_SEGS:
		jitter.append(rng.randf_range(-0.012, 0.012))
	var col_up: Color = (_palette[1] as Color).lightened(0.06)
	col_up.a = 1.0
	var col_dn: Color = (_palette[2] as Color).lightened(0.04)
	col_dn.a = 1.0
	# Godot y 向下：θ∈[0,PI]（sin>0）是下半圈用暗色，θ∈[PI,TAU] 是上半圈用亮色；
	# 两条半 polyline，θ=0/PI 处同 jitter 同点衔接（笔迹连续）
	for half in 2:
		var pts := PackedVector2Array()
		var th0 := PI * float(half)
		for j in OUTLINE_SEGS / 2 + 1:
			var th := th0 + PI * float(j) / float(OUTLINE_SEGS / 2.0)
			var jj := (j + (OUTLINE_SEGS / 2 if half == 1 else 0)) % OUTLINE_SEGS
			var r: float = (_outline_radius(th) + lw * 0.45) * (1.0 + float(jitter[jj]))
			pts.append(Vector2(cos(th), sin(th)) * r)
		draw_polyline(pts, col_dn if half == 0 else col_up, lw * 1.3)
