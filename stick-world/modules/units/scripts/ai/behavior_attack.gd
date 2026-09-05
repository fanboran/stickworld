class_name BehaviorAttack
extends BehaviorBase
## 攻击行为 -- 找最近敌人 -> 接近到射程内 -> 攻击（命中帧->伤害事件）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2 / §7.4 / §8。
## 包含概率钩子（§7.4 第一层）：擅自冲锋、犹豫。
##
## 完成条件（finish 后由 AIController 决策切换）：
##   - 无敌人 / 战斗结束
##   - 自身溃逃（士气低于阈值）-> AIController 切 retreat
##   - 自身重伤且附近有掩体 -> AIController 切 seek_cover
##
## params 可选字段：
##   - battle: BattleInstance（不传则从 entity.get_battle_instance() 取）

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发（惯例见 ai_controller.gd:16）
# audit-exempt: headless 防御性路径 preload（经 api 转发会重新依赖 class_name 注册，
# 失去防御意义）；TargetFinder 为 combat 对外公共类型（combat/api.gd 已声明契约）
const ScriptTargetFinder := preload("res://modules/combat/scripts/target_finder.gd")
## 兵种行为档案（RWR 式基线+覆盖，见 behavior_profiles.gd）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 目标刷新间隔（秒）
const ACQUIRE_INTERVAL: float = 0.5
## 犹豫检查间隔（秒）
const HESITATE_CHECK_INTERVAL: float = 0.5
## 低士气阈值（低于此值触发撤退决策）
const LOW_MORALE_THRESHOLD: float = 0.3
## 低 HP 阈值（低于此值且附近有掩体触发找掩体）
const LOW_HP_THRESHOLD: float = 0.3
## 掩体查询范围（附近多少像素内有掩体算"附近"）
const COVER_NEARBY_RANGE: float = 200.0
## 追击范围倍数（行业最佳实践：目标超出攻击范围 × LEASH_MULT 则放弃追击，防追到天涯海角）
const LEASH_MULT: float = 4.0
## y 对齐死区（px，dump 无真值 → 待实测校准）：|Δy| 小于此值视为已对齐不再走位
const Y_ALIGN_DY_THRESHOLD: float = 16.0
## IsTargetReallyClose 阈值倍数（半射程近似，dump 无真值 → 待实测校准）
const REALLY_CLOSE_MULT: float = 0.5

# ─────────────────────────────── @export（概率钩子，§7.4）────────────────────────────────
## 擅自冲锋概率（每次接近时）
@export var prob_aggressive_push: float = 0.05
## 犹豫概率（每次检查时）
@export var prob_hesitate: float = 0.03
## 狂暴冲锋概率（反编译参考实装 E：狂暴时替代 prob_aggressive_push）
const RAGE_PUSH_PROB: float = 0.35

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 当前目标敌人
var _target: Node = null
## 目标刷新计时器
var _acquire_timer: float = 0.0
## 犹豫检查计时器
var _hesitate_check_timer: float = 0.0
## 犹豫持续计时器（>0 时停滞）
var _hesitate_timer: float = 0.0
## 狂暴标记（反编译参考实装 E）：低血狂暴/被围背墙时由 AIController 传入。
## 狂暴时跳过"低血找掩体"、冲锋概率提升、不因士气波动收手。
var _rage: bool = false
## 兵种行为档案（RWR 式基线+覆盖）：enter 时按武器类型解析，
## 覆盖冲锋/犹豫/追击/保距等参数——兵种个性 = 参数差（见 behavior_profiles.gd）。
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
# ── 灵动化（RWR 士兵的"不安分"，Demo P5）──
## 战斗微移步：射程内站桩输出时的随机小步（横移计时/方向/持续时间）
var _strafe_timer: float = 0.0
var _strafe_dir: float = 0.0
var _strafe_hold: float = 0.0
## 受击规避：被打醒后小概率侧移一小步（边沿检测只在第一帧掷骰）
var _in_stun_prev: bool = false
var _evade_hold: float = 0.0
var _evade_dir: float = 0.0


