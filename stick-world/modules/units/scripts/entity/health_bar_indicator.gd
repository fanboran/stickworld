class_name HealthBarIndicator
extends Node2D
## 头顶阵营指示 + 手绘风血条。
##
## 视觉设计（2026-08-31 观察场审计重做）：
## - 阵营判断走血条本身，不染身体：满血 = 头顶一颗**阵营色小圆点**；
##   第一次掉血后圆点**展开为手绘动漫风横条**（实心填充 + 粗黑描边，
##   边缘带轻微弯曲扰动 = "计算机手绘逐帧抖动"（boiling line）效果）。
## - 条的填充色 = 阵营色（蓝方蓝条 / 红方红条），血量 = 填充长度；
##   掉血段有白色"残影"缓动跟随（格斗游戏血条惯例）。
## - 受击时血条左右抖动，幅度随受伤程度（shake energy 指数衰减）。
## - 条的**总长度与 max_hp 成正比**（巨物条更长），宽度有上下限。
## - 尸体隐藏。
##
## 绘制参照 ActionProgressIndicator（自绘，无资源依赖）。

# ─────────────────────────────── 常量 ────────────────────────────────
# 头顶标记高度：贴头顶但不压头（2026-09-05 观察场像素测量三轮定标：
# -110 时距头顶 ~1/3 身高视觉"飘"；-92 过调（孤立间隙 13-15px）；
# -85 实测孤立间隙 7-11px 落在目标带内。密集阵型中标记与前排身体
# 0-1px 贴靠是纵深阵型的物理结果，不靠本值解决）
const OFFSET_Y: float = -85.0
## 视口裁剪外扩边距（px）：单位中心出屏这么远才藏血条，避免屏缘闪烁
const VIEW_MARGIN: float = 64.0
## 圆点半径（px；2026-09-01 观察场反馈：0.55 缩放下 4.5px 只有 2.5 屏幕像素，
## 满血友军"像没血条"——微调放大可见性，设计语言不变（满血=点，掉血=条））
const DOT_RADIUS: float = 6.0
## 条高（px）
const BAR_HEIGHT: float = 7.0
## 条宽 = clamp(BASE + max_hp × K, MIN, MAX)：长度与血量上限成正比
const WIDTH_BASE: float = 34.0
const WIDTH_PER_HP: float = 0.42
const WIDTH_MIN: float = 34.0
const WIDTH_MAX: float = 96.0
## 描边宽（粗黑线 = 手绘实心线条感）
const OUTLINE_WIDTH: float = 1.6
## boiling line 抖动幅度（px，边缘扰动）与重掷间隔（s）
const WOBBLE_AMP: float = 0.9
const WOBBLE_INTERVAL: float = 0.12
## 受击抖动：最大水平偏移（px）与衰减速率
const SHAKE_MAX_OFFSET: float = 7.0
const SHAKE_FREQ: float = 46.0
## 白色掉血残影缓动速率
const TRAIL_LERP: float = 5.0
## 圆点 → 横条展开速率（每秒进度）
const EXPAND_SPEED: float = 7.0
## 阵营色（对齐 BattleInstance.FACTION_ATTACKER/DEFENDER；0 = 中性灰）
const FACTION_COLORS: Dictionary = {
	1: Color(0.38, 0.58, 0.98),  ## 蓝方（进攻）
	2: Color(0.88, 0.32, 0.26),  ## 红方（防守）
}
const COLOR_NEUTRAL := Color(0.75, 0.75, 0.72)
const COLOR_BG := Color(0.08, 0.07, 0.06, 0.72)
const COLOR_OUTLINE := Color(0.05, 0.04, 0.03, 0.95)
const COLOR_TRAIL := Color(1.0, 0.97, 0.9, 0.95)
## 低血闪烁（<30% 填充明度波动）
const LOW_THRESHOLD: float = 0.3

# ─────────────────────────────── 状态 ────────────────────────────────
## 当前血量比例 [0,1]
var _ratio: float = 1.0
## 已连接的健康组件（_ready 后设置）
var _health: Node = null
## 血量上限（决定条宽）
var _max_hp: float = 1.0
## 阵营 ID（0=未参战 → 灰点）
var _faction: int = 0
## 是否受过伤（true 后圆点展开为横条；治疗回满退回圆点）
var _ever_damaged: bool = false
## 展开进度 0(圆点)~1(全宽横条)
var _expand: float = 0.0
## 白色残影跟随比例
var _trail_ratio: float = 1.0
## 受击抖动能量 [0,1]
var _shake_energy: float = 0.0
## boiling line 相位（每 WOBBLE_INTERVAL 重掷）
var _wobble_seed: int = 0
var _wobble_timer: float = 0.0
## 抖动/展开动画计时
var _anim_time: float = 0.0


