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
## y 纵深个性漂移（SWL personalityControlledY 直译）：漂移目标 Y 与重掷计时
var _drift_y: float = 0.0
var _drift_timer: float = 0.0
## 攻击后举盾截止时刻（s；SWL Ai.cooldownAfterAttackForBlock 直译——
## 矛兵攻击完举盾瞬间防反打，"盾墙"手感来源）
var _post_block_until: float = 0.0


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


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if entity.has_method("is_dead") and entity.is_dead():
		finish()
		return
	# 受击硬直（行业最佳实践 hit stun）：被打瞬间短暂停滞，不追不打
	if entity.has_method("is_in_hit_stun") and entity.is_in_hit_stun():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
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
		if dist <= attack_range and weapon != null and weapon.has_method("can_attack") and weapon.can_attack():
			weapon.perform_attack(_target)
			_aiming = false
	elif dist <= attack_range:
		# 在射程内：停止移动并攻击。弓手先进瞄准节奏（SWL ShouldAim）：持瞄随机
		# 时长再放箭，放箭瞬间重掷（GenerateNextShotRandomness），节奏不再是卡冷却平A
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		if _update_aim_rhythm(delta) and weapon != null and weapon.has_method("can_attack") and weapon.can_attack():
			weapon.perform_attack(_target)
			_aiming = false
			# 攻击后举盾（cooldownAfterAttackForBlock）：矛兵攻击完一拍盾防反打
			if _p("block_after_attack", 0.0) > 0.0:
				_post_block_until = Time.get_ticks_msec() / 1000.0 + _p("block_after_attack", 0.0)
			# 攻击命中帧触发攻击动画（反编译参考实装 C）：播完由 rig.animation_finished 回切
			if entity.has_method("play_attack"):
				entity.play_attack()
		# 射手容错间距（SWL PushApartTolerance）：站桩输出时与友军保持间距
		if _p("push_apart", 0.0) > 0.0:
			_apply_push_apart(_p("push_apart", 0.0), delta)
	else:
		# 攻击槽位（SWL GetTargetAttackSpot/NumberOfUnitsThatCanHit）：目标贴身名额
		# 已满时在**外圈等位**（射程 1.25 倍处徘徊），不硬挤进人堆——"后排无所事事
		# 硬挤"的解法；等位期间远程照常输出，近战等前排空位
		var attack_radius: float = maxf(attack_range * 0.85, 24.0)
		if _battle != null and _battle.has_method("get_attacker_count") \
				and _battle.get_attacker_count(_target) >= 3:
			attack_radius = maxf(attack_range * 1.25, 100.0)
		var to_target: Vector2 = _target.global_position - entity.global_position
		var desired_pos: Vector2 = _target.global_position + to_target.normalized() * attack_radius
		var dir: Vector2 = (desired_pos - entity.global_position).normalized()
		# y 轴纵深走位（SWL AdjustGoalYToMoveTowardsTarget + personalityControlledY 直译）：
		# 接敌途中朝个性纵深位偏移，人群自然铺开不挤一条横线
		dir = _apply_y_drift(dir, delta)
		var run: bool = randf() < (RAGE_PUSH_PROB if _rage else _p("aggressive_push_prob", prob_aggressive_push))
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
	_aim_timer -= delta
	return _aim_timer <= 0.0


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


## y 轴纵深个性漂移（SWL AdjustGoalYToMoveTowardsTarget + personalityControlledY 直译）：
## 接敌移动方向上叠加朝"个性纵深位"的分量，每 y_drift_interval 重掷一次目标 Y，
## 可走带 = entity.ground_y ~ ground_bottom（MapInstance 注入的同款约束字段）。
func _apply_y_drift(dir: Vector2, delta: float) -> Vector2:
	var band: float = _p("y_drift_band", 0.0)
	if band <= 0.0 or dir == Vector2.ZERO:
		return dir
	# 接敌方向不以水平为主（绕后/背身包抄）时不漂移——纯 y 走位在侧视里
	# 观感是"背对敌人朝队友走"（2026-08-31 四轮审计）
	if absf(dir.x) < 0.4:
		return dir
	_drift_timer -= delta
	if _drift_timer <= 0.0:
		var iv: Vector2 = _profile.get("y_drift_interval", Vector2(0.5, 1.2))
		_drift_timer = randf_range(iv.x, iv.y)
		var gy: float = float(entity.get("ground_y")) if "ground_y" in entity else 0.0
		var gb: float = float(entity.get("ground_bottom")) if "ground_bottom" in entity else 0.0
		if gb > gy:
			_drift_y = clampf(entity.global_position.y + randf_range(-band, band), gy + 20.0, gb - 20.0)
	var dy: float = _drift_y - entity.global_position.y
	if absf(dy) < 10.0:
		return dir
	return (dir + Vector2(0.0, signf(dy)) * 0.22).normalized()


## Box-Muller 高斯采样（SWL NextGaussian 对齐）
func _gauss(mean: float, sigma: float) -> float:
	var u1: float = maxf(randf(), 0.0001)
	return mean + sqrt(-2.0 * log(u1)) * cos(TAU * randf()) * sigma


# ─────────────────────────────── 召唤护卫（SWL MagikillAi 直译）────────────────────────────────

## 召唤冷却剩余（s）
var _summon_cd: float = 0.0
## 间距避让节流计时（s）
var _spacing_timer: float = 0.0

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
## 法师站后排持续施法。护卫自动参战（同阵营同 battle）并被 AI 驱动。
func _update_summon(dist: float, delta: float) -> void:
	var count: int = int(_p("summon_count", 0.0))
	if count <= 0:
		return
	_summon_cd -= delta
	if _summon_cd > 0.0:
		return
	if dist > _summon_trigger_range():
		return
	_summon_cd = _p("summon_cooldown", 12.0)
	var spawned: Array = _spawn_minidons(count)
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
		return []
	var host: Node = entity.get_parent()
	if host == null:
		return []
	var spawned: Array = []
	for i in count:
		var e: Node2D = scene.instantiate()
		host.add_child(e)
		var side: float = -1.0 if i % 2 == 0 else 1.0
		var off: Vector2 = Vector2(side * 40.0, (float(i) * 0.5 - count * 0.25) * 40.0)
		e.global_position = entity.global_position + off
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
