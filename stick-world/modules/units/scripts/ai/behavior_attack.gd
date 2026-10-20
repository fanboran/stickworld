class_name BehaviorAttack
extends BehaviorBase
## 攻击行为 -- 找最近敌人 -> 接近到射程内 -> 攻击（命中帧->伤害事件）。
##
## SWL 攻击行为口径（裁决#32，对照 legacy dump Ai 基类方法表逐项核对）：
## 真货保留 = 跑走切换（DetermineXRunPower）/ 贴身判定（IsTargetReallyClose）/
## 攻击槽位（GetTargetAttackSpot）/ y 纵深对齐（6 函数族）/ 风筝（ArcherAi.ShouldKite）/
## 持瞄节奏（isAiming/GenerateNextShotRandomness）/ 脱靶容忍（MissingArrowsTolerance）/
## 站桩间距（PushApartTolerance）；RWR/自创机制已删 = 犹豫 / 受击规避小跳 /
## 包抄走位 / 围攻名额外圈等位 / 连射点射停顿 / 近战出手预判门（裁决#31-#32——
## SWL/SW3 出手只有冷却门，命中帧自检射程，出手不做任何预判）。
##
## 完成条件（finish 后由 AIController 决策切换）：
##   - 无敌人 / 战斗结束
##   （裁决【删溃逃、立避战】：不因低血打断攻击——保持还击，去留由 C6 调制裁决）
##
## params 可选字段：
##   - battle: BattleInstance（不传则从 entity.get_battle_instance() 取）

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发（惯例见 ai_controller.gd:16）。
# TargetFinder 为 tactics 对外公共类型（tactics/api.gd 契约出口）——消费点已随
# P1 找目标系统拆分迁 target_acquire.gd（该文件自持 preload）
## 兵种行为档案（RWR 式基线+覆盖，见 behavior_profiles.gd）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
## 找目标系统（SW3 FindTargetAiSystem 直译 P1：增量换靶/滞回/驻留时长/分层阈值）
const ScriptTargetAcquire := preload("res://modules/units/scripts/ai/target_acquire.gd")

# ─────────────────────────────── 常量

## y 对齐死区（px，dump 无真值 → 待实测校准）：|Δy| 小于此值视为已对齐不再走位
const Y_ALIGN_DY_THRESHOLD: float = 16.0
## 攻击槽位系数（SWL AttackFromRange 直译，翻译档 §7.1.2）：接近停步点 =
## 预测目标位置 ± 0.7 × attackRange（全局系数 0.7 直读 .so 数据段）
const ATTACK_SLOT_FRAC: float = 0.7
## 出手门系数（SWL Ai.CanAttack 直译）：目标静止时 |Δx| < 0.8 × range 才可出手
##（追击中目标在动为 0.5×range——本仓出手锁足后目标动时走槽位接近路径，
## 不复刻 0.5 档）
const ATTACK_GATE_FRAC: float = 0.8
## 贴身判定阈值（SWL IsTargetReallyClose 直译）：|Δx| < 2.5u × 52 ≈ 130px——
## 绕开攻击槽位直接压上（旧"半射程"近似作废）
const REALLY_CLOSE_DX: float = 130.0
## 弓手开火下限（SWL ArcherAi.CanAttack 直译）：|Δx| ≤ 0.8u(42px，DAT_015c1cb8
## 直读) 不开火——贴脸弓切近战 attackRange 语义
const ARCHER_MIN_FIRE_DX: float = 42.0
## 弓手保距线（SWL GetTargetAttackSpot 直译）：射程内站桩最小间距 = 目标 ±3u
## ≈156px——被贴脸退到此线（spot 保持距离语义，非风筝：AI 弓手不风筝，
## ShouldKite 是 Pro 玩家操控专属）
const ARCHER_HOLD_DIST: float = 156.0
## 弓手停步线系数（SWL GetTargetAttackSpot 射程外分支直读 DAT_016c55a4）：
## 射程外走向距目标 0.9×range 处（range 15u → 13.5u ≈ 702px，天然落在己方半场）
const ARCHER_RANGE_FRAC: float = 0.9
## 远程走位死区（px）：距停步/保距线 ≤ 此值不挪步（防贴线抖动）
const RANGED_LINE_DEADZONE: float = 40.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 当前目标敌人（每物理帧自 _acq 同步；下游消费与测试观测面——目标状态的
## 唯一权威在 _acq，写侧经 target_acquire 的选举/强制目标通道）
var _target: Node = null
## 找目标系统（SW3 FindTargetAiSystem 直译 P1）：目标状态/选举/驻留/滞回/
## 分层阈值全在 helper——enter 装配 + update 懒装配兜底（测试直构不进 enter
## 也能跑）
var _acq: ScriptTargetAcquire = null
## 行为累积钟（s）：update 每拍累加 delta，暂停/减速与物理帧同步冻结——
## 禁墙钟（ai_decision_clock 纪律：暂停/hitstop 期实时钟空转破坏节拍契约）。
## post_block/burst 等行为内窗口的时基
var _clock: float = 0.0
## 命运骰 RNG（单位种子隔离：首掷按实体实例 id 派生，测试可重掷 _rng.seed
## 复现序列——P4 回放「每单位可注入种子」的前置收口）
var _rng := RandomNumberGenerator.new()
var _rng_seeded: bool = false
## 兵种行为档案（RWR 式基线+覆盖）：enter 时按武器类型解析，
## 覆盖风筝/持瞄/追击等参数——兵种个性 = 参数差（见 behavior_profiles.gd）。
var _profile: Dictionary = {}
## 瞄准节奏状态（SWL ArcherAi.isAiming/GenerateNextShotRandomness 直译）：
## 当前持瞄目标与剩余持瞄时长——放箭时机 = 满弓节奏上叠高斯抖动
var _aiming: bool = false
var _aim_timer: float = 0.0
var _aim_target: Node = null
## y 纵深个性漂移（SWL personalityControlledY 直译）：相对目标 y 的个性偏移与重掷计时
## （11a 改造：漂移从"独立随机游走"并入 y 对齐 6 函数的 goal_y，见 _adjust_goal_y）
var _drift_offset: float = 0.0
var _drift_timer: float = 0.0
## 攻击后举盾截止时刻（s；SWL Ai.cooldownAfterAttackForBlock 直译——
## 矛兵攻击完举盾瞬间防反打，"盾墙"手感来源）
var _post_block_until: float = 0.0
## 挥砍锁足（米拉奇口径：出手=冷却窗全模停止，`Isometric2DEntity.as` 方法体
## 直读——attack 期间 vx=vy=0 到 weaponSpeed 帧走完）：近战 perform_attack 置位，
## 冷却好（can_attack 翻真）解锁。挥砍动画期带着走位 = 「边走边挥砍」滑行感
## 的根治；远程不走此锁（边撤边射是 SWL 弓手真行为）
var _melee_swing_lock: bool = false
## 锁时限（_clock 时刻）：武器冷却 × 1.5——保险闸：低帧下动画结束回调若迟到
## （_current_anim 卡在 attack 态），锁不会永久卡死单位
var _melee_lock_until: float = 0.0

