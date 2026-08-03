class_name HealthBarIndicator
extends Node2D
## 头顶血条 -- 火柴人受击后显示 HP 比例，满血隐藏。
##
## 由 StickmanEntity 装配，监听 HealthComponent 信号自动刷新。
## 绘制方案参照 ActionProgressIndicator（自绘矩形，无资源依赖）。

const BAR_WIDTH: float = 46.0
const BAR_HEIGHT: float = 5.0
const OFFSET_Y: float = -140.0
const COLOR_BG := Color(0, 0, 0, 0.6)
const COLOR_FG_HIGH := Color(0.35, 0.85, 0.35, 1.0)  ## 高血量（绿）
const COLOR_FG_MID := Color(1.0, 0.8, 0.25, 1.0)    ## 中血量（黄）
const COLOR_FG_LOW := Color(0.9, 0.3, 0.25, 1.0)    ## 低血量（红）
const COLOR_BORDER := Color(0, 0, 0, 0.85)
## 中/低血量阈值（比例）
const MID_THRESHOLD: float = 0.6
const LOW_THRESHOLD: float = 0.3

## 当前血量比例 [0,1]
var _ratio: float = 1.0
## 已连接的健康组件（_ready 后设置）
var _health: Node = null


func _ready() -> void:
	z_index = 50
	position.y = OFFSET_Y
	visible = false


## 绑定 HealthComponent（由实体装配时调用），自动监听受伤/恢复。
func setup(health: Node) -> void:
	_health = health
	if _health == null:
		return
	if _health.has_signal("damaged"):
		_health.damaged.connect(_on_damaged)
	if _health.has_signal("healed"):
		_health.healed.connect(_on_healed)
	if _health.has_signal("died"):
		_health.died.connect(_on_died)


## 手动设置血量比例（也供外部直接调用）
func set_ratio(ratio: float) -> void:
	_ratio = clampf(ratio, 0.0, 1.0)
	# 满血不显示（未受伤的火柴人不挂血条）
	visible = _ratio < 1.0 and _ratio > 0.0
	queue_redraw()


func hide_bar() -> void:
	visible = false
	queue_redraw()


## 受伤回调（damaged 信号带 amount, source 两参）
func _on_damaged(_amount: float, _source: Node) -> void:
	_refresh()


## 治疗回调（healed 信号带 amount 一参）
func _on_healed(_amount: float) -> void:
	_refresh()


## 从 HealthComponent 读取当前比例并刷新
func _refresh() -> void:
	if _health == null or not is_instance_valid(_health):
		return
	var max_hp: float = _health.get("max_hp") if "max_hp" in _health else 1.0
	var hp: float = _health.get("hp") if "hp" in _health else 0.0
	if max_hp <= 0.0:
		return
	set_ratio(hp / max_hp)


func _on_died() -> void:
	hide_bar()


func _draw() -> void:
	if not visible or _ratio <= 0.0:
		return
	var x: float = -BAR_WIDTH * 0.5
	draw_rect(Rect2(x, 0, BAR_WIDTH, BAR_HEIGHT), COLOR_BG, true)
	var fg_w: float = BAR_WIDTH * _ratio
	if fg_w > 0.0:
		var color: Color = COLOR_FG_HIGH
		if _ratio <= LOW_THRESHOLD:
			color = COLOR_FG_LOW
		elif _ratio <= MID_THRESHOLD:
			color = COLOR_FG_MID
		draw_rect(Rect2(x, 0, fg_w, BAR_HEIGHT), color, true)
	draw_rect(Rect2(x, 0, BAR_WIDTH, BAR_HEIGHT), COLOR_BORDER, false, 1.0)
