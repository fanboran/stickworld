class_name TreeYarnBall
extends Node2D
## 毛线团树叶球 —— 终版架构的树叶实时渲染（用户 2026-09-06 反馈修正版）。
##
## 画法（用户定稿语言）："小学生画树的那种线条……像毛线团一样织在一起，
## 不是有个边界把线条强行截断了，而是线条本身就是有着自己的规律算法
## 绘制出来的"——**无底衬、无蒙版、无截断**，全部笔触 = 弧线：
##   · 绕心弧：锚点距离/角度/跨度参数化，锚点越靠外弧越长（自然贴出圆轮廓）
##   · 自由弧：随机方向 + 弦心距算好不出界，弯曲方向随机（织感、各方向都有）
## 线宽统一档 + 少量粗短笔做层次（"优化的粗细"），密度靠笔数堆满（密不透风）。
## 动态：每秒翻一次姿态——40% 笔重摇（风吹乱一部分叶）、60% 不动（连续感）。
## 种子确定性：同 base_seed 同貌（resource_node 位置哈希保证读档同树同貌）。

## 翻动节拍（用户规格：每秒动态一次）
const SWAP_INTERVAL := 1.0
## 姿态变体数
const VARIANTS := 4
## 每拍重掷的线占比（其余保持不动，翻动是"风吹乱"而非整体瞬移）
const SWAP_FRACTION := 0.4

## 叶色板（tree_pipeline.LEAF_PALETTES 同款：用户审美验收过的绿）
const PALETTES: Array = [
	[Color8(158, 196, 92), Color8(108, 162, 66), Color8(70, 118, 48)],
	[Color8(140, 192, 104), Color8(92, 152, 76), Color8(58, 112, 54)],
	[Color8(152, 186, 116), Color8(102, 150, 82), Color8(66, 116, 60)],
	[Color8(172, 196, 96), Color8(122, 164, 72), Color8(82, 126, 54)],
]

## 团半径（用户规格：冠 180 / 侧簇 15-30）
var radius := 60.0
## 确定性种子（位置哈希派生）
var base_seed := 0

var _timer := 0.0
var _variant := 0
var _palette: Array = PALETTES[0]


func _ready() -> void:
	_palette = PALETTES[abs(base_seed) % PALETTES.size()]
	queue_redraw()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_timer += delta
	if _timer >= SWAP_INTERVAL:
		_timer = fmod(_timer, SWAP_INTERVAL)
		_variant = (_variant + 1) % VARIANTS
		queue_redraw()


## 单条线的派生种子：基线（variant=0）跨姿态不变，姿态线随 _variant 换
func _strand_rng(variant: int, i: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d/%d/%d" % [base_seed, variant, i])
	return rng


func _draw() -> void:
	# 笔数按面积密度：大团封顶 360、小团保底 40——纯笔触堆满（密不透风，
	# 无底衬下靠覆盖倍率 ≥2.5x 保证任何点都有笔压着）
	var n_total := clampi(int(radius * radius / 95.0), 40, 360)
	# 线宽基准（统一粗细红线 + "优化的粗细"：±15% 手抖 + 12% 粗短笔层次）
	var lw := clampf(radius * 0.055, 5.5, 9.0)
	for i in n_total:
		var is_base := (i % 10) >= int(SWAP_FRACTION * 10.0)
		var rng := _strand_rng(0 if is_base else _variant, i)
		if rng.randf() < 0.5:
			_draw_orbit_arc(rng, lw)
		else:
			_draw_free_arc(rng, lw)


## 三档色按落笔高度：上亮下暗（局部 y 向下为正）——球体感
func _band_color(y: float, rng: RandomNumberGenerator) -> Color:
	var band := 1
	if y < -radius * 0.2:
		band = 0
	elif y > radius * 0.2:
		band = 2
	var col: Color = _palette[band]
	# 同档内轻微明度抖动（±4%）：笔触之间的呼吸感
	col = col.lightened(rng.randf_range(-0.04, 0.04))
	col.a = 1.0
	return col


## 绕心弧：锚点距球心 a，沿圆周走一段——毛线团"绕线"的本体。
## 锚点越靠外跨度越大（贴轮廓长弧），最外笔触的包络自然形成圆边，
## 线径向噪声 ≤3% 半径（松而不刺，红线：冠是圆不是刺球）
func _draw_orbit_arc(rng: RandomNumberGenerator, lw: float) -> void:
	var a := radius * rng.randf_range(0.18, 0.96)
	var th0 := rng.randf() * TAU
	var sign := 1.0 if rng.randf() < 0.5 else -1.0
	var sweep: float = deg_to_rad(rng.randf_range(30.0, 140.0)) * (0.4 + 0.6 * a / radius)
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


## 自由弧：随机方向的弯弧（二次贝塞尔），弦心距算好不出界——
## 各方向都有（红线：不要绕圈），弯向随机 = 毛线团的"织"
func _draw_free_arc(rng: RandomNumberGenerator, lw: float) -> void:
	var th := rng.randf() * TAU
	var d := rng.randf_range(-0.82, 0.82) * radius
	var r_in := radius * 0.95
	var half := sqrt(maxf(r_in * r_in - d * d, 0.0)) * rng.randf_range(0.55, 0.95)
	if half < lw * 1.5:
		return
	var dir := Vector2(cos(th), sin(th))
	var nrm := Vector2(-dir.y, dir.x)
	var mid := nrm * d
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