# ── 实体能力位缓存（战斗性能优化）──
## update 每物理帧逐单位调用，链式 entity.has_method(...) 是纯重复开销：
## 实体脚本方法表在实例存续期不变，首次 update 检测一次即可（零语义差异）
var _cap_checked: bool = false
var _cap_is_dead: bool = false
var _cap_hit_stun: bool = false
var _cap_ai_stop: bool = false
var _cap_ai_move: bool = false
var _cap_get_health: bool = false
var _cap_get_weapon: bool = false
var _cap_play_attack: bool = false
var _cap_get_facing: bool = false
var _cap_get_faction: bool = false
var _cap_get_map: bool = false
var _cap_get_battle: bool = false


func _check_caps() -> void:
	_cap_checked = true
	_cap_is_dead = entity.has_method("is_dead")
	_cap_hit_stun = entity.has_method("is_in_hit_stun")
	_cap_ai_stop = entity.has_method("ai_stop")
	_cap_ai_move = entity.has_method("ai_move")
	_cap_get_health = entity.has_method("get_health")
	_cap_get_weapon = entity.has_method("get_weapon")
	_cap_play_attack = entity.has_method("play_attack")
	_cap_get_facing = entity.has_method("get_facing")
	_cap_get_faction = entity.has_method("get_faction")
	_cap_get_map = entity.has_method("get_map")
	_cap_get_battle = entity.has_method("get_battle_instance")


