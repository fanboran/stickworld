class_name StickmanEntity
extends CharacterBody2D
## 火柴人实体 —— 物理+碰撞外壳。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1。
## 在已有 StickmanRig（纯渲染骨架）外包一层 CharacterBody2D，
## 承担物理移动、碰撞、附身接口。
##
## P0 阶段：
##   - 玩家附身时 WASD 控制移动
##   - 未附身时静止 idle（AI 留到阶段 0.3）
##
## 子节点结构：
##   StickmanEntity (CharacterBody2D)
##   ├── RigHost (Node2D, 实例化 stickman_test.tscn，禁用其脚本)
##   │   ├── StickmanRig (Skeleton2D)
##   │   └── Node2D (IK markers parent)
##   └── CollisionShape2D

# ─────────────────────────────── 常量 ────────────────────────────────
## 基础行走速度（px/s）—— ×1.6 加速后
const WALK_SPEED: float = 160.0
## 奔跑速度—— ×1.6 加速后
const RUN_SPEED: float = 208.0
## walk 动画基准速率（速度=WALK_ANIM_BASE 时 anim_speed=1.0 * ANIM_SPEED_MULT）
const WALK_ANIM_BASE: float = 100.0
## 动画整体播放倍率（×1.4 加速）
const ANIM_SPEED_MULT: float = 1.4
## walk 动画最低播放速率
const MIN_ANIM_SCALE: float = 0.2
## 切到 idle 的速度阈值
const IDLE_THRESHOLD: float = 5.0
## 火柴人渲染缩放（对齐 stickman_test.BASE_SCALE * 1.5，适配 DESIGN_HEIGHT=1080）
const BASE_SCALE: float = 0.4

# ─────────────────────────────── @export ────────────────────────────────
## 是否被玩家附身（true=玩家控制，false=AI 控制）
@export var possessed: bool = false:
	set(v):
		possessed = v
		_on_possession_changed(v)

## 移动加速度（px/s²）
@export var accel: float = 600.0
## 减速度（px/s²）
@export var decel: float = 800.0

# ─────────────────────────────── 地面约束（§7.1.1）────────────────────────────────
## 地面线 Y（由 MapInstance.spawn_entity 注入，火柴人可走区域顶部）
var ground_y: float = 450.0
## 地面底部 Y（火柴人可走区域底部，= ground_y + DESIGN_HEIGHT * ground_ratio）
var ground_bottom: float = 882.0
## X 活动范围左边界（由 MapInstance 注入）
var map_left: float = 0.0
## X 活动范围右边界（由 MapInstance 注入）
var map_right: float = 8192.0
## 脚部到节点原点的偏移（CollisionShape2D 半高，约 45）
var foot_offset: float = 45.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## StickmanRig 引用（渲染骨架）
var rig: Node2D = null
## IK markers 父节点引用
var _markers_parent: Node2D = null
## 当前速度（标量，px/s）
var _current_speed: float = 0.0
## 是否在奔跑
var _is_running: bool = false
## 朝向（1=右，-1=左）
var _facing: int = 1
## 当前动画名
var _current_anim: String = "idle"
## 开场 IK workaround（前 0.25s 模拟向右移动触发 IK 解算）
var _startup_fix_time: float = 0.25
var _startup_fix_elapsed: float = 0.0
var _startup_done: bool = false


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _enter_tree() -> void:
	# 禁用 RigHost 上的 stickman_test.gd 脚本，阻止其 _ready/_process/_input 运行
	# 必须在 _ready 之前完成
	var rig_host := get_node_or_null("RigHost")
	if rig_host != null and rig_host.get_script() != null:
		rig_host.set_script(null)


func _ready() -> void:
	# 拿到 StickmanRig 和 IK markers 引用
	var rig_host := get_node_or_null("RigHost")
	if rig_host != null:
		rig = rig_host.get_node_or_null("StickmanRig")
		_markers_parent = rig_host.get_node_or_null("Node2D")
	# 应用初始缩放
	_apply_scale()
	# 播放 idle
	_play_anim("idle")