func _ready() -> void:
	# 绝对顶层：单位按 y 排序 z_index（0~140+）后，血条作为子节点若用相对 z
	# 会被更靠前的单位盖住——z_as_relative=false 挂全局顶层
	z_as_relative = false
	z_index = 1000
	position.y = OFFSET_Y
	visible = true


## 设置体型缩放（minidon 等小体型单位）：血条高度/大小同步缩小。
## 由实体 _apply_scale 转发调用。
func set_body_scale(bs: float) -> void:
	position.y = OFFSET_Y * bs
	scale = Vector2(maxf(0.1, bs), maxf(0.1, bs))


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
	_refresh()


## 设置阵营（由 StickmanEntity.set_faction 转发；切阵营换点/条颜色）
func set_faction(fid: int) -> void:
	_faction = fid
	queue_redraw()


func _process(delta: float) -> void:
	_anim_time += delta
	# boiling line：定期重掷扰动相位（手绘逐帧抖动感）。
	# 战斗性能优化：仅掉过血（横条形态）才抖——满血圆点无抖动细节，
	# 混战时 ~200 根满血条每 0.12s 的无条件重画（多边形重建+三角化）是纯浪费
	_wobble_timer += delta
	if _wobble_timer >= WOBBLE_INTERVAL and _ever_damaged:
		_wobble_timer = 0.0
		_wobble_seed = randi()
		queue_redraw()
	# 白色残影缓动（只在掉血方向追，回血直接跟）
	if _trail_ratio > _ratio:
		_trail_ratio = maxf(_ratio, lerpf(_trail_ratio, _ratio, TRAIL_LERP * delta))
		queue_redraw()
	else:
		_trail_ratio = _ratio
	# 受击抖动衰减
	if _shake_energy > 0.0:
		_shake_energy = maxf(0.0, _shake_energy - delta * (3.0 + _shake_energy * 5.0))
		queue_redraw()
	# 圆点 ↔ 横条展开动画
	var expand_target: float = 1.0 if _ever_damaged else 0.0
	if not is_equal_approx(_expand, expand_target):
		_expand = move_toward(_expand, expand_target, EXPAND_SPEED * delta)
		queue_redraw()


# ─────────────────────────────── 信号回调 ────────────────────────────────

## 受伤回调（damaged 信号带 amount, source 两参）：掉血展开 + 抖动。
func _on_damaged(amount: float, _source: Node) -> void:
	_ever_damaged = true
	var ratio_before: float = _ratio
	_refresh()
	# 抖动幅度 ∝ 受伤占上限比例（clamp 到有感知的范围）
	if _max_hp > 0.0 and amount > 0.0:
		_shake_energy = clampf(_shake_energy + (amount / _max_hp) * 2.6, 0.22, 1.0)
	if ratio_before <= 0.0 or _ratio < ratio_before:
		queue_redraw()


## 治疗回调（healed 信号带 amount 一参）：回满退回圆点。
func _on_healed(_amount: float) -> void:
	_refresh()


func _on_died() -> void:
	_ratio = 0.0
	visible = false
	set_process(false)  # 战斗性能优化：死单位血条不再每帧跑 _process
	queue_redraw()


## 从 HealthComponent 读取当前比例并刷新
func _refresh() -> void:
	if _health == null or not is_instance_valid(_health):
		return
	_max_hp = float(_health.get("max_hp")) if "max_hp" in _health else 1.0
	var hp: float = float(_health.get("hp")) if "hp" in _health else 0.0
	if _max_hp <= 0.0:
		return
	var new_ratio: float = clampf(hp / _max_hp, 0.0, 1.0)
	if new_ratio >= 1.0:
		# 回满：退回圆点（残留残影清零）
		_ever_damaged = false
		_trail_ratio = 1.0
	_ratio = new_ratio
	visible = hp > 0.0
	queue_redraw()


# ─────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	if not visible or _ratio <= 0.0:
		return
	var color: Color = FACTION_COLORS.get(_faction, COLOR_NEUTRAL)
	# 低血：填充明度闪烁（不用红色——红=低血会与红方语义撞色，改暗化+闪）
	if _ratio <= LOW_THRESHOLD:
		var flicker: float = 0.72 + 0.28 * sin(_anim_time * 10.0)
		color = color.darkened(1.0 - flicker)
	_draw_bar(color)
	# 展开未完成时叠加阵营圆点（渐隐）
	if _expand < 0.999:
		_draw_dot(color)


## 阵营色小圆点（展开进度越完整越淡出）
func _draw_dot(color: Color) -> void:
	var alpha: float = 1.0 - _expand
	var c := Color(color.r, color.g, color.b, color.a * alpha)
	var o := Color(COLOR_OUTLINE.r, COLOR_OUTLINE.g, COLOR_OUTLINE.b, COLOR_OUTLINE.a * alpha)
	var pts := _wobbled_circle(DOT_RADIUS, 10)
	draw_colored_polygon(pts, c)
	# 闭合手绘描边（跳过自动闭合的重复末点）
	var loop := pts.duplicate()
	loop.append(pts[0])
	draw_polyline(loop, o, OUTLINE_WIDTH)