func _ready() -> void:
	behavior_name = "attack"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	# 兵种档案解析（按主手武器类型；取不到武器回落空档案 = 全基线）
	_profile = {}
	if entity != null and is_instance_valid(entity) and entity.has_method("get_weapon"):
		var w: Node = entity.get_weapon()
		if w != null and "weapon_type" in w:
			_profile = ScriptBehaviorProfiles.get_profile(int(w.weapon_type))
	_target = null
	_ensure_acq()
	# 强制目标（遇阻接战"打通"态）：params 注入的拦路者——路径敌人未必是最近敌，
	# 目标选择最高优先；死亡/失效/超追击范围由 _acq 清除回落正常选敌
	_acq.set_forced_target(params.get("forced_target", null))
	_aiming = false
	_aim_target = null
	_aim_timer = 0.0
	_drift_timer = 0.0
	_drift_offset = 0.0
	_melee_swing_lock = false


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if not _cap_checked:
		_check_caps()
	if _cap_is_dead and entity.is_dead():
		finish()
		return
	# 战斗朝向锁（AttackWhileRunning 语义）：有活跃攻击目标即锁——朝向归开火
	# 瞄准管，移动翻面让位（边退边射倒退跑）；行为退出在 exit 解锁
	if entity.has_method("set_combat_face_lock"):
		entity.set_combat_face_lock(_target != null and is_instance_valid(_target))
	# 行为累积钟（时基声明见字段注释）——先于一切早退路径累加：压制/硬直/
	# 风筝停滞期窗口照常流逝（停滞的是单位不是时间）
	_clock += delta
	# 压制禁令消费段（A6 · C9）：压制期停滞——不追不打不调整，同受击硬直口径。
	# 决策链已在 ai_controller 拦截新行为，此处兜底"压制发生在两拍之间的在途
	# 攻击行为"（禁令立即生效，不等下一决策拍）。受击反馈/被推挤在物理层不受
	# 禁令影响——惩罚来自模拟因果。duck 查询：组件缺失（测试桩）跳过 = 零回归。
	# 压制锁步（02 二-A.5）：停滞 + 蜷缩举盾站桩吃伤害（根除避战裁决），
	# 姿态反馈在共享口内（behavior_base.pinned_by_suppression）。
	if pinned_by_suppression():
		return
	# 受击硬直（行业最佳实践 hit stun；SW3 Movement 帧表同源语义）：被打瞬间
	# 短暂停滞，不追不打（裁决#32：受击规避小跳是 RWR 血统，SWL 无此机制——
	# 硬直就是硬直，不侧移）
	var stunned: bool = _cap_hit_stun and entity.is_in_hit_stun()
	if stunned:
		if _cap_ai_stop:
			entity.ai_stop()
		return
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("is_active") or not _battle.is_active():
		if _cap_ai_stop:
			entity.ai_stop()
		finish()
		return

	# 找目标系统推进（裁决#35 米拉奇锁定到死：目标活着原样奉还，死亡/失效/
	# 守位出界才重选；选举/强制目标/守位守卫全在 target_acquire.gd）。
	# null = 无目标可打交还决策层
	_ensure_acq()
	_target = _acq.advance(delta)
	if _target == null:
		if _cap_ai_stop:
			entity.ai_stop()
		finish()
		return

	# 自身状态检查：HP 过低 -> finish 让 AIController 决策（裁决【删溃逃、立避战】：
	# 旧 is_routed finish 自检随溃逃退役——被打单位保持还击，去留由
	# ai_controller 的 C6 概率调制裁决，避免逐拍 finish→重 travel 抖动）
	# 低血找掩体/低血狂暴自检已删（裁决#31：两者此前已令删——被打单位保持还击）
	# 犹豫概率钩子已删（裁决#32：两份 dump 均无此机制，RWR 血统——
	# 随机站停是"接敌不打法"观感来源之一）

	# 攻击 / 接近逻辑
	var weapon: Node = entity.get_weapon() if _cap_get_weapon else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	var dist: float = entity.global_position.distance_to(_target.global_position)
	# 拉弓瞄准俯仰（SWL Archer.UpdateAim：弓手逐拍把弹道仰角推给表现层；
	# 非弓/无武器自然归零——风筝/锚定/接近各分支同享这一次推送）
	if entity.has_method("set_aim_pitch"):
		entity.set_aim_pitch(
				weapon.get_aim_pitch(_target) if weapon != null and weapon.has_method("get_aim_pitch") else 0.0)
	# 召唤护卫（SWL MagikillAi.ShouldCastSummon 直译）：敌人逼近施法距离且冷却
	# 就绪时召唤脆皮护卫（minidon）挡脸——原版法师的生存方案，替代自创风筝
	_update_summon(dist, delta)
	# 姿态举盾聚合（SWL 直译）：推进/接敌/风筝全程生效
	_update_arrow_threat_block(weapon)
	# 挥砍锁足（米拉奇口径 × SWL 可打断窗合取）：出手后挥砍动画没播完就全模
	# 停止——目标走出射程也不追、新目标也不追，这一剑挥完再说（动画期带着走位
	# = 「边走边挥砍」滑行感）。移动闸跟动画走；出手闸照常：命中帧已过进可打断
	# 尾段（can_attack 翻真）时原地提前出下一手（SWL AnimationCancelFraction
	# 真货，DPS 不掉）。受击硬直/压制在上方早退，优先级更高
	if _melee_swing_lock:
		if _clock >= _melee_lock_until or (
				entity.has_method("is_attack_anim_active")
				and not entity.is_attack_anim_active()):
			_melee_swing_lock = false
		else:
			# 站桩中可打断窗开了且目标仍在出手门内 → 原地出手（不挪步）
			if dist <= _melee_gate_dist(weapon) and weapon != null 					and weapon.has_method("can_attack") and weapon.can_attack() 					and not _arrows_wasted(_target, weapon):
				weapon.perform_attack(_target)
				_melee_lock_until = _clock + _swing_lock_duration(weapon)
				if _cap_play_attack:
					entity.play_attack()
			if _cap_ai_stop:
				entity.ai_stop()
			_face_target()
			# 站桩间距照常（SWL PushApartTolerance：锁足不当墙，人群仍自然松开）
			if _p("push_apart", 0.0) > 0.0:
				_apply_push_apart(_p("push_apart", 0.0), delta)
			return
	# 风筝分支（机制保留、数据全关）：SWL 真值——**AI 弓手不风筝**，
	# ShouldKite 整段门在 IsBeingUserControlledByPro（Pro 玩家操控专属，
	# 翻译档 §7.1.2）；AI 弓手被贴脸由站位 spot 的 3u 保距线应对（见
	# _ranged_update）。三档兵种 kite_range 已归零，本分支为死路兜底。
	var kite_range: float = _p("kite_range", 0.0)
	if kite_range > 0.0 and dist < kite_range:
		var away: Vector2 = (entity.global_position - _target.global_position).normalized()
		if _cap_ai_move:
			entity.ai_move(away, _p("kite_run", 0.0) > 0.5)
		# 风筝还击（SWL 弓手边撤边射）：前摇/弹道与移动解耦（延迟结算计时独立），
		# 冷却好就边跑边放——不再被追着跑还不还手（远程弹道解算自带目标预判，
		# 不做 9s 出手预测门槛——那道门只拦近战空挥）
		if dist <= attack_range and weapon != null and weapon.has_method("can_attack") \
				and weapon.can_attack() and not _arrows_wasted(_target, weapon):
			_face_target()  # 回头面向目标开火（否则背身拉弓）
			weapon.perform_attack(_target)
			_aiming = false
	elif _is_ranged_weapon(weapon):
		# 远程二线驻射（SWL 停驻语义）：停驻线/槽位锚定/开火全在此分支
		_ranged_update(dist, delta, weapon, attack_range)
	elif dist <= _melee_gate_dist(weapon):
		# 近战出手门内（SWL CanAttack：0.8×range，矛兵前排有友军遮挡时放宽到
		# 0.8×二线 130=104 隔排刺击）：站定出手。SWL 出手链 = 冷却好即打，命中帧
		# 自检射程（SW3 MeleeAttackSystem.HitUpdate→InRangeForHit），出手端无任何
		# 预判门——近战预判门/连射点射/y 对齐拦射已随裁决#32 删（射程内站桩不打的
		# 三道闸）。
		if _cap_ai_stop:
			entity.ai_stop()
		_face_target()  # 开火面向目标（走位/漂移后可能侧身）
		# 持瞄节奏（SWL ArcherAi.isAiming/ShouldAim）：近战无档案直接放行；
		# 脱靶容忍拦"箭已够杀还射"（远程专属门）
		var aim_ready: bool = _update_aim_rhythm(delta)
		if aim_ready and weapon != null and weapon.has_method("can_attack") \
				and weapon.can_attack() and not _arrows_wasted(_target, weapon):
			weapon.perform_attack(_target)
			_aiming = false
			# 近战挥砍锁足（米拉奇口径）：本剑挥完前不追不挪
			_melee_swing_lock = true
			_melee_lock_until = _clock + _swing_lock_duration(weapon)
			# 攻击后举盾（cooldownAfterAttackForBlock）：矛兵攻击完一拍盾防反打
			if _p("block_after_attack", 0.0) > 0.0:
				_post_block_until = _clock + _p("block_after_attack", 0.0)
			# 攻击命中帧触发攻击动画（反编译参考实装 C）：播完由 rig.animation_finished 回切
			if _cap_play_attack:
				entity.play_attack()
		# 射手容错间距（SWL PushApartTolerance）：站桩输出时与友军保持间距
		if _p("push_apart", 0.0) > 0.0:
			_apply_push_apart(_p("push_apart", 0.0), delta)
	else:
		# 近战接敌推进 = 追最近敌（裁决#32 创始人口径）：直奔目标攻击槽位，远跑近走
		#（DetermineXRunPower）。围攻名额外圈等位/包抄侧向/冲锋掷骰已删——
		# SWL 无此三件，人堆靠分离椭圆自然展开（SW3 同款：ComputeAttackerZStagger
		# 只做纵深错位不做名队排队）。槽位锚定仅产线战线在役时生效（观察场无战线）。
		if _approach_via_slot():
			return
		var to_target: Vector2 = _target.global_position - entity.global_position
		# IsTargetReallyClose（SWL 直译，翻译档 §7.1.2）：|Δx| < 2.5u（130px）——
		# 贴身目标绕开攻击槽位外圈，直接压上
		var really_close: bool = _is_target_really_close()
		# 攻击槽位（SWL GetTargetAttackSpot）：停在 0.7×射程的攻击位
		#（AttackFromRange = 0.7 × attackRange 全局系数直译）
		var attack_radius: float = maxf(attack_range * ATTACK_SLOT_FRAC, 24.0)
		var desired_pos: Vector2 = _target.global_position if really_close \
				else _target.global_position + to_target.normalized() * attack_radius
		var dir: Vector2 = (desired_pos - entity.global_position).normalized()
		# y 轴纵深走位（SWL y 对齐 6 函数直译）：接敌途中朝目标 y（带个性漂移带）对齐，
		# 人群自然铺开不挤一条横线
		dir = _apply_y_walk(dir, delta)
		# DetermineXRunPower（SWL 直译）：远跑近走
		var run: bool = _determine_x_run_power(desired_pos, attack_range) >= 1.0
		if _cap_ai_move:
			entity.ai_move(dir, run)


