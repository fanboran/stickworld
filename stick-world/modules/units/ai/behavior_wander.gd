class_name BehaviorWander
extends "res://modules/units/ai/behavior_base.gd"
## 漫游行为 -- 基于 Reynolds Steering Behaviors 的平滑漫游。
##
## 参考：Craig Reynolds, "Steering Behaviors for Autonomous Characters" (1999)
## https://www.red3d.com/cwr/steer/
##
## 核心改进（相比直线走向目标点）：
## 1. Wander：每帧微调方向角度，产生平滑曲线而非生硬直线
## 2. Boundary avoidance：接近地图边界时自动转向，不会"日墙"
## 3. Stuck recovery：检测到卡住后转 120~240°，而非继续撞墙
##
## params 可选字段：
##   - duration: float  漫游时长（秒），不传则随机 3~6 秒

# ─────────────────────────────── 常量 ────────────────────────────────
## 漫游最短/最长时长（秒）
const MIN_DURATION: float = 3.0
const MAX_DURATION: float = 6.0
## 方向角度每帧的最大变化量（弧度），值越大转向越急
const WANDER_JITTER: float = 2.5
## 卡住检测：如果 N 秒内移动距离 < 阈值，视为卡住
const STUCK_TIME: float = 0.2
const STUCK_DIST: float = 3.0
## 卡住恢复冷却时间（秒），防止连续触发导致左右抽搐
const STUCK_COOLDOWN: float = 0.5
## 边界规避余量（像素），进入此范围开始转向
const BOUNDARY_MARGIN: float = 80.0
## 边界规避力强度（相对于漫游方向的权重）
const BOUNDARY_FORCE: float = 3.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 当前漫游方向（归一化）
var _wander_dir: Vector2 = Vector2.ZERO
## 已漫游时间
var _timer: float = 0.0
## 本次漫游时长
var _duration: float = 4.0
## 上一帧位置（卡住检测用）
var _last_pos: Vector2 = Vector2.ZERO
## 卡住计时器
var _stuck_timer: float = 0.0
## 卡住恢复冷却（冷却期间不检测卡住，防止左右抽搐）
var _stuck_cooldown: float = 0.0


func _ready() -> void:
	behavior_name = "wander"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_timer = 0.0
	_duration = params.get("duration", randf_range(MIN_DURATION, MAX_DURATION))
	_last_pos = entity.global_position if entity != null else Vector2.ZERO
	_stuck_timer = 0.0
	_stuck_cooldown = 0.0
	_pick_new_direction()


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return

	_timer += delta

	# 漫游时长到了 -> 结束
	if _timer >= _duration:
		finish()
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return

	# ── 卡住检测（冷却期间跳过，防止转向后立刻又触发）──
	if _stuck_cooldown > 0.0:
		_stuck_cooldown -= delta
	else:
		var moved: float = entity.global_position.distance_to(_last_pos)
		if moved < STUCK_DIST:
			_stuck_timer += delta
			if _stuck_timer > STUCK_TIME:
				# 卡住了：转 120~240°，偏向掉头避免左右横跳
				_turn_away()
				_stuck_timer = 0.0
				_stuck_cooldown = STUCK_COOLDOWN
		else:
			_stuck_timer = 0.0
	_last_pos = entity.global_position

	# ── 边界规避 ──
	# 接近地图边缘时施加反向转向力
	var pos: Vector2 = entity.global_position
	var steer: Vector2 = Vector2.ZERO

	# X 轴边界
	if pos.x < entity.map_left + BOUNDARY_MARGIN:
		steer.x = (entity.map_left + BOUNDARY_MARGIN - pos.x) / BOUNDARY_MARGIN
	elif pos.x > entity.map_right - BOUNDARY_MARGIN:
		steer.x = -(pos.x - (entity.map_right - BOUNDARY_MARGIN)) / BOUNDARY_MARGIN

	# Y 轴边界（用脚部位置判断）
	var foot_y: float = pos.y + entity.foot_offset
	if foot_y < entity.ground_y + 30.0:
		steer.y = 0.5
	elif foot_y > entity.ground_bottom - 30.0:
		steer.y = -0.5

	# 边界力足够强时覆盖漫游方向
	if steer.length() > 0.1:
		_wander_dir = (_wander_dir + steer * BOUNDARY_FORCE).normalized()

	# ── 平滑漫游 ──
	# 每帧对方向做小角度旋转，产生平滑曲线
	_apply_jitter(delta)

	# 驱动实体
	if entity.has_method("ai_move"):
		entity.ai_move(_wander_dir)


# ─────────────────────────────── 内部方法 ────────────────────────────────

## 随机选一个新方向
func _pick_new_direction() -> void:
	_wander_dir = Vector2.from_angle(randf() * TAU)


## 卡住时转 120~240°，偏向掉头而非侧转，避免左右横跳抽搐
func _turn_away() -> void:
	if _wander_dir.length() < 0.1:
		_pick_new_direction()
		return
	# 120°~240° = PI*2/3 ~ PI*4/3，确保不会只转 90° 导致垂直于墙来回横跳
	var turn: float = randf_range(PI * 2.0 / 3.0, PI * 4.0 / 3.0)
	if randf() < 0.5:
		turn = -turn
	var cos_t: float = cos(turn)
	var sin_t: float = sin(turn)
	_wander_dir = Vector2(
		_wander_dir.x * cos_t - _wander_dir.y * sin_t,
		_wander_dir.x * sin_t + _wander_dir.y * cos_t
	).normalized()


## 每帧对方向做小角度随机旋转（Reynolds wander 的简化版）
func _apply_jitter(delta: float) -> void:
	# 随机角度偏移，scaled by delta 保持帧率无关
	var jitter: float = randf_range(-WANDER_JITTER, WANDER_JITTER) * delta
	var cos_t: float = cos(jitter)
	var sin_t: float = sin(jitter)
	_wander_dir = Vector2(
		_wander_dir.x * cos_t - _wander_dir.y * sin_t,
		_wander_dir.x * sin_t + _wander_dir.y * cos_t
	).normalized()
