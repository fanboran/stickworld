extends RefCounted
## 弓手瞄准表现窗助手 —— 从 weapon_mount.gd 拆出的持瞄表现子域（无自持状态）。
##
## 职责：持瞄拉弓 / 移动让位 / 装填播段的逐帧仲裁（process_tick）与窗的
## 开关（mark_bow_aim_started / end_bow_aim_visual）、经实体 VisualController
## 的持瞄保持换装（set_bow_aim_walk_override）与动画播放（play_via_visual）。
##
## 挂 _process 而非 _physics_process（宿主 _process 转发）：sim 模式
## （BattleSim 默认开）下宿主 _physics_process 早退，而表现仲裁是渲染率
## 关注、且 AI 侧（behavior_attack）照常在实体上跑——_process 两模通吃。
##
## 纪律：表现窗状态（_aim_visual_active/_aim_visual_until/_aim_visual_player/
## _reload_visual_done，被宿主 perform_attack/release_player_shot/begin_player_draw
## 出手路径消费）全部留在宿主 WeaponMount，经 _mount 动态回引读写。

const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT

## 瞄准表现窗超时（s）：burst 瞄准上限（0.9×3.2≈2.9）+ 冷却残段（≤2.0）再留余量
const BOW_AIM_VISUAL_TIMEOUT: float = 5.0
## 装填播放判定的冷却残量下限（s）：低于此值视为冷却已尽（防帧尾毛刺在
## 冷却归零边缘反复横跳）
const RELOAD_COOLDOWN_EPS: float = 0.05

var _mount  ## 宿主 WeaponMount（动态回引；状态唯一真相源在宿主）


func _init(mount) -> void:
	_mount = mount


## 持瞄拉弓 / 移动让位的逐帧仲裁。
func process_tick(_delta: float) -> void:
	if not _mount._aim_visual_active:
		return
	if _mount.weapon_type != _mount.WeaponType.BOW:
		end_bow_aim_visual(false)
		return
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	# 玩家蓄力窗的收口守卫：附身取消（cancel_charge 不经过本挂载）/ 附身丢失 /
	# 死亡，都会让"按住全程"的无限窗失去归属——立刻收弓回站姿，别钉在拉满
	if _mount._aim_visual_player:
		var user_controlled: bool = owner_entity != null \
				and owner_entity.has_method("is_user_controlled") and owner_entity.is_user_controlled() \
				and not (owner_entity.has_method("is_dead") and owner_entity.is_dead())
		if not user_controlled:
			end_bow_aim_visual(true)
			return
	# 超时收弓（玩家蓄力路径无超时）：窗残而行为已切走时，别把人钉在拉满姿态
	var now: float = _mount._now()
	if now > _mount._aim_visual_until:
		end_bow_aim_visual(true)
		return
	if owner_entity == null:
		return
	var current: String = str(owner_entity.get("_current_anim"))
	var moving: bool = owner_entity.velocity.length_squared() > _mount.BOW_MOVE_SQ_THRESHOLD
	if moving:
		# 移动让位走姿：attack_bow_hold 前缀会被 entity_motion 的攻击动画守卫
		# 拦住 walk 切换（滑步定腿）——这里显式交还移动表现。walk state 资源
		# 已被持瞄保持通道换装为 walk_bow_hold（上身拉满+下肢走步，窗开时
		# set_bow_aim_walk_override(true)），脚步动作与拉满上身同变体提供
		if current == Anims.ANIM_ATTACK_BOW_HOLD:
			play_via_visual(Anims.ANIM_WALK)
	else:
		# 站定：冷却未尽先装填（SWL IsReloading/Reload 语义，对照档 §5）——
		# 释放段播完回基础态后，冷却窗内播 attack_bow_reload（收弓取箭上弦），
		# 冷却尽才拉满持瞄。不做这层则弓手两轮之间全程满弓，
		# "拉弓-放箭-装填-再拉"的循环节奏不可见。motion 减速到 0 时会把状态
		# 写回 idle（表现窗拦不住那一次写入），这里检测到基础态残留重新拉起。
		# 装填尾段被冷却尽的拉满直接打断（SWL 下一轮 Draw 起拍——射速权威在
		# 冷却计时，不为装填动画拖拍）；冷却未尽且装填已播完则维持现状站定
		if current == "idle" or current == Anims.ANIM_WALK or current == "run" \
				or current == Anims.ANIM_ATTACK_BOW_RELOAD:
			if _mount._cooldown_left() > RELOAD_COOLDOWN_EPS:
				if not _mount._reload_visual_done and current != Anims.ANIM_ATTACK_BOW_RELOAD:
					_mount._reload_visual_done = true
					play_via_visual(Anims.ANIM_ATTACK_BOW_RELOAD)
			else:
				_mount._reload_visual_done = false
				if current != Anims.ANIM_ATTACK_BOW_HOLD:
					play_via_visual(Anims.ANIM_ATTACK_BOW_HOLD)


## 持瞄开始 → 起拉弓表现窗（拉弓保持段由 _process 仲裁落位）
func mark_bow_aim_started() -> void:
	if _mount.weapon_type != _mount.WeaponType.BOW:
		return
	_mount._aim_visual_active = true
	_mount._aim_visual_player = false  # AI 持瞄窗（超时兜底）；玩家窗只在 begin_player_draw 置位
	_mount._aim_visual_until = _mount._now() + BOW_AIM_VISUAL_TIMEOUT
	# 持瞄窗 walk 换装：窗内移动走 walk_bow_hold（上身拉满+下肢走步）
	set_bow_aim_walk_override(true)


## 收瞄准表现窗。return_to_idle=true 且当前停在拉弓保持段时回站姿
## （出手路径传 false——release 动画随后接管，不必插一脚 idle）。
## 装填闩锁随窗复位：新窗（下一轮持瞄）重新计一次装填
func end_bow_aim_visual(return_to_idle: bool) -> void:
	_mount._aim_visual_active = false
	_mount._aim_visual_player = false
	_mount._reload_visual_done = false
	# 窗关即撤持瞄保持换装：walk state 回武器基础走姿（弓 = walk_bow）
	set_bow_aim_walk_override(false)
	if not return_to_idle:
		return
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		return
	if str(owner_entity.get("_current_anim")) == Anims.ANIM_ATTACK_BOW_HOLD:
		play_via_visual("idle")


## 持瞄窗 walk 换装开关（经实体 VisualController 的持瞄保持通道）：2D rig
## set_state_anim 换装与 billboard 镜像（visual_controller.get_stance_anims
## 观测口 → char_rig_3d.set_stance_anims）两处同口径——状态留宿主挂载，
## 名字解析与换装执行在 VisualController（walk state 资源替换，state 不增）。
func set_bow_aim_walk_override(on: bool) -> void:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		return
	var visual: Node = owner_entity.get("_visual")
	if visual != null and visual.has_method("set_bow_aim_stance"):
		visual.set_bow_aim_stance(on)


## 经实体 VisualController 播动画（_current_anim 状态先行 + rig/HD-2D 镜像同走，
## 死亡/动作锁定守卫在 play 内侧）。武器挂载不直写实体状态字段。
func play_via_visual(anim_name: String) -> void:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		return
	var visual: Node = owner_entity.get("_visual")
	if visual != null and visual.has_method("play"):
		visual.play(anim_name)