func _ready() -> void:
	behavior_name = "attack"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	_rage = params.get("rage", false)
	# 兵种档案解析（按主手武器类型；取不到武器回落空档案 = 全基线）
	_profile = {}
	if entity != null and is_instance_valid(entity) and entity.has_method("get_weapon"):
		var w: Node = entity.get_weapon()
		if w != null and "weapon_type" in w:
			_profile = ScriptBehaviorProfiles.get_profile(int(w.weapon_type))
	_target = null
	_acquire_timer = 0.0
	_hesitate_check_timer = 0.0
	_hesitate_timer = 0.0
	_aiming = false
	_aim_target = null
	_aim_timer = 0.0
	_drift_timer = 0.0
	_drift_offset = 0.0


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if entity.has_method("is_dead") and entity.is_dead():
		finish()
		return
	# 受击硬直（行业最佳实践 hit stun）：被打瞬间短暂停滞，不追不打；
	# 醒后小概率规避小跳（RWR 士兵被打了会挪窝，不站桩吃第二下）
	var stunned: bool = entity.has_method("is_in_hit_stun") and entity.is_in_hit_stun()
	if stunned:
		if not _in_stun_prev and _evade_hold <= 0.0:
			if randf() < 0.30:
				_evade_hold = 0.35
				_evade_dir = 1.0 if randf() < 0.5 else -1.0
		_in_stun_prev = true
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	_in_stun_prev = false
	if _evade_hold > 0.0:
		_evade_hold -= delta
		if entity.has_method("ai_move"):
			entity.ai_move(Vector2(0.0, _evade_dir), false)
		return
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("is_active") or not _battle.is_active():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		finish()
		return

	# 刷新目标
	_acquire_timer -= delta
	if _target == null or not is_instance_valid(_target) or (_target.has_method("is_dead") and _target.is_dead()) or _is_beyond_leash() or _acquire_timer <= 0.0:
		# 队伍级共享目标（反编译参考实装 D-B）：排长决策 → 队员执行（集火）。
		# 所属小队有共享攻击目标时优先用它，否则回退各自寻敌。
		var squad_target: Node = _get_squad_target()
		if squad_target != null:
			# 队伍目标始终优先（排长换目标 = 全队换目标）
			_target = squad_target
		elif _target != null and is_instance_valid(_target) and not (_target.has_method("is_dead") and _target.is_dead()) and not _is_beyond_leash():
			# 目标切换滞后（行业最佳实践 sticky target）：当前目标仍有效且未超追击范围则锁定保留，
			# 不因刷新周期重选（避免频繁换目标导致攻击输出丢失）
			pass
		else:
			# 公共目标选择核心（反编译参考实装 A）：规则经 opts 扩展，见 ScriptTargetFinder。
			# ignore_current_attackers = 防集火重叠；prefer_large = 大目标偏好
			# （SWL ArcherAi.AttackLargeTarget：弓手优先射巨物，档案 prefer_large 控制）
			_target = ScriptTargetFinder.find_target(entity, {
				"battle": _battle,
				"ignore_current_attackers": true,
				"prefer_large": _p("prefer_large", 0.0),
			})
		# 感知节奏按兵种档案（RWR 扫视轮询）：基线 0.5s，弓/剑 0.4s 等
		_acquire_timer = _p("acquire_interval", ACQUIRE_INTERVAL)
		if _target == null:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			finish()
			return

	# 自身状态检查：士气/HP 过低 -> finish 让 AIController 决策
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null:
		if health.has_method("is_routed") and health.is_routed():
			finish()
			return
		# 狂暴时放宽士气下限（低血狂暴不因士气波动收手；溃逃仍由 AIController 处理）
		if not _rage and health.has_method("get_morale_ratio") and health.get_morale_ratio() < LOW_MORALE_THRESHOLD:
			finish()
			return
		# 狂暴时跳过"低血找掩体"（反编译参考实装 E）：背水一战不撤退
		if not _rage and health.has_method("get_hp_ratio") and health.get_hp_ratio() < LOW_HP_THRESHOLD and _has_cover_nearby():
			finish()
			return

	# 犹豫概率钩子（§7.4 第一层）
	if _hesitate_timer > 0.0:
		_hesitate_timer -= delta
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	_hesitate_check_timer -= delta
	if _hesitate_check_timer <= 0.0:
		_hesitate_check_timer = HESITATE_CHECK_INTERVAL
		if randf() < _p("hesitate_prob", prob_hesitate):
			var ht: Vector2 = _profile.get("hesitate_time", Vector2(0.3, 0.8))
			_hesitate_timer = randf_range(ht.x, ht.y)
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			return

	# 攻击 / 接近逻辑
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	var dist: float = entity.global_position.distance_to(_target.global_position)
	# 召唤护卫（SWL MagikillAi.ShouldCastSummon 直译）：敌人逼近施法距离且冷却
	# 就绪时召唤脆皮护卫（minidon）挡脸——原版法师的生存方案，替代自创风筝
	_update_summon(dist, delta)
	# 姿态举盾聚合（SWL 直译）：推进/接敌/风筝全程生效
	_update_arrow_threat_block(weapon)
	# 风筝（兵种档案 kite_range > 0，ArcherAi/MagikillAi 保持距离）：敌人逼近时
	# 背向撤离不贴脸输出——即使已在射程内也先拉开（远程兵种存活优先）
	var kite_range: float = _p("kite_range", 0.0)
	if kite_range > 0.0 and dist < kite_range:
		var away: Vector2 = (entity.global_position - _target.global_position).normalized()
		if entity.has_method("ai_move"):
			entity.ai_move(away, _p("kite_run", 0.0) > 0.5)
		# 风筝还击（SWL 弓手边撤边射）：前摇/弹道与移动解耦（延迟结算计时独立），
		# 冷却好就边跑边放——不再被追着跑还不还手
		if dist <= attack_range and weapon != null and weapon.has_method("can_attack") \
				and weapon.can_attack() and not _arrows_wasted(_target, weapon):
			_face_target()  # 回头面向目标开火（否则背身拉弓）
			weapon.perform_attack(_target)
			_aiming = false
	elif dist <= attack_range:
		# 在射程内：停止移动并攻击。弓手先进瞄准节奏（SWL ShouldAim）：持瞄随机
		# 时长再放箭，放箭瞬间重掷（GenerateNextShotRandomness），节奏不再是卡冷却平A
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_face_target()  # 开火面向目标（走位/漂移后可能侧身）
		# 9p（SWL ShouldAim/CanAttack 的 y 门槛，档案 y_aim_tolerance）：|Δy| 超容忍时
		# 先 y 走位保证接近水平持平、距离以水平为主导，不出手——否则横轴观感=故意射空
		var aim_tol: float = _p("y_aim_tolerance", 0.0)
		var dy_align: float = _target.global_position.y - entity.global_position.y
		if aim_tol > 0.0 and absf(dy_align) > aim_tol and _can_adjust_y_position_only(attack_range):
			if entity.has_method("ai_move"):
				entity.ai_move(Vector2(0.0, signf(dy_align)), false)
			_update_aim_rhythm(delta)  # 持瞄节奏照常走，y 对齐即放箭
			return
		if _update_aim_rhythm(delta) and weapon != null and weapon.has_method("can_attack") \
				and weapon.can_attack() and not _arrows_wasted(_target, weapon):
			weapon.perform_attack(_target)
			_aiming = false
			# 攻击后举盾（cooldownAfterAttackForBlock）：矛兵攻击完一拍盾防反打
			if _p("block_after_attack", 0.0) > 0.0:
				_post_block_until = Time.get_ticks_msec() / 1000.0 + _p("block_after_attack", 0.0)
			# 攻击命中帧触发攻击动画（反编译参考实装 C）：播完由 rig.animation_finished 回切
			if entity.has_method("play_attack"):
				entity.play_attack()
		# 战斗微移步（RWR"不安分"感）：站桩输出时随机小步横移，活着的感觉
		_strafe_timer -= delta
		if _strafe_timer <= 0.0:
			_strafe_timer = randf_range(1.5, 3.5)
			if randf() < 0.35:
				_strafe_dir = 1.0 if randf() < 0.5 else -1.0
				_strafe_hold = 0.30
		if _strafe_hold > 0.0:
			_strafe_hold -= delta
			if entity.has_method("ai_move"):
				entity.ai_move(Vector2(0.0, _strafe_dir), false)
		# 射手容错间距（SWL PushApartTolerance）：站桩输出时与友军保持间距
		if _p("push_apart", 0.0) > 0.0:
			_apply_push_apart(_p("push_apart", 0.0), delta)
	else:
		var to_target: Vector2 = _target.global_position - entity.global_position
		# IsTargetReallyClose（SWL 直译）：贴身目标绕开攻击槽位外圈等位，直接压上
		var really_close: bool = _is_target_really_close(dist, attack_range)
		# 攻击槽位（SWL GetTargetAttackSpot/NumberOfUnitsThatCanHit）：目标贴身名额
		# 已满时在**外圈等位**（射程 1.25 倍处徘徊），不硬挤进人堆——"后排无所事事
		# 硬挤"的解法；等位期间远程照常输出，近战等前排空位
		var attack_radius: float = maxf(attack_range * 0.85, 24.0)
		if not really_close and _battle != null and _battle.has_method("get_attacker_count") \
				and _battle.get_attacker_count(_target) >= 3:
			attack_radius = maxf(attack_range * 1.25, 100.0)
		var desired_pos: Vector2 = _target.global_position if really_close \
				else _target.global_position + to_target.normalized() * attack_radius
		var dir: Vector2 = (desired_pos - entity.global_position).normalized()
		# y 轴纵深走位（SWL y 对齐 6 函数直译）：接敌途中朝目标 y（带个性漂移带）对齐，
		# 人群自然铺开不挤一条横线
		dir = _apply_y_walk(dir, delta)
		# 9i+ 包抄走位（P6 批次 7c，design §2.1.3.6 #5，档案开关默认关 = 零回归）：
		# 侧翼单位（相对本方存活质心 y 偏移超阈值）接近方向叠加侧向分量，形成绕击取向
		dir = _apply_flank(dir)
		# DetermineXRunPower（SWL 直译）：远跑近走；近身爆发交给冲锋掷骰
		var run: bool = _determine_x_run_power(desired_pos, attack_range) >= 1.0
		if not run and randf() < (RAGE_PUSH_PROB if _rage else _p("aggressive_push_prob", prob_aggressive_push)):
			run = true
		if entity.has_method("ai_move"):
			entity.ai_move(dir, run)


