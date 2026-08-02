extends Node
## 火柴人视觉控制器 —— 动画播放与头顶动作进度条。
##
## 职责：
## - 动画播放（walk/idle/run/build/dead，含搬运映射与动作锁定）
## - 搬运状态切换（walk_carry）
## - 动作动画锁定/解除（如 build 敲击）
## - 头顶动作进度条（搬运动作 / 建造进度）
##
## 由 StickmanEntity._ready 挂载为 VisualController 子节点并调用 setup(entity)，
## 实体通过同名公共动画 API 转发到本组件（set_carrying / set_action_anim /
## clear_action / set_action_progress / hide_action_progress）。

## 动画整体播放倍率（×1.4 加速）
const ANIM_SPEED_MULT: float = 1.4
## walk 动画最低播放速率
const MIN_ANIM_SCALE: float = 0.2
## 切到 idle 的速度阈值
const IDLE_THRESHOLD: float = 5.0

## 实体引用（注入）
var _entity: Node2D = null
## 头顶动作进度条节点
var _action_progress_indicator: Node2D = null


func setup(entity: Node2D) -> void:
	_entity = entity


# ─────────────────────────────── 动画播放 ────────────────────────────────

## 播放动画（含搬运映射与动作锁定处理）。
func play(anim_name: String) -> void:
	var rig: Node2D = _entity.rig
	if rig == null:
		return
	# 动作锁定时保持当前动作动画（如 build），不切走
	if _entity._action_locked:
		return
	# 搬运状态：walk/idle 映射为 walk_carry（手搬姿势）
	var play_name: String = anim_name
	if _entity._carrying and (anim_name == "walk" or anim_name == "idle"):
		play_name = "walk_carry"
	rig.play(play_name)
	_entity._current_anim = anim_name


## 设置动画播放速率（按当前速度缩放）。
func set_anim_speed(v: float) -> void:
	if _entity.rig != null:
		_entity.rig.set_anim_speed(maxf(v, MIN_ANIM_SCALE))


## 设置搬运状态：搬运工持物时 walk 切换为 walk_carry 动画。
## 由 BehaviorHaul / 玩家交互调用（经实体转发）。
func set_carrying(v: bool) -> void:
	_entity._carrying = v
	# 立即同步动画：搬运时切 walk_carry，否则按速度切 walk/idle
	if _entity.rig == null:
		return
	if v:
		_entity.rig.play("walk_carry")
	else:
		if _entity._current_speed > IDLE_THRESHOLD:
			_entity.rig.play("walk")
		else:
			_entity.rig.play("idle")


## 锁定动作动画（如 build 敲击），锁定期间 play() 不切换。
## 由 BehaviorWork 在工地播放建造动画时调用（经实体转发）。
func set_action_anim(anim_name: String) -> void:
	_entity._action_locked = true
	if _entity.rig != null:
		_entity.rig.play(anim_name)
	_entity._current_anim = anim_name


## 解除动作锁定，恢复正常动画（根据当前速度切 walk/idle）。
func clear_action() -> void:
	_entity._action_locked = false
	if _entity._current_speed > IDLE_THRESHOLD:
		play("walk")
	else:
		play("idle")


# ─────────────────────────────── 头顶动作进度条 ────────────────────────────────

## 确保头顶进度条节点存在。
func _ensure_action_indicator() -> void:
	if _action_progress_indicator != null and is_instance_valid(_action_progress_indicator):
		return
	var cls := load("res://modules/units/scripts/entity/action_progress_indicator.gd")
	_action_progress_indicator = cls.new()
	_action_progress_indicator.position = Vector2(0, -130.0)  # 头顶上方
	_entity.add_child(_action_progress_indicator)


## 设置头顶动作进度（0~1，>0 显示，0 隐藏）。由 BehaviorHaul/BehaviorWork/玩家调用。
func set_progress(ratio: float) -> void:
	_ensure_action_indicator()
	if _action_progress_indicator != null:
		_action_progress_indicator.set_progress(ratio)


## 隐藏头顶动作进度条。
func hide_progress() -> void:
	if _action_progress_indicator != null:
		_action_progress_indicator.hide_bar()
