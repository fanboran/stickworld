class_name TreeYarnBall
extends Node2D
## 毛线团树叶球 —— 终版架构的树叶实时渲染（用户 2026-09-05 定稿原话：
## "给我一个毛线团一样的一个球就行了……每秒都动态一次……随风飘动的感觉"）。
##
## 画法：深绿实心圆底衬（密不透风 + 冠形是圆）+ 球内随机弦线折线化
## （各方向均匀、统一粗细、上亮下暗三档绿出体积）。
## 动态：每秒翻一次姿态——40% 线重掷（风吹乱一部分叶）、60% 基线不动（连续感），
## 与 SketchCloud YARN 的姿态翻动同语言（节拍放慢到 1s，用户规格"每秒动态一次"）。
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
	# 底衬：深绿实心圆——密不透风（红线：线条要密）、轮廓是圆（红线：不是刺球）；
	# 压暗到明显深于线色，乱线才读得出来（毛线团的缠绕感）
	var under: Color = (_palette[2] as Color).darkened(0.38)
	under.a = 1.0
	draw_circle(Vector2.ZERO, radius * 0.97, under)
	# 线数按面积密度：大团封顶 330，小团保底 30（密不透风，宁过头不不足）
	var n_total := clampi(int(radius * radius / 100.0), 30, 330)
	# 统一粗细（红线：不要混特别细的线条），仅 ±10% 手抖
	var lw := clampf(radius * 0.055, 4.0, 8.0)
	for i in n_total:
		var is_base := (i % 10) >= int(SWAP_FRACTION * 10.0)
		_draw_strand(_strand_rng(0 if is_base else _variant, i), lw)


## 一根毛线：球内随机方向的弦，折线化出弯（端点收在 0.94R 内保圆轮廓）
func _draw_strand(rng: RandomNumberGenerator, lw: float) -> void:
	var th := rng.randf() * TAU
	var d := rng.randf_range(-0.85, 0.85) * radius
	var r_in := radius * 0.94
	var half := sqrt(maxf(r_in * r_in - d * d, 0.0))
	if half < lw * 1.5:
		return
	var dir := Vector2(cos(th), sin(th))
	var nrm := Vector2(-dir.y, dir.x)
	var mid := nrm * d
	var p0 := mid - dir * half
	var p1 := mid + dir * half
	var pts := PackedVector2Array()
	pts.append(p0 + dir * rng.randf_range(0.0, 3.0))
	for k in 2:
		var t := float(k + 1) / 3.0
		pts.append(p0.lerp(p1, t) + nrm * rng.randf_range(-1.0, 1.0) * half * 0.18)
	pts.append(p1 - dir * rng.randf_range(0.0, 3.0))
	# 三档色按弦高位置：上亮下暗（局部 y 向下为正）——毛线团的体积感
	var band := 1
	if mid.y < -radius * 0.2:
		band = 0
	elif mid.y > radius * 0.2:
		band = 2
	var col: Color = (_palette[band] as Color).lightened(0.05 if band == 0 else 0.0)
	col.a = 1.0
	draw_polyline(pts, col, lw * rng.randf_range(0.9, 1.1))