func exit(next: String) -> void:
	# 切行为时兜底收盾：威胁标记按时间衰减，但本行为不再每帧刷新后，
	# 举盾态若残留会永久挡刀（move/idle 不会帮我们关）
	if entity != null and is_instance_valid(entity) and entity.has_method("get_weapon"):
		var weapon: Node = entity.get_weapon()
		if weapon != null and weapon.has_method("set_blocking"):
			weapon.set_blocking(false)
	super.exit(next)


# ─────────────────────────────── 兵种机制（legacy 直译）────────────────────────────────

## RWR 点射停顿（ai_burst_wait_time[_variance] 语义适配）：连射散布过热时
## 下一箭前插入长停顿（持瞄 ×1.8~3.2 随机倍）等散布恢复——"会点射不无脑扫射"
const BURST_HEAT_THRESHOLD := 0.8
const BURST_WAIT_MULT := Vector2(1.8, 3.2)


## 拉弓瞄准节奏（SWL ArcherAi.ShouldAim/isAiming/GenerateNextShotRandomness 直译）。
## 档案 aim_hold 有值时：进入射程先"持瞄"高斯随机时长再放箭；换目标重掷。
## 返回 true = 持瞄结束可放箭（无瞄准档案的兵种直接放行）。
func _update_aim_rhythm(delta: float) -> bool:
	var hold: Vector2 = _profile.get("aim_hold", Vector2.ZERO)
	if hold.y <= 0.0:
		return true
	if _aim_target != _target:
		_aim_target = _target
		_aiming = false
	if not _aiming:
		_aiming = true
		_aim_timer = _gauss((hold.x + hold.y) * 0.5, maxf(0.05, (hold.y - hold.x) / 3.0))
		var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
		if weapon != null and weapon.has_method("get_sustained_fire_heat") \
				and weapon.get_sustained_fire_heat() >= BURST_HEAT_THRESHOLD:
			_aim_timer *= randf_range(BURST_WAIT_MULT.x, BURST_WAIT_MULT.y)
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
## ② 攻击后格挡（Ai.cooldownAfterAttackForBlock）——刚攻击完举盾一拍防反打。
## 两来源任一命中即举盾，窗口全过收盾。
func _update_arrow_threat_block(weapon: Node) -> void:
	if weapon == null or not weapon.has_method("set_blocking"):
		return
	var want: bool = false
	if bool(_profile.get("arrow_threat_block", false)):
		var now: float = Time.get_ticks_msec() / 1000.0
		var last: float = float(entity.get("arrow_threat_time")) if "arrow_threat_time" in entity else -999.0
		want = now - last < _p("arrow_block_hold", 0.8)
	if not want and _p("block_after_attack", 0.0) > 0.0:
		want = Time.get_ticks_msec() / 1000.0 < _post_block_until
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


