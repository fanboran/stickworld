class_name SteeringStuck
extends RefCounted
## 卡住检测公共组件 —— 从 behavior_wander 抽出的三件套（卡住检测 / 掉头 / 冷却），
## wander 与静态障碍避障（steering_wall_avoid）两边复用（寻路避障方案A，调研
## `docs/技术/架构/寻路避障调研.md` §三 P0 第 1 条）。
##
## 判定口径：单拍位移 < STUCK_DIST 持续累计，超 STUCK_TIME 视为卡住（触发一次
## 并进入冷却——冷却期内不检测，防止掉头后立刻又触发左右抽搐）。掉头方向 =
## 当前方向旋转 120°~240°（偏向大掉头而非侧转，避免垂直于墙来回横跳）。
##
## 纯状态组件：不持实体引用，位置由调用方逐拍喂入（行为层节流拍/物理帧均可）。

## 卡住检测窗口（s）：窗口内持续微位移才算卡住
const STUCK_TIME: float = 0.2
## 卡住位移阈值（px）：单拍位移低于此视为"没动"
const STUCK_DIST: float = 3.0
## 卡住恢复冷却（s）：触发后冷却期内不再检测（防连续触发左右抽搐）
const STUCK_COOLDOWN: float = 0.5

## 上一拍位置
var _last_pos: Vector2 = Vector2.ZERO
## 窗口内累计卡住时长
var _timer: float = 0.0
## 冷却剩余
var _cooldown: float = 0.0
## 是否已喂过首拍位置（首拍不比位移）
var _armed: bool = false


## 进入行为时复位（喂初始位置）。
func arm(pos: Vector2) -> void:
	_last_pos = pos
	_timer = 0.0
	_cooldown = 0.0
	_armed = true


## 逐拍推进。返回 true = 本拍触发卡住（已进入冷却）。
func tick(delta: float, pos: Vector2) -> bool:
	if not _armed:
		arm(pos)
		return false
	if _cooldown > 0.0:
		_cooldown -= delta
		_last_pos = pos
		return false
	var moved: float = pos.distance_to(_last_pos)
	_last_pos = pos
	if moved >= STUCK_DIST:
		_timer = 0.0
		return false
	_timer += delta
	if _timer > STUCK_TIME:
		_timer = 0.0
		_cooldown = STUCK_COOLDOWN
		return true
	return false


## 是否处于冷却期（掉头恢复中，不检测）。
func in_cooldown() -> bool:
	return _cooldown > 0.0


## 卡住掉头方向（120°~240° 随机旋转，偏向大掉头防垂直横跳）：dir 为当前移动
## 方向（归一）；无有效方向时随机取一新向。静态方法，wander 与避障共用。
static func turn_away(dir: Vector2) -> Vector2:
	if dir.length() < 0.1:
		return Vector2.from_angle(randf() * TAU)
	# 120°~240° = PI*2/3 ~ PI*4/3，确保不会只转 90° 导致垂直于墙来回横跳
	var turn: float = randf_range(PI * 2.0 / 3.0, PI * 4.0 / 3.0)
	if randf() < 0.5:
		turn = -turn
	var cos_t: float = cos(turn)
	var sin_t: float = sin(turn)
	return Vector2(
		dir.x * cos_t - dir.y * sin_t,
		dir.x * sin_t + dir.y * cos_t
	).normalized()