# ─────────────────────────────── 远程站位与开火（SWL 真值）────────────────────────────────

## 远程站位与开火（SWL ArcherAi.GetTargetAttackSpot/CanAttack 真值直译，翻译档
## §7.1.2）：站位只相对**目标**——射程外走向距目标 0.9×range 处（停步线），
## 射程内保持 ≥3u（156px）站桩射（被贴脸自然退开到 3u，非风筝）；开火门 =
## 0.8u(42px) < |Δx| < 全射程（贴脸不射——近战 attackRange 1.5 语义的弓手版），
## y 不参与任何判定。AI 弓手**不风筝**（ShouldKite 是 Pro 玩家操控专属）。
## 槽位锚定优先（产线战线班槽齐射），无锚回落本真值站位。
func _ranged_update(dist: float, delta: float, weapon: Node, attack_range: float) -> void:
	# 槽位锚定优先（产线：接战后按班槽原地成排齐射 / 射程外走槽不压敌）
	if _hold_formation_slot(dist) or _approach_via_slot():
		_ranged_fire(delta, weapon, attack_range)
		if _p("push_apart", 0.0) > 0.0:
			_apply_push_apart(_p("push_apart", 0.0), delta)
		return
	var dx: float = absf(_target.global_position.x - entity.global_position.x)
	var moved: bool = false
	if dx >= attack_range:
		# 射程外：奔向距目标 0.9×range 的停步线（GetTargetAttackSpot 射程外分支
		# DAT_016c55a4=0.9 直读）
		var to_t: float = signf(_target.global_position.x - entity.global_position.x)
		if to_t == 0.0:
			to_t = 1.0
		var hold_x: float = _target.global_position.x - to_t * attack_range * ARCHER_RANGE_FRAC
		var step: float = hold_x - entity.global_position.x
		if absf(step) > RANGED_LINE_DEADZONE:
			var dir: Vector2 = _apply_y_walk(Vector2(signf(step), 0.0), delta)
			if _cap_ai_move:
				entity.ai_move(dir, absf(step) > SLOT_RUN_DIST)
			moved = true
	elif dx < ARCHER_HOLD_DIST:
		# 射程内但贴太近（<3u）：退开到保距线（spot 的 target±3u 语义，非风筝）
		var away: float = signf(entity.global_position.x - _target.global_position.x)
		if away == 0.0:
			away = 1.0
		if _cap_ai_move:
			entity.ai_move(Vector2(away, 0.0), false)
		moved = true
	if not moved:
		# 保距带内（3u ≤ dx < 射程）：站桩成排射（SWL 弓手常态）
		if _cap_ai_stop:
			entity.ai_stop()
	_ranged_fire(delta, weapon, attack_range)
	if _p("push_apart", 0.0) > 0.0:
		_apply_push_apart(_p("push_apart", 0.0), delta)


## 远程开火门（ArcherAi.CanAttack 真值直译）：**|Δx|** < 全射程 且 |Δx| > 0.8u
## （42px，DAT_015c1cb8 直读——贴脸不射）；持瞄节奏/脱靶容忍同构，无挥砍锁足。
func _ranged_fire(delta: float, weapon: Node, attack_range: float) -> void:
	var dx: float = absf(_target.global_position.x - entity.global_position.x)
	if dx > attack_range or dx <= ARCHER_MIN_FIRE_DX or weapon == null \
			or not weapon.has_method("can_attack") or not weapon.can_attack() \
			or _arrows_wasted(_target, weapon):
		return
	if not _update_aim_rhythm(delta):
		return
	_face_target()
	weapon.perform_attack(_target)
	_aiming = false


## 己方近战体后缘参照（二线驻射 v2）已随 SWL 真值站位退役：弓手站位只相对
## 目标（射程外 0.9×range 停步线），无自创参照体（翻译档 §7.1.2）。


## 无线可守时的常态接近（压向目标攻击环，y 对齐照旧）——近战 approach 的
## 远程精简版（远程免 IsTargetReallyClose 压上：压上 = 脱离二线钻人堆）
func _approach_target(delta: float, attack_range: float) -> void:
	var to_target: Vector2 = _target.global_position - entity.global_position
	var attack_radius: float = maxf(attack_range * ATTACK_SLOT_FRAC, 24.0)
	var desired_pos: Vector2 = _target.global_position + to_target.normalized() * attack_radius
	var dir: Vector2 = _apply_y_walk((desired_pos - entity.global_position).normalized(), delta)
	if _cap_ai_move:
		entity.ai_move(dir, _determine_x_run_power(desired_pos, attack_range) >= 1.0)


func exit(next: String) -> void:
	# 切行为时兜底收盾：威胁标记按时间衰减，但本行为不再每帧刷新后，
	# 举盾态若残留会永久挡刀（move/idle 不会帮我们关）
	if entity != null and is_instance_valid(entity) and entity.has_method("get_weapon"):
		var weapon: Node = entity.get_weapon()
		if weapon != null and weapon.has_method("set_blocking"):
			weapon.set_blocking(false)
	# 清战斗朝向锁（否则单位永久朝向锁死——锁只在本行为活跃期有效）
	if entity != null and is_instance_valid(entity) and entity.has_method("set_combat_face_lock"):
		entity.set_combat_face_lock(false)
	# 清拉弓瞄准俯仰（表现态归零，防切行为后残留仰角）
	if entity != null and is_instance_valid(entity) and entity.has_method("set_aim_pitch"):
		entity.set_aim_pitch(0.0)
	super.exit(next)


# ─────────────────────────────── 兵种机制（legacy 直译）────────────────────────────────

# ─────────────────────── 槽位锚定驻防（批5 远程部分）─────────────────────────

## 槽位锚定死区（px）：距槽位 ≤ 此值站定不追（SWL FormationPositionIsStable 防抖同源）
const SLOT_HOLD_DEADZONE: float = 48.0
## 距槽位超此值转奔跑归位（方阵重排/危险重冻结后的整队追赶）
const SLOT_RUN_DIST: float = 240.0