## 9i+ 包抄走位（P6 批次 7c，design §2.1.3.6 #5，档案开关默认关 = 零回归）。
## 侧翼单位（相对本方存活质心 y 偏移绝对值 ≥ flank_y_offset）接近方向叠加侧向分量，
## 符号由侧翼侧决定，形成绕击取向；开关关或非侧翼 → 原方向不变。
func _apply_flank(dir: Vector2) -> Vector2:
	if dir == Vector2.ZERO or not bool(_p_b("flank_enabled", false)):
		return dir
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("get_allies_of"):
		return dir
	if not entity.has_method("get_faction"):
		return dir
	# 本方存活质心 y
	var sum_y: float = 0.0
	var n: int = 0
	for u in _battle.get_allies_of(entity.get_faction()):
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		sum_y += u.global_position.y
		n += 1
	if n <= 1:
		return dir
	var mid_y: float = sum_y / float(n)
	var dy: float = entity.global_position.y - mid_y
	var threshold: float = float(_p("flank_y_offset", 120.0))
	if absf(dy) < threshold:
		return dir
	# 侧向分量符号：单位偏上 → 向下绕（+y），偏下 → 向上绕（−y），形成包抄
	var side_sign: float = signf(dy)
	var strength: float = float(_p("flank_side_strength", 0.40))
	return (dir + Vector2(0.0, side_sign * strength)).normalized()


