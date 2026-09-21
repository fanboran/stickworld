extends Node2D
## 蓄力轨迹预览 —— SWL ArcherPredictedArrowPath 的复刻（拉弓/投矛期间）。
##
## 原版真值（IL2CPP dump）：numberOfPredictionsIntoFuture / timeBetweenPredictions /
## AlphaRatio（透明度随序号衰减）/ ProjectilePositionOverTime(startingPosition,
## startingVelocity, t)——抛物线采样预测点列。杖指向施法时画落点 AOE 圈。
##
## 纯 _draw 自绘（ProgressPainter/HealthBarIndicator 同款惯例），
## 2D 画布域直绘（箭矢同层 z=900——预览的就是箭矢将要飞的弹道域），
## 默认隐藏，拉弓态由 entity_possession 每帧 set_trajectory 刷新。

## 预测点数与间隔（原版同语义：点数 × 间隔 = 预览时长窗口）
const DOT_COUNT: int = 12
const TIME_STEP: float = 0.055
## 点半径（首点→末点渐缩，AlphaRatio 衰减观感）
const DOT_RADIUS_FIRST: float = 5.0
const DOT_RADIUS_LAST: float = 2.0
## 预览点颜色（白，透明度衰减）
const DOT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.9)
## AOE 圈颜色（杖指向施法落点指示）
const AOE_COLOR: Color = Color(0.55, 0.4, 1.0, 0.55)

## 弹道预览态（active 时按 origin/velocity/gravity 抛物线采样画点列）
var _active: bool = false
var _origin: Vector2 = Vector2.ZERO
var _velocity: Vector2 = Vector2.ZERO
var _gravity: float = 2000.0
## AOE 圈预览态（指向施法：落点 + 半径）
var _aoe_active: bool = false
var _aoe_center: Vector2 = Vector2.ZERO
var _aoe_radius: float = 90.0


func _ready() -> void:
	z_as_relative = false
	z_index = 900
	visible = false


## 弹道预览（弓/矛蓄力态每帧刷新）：origin/velocity 为世界坐标，
## gravity 与投射物同源（箭 ARROW_GRAVITY / 矛 SPEAR_GRAVITY）。
func set_trajectory(origin: Vector2, velocity: Vector2, gravity: float = 2000.0) -> void:
	_active = true
	_aoe_active = false
	_origin = origin
	_velocity = velocity
	_gravity = gravity
	visible = true
	queue_redraw()


## AOE 圈预览（杖指向施法：落点=鼠标世界坐标，半径=法术档案 AOE）
func set_spell_aoe(center: Vector2, radius: float) -> void:
	_aoe_active = true
	_active = false
	_aoe_center = center
	_aoe_radius = radius
	visible = true
	queue_redraw()


## 隐藏预览（松手/取消附身；由实体侧统一收口）
func set_trajectory_active(v: bool) -> void:
	if not v:
		_active = false
		_aoe_active = false
		visible = false


func is_previewing() -> bool:
	return _active or _aoe_active


func _draw() -> void:
	if _active:
		_draw_trajectory_dots()
	elif _aoe_active:
		_draw_aoe_circle()


## 抛物线采样点列：p(t) = origin + velocity·t + ½·gravity·t²（y 向下为正，
## 与 arrow_projectile 积分同式）；透明度/半径随序号线性衰减（AlphaRatio）。
func _draw_trajectory_dots() -> void:
	for i in range(1, DOT_COUNT + 1):
		var t: float = float(i) * TIME_STEP
		var pos: Vector2 = _origin + _velocity * t \
				+ Vector2(0.0, 0.5 * _gravity * t * t)
		var ratio: float = float(i) / float(DOT_COUNT)
		var radius: float = lerpf(DOT_RADIUS_FIRST, DOT_RADIUS_LAST, ratio)
		var color: Color = DOT_COLOR
		color.a *= (1.0 - 0.75 * ratio)
		draw_circle(to_local(pos), radius, color)


## 落点 AOE 圈（杖指向施法）：实心淡圈 + 描边
func _draw_aoe_circle() -> void:
	var center_local: Vector2 = to_local(_aoe_center)
	draw_circle(center_local, _aoe_radius, AOE_COLOR)
	draw_arc(center_local, _aoe_radius, 0.0, TAU, 48,
			Color(AOE_COLOR.r, AOE_COLOR.g, AOE_COLOR.b, 0.9), 2.0)