## 槽位锚定驻防：射程内远程单位的站位目标 = 编队槽位（formation_system 的班
## 战斗锚方阵，get_unit_combat_slot）。距槽位超死区且不在近身危险带 → 走向槽位
## （边走边射——本分支后续开火逻辑照常执行，战斗朝向锁保证倒退归位不翻面）；
## 死区内站定。锚定期间 y 对齐游走/随机微移步由调用方跳过（槽位是 y 权威）。
## 返回是否处于锚定态（无班/无锚/无编队系统 = false，回落原站桩语义零回归）。
func _hold_formation_slot(dist: float) -> bool:
	if entity == null or not is_instance_valid(entity) or not entity.has_method("get_formation_system"):
		return false
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("get_unit_combat_slot"):
		return false
	var slot: Vector2 = fs.get_unit_combat_slot(entity)
	if is_inf(slot.x):
		return false
	# 保距带（SWL 真值口径，翻译档 §7.1.2）：敌进 3u（ARCHER_HOLD_DIST）内不
	# 迎敌回槽——槽位在敌远侧（后撤归位）才走（危险重冻结会把锚整体后移，
	# 后撤方向的槽位永远合法 → 方阵整体有序后撤）；保距带内站定还击。
	#（旧 kite×1.5 危险带随风筝退役——AI 弓手不风筝，保距线就是 spot 的 3u）
	if dist < ARCHER_HOLD_DIST:
		var slot_farther: bool = _target.global_position.distance_to(slot) > dist + 20.0
		if not slot_farther:
			if _cap_ai_stop:
				entity.ai_stop()
			return true
	var d_slot: float = entity.global_position.distance_to(slot)
	if d_slot <= SLOT_HOLD_DEADZONE:
		if _cap_ai_stop:
			entity.ai_stop()
		return true
	var dir: Vector2 = (slot - entity.global_position).normalized()
	if _cap_ai_move:
		entity.ai_move(dir, d_slot > SLOT_RUN_DIST)
	return true


## 锚定期接敌改道（批5，approach 分支消费）：有槽位时射程外成员走向自身槽位
## （远处奔跑归位）。到槽死区内站定待敌——不追敌不空走，SWL 接战常态：站在
## 方阵里等敌人进射程。远程查战线槽或班战斗锚（get_unit_combat_slot 战线优先），
## 近战只查战线槽（get_unit_line_slot）；无槽位返回 false 走原接敌。
func _approach_via_slot() -> bool:
	if entity == null or not is_instance_valid(entity) or not entity.has_method("get_formation_system"):
		return false
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs):
		return false
	var slot: Vector2 = Vector2.INF
	if _is_ranged_weapon(entity.get_weapon() if _cap_get_weapon else null) \
			and fs.has_method("get_unit_combat_slot"):
		slot = fs.get_unit_combat_slot(entity)
	elif fs.has_method("get_unit_line_slot"):
		slot = fs.get_unit_line_slot(entity)
	if is_inf(slot.x):
		return false
	var d_slot: float = entity.global_position.distance_to(slot)
	if d_slot <= SLOT_HOLD_DEADZONE:
		if _cap_ai_stop:
			entity.ai_stop()
		return true
	if _cap_ai_move:
		entity.ai_move((slot - entity.global_position).normalized(), d_slot > SLOT_RUN_DIST)
	return true


## 拉弓瞄准节奏（SWL ArcherAi.ShouldAim/isAiming/GenerateNextShotRandomness 直译）。
## 档案 aim_hold 有值时：进入射程先"持瞄"高斯随机时长再放箭。
## 对拍根因修正：换目标只重绑准星、**不重置持瞄进度**——目标重选节拍短于
## 持瞄均值时，原"换靶即重掷"让持瞄永远差一步到点 = 弓手站桩不放箭。
## 重置只发生在行为重入（enter）与出手后（_aiming=false）。
## 返回 true = 持瞄结束可放箭（无瞄准档案的兵种直接放行）。
func _update_aim_rhythm(delta: float) -> bool:
	var hold: Vector2 = _profile.get("aim_hold", Vector2.ZERO)
	if hold.y <= 0.0:
		return true
	if _aim_target != _target:
		_aim_target = _target  # 仅重绑，不清进度（对拍根因，见函数头注释）
	if not _aiming:
		_aiming = true
		_aim_timer = _gauss((hold.x + hold.y) * 0.5, maxf(0.05, (hold.y - hold.x) / 3.0))
		# AI 附身技能档位（SWL Personality.UserControlSkill）：LIMITED 拉弓更拖沓、
		# PRO 更果断（默认中位 ×1.0 零回归）
		_aim_timer *= float(ScriptBehaviorProfiles.SKILL_AIM_HOLD_MULT.get(
				int(_profile.get("user_control_skill", 1)), 1.0))
	_aim_timer -= delta
	return _aim_timer <= 0.0


## 弓手脱靶容忍（dump ArcherAi.MissingArrowsTolerance 语义直译，11d：弹药浪费阈值）。
## 目标头上在飞箭矢伤害估计已超出"击杀所需 + 容忍度"（预测超杀 > tolerance）
## 时本次不出手——原版弓手对将死目标换靶不浪费箭，集火 DPS 显著提升。
## 在飞伤害由 WeaponMount 发射时登记、箭矢终态扣减（arrow_projectile）。
## 容忍度取档案 missing_arrows_tolerance（0=关，近战不受此门禁）。
func _arrows_wasted(target: Node, weapon: Node) -> bool:
	var tol: float = _p("missing_arrows_tolerance", 0.0)
	if tol <= 0.0 or target == null or not is_instance_valid(target):
		return false
	if not "incoming_arrow_damage" in target:
		return false
	var incoming: float = float(target.get("incoming_arrow_damage"))
	if incoming <= 0.0:
		return false
	var health: Node = target.get_health() if target.has_method("get_health") else null
	if health == null or not "hp" in health:
		return false
	# 预测超杀 = 在飞伤害 − 目标剩余 HP；超出容忍度则本次不出手（继续持瞄）
	return (incoming - float(health.hp)) > tol


