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
	elif anim_name == "block":
		# 格挡动画播完按当前速度回 walk/idle
		if _entity == null or _entity._action_locked:
			return
		if _entity._current_speed > IDLE_THRESHOLD:
			play("walk")
		else:
			play("idle")


# ─────────────────────────────── 动画播放 ────────────────────────────────

## 播放动画（含搬运映射与动作锁定处理）。
func play(anim_name: String) -> void:
	var rig: Node2D = _entity.rig
	if rig == null:
		return
	# 死亡终态门禁（2026-08-31 审计 P0-1）：dead 是 ANY→dead 的终态，
	# 死后一切 walk/idle/attack 请求一律拒绝——防移动减速逻辑把死亡动画
	# 在 0.25s 内覆盖成"尸体站起来"
	if _entity.has_method("is_dead") and _entity.is_dead() \
			and anim_name != "dead" and anim_name != "dead_headshot":
		return
	# 动作锁定时保持当前动作动画（如 build），不切走
	if _entity._action_locked:
		return
	# 搬运状态：walk/idle 映射为 walk_carry（手搬姿势）
	var play_name: String = anim_name
	if _entity._carrying and (anim_name == "walk" or anim_name == "idle"):
		play_name = "walk_carry"
	# 待机变体（反编译参考实装 B）：刚进入 idle 时随机一次并保持（防每帧切换闪变）。
	# 站姿按武器类型分型（原版各兵种 Stand：剑士双变体池、矛/弓/镐/杖各一）。
	# set_idle_variant 用 set_state_animation 把 idle state 的动画换成变体（共用 state），
	# 因此这里仍 play("idle")（状态机有 idle 状态），不能 travel 变体名（状态机无 idle_v2 状态）。
	if anim_name == "idle" and _entity._current_anim != "idle":
		var variant: String = Anims.pick_stand_variant_for(_weapon_type())
		if rig.has_method("set_idle_variant"):
			rig.set_idle_variant(variant)
	rig.play(play_name)
	_entity._current_anim = anim_name


## 当前武器类型（WeaponMount 未挂载时回落持剑 0）。
func _weapon_type() -> int:
	var wm: Node = _entity.get_node_or_null("WeaponMount")
	if wm != null and "weapon_type" in wm:
		return int(wm.weapon_type)
	return 0


## 强制重挑站姿（换武器后调用）：仅待机态立即生效，动作锁定/搬运用
## walk_carry 时不打断，其余状态回 idle 时自然生效。
func refresh_idle_stance() -> void:
	if _entity._action_locked or _entity._carrying:
		return
	if _entity._current_anim == "idle":
		_entity._current_anim = ""
		play("idle")


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


## 受击插播（反编译参考实装 B）：按方向触发受击动画，播完自动回原状态。
## 变体池直译（SWL SelectHitAnimation）：big=强击 / head=头部部位 / blocking=举盾中被击
func play_hit(from_front: bool, big: bool = false, head: bool = false, blocking: bool = false) -> void:
	var rig: Node2D = _entity.rig
	if rig != null and rig.has_method("play_hit"):
		rig.play_hit(from_front, big, head, blocking)


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