## 档案布尔字段读取（_p 只读 float，布尔单独入口）
func _p_b(key: String, fallback: bool) -> bool:
	return bool(_profile.get(key, fallback))


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


## CanAdjustYPositionOnly（dump L175）：x 已在攻击半径内但 y 未对齐 → 纯 y 走位
## （水平已到位不再横移，只补纵深）。9p 射程内分支消费者。
func _can_adjust_y_position_only(attack_radius: float) -> bool:
	if not _can_walk_towards_target() or entity == null:
		return false
	var dx: float = absf(_target.global_position.x - entity.global_position.x)
	return dx <= attack_radius


## DetermineYComponentWhenRunningToTarget（dump L157）：跑向目标时的 y 分量
## （±y_align_strength，goal_y 死区内不出分量）。
func _determine_y_component(delta: float) -> float:
	# 个性漂移偏移重掷（DIRECTION_CHANGE_FREQUENCY=0.5s 节奏对齐）
	_drift_timer -= delta
	if _drift_timer <= 0.0:
		var iv: Vector2 = _profile.get("y_drift_interval", Vector2(0.5, 1.2))
		_drift_timer = randf_range(iv.x, iv.y)
		_drift_offset = randf_range(-_p("y_drift_band", 0.0), _p("y_drift_band", 0.0))
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


## Box-Muller 高斯采样（SWL NextGaussian 对齐）
func _gauss(mean: float, sigma: float) -> float:
	var u1: float = maxf(randf(), 0.0001)
	return mean + sqrt(-2.0 * log(u1)) * cos(TAU * randf()) * sigma


# ─────────────────────────────── 召唤护卫（SWL MagikillAi 直译）────────────────────────────────