func _physics_process(delta: float) -> void:
	# 开场 IK workaround
	if not _startup_done:
		_startup_fix_elapsed += delta
		if _startup_fix_elapsed < _startup_fix_time:
			if rig != null:
				rig.position += Vector2.RIGHT * 30 * delta
				_sync_markers_transform()
				if _current_anim == "idle":
					_play_anim("walk")
			return
		else:
			_startup_done = true
			if rig != null:
				rig.position = Vector2.ZERO
				_sync_markers_transform()
			_play_anim("idle")
			_current_speed = 0.0
			velocity = Vector2.ZERO

	# 仅在被附身时处理玩家输入
	if possessed:
		_handle_player_input(delta)
	else:
		# P0：AI 未实现，逐渐减速到 idle
		_handle_deceleration(delta)
		velocity = velocity.lerp(Vector2.ZERO, decel * delta * 0.01)
		if velocity.length() < IDLE_THRESHOLD:
			velocity = Vector2.ZERO

	# 火柴人可在地面范围内上下左右移动（详见 §7.1.1）
	move_and_slide()
	# Y 范围约束：脚部保持在 [ground_y, ground_bottom] 内
	var y_min: float = ground_y - foot_offset
	var y_max: float = ground_bottom - foot_offset
	global_position.y = clampf(global_position.y, y_min, y_max)
	# X 边界约束
	global_position.x = clampf(global_position.x, map_left, map_right)
	_sync_markers_transform()


# ─────────────────────────────── 玩家输入 ────────────────────────────────

func _handle_player_input(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0

	if dir != Vector2.ZERO:
		if dir.length() > 1.0:
			dir = dir.normalized()
		if dir.x != 0:
			_facing = 1 if dir.x > 0 else -1
			_apply_scale()
		_handle_acceleration(delta)
		velocity = dir * _current_speed
	else:
		_handle_deceleration(delta)
		if _current_speed > 0:
			# 保留方向但减速
			var v_dir := velocity.normalized() if velocity.length() > 0.001 else Vector2.ZERO
			velocity = v_dir * _current_speed
		else:
			velocity = Vector2.ZERO


func _handle_acceleration(delta: float) -> void:
	if _is_running:
		_current_speed = RUN_SPEED
		return
	_current_speed += accel * delta
	if _current_speed >= WALK_SPEED:
		_is_running = true
		_current_speed = RUN_SPEED
		_play_anim("run")
		if rig != null:
			rig.set_anim_speed(1.0 * ANIM_SPEED_MULT)
	elif _current_anim != "walk" and _current_anim != "run":
		_play_anim("walk")
	if _current_anim == "walk" and not _is_running:
		var s := _current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT
		if rig != null:
			rig.set_anim_speed(maxf(s, MIN_ANIM_SCALE))


func _handle_deceleration(delta: float) -> void:
	if _is_running:
		_is_running = false
		_current_speed = WALK_SPEED
		_play_anim("walk")
	if _current_speed > 0:
		_current_speed -= decel * delta
		if _current_speed <= IDLE_THRESHOLD:
			_current_speed = 0.0
			_play_anim("idle")
		else:
			if _current_anim == "idle":
				_play_anim("walk")
			var s := _current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT
			if rig != null:
				rig.set_anim_speed(maxf(s, MIN_ANIM_SCALE))


# ─────────────────────────────── 渲染同步 ────────────────────────────────

func _apply_scale() -> void:
	if rig == null:
		return
	var s := BASE_SCALE
	rig.scale = Vector2(s * _facing, s)
	_sync_markers_transform()


func _sync_markers_transform() -> void:
	if _markers_parent == null or rig == null:
		return
	# IK markers 父节点必须与 StickmanRig 同 transform，否则 IK 不可达
	_markers_parent.global_transform = rig.global_transform


func _play_anim(anim_name: String) -> void:
	if rig == null:
		return
	rig.play(anim_name)
	_current_anim = anim_name


# ─────────────────────────────── 公共 API ────────────────────────────────

## 由 MapInstance.spawn_entity 调用，注入地面约束参数（§7.1.1）
func set_ground_constraints(p_ground_y: float, p_ground_bottom: float, p_map_left: float, p_map_right: float) -> void:
	ground_y = p_ground_y
	ground_bottom = p_ground_bottom
	map_left = p_map_left
	map_right = p_map_right


## 切换附身状态
func set_possessed(p: bool) -> void:
	possessed = p


func is_possessed() -> bool:
	return possessed


## 获取朝向
func get_facing() -> int:
	return _facing


## 获取当前动画名
func get_current_anim() -> String:
	return _current_anim


func _on_possession_changed(p: bool) -> void:
	# 附身切换时重置速度，避免残留
	if not p:
		_current_speed = 0.0
		_is_running = false
		velocity = Vector2.ZERO