## 姿态举盾聚合（SWL 直译）：
## ① 箭矢威胁（SpeartonAi.IsAnyArrowThreat）——有敌方箭矢瞄向自己即举盾；
##    （A6 标注：arrow_threat_time 是**轻量感知代理**——真实压制状态已落地
##    （StatusEffects.SUPPRESSED，消费点 ai_controller 决策链 + 本行为压制
##    消费段），本代理保留消费未达压制门槛的瞄射窗口（arrow_threat_block
##    语义不变），与真实禁令分工不混判）
## ② 攻击后格挡（Ai.cooldownAfterAttackForBlock）——刚攻击完举盾一拍防反打。
## 两来源任一命中即举盾，窗口全过收盾。
func _update_arrow_threat_block(weapon: Node) -> void:
	if weapon == null or not weapon.has_method("set_blocking"):
		return
	var want: bool = false
	if bool(_profile.get("arrow_threat_block", false)):
		# 威胁账本时基 = 物理帧钟（weapon_ranged 写入侧同源，暂停冻结、回放确定）
		var now: float = _frame_now()
		var last: float = float(entity.get("arrow_threat_time")) if "arrow_threat_time" in entity else -999.0
		want = now - last < _p("arrow_block_hold", 0.8)
	if not want and _p("block_after_attack", 0.0) > 0.0:
		want = _clock < _post_block_until
	weapon.set_blocking(want)


## ─── y 对齐 6 函数（SWL Ai 基类直译，dump legacy_AI_classes.cs L156-184）───
## 接敌 y 走位不是纯随机漂移：ShouldAdjustYPositionTowardsTarget 判定（门槛 =
## IsCloseEnoughToAdjustYTowardsTarget / adjustYEarly）→ DetermineYComponentWhenRunningToTarget
## 出 y 分量 → AdjustGoalYToMoveTowardsTarget 把"目标 y + 个性漂移带"夹进可走带。
## CanAdjustYPositionOnly = x 已到位只调 y（9p 射程内分支消费者）。
## CanWalkTowardsTarget = 可直走（绕障/城墙玩法未复刻，挂 11e 总账，恒真）。

## 接敌 y 走位合成：ShouldAdjust 判定通过时把 y 对齐分量叠加进移动方向。
func _apply_y_walk(dir: Vector2, delta: float) -> Vector2:
	if dir == Vector2.ZERO or not _should_adjust_y_towards_target():
		return dir
	# 接敌方向不以水平为主（绕后/背身包抄）时不调 y——纯 y 走位在侧视里
	# 观感是"背对敌人朝队友走"（2026-08-31 四轮审计）
	if absf(dir.x) < 0.4:
		return dir
	var y_comp: float = _determine_y_component(delta)
	if absf(y_comp) <= 0.0:
		return dir
	return (dir + Vector2(0.0, y_comp)).normalized()


## ShouldAdjustYPositionTowardsTarget（dump L181）：目标 y 未对齐（超死区）且
## 可朝目标走，且（提前对齐 || 水平已足够近）→ true。
func _should_adjust_y_towards_target() -> bool:
	if not _can_walk_towards_target():
		return false
	var band: float = _p("y_drift_band", 0.0)
	if band <= 0.0:
		return false
	if absf(_target.global_position.y - entity.global_position.y) <= Y_ALIGN_DY_THRESHOLD:
		return false
	# adjustYEarly（远程兵种提前对齐）跳过"足够近"门槛（dump RunToPosition 参数）
	if _p("y_align_early", 0.0) <= 0.5 and not _is_close_enough_to_adjust_y():
		return false
	return true


## IsCloseEnoughToAdjustYTowardsTarget（dump L184；ArcherAi L245 override 收紧 →
## 档案 y_align_x_range 分型）：|Δx| 足够近才调 y，远处浪费走位、弓手靠抛物线覆盖。
func _is_close_enough_to_adjust_y() -> bool:
	var dx: float = absf(_target.global_position.x - entity.global_position.x)
	return dx <= _p("y_align_x_range", 300.0)


## CanWalkTowardsTarget（dump L178）：目标存活可直走。城墙/雕像绕障未复刻
## （RestrictTargetSpotWhenBehindWall 系挂 11e 总账），恒真直译。
func _can_walk_towards_target() -> bool:
	return _target != null and is_instance_valid(_target) \
			and not (_target.has_method("is_dead") and _target.is_dead())


## CanAdjustYPositionOnly（dump L175）已随裁决#32 失去消费者（射程内 y 对齐
## 拦射门删除——弹道解算吸收 y 差，y 对齐只在接敌途中生效）


## DetermineYComponentWhenRunningToTarget（dump L157）：跑向目标时的 y 分量
## （±y_align_strength，goal_y 死区内不出分量）。
func _determine_y_component(delta: float) -> float:
	# 个性漂移偏移重掷（DIRECTION_CHANGE_FREQUENCY=0.5s 节奏对齐）
	_drift_timer -= delta
	if _drift_timer <= 0.0:
		var iv: Vector2 = _profile.get("y_drift_interval", Vector2(0.5, 1.2))
		_drift_timer = _roll_range(iv.x, iv.y)
		_drift_offset = _roll_range(-_p("y_drift_band", 0.0), _p("y_drift_band", 0.0))
	var dy: float = _adjust_goal_y() - entity.global_position.y
	if absf(dy) < 10.0:
		return 0.0
	return signf(dy) * _p("y_align_strength", 0.22)


## AdjustGoalYToMoveTowardsTarget（dump L169）：goal_y = 目标 y + 个性漂移偏移
## （personalityControlledY 语义），夹紧可走带（MapInstance 注入的 ground_y~ground_bottom）。
func _adjust_goal_y() -> float:
	var ty: float = _target.global_position.y + _drift_offset
	var gy: float = float(entity.get("ground_y")) if "ground_y" in entity else 0.0
	var gb: float = float(entity.get("ground_bottom")) if "ground_bottom" in entity else 0.0
	if gb > gy:
		return clampf(ty, gy + 20.0, gb - 20.0)
	return ty


## Box-Muller 高斯采样（SWL NextGaussian 对齐；单位种子 RNG 驱动）
func _gauss(mean: float, sigma: float) -> float:
	var u1: float = maxf(_roll(), 0.0001)
	return mean + sqrt(-2.0 * log(u1)) * cos(TAU * _roll()) * sigma


# ─────────────────────────────── 召唤护卫（SWL MagikillAi 直译）────────────────────────────────

## 召唤冷却剩余（s）
var _summon_cd: float = 0.0
## 间距避让节流计时（s）
var _spacing_timer: float = 0.0
## 本施法者召唤的护卫（存活跟踪：召唤封顶用——无上限时 12s 一轮人口爆炸，
## 2026-09-01 观察场反馈"运行一段时间人越来越多"根因）
var _summons_alive: Array = []