## 召唤冷却剩余（s）
var _summon_cd: float = 0.0
## 间距避让节流计时（s）
var _spacing_timer: float = 0.0
## 本施法者召唤的护卫（存活跟踪：召唤封顶用——无上限时 12s 一轮人口爆炸，
## 2026-09-01 观察场反馈"运行一段时间人越来越多"根因）
var _summons_alive: Array = []

## PushApartTolerance（SWL 直译）：站桩输出时若友军贴得太近，向反方向微移
## 拉开（节流 0.4s，只调 y 向优先——不打断对敌朝向）
func _apply_push_apart(spacing: float, delta: float) -> void:
	_spacing_timer -= delta
	if _spacing_timer > 0.0:
		return
	_spacing_timer = 0.4
	if not entity.has_method("get_battle_instance"):
		return
	var bi: Node = entity.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_allies_of"):
		return
	var faction: int = entity.get_faction() if entity.has_method("get_faction") else 0
	var pos: Vector2 = entity.global_position
	for a in bi.get_allies_of(faction):
		if a == null or not is_instance_valid(a) or a == entity:
			continue
		if a.has_method("is_dead") and a.is_dead():
			continue
		var d: float = pos.distance_to(a.global_position)
		if d < spacing and d > 0.01:
			var away: Vector2 = (pos - a.global_position).normalized()
			if entity.has_method("ai_move"):
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
	if not spawned.is_empty() and entity.has_method("play_attack"):
		entity.play_attack()  # 施法动画（Magikill-Spell1）


## 召唤触发距离：施法距离内（贴太远召了也白召）
func _summon_trigger_range() -> float:
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
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


## IsTargetReallyClose（SWL Ai 直译）：目标贴身（≈半射程内）——绕开攻击槽位
## 外圈等位直接压上。
func _is_target_really_close(dist: float, attack_range: float) -> bool:
	return dist <= maxf(attack_range * REALLY_CLOSE_MULT, 40.0)


## DetermineXRunPower（SWL Ai 直译）：水平推进强度 0~1——远处全速逼近（run），
## 近处收步（walk）。阈值 = 1.5×射程（dump 无真值 → 待实测校准）。
func _determine_x_run_power(desired_pos: Vector2, attack_range: float) -> float:
	var dx: float = absf(desired_pos.x - entity.global_position.x)
	return clampf(dx / maxf(attack_range * 1.5, 1.0), 0.0, 1.0)


## 队伍级共享攻击目标（反编译参考实装 D-B）：本兵所属小队的排长决策目标。
## 无 formation / 无小队 / 无共享目标时返回 null（回退各自寻敌）。
func _get_squad_target() -> Node:
	if entity == null or not entity.has_method("get_formation_system"):
		return null
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("get_unit_squad"):
		return null
	var squad_id: String = fs.get_unit_squad(entity)
	if squad_id.is_empty() or not fs.has_method("get_squad_target"):
		return null
	return fs.get_squad_target(squad_id)

## 追击范围检查（行业最佳实践）：当前目标是否已超出攻击范围 × 追击倍数（兵种档案 leash_mult）。
## 超范围视为"追丢了"，触发重新选目标（避免追杀单个敌人到天涯海角）。
func _is_beyond_leash() -> bool:
	if _target == null or not is_instance_valid(_target) or entity == null:
		return false
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	return entity.global_position.distance_to(_target.global_position) > attack_range * _p("leash_mult", LEASH_MULT)

## 检查附近是否有掩体（用于"重伤找掩体"决策）
func _has_cover_nearby() -> bool:
	if _battle == null or not _battle.has_method("get_cover"):
		return false
	var cover = _battle.get_cover()
	if cover == null or not cover.has_method("has_covers") or not cover.has_covers():
		return false
	if cover.has_method("is_in_cover") and cover.is_in_cover(entity.global_position):
		return true
	if cover.has_method("find_nearest_cover"):
		var nearest: Vector2 = cover.find_nearest_cover(entity.global_position)
		return entity.global_position.distance_to(nearest) < COVER_NEARBY_RANGE
	return false


## 获取当前目标（供测试/调试）
func get_target() -> Node:
	return _target
