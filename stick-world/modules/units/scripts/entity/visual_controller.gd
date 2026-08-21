extends Node
## 火柴人视觉控制器 —— 动画播放与头顶动作进度条。
##
## 职责：
## - 动画播放（walk/idle/run/build/dead，含搬运映射与动作锁定）
## - 搬运状态切换（walk_carry）
## - 动作动画锁定/解除（如 build 敲击）
## - 待机变体随机（stand 变体池，防全员同帧；反编译参考实装 B）
## - 受击插播（hit_front/hit_back 按方向；反编译参考实装 B）
## - 头顶动作进度条（搬运动作 / 建造进度）
##
## 由 StickmanEntity._ready 挂载为 VisualController 子节点并调用 setup(entity)，
## 实体通过同名公共动画 API 转发到本组件（set_carrying / set_action_anim /
## clear_action / set_action_progress / hide_action_progress）。

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发（惯例见 ai_controller.gd:16）
const Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")

## 动画整体播放倍率（×1.4 加速）
const ANIM_SPEED_MULT: float = 1.4
## walk 动画最低播放速率（0.6 而非 0.2：过低会让起步/停止段动画几乎定格在
## "四肢伸直"的起步帧 → 人已滑步四肢却僵直；0.6 倍速下起步即明显摆动）
const MIN_ANIM_SCALE: float = 0.6
## 切到 idle 的速度阈值
const IDLE_THRESHOLD: float = 5.0

## 实体引用（注入）
var _entity: Node2D = null
## 头顶动作进度条节点
var _action_progress_indicator: Node2D = null


func setup(entity: Node2D) -> void:
	_entity = entity
	# 连接 rig 动画结束信号（攻击播完回切等；反编译参考实装 C）
	_connect_rig_finished()


## 惰性连接 rig.animation_finished（rig 实例在 setup 时已就绪，但保险起见做存在性检查）。
func _connect_rig_finished() -> void:
	var rig: Node2D = _entity.rig if _entity != null else null
	if rig != null and rig.has_signal("animation_finished") \
			and not rig.animation_finished.is_connected(_on_rig_anim_finished):
		rig.animation_finished.connect(_on_rig_anim_finished)


## 单次动画播完回切（对应传奇 AnimationSystem.UpdateFinishAnimation）：
## 攻击动画结束 → 按当前速度回 walk/idle；列阵动画结束 → 回 idle（动作锁定时不打断，如 build）。
func _on_rig_anim_finished(anim_name: String) -> void:
	if anim_name.begins_with("attack"):
		if _entity == null or _entity._action_locked:
			return
		if _entity._current_speed > IDLE_THRESHOLD:
			play("walk")
		else:
			play("idle")
	elif anim_name == "arrive":
		# 列阵到位动画播完回待机（AI 完善批次 4）
		if _entity == null or _entity._action_locked:
			return
		play("idle")


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
	# 待机变体（反编译参考实装 B）：刚进入 idle 时随机一次并保持（防每帧切换闪变）。
	# set_idle_variant 用 set_state_animation 把 idle state 的动画换成变体（共用 state），
	# 因此这里仍 play("idle")（状态机有 idle 状态），不能 travel 变体名（状态机无 idle_v2 状态）。
	if anim_name == "idle" and _entity._current_anim != "idle":
		var variant: String = Anims.pick_stand_variant()
		if rig.has_method("set_idle_variant"):
			rig.set_idle_variant(variant)
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


## 受击插播（反编译参考实装 B）：按方向触发 hit_front/hit_back，播完自动回原状态。
func play_hit(from_front: bool) -> void:
	var rig: Node2D = _entity.rig
	if rig != null and rig.has_method("play_hit"):
		rig.play_hit(from_front)


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