## PushApartTolerance（SWL 直译）：站桩输出时若友军贴得太近，向反方向微移
## 拉开（节流 0.4s，只调 y 向优先——不打断对敌朝向）。
## 战斗性能优化：地图空间网格邻域查询替代全友军列表扫描
func _apply_push_apart(spacing: float, delta: float) -> void:
	_spacing_timer -= delta
	if _spacing_timer > 0.0:
		return
	_spacing_timer = 0.4
	var faction: int = entity.get_faction() if _cap_get_faction else 0
	var pos: Vector2 = entity.global_position
	var map: Node = entity.get_map() if _cap_get_map else null
	if faction != 0 and map != null and is_instance_valid(map) and map.has_method("query_neighbors"):
		for a in map.query_neighbors(pos, spacing + 8.0):
			if a == null or not is_instance_valid(a) or a == entity:
				continue
			if a.has_method("is_dead") and a.is_dead():
				continue
			if not a.has_method("get_faction") or a.get_faction() != faction:
				continue
			var d: float = pos.distance_to(a.global_position)
			if d < spacing and d > 0.01:
				var away: Vector2 = (pos - a.global_position).normalized()
				if _cap_ai_move:
					entity.ai_move(away * 0.6, false)
				return
		return
	# 回落：战斗友军列表全扫（旧语义）
	if not _cap_get_battle:
		return
	var bi: Node = entity.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_allies_of"):
		return
	for a in bi.get_allies_of(faction):
		if a == null or not is_instance_valid(a) or a == entity:
			continue
		if a.has_method("is_dead") and a.is_dead():
			continue
		var d: float = pos.distance_to(a.global_position)
		if d < spacing and d > 0.01:
			var away: Vector2 = (pos - a.global_position).normalized()
			if _cap_ai_move:
				entity.ai_move(away * 0.6, false)
			return


## ShouldCastSummon：档案 summon_count>0 且冷却就绪且敌人进入施法距离时，
## 在自身两侧召唤脆皮护卫（minidon）——原版法师的生存方案：护卫挡脸，
## 法师站后排持续施法。**同时存活数封顶 summon_count**：护卫阵亡后才补召
## （仍受冷却），否则一场长仗每 12s 无限拉人，场上人口爆炸。
func _update_summon(dist: float, delta: float) -> void:
	var count: int = int(_p("summon_count", 0.0))
	if count <= 0:
		return
	# 清理失效/死亡引用，统计存活（参数不注解 Node：数组里存有已释放对象时
	# 类型转换直接报错"Cannot convert Object to Object"，靠 is_instance_valid 短路兜底）
	_summons_alive = _summons_alive.filter(func(s) -> bool:
		return is_instance_valid(s) and not (s.has_method("is_dead") and s.is_dead()))
	if _summons_alive.size() >= count:
		return
	_summon_cd -= delta
	if _summon_cd > 0.0:
		return
	if dist > _summon_trigger_range():
		return
	_summon_cd = _p("summon_cooldown", 12.0)
	var spawned: Array = _spawn_minidons(mini(count - _summons_alive.size(), count))
	_summons_alive.append_array(spawned)
	if not spawned.is_empty() and _cap_play_attack:
		entity.play_attack()  # 施法动画（Magikill-Spell1）


## 召唤触发距离：施法距离内（贴太远召了也白召）
func _summon_trigger_range() -> float:
	var weapon: Node = entity.get_weapon() if _cap_get_weapon else null
	return weapon.attack_range if weapon != null and "attack_range" in weapon else 280.0


## 生成 count 个护卫：复用 stickman_entity 场景，同阵营参战、持剑、脆皮
func _spawn_minidons(count: int) -> Array:
	var scene: PackedScene = load("res://modules/units/scenes/stickman_entity.tscn")
	if scene == null:
		push_warning("[BehaviorAttack] 护卫场景加载失败，取消召唤")
		return []
	var host: Node = entity.get_parent()
	if host == null:
		push_warning("[BehaviorAttack] 施法者无宿主节点，取消召唤")
		return []
	# SWL SpawnMinion 协程 + SummonGroundScorch 地面焦痕语义：护卫从施法者
	# **面朝方向的正前方**冒出（横版语义"前"= facing ±x，2026-09-01 反馈修正——
	# 此前用指向目标的二维向量，目标 y 漂移时出生点跑纵深处 = "正上方"观感），
	# 沿纵深 y 排开；地面焦痕 FX 待素材批次补
	var facing: float = 1.0
	if entity != null and entity.has_method("get_facing"):
		facing = float(entity.get_facing())
	var spawned: Array = []
	# 9q：出生 y 以施法者**脚部** y 为基准（root 参考系不随 body_scale 对齐，
	# 缩放单位的脚部必须按 foot_offset 换算——foot_offset 已随 body_scale 缩放）
	var caster_foot: float = float(entity.get("foot_offset")) if "foot_offset" in entity else 0.0
	var feet_y: float = entity.global_position.y + caster_foot
	for i in count:
		var e: Node2D = scene.instantiate()
		host.add_child(e)
		# SWL minidon 体型：比常规兵种小一圈（原版为 Minion prefab 配置，
		# 本项目经 body_scale 数据字段等价实现；渲染+判定+血条同步缩放）
		if e.has_method("set_body_scale"):
			e.set_body_scale(_p("summon_body_scale", 0.65))
		var lateral_y: float = (float(i) - (count - 1) * 0.5) * 44.0
		# 9q：护卫脚落在"法师脚部 y + 纵深排开"上，root 反推（护卫自身 foot_offset 已随缩放）
		var e_foot: float = float(e.get("foot_offset")) if "foot_offset" in e else 0.0
		e.global_position = Vector2(entity.global_position.x + facing * 72.0,
				feet_y + lateral_y - e_foot)
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		if e.has_method("set_faction") and entity.has_method("get_faction"):
			e.set_faction(entity.get_faction())
		# 参战注册（BattleInstance.add_unit：内部会回填 battle_instance 引用）
		if entity.has_method("get_battle_instance"):
			var bi: Node = entity.get_battle_instance()
			if bi != null and is_instance_valid(bi) and bi.has_method("add_unit"):
				bi.add_unit(e, entity.get_faction())
		var wm: Node = e.get_node_or_null("WeaponMount")
		if wm != null:
			wm.weapon_type = 0  # SWORD
		var hc = e.get("health_component")
		if hc != null:
			var hp: float = _p("summon_hp", 40.0)
			hc.set("max_hp", hp)
			hc.set("hp", hp)
		spawned.append(e)
	return spawned