## 手绘风横条：背景条 + 白残影 + 阵营填充 + 粗黑手绘描边。
## 水平受击抖动在此应用（左右来回，幅度 = 能量 × 最大偏移）。
func _draw_bar(color: Color) -> void:
	var width: float = clampf(WIDTH_BASE + _max_hp * WIDTH_PER_HP, WIDTH_MIN, WIDTH_MAX)
	var shake_x: float = sin(_anim_time * SHAKE_FREQ) * _shake_energy * SHAKE_MAX_OFFSET \
			+ sin(_anim_time * SHAKE_FREQ * 2.3) * _shake_energy * SHAKE_MAX_OFFSET * 0.3
	var h: float = BAR_HEIGHT
	var half: float = width * 0.5 * _expand
	if half < 1.0:
		return
	var left: float = -half + shake_x
	var bg := Rect2(left, -h * 0.5, half * 2.0, h)
	# 背景条（暗底）
	_draw_wobbly_rect(bg, COLOR_BG, COLOR_OUTLINE)
	# 白色掉血残影（长度按 trail 比例）
	if _trail_ratio > _ratio + 0.005:
		var trail_w: float = half * 2.0 * _trail_ratio
		var trail := Rect2(left, -h * 0.5, trail_w, h)
		_draw_wobbly_rect(trail, COLOR_TRAIL, Color(0, 0, 0, 0))
	# 阵营色填充（长度 = 血量）
	var fg_w: float = half * 2.0 * _ratio
	if fg_w > 0.5:
		var fg := Rect2(left, -h * 0.5, fg_w, h)
		_draw_wobbly_rect(fg, color, Color(0, 0, 0, 0))
	# 整体手绘描边盖在最上
	_draw_wobbly_rect(bg, Color(0, 0, 0, 0), COLOR_OUTLINE)


## 画一个"手绘感"实心矩形：上下边缘各 6 段、端头半圆、顶点带 boiling 扰动。
func _draw_wobbly_rect(r: Rect2, fill: Color, outline: Color) -> void:
	# 过窄矩形（展开动画起步 / 低血填充 / 残影尾端）加端帽与扰动后会自相交，
	# canvas 三角化失败报 Invalid polygon——细到看不出手绘感时退回普通矩形
	if r.size.x < 6.0 or r.size.y < 4.0:
		if fill.a > 0.0:
			draw_rect(r, fill, true)
		if outline.a > 0.0:
			draw_rect(r, outline, false, OUTLINE_WIDTH)
		return
	var pts := PackedVector2Array()
	var seg := 6
	var rad: float = r.size.y * 0.5
	# 上边缘（左→右）
	for i in seg + 1:
		var t: float = float(i) / float(seg)
		var x: float = r.position.x + r.size.x * t
		var ny: float = _wobble(i) * WOBBLE_AMP
		pts.append(Vector2(x, r.position.y + ny))
	# 右端外凸圆头（手绘收笔）：向外凸不向内凹——内凹会在端点形成
	# 针尖状退化细针，earclip 三角化直接失败（Invalid polygon）
	pts.append(Vector2(r.end.x + rad * 0.6 + _wobble(20) * WOBBLE_AMP,
			r.position.y + r.size.y * 0.5))
	# 下边缘（右→左）
	for i in seg + 1:
		var t: float = 1.0 - float(i) / float(seg)
		var x: float = r.position.x + r.size.x * t
		var ny: float = _wobble(i + 40) * WOBBLE_AMP
		pts.append(Vector2(x, r.end.y + ny))
	# 左端外凸圆头
	pts.append(Vector2(r.position.x - rad * 0.6 + _wobble(60) * WOBBLE_AMP,
			r.position.y + r.size.y * 0.5))
	if fill.a > 0.0:
		draw_colored_polygon(pts, fill)
	if outline.a > 0.0:
		var loop := pts.duplicate()
		loop.append(pts[0])
		draw_polyline(loop, outline, OUTLINE_WIDTH)


## 确定性伪噪声（-0.5~0.5）：seed 变化 = boiling 逐帧重掷
func _wobble(i: int) -> float:
	var v: float = sin(float(i) * 127.1 + float(_wobble_seed) * 0.3117) * 43758.5453
	return fposmod(v, 1.0) - 0.5


## 手绘感圆点轮廓（半径带扰动）
func _wobbled_circle(radius: float, seg: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in seg:
		var a: float = TAU * float(i) / float(seg)
		var r: float = radius + _wobble(i) * WOBBLE_AMP
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts
