extends RefCounted
## 火柴人朝向助手 —— 从 stickman_entity 拆出的翻面控制子域。
##
## 职责：
## - 翻面节流（SW3 Movement.LimitFacingChangeRate/LastFacingChangeFrame 直译，
##   帧号制）：0.5s（15 物理帧）内只许翻一次，移动意图高频反号不再逐帧甩头
## - facing 滞回（批3 源治热锅蚂蚁）：反向移动意图须连续持续 FACING_PERSIST_SECS
##   才放行翻面——瞬时反号（分离推挤换边/槽位路径横穿）攒不满窗根本翻不动
## - 出生朝向宽限窗（裁决#21c）：出生/参战登记落定的朝向是"第一眼"观感，窗口内
##   移动侧不产生翻面请求，防"开局转身背对"
## - 战斗朝向锁（SWL/SW3 AttackWhileRunning 语义）：攻击行为活跃期朝向归开火瞄准
##   管，移动翻面让位（边退边射 = 脸永远朝敌人，防背身拉弓）
## - 瞄准俯仰（SWL Archer._currentAim 表亲）：behavior_attack 弓手按弹道解算推送，
##   视觉链消费——纯表现态，不回写战斗逻辑
##
## 纪律：_facing 本体留宿主（受击方向判定/渲染缩放/移动链多处直读），本类经
## _entity 回引读写；节流/滞回/锁/俯仰态为本域私有，随迁本类。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null

# ─────────────────────────────── 节流/滞回态（本域私有）─────────────────────────────────
## 朝向节流基准帧（try_set_facing 消费；SW3 LastFacingChangeFrame 直译：
## 帧号制 = 确定性可回放，墙钟制在掉帧/变速下行为漂移）
var _last_direction_change_frame: int = -1
## 反向移动意图连续持续时间（note_move_facing 累积，翻面放行判据）
var _facing_desire_acc: float = 0.0
## 出生后首次移动翻面意图帧（出生宽限窗起点；<0 = 未起算）
var _first_move_facing_frame: int = -1
## 战斗朝向锁（behavior_attack 置位：有活跃攻击目标时 true——朝向归
## _face_target 开火瞄准管，移动不翻面）
var _combat_face_lock: bool = false
## 拉弓瞄准俯仰角（rig 域弧度，负=仰头）
var _aim_pitch: float = 0.0


func _init(entity: Node) -> void:
	_entity = entity


# ─────────────────────────────── 朝向常量 ────────────────────────────────
## 朝向最小变更间隔（物理帧；SW3 Movement.LimitFacingChangeRate 直译。
## 0.5s × 30Hz = 15 帧——SW3 官方注释原话"Anti-jitter for very fast melee units
## that overshoot their melee point"）
const FACING_RATE_LIMIT_FRAMES: int = 15
## facing 滞回窗（批3 源治热锅蚂蚁）：反向移动意图须连续持续此时长才放行
## 翻面请求。节流只限翻面速率——意图高频反号时每个节流窗放行一次照样甩头；
## 滞回让瞬时反号（分离推挤换边/槽位路径横穿/y 微移）攒不满窗根本翻不动
const FACING_PERSIST_SECS: float = 0.25
## 出生朝向宽限窗（裁决#21c）：1s @30Hz。窗口内移动侧一律不产生翻面请求，
## 否则单位开场第一步（去槽位/被推挤）就把脸转向移动方向，肉眼即"开局转身背对"。
## 战斗面向（face_towards → _force_facing）不经本闸，瞄准/攻击照旧是朝向权威。
const SPAWN_FACING_GRACE_FRAMES: int = 30


## 面向指定世界坐标（横向翻转；AI 开火前调用——风筝撤退中开火必须回头
## 面向目标，否则"背身拉弓"）。
func face_towards(pos: Vector2) -> void:
	var dx: float = pos.x - _entity.global_position.x
	if absf(dx) < 1.0:
		return
	# 战斗面向强制通道：绕过战斗朝向锁（锁只拦移动翻面，开火瞄准才是朝向
	# 权威——被锁拦住时，目标丢失窗口里被移动翻成背向的单位会**卡死在背身
	# 拉弓**：重锁后 _face_target 永远被拒，创始人点正「左下角弓手背对拉弓」）
	if OS.get_environment("STICK_TRACE_FACING") == "1" and signf(dx) != signf(_entity._facing):
		print("[FaceTrace] aim iid=%d dx=%.0f pos=%s" % [_entity.get_instance_id(), dx, _entity.global_position])
	_force_facing(1 if dx > 0.0 else -1)


## 朝向变更节流（SW3 直译，帧号制）：移动翻面唯一入口。玩家附身豁免
##（手控输入不经 AI 节拍）。返回是否生效（false=节流窗内，保持原朝向）
func try_set_facing(new_facing: int) -> bool:
	if new_facing == _entity._facing:
		return true
	# 战斗朝向锁（SWL/SW3 AttackWhileRunning 语义：移动方向与朝向解耦）——
	# 攻击行为活跃期由开火瞄准独占朝向，移动翻面让位（边退边射 = 倒退跑，
	# 脸永远朝敌人；旧实现移动侧抢闸导致背身拉弓，创始人点正）
	if _combat_face_lock:
		return false
	return _set_facing_rate_limited(new_facing)


## 强制翻面（face_towards 战斗面向消费）：绕过战斗朝向锁，仍走翻面节流
func _force_facing(new_facing: int) -> bool:
	if new_facing == _entity._facing:
		return true
	return _set_facing_rate_limited(new_facing)


func _set_facing_rate_limited(new_facing: int) -> bool:
	var pf := Engine.get_physics_frames()
	if not _entity.is_user_controlled() and _last_direction_change_frame >= 0 \
			and pf - _last_direction_change_frame < FACING_RATE_LIMIT_FRAMES:
		return false
	_last_direction_change_frame = pf
	_entity._facing = new_facing
	_entity._apply_scale()
	return true


## 移动侧意图喂入（批3 facing 滞回，_apply_movement 每物理帧调用）：
## 返回该侧翻面请求是否放行——反向意图连续 ≥ FACING_PERSIST_SECS 才 true。
## 附身豁免（手控直给）；face_battle_dir 等稳定朝向源不经本闸（直接走
## try_set_facing 的节流），站定收口不被移动滞回卡住。
func note_move_facing(side: int, delta: float) -> bool:
	if _entity.is_user_controlled() or side == 0 or side == _entity._facing:
		_facing_desire_acc = 0.0
		return true
	if _first_move_facing_frame < 0:
		_first_move_facing_frame = Engine.get_physics_frames()
	elif Engine.get_physics_frames() - _first_move_facing_frame < SPAWN_FACING_GRACE_FRAMES:
		_facing_desire_acc = 0.0
		return false
	_facing_desire_acc += delta
	var ok := _facing_desire_acc >= FACING_PERSIST_SECS
	if ok and OS.get_environment("STICK_TRACE_FACING") == "1":
		print("[FaceTrace] move iid=%d side=%+d acc=%.2f pos=%s vel=%s"
				% [_entity.get_instance_id(), side, _facing_desire_acc,
						_entity.global_position, _entity.velocity])
	return ok


## 战斗朝向锁开关（behavior_attack 置位：有活跃攻击目标时 true）。
func set_combat_face_lock(locked: bool) -> void:
	_combat_face_lock = locked


## 写拉弓瞄准俯仰角（behavior_attack 每拍按弹道解算推送）。
func set_aim_pitch(rad: float) -> void:
	_aim_pitch = rad


## 读拉弓瞄准俯仰角（视觉链消费：visual_controller → rig / billboard 镜像 feed）。
func get_aim_pitch() -> float:
	return _aim_pitch