# ─────────────────────────────── 内部 ────────────────────────────────


## 读取兵种档案参数（缺省回落 fallback——对应原硬编码常量）。
func _p(key: String, fallback: float) -> float:
	return float(_profile.get(key, fallback))


## 开火前面向目标（横向翻转）——统一 Face 入口（SWL Ai.Face 直译，
## 见 behavior_base.face_target）：风筝边撤边打、y 纵深走位后都会侧身/背身，
## 不回调会播"反向拉弓"。近战接敌方向天然朝目标，无需处理。
func _face_target() -> void:
	face_target(_target)


## IsTargetReallyClose（SWL 直译，翻译档 §7.1.2）：目标贴身 = **|Δx| < 2.5u**
## （130px 真值；非"半射程"近似）——绕开攻击槽位外圈等位直接压上。
func _is_target_really_close() -> bool:
	return absf(_target.global_position.x - entity.global_position.x) <= REALLY_CLOSE_DX


## 近战出手门（SWL Ai.CanAttack 直译）：默认 0.8 × attackRange（目标静止档；
## 追击动目标 SWL 收 0.5——本仓锁足后目标动时走槽位接近，不复刻该档）。
## 矛兵（有二线射程）且**前排有友军遮挡**时放宽到 0.8 × attackRangeSecondLine
## = 104px 隔排刺击——SWL colInFormation==1 用 2.5u 的编队列位语义在无战线
## 场景下的等价物：自己与目标 x 之间（同纵深带 |Δy| < 48）有存活友军。
func _melee_gate_dist(weapon: Node) -> float:
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	var gate: float = attack_range * ATTACK_GATE_FRAC
	var second_line: float = float(weapon.attack_range_second_line) if weapon != null and "attack_range_second_line" in weapon else 0.0
	if second_line > 0.0 and _ally_blocks_front():
		gate = maxf(gate, second_line * ATTACK_GATE_FRAC)
	return gate


## 前排遮挡判定（二线刺击前提）：任一同阵营存活友军落在我与目标的 x 区间内、
## 且纵深带相近（|Δy| < 48 = 固体箱深，同排语义）。
func _ally_blocks_front() -> bool:
	if not _cap_get_faction or not _cap_get_battle:
		return false
	var bi: Node = entity.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_allies_of"):
		return false
	var sx: float = entity.global_position.x
	var sy: float = entity.global_position.y
	var tx: float = _target.global_position.x
	var toward: float = signf(tx - sx)
	if toward == 0.0:
		return false
	for a in bi.get_allies_of(entity.get_faction()):
		if a == null or not is_instance_valid(a) or a == entity:
			continue
		if a.has_method("is_dead") and a.is_dead():
			continue
		var ax: float = (a as Node2D).global_position.x
		# 友军在我方与目标之间（同向且不越过目标）
		if signf(ax - sx) != toward or absf(ax - tx) < 1.0:
			continue
		if absf((a as Node2D).global_position.y - sy) < 48.0:
			return true
	return false


## DetermineXRunPower（SWL Ai 直译）：水平推进强度 0~1——远处全速逼近（run），
## 近处收步（walk）。阈值 = 1.5×射程（dump 无真值 → 待实测校准）。
func _determine_x_run_power(desired_pos: Vector2, attack_range: float) -> float:
	var dx: float = absf(desired_pos.x - entity.global_position.x)
	return clampf(dx / maxf(attack_range * 1.5, 1.0), 0.0, 1.0)


## 是否远程武器（弓/杖——弹道延迟结算且解算自带移动目标预判）。
func _is_ranged_weapon(weapon: Node) -> bool:
	var wt: int = int(weapon.weapon_type) if weapon != null and "weapon_type" in weapon else 0
	return wt == ScriptBehaviorProfiles.BOW or wt == ScriptBehaviorProfiles.STAFF
## 近战出手预判门（9s _strike_will_land/_hit_frame_seconds）已随裁决#32 删：
## SWL/SW3 出手只有冷却门，命中帧自检射程（weapon_mount._do_strike 的
## 结算帧检查即 SW3 HitUpdate.InRangeForHit 等价物），出手不做移动预判——
## 预判门在追击混战里退化成"目标在动就永不出手"= 射程内站桩不打的主闸


## 挥砍锁时长 = 武器冷却 × 1.5（动画时长的上界近似；冷却读不到回退 1.2s）。
## 常规解锁路径是动画播完（is_attack_anim_active 翻假），本时限只是卡死保险
func _swing_lock_duration(weapon: Node) -> float:
	if weapon != null and "cooldown" in weapon:
		return float(weapon.cooldown) * 1.5
	return 1.2


## 获取当前目标（供测试/调试；目标状态权威在 _acq）
func get_target() -> Node:
	return _acq.get_target() if _acq != null else _target


# ─────────────────────────────── 时钟与命运骰 ────────────────────────────────

## 找目标系统装配（enter 显式 + update 懒兜底；幂等——重入重绑宿主引用）
func _ensure_acq() -> void:
	if _acq == null:
		_acq = ScriptTargetAcquire.new()
	_acq.setup(entity, _battle, _profile)
	# 班级集火接线已删（裁决#31：排长不指定具体目标——个体各自最近敌）


## 物理帧钟（s）：Engine.get_physics_frames / ticks_per_second——跨模块共享账本
## （arrow_threat_time 的写入侧 weapon_ranged / 消费侧 team_ai_snapshot、
## squad_phase_plan）的统一时基：暂停冻结、回放确定。与行为内 _clock 并存
## （_clock = 本行为视角的累积秒，帧钟 = 全局物理时刻，两者速率同源不同零点）
func _frame_now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


## 命运骰掷点（单位种子 RNG；首掷按实体实例 id 派生种子 = 每单位不同序列，
## 对齐 ai_controller._resolve_jitter_seed 惯例；测试重掷 _rng.seed 可复现）
func _roll() -> float:
	_seed_rng_once()
	return _rng.randf()


func _roll_range(from: float, to: float) -> float:
	_seed_rng_once()
	return _rng.randf_range(from, to)


func _seed_rng_once() -> void:
	if _rng_seeded:
		return
	_rng_seeded = true
	_rng.seed = int(entity.get_instance_id()) \
			if entity != null and is_instance_valid(entity) else 20261006
