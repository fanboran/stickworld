class_name DamagePipeline
extends RefCounted
## SWL 式单入口伤害管线（复刻 Unit.Damage(amount, direction, inflictor, isHeadShot,
## isBlockable, damageType, isCrit) 语义）。
##
## 与原版一致的分层：
##   ① 入参打包 DamageParameters（伤害来源上下文）
##   ② 修饰链（结算前）：爆头加值 / 暴击倍率 / 格挡减免 / 单位类型减伤（雕像 0.3、巨人 0.66）
##   ③ 入血结算：HealthComponent.take_damage（伴随士气下降）
##   ④ 反伤链（结算后）：暴击自伤 critBonusDamageInflictedToSelf + ApplyDamageReflect
##      （受击方 reflect_damage 配置反弹给攻击者，受 CanReceiveReflectDamage 约束）
##   ⑤ 表现链（结算后）：受击方向动画 / 血溅 / 音效钩子 / 死亡处理
##      （爆头致死打 died_from_headshot 标记 → 播 Death-Headshot 动画，原版 Kill(isHeadShot)）
##
## 数值来源原则：**加值还是倍率，跟原版字段保持一致**，不要顺手改语义。
##   - 爆头 = Unit.headShotBonusDamage（**加值**，每单位配置）→ 加算，不是 ×1.5
##   - 暴击 = isCrit（倍率，各武器可调）+ critBonusDamageInflictedToSelf（**自伤代价**）
##
## 所有伤害（近战/箭矢/法术/反伤/溅射）必须经 apply() 进入，禁止绕过直调
## HealthComponent.take_damage——这是原版 Damage 单入口的复刻核心。

# ─────────────────────────────── 伤害类型 ────────────────────────────────
enum DAMAGE_TYPE { MELEE, RANGED, SPELL, REFLECT, SPLASH }

## 对巨型单位（巨人）减伤系数（复刻 DAMAGE_REDUCTION_TO_MASSIVE = 0.66）
const DAMAGE_REDUCTION_TO_MASSIVE := 0.66
## 对雕像减伤系数（复刻 DAMAGE_REDUCTION_TO_STATUE = 0.3）
const DAMAGE_REDUCTION_TO_STATUE := 0.3


## 伤害参数包（对应 Unit.DamageParameters）
class Params:
	extends RefCounted
	## 伤害数值
	var amount: float = 0.0
	## 施加者实体（可为 null：环境/溅射）
	var inflictor: Node = null
	## 受击方向（攻击者→受击者单位向量；决定受击动画朝向/是否背后受击）
	var direction: Vector2 = Vector2.ZERO
	## 是否爆头（箭矢头部命中；爆头有额外加成/动画）
	var is_head_shot: bool = false
	## 爆头加伤（原版 Unit.headShotBonusDamage：**加值**，非倍率；每单位配置）
	var head_shot_bonus_damage: float = 10.0
	## 是否可被格挡（法术/反伤不可格挡）
	var is_blockable: bool = true
	## 伤害类型
	var type: DAMAGE_TYPE = DAMAGE_TYPE.MELEE
	## 是否暴击
	var is_crit: bool = false
	## 暴击伤害倍率（各武器可调，缺省 ×2）
	var crit_damage_multiplier: float = 2.0
	## 暴击自伤（原版 critBonusDamageInflictedToSelf：暴击的代价，如剑崩断反伤自己）
	var crit_self_damage: float = 0.0
	## 溅射半径（>0 时对周围敌人溅射）
	var splash_radius: float = 0.0
	## 溅射系数（对主目标外的单位）
	var splash_modifier: float = 0.5
	## 击退冲量（0=无击退；近战/箭矢按 damage×16 传入）
	var knockback: float = 0.0

	func _init(p_amount: float = 0.0, p_inflictor: Node = null) -> void:
		amount = p_amount
		inflictor = p_inflictor


## 单入口：所有伤害由此进入。
## target: 受击实体（需有 HealthComponent 子节点，可为 StickmanEntity 或雕像建筑）
## 返回实际生效的伤害值（0 = 被完全格挡/无效）。
static func apply(target: Node, p: Params) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var health: Node = target.get_node_or_null("HealthComponent") if target.has_method("get_node_or_null") else null
	if health == null or health.is_dead():
		return 0.0

	var final_amount: float = p.amount

	# ── ① 修饰链（结算前）──
	# 爆头加值：原版 headShotBonusDamage 是**加值字段**（每单位配置），不是倍率。
	# 早前实现的固定 ×1.5 是把"数据驱动"译成了"硬编码"，这里改回加算。
	if p.is_head_shot:
		final_amount += p.head_shot_bonus_damage
	# 暴击（倍率；各武器可调）
	if p.is_crit:
		final_amount *= p.crit_damage_multiplier
	# 单位类型减伤（原版：雕像 0.3 / 巨人 0.66，仅对可格挡类直伤生效）
	if p.type != DAMAGE_TYPE.REFLECT:
		if _is_statue(target):
			final_amount *= DAMAGE_REDUCTION_TO_STATUE
		elif _is_massive(target):
			final_amount *= DAMAGE_REDUCTION_TO_MASSIVE
	# 格挡判定（举盾姿态 + 正面来袭 + 概率）：减伤 85%，播放格挡动画；
	# 不可格挡类型（法术/反伤/溅射）跳过。成功格挡后进入 blockResetInterval 冷却。
	if p.is_blockable and _try_block(target, p.direction):
		final_amount *= 0.15
		if target.has_method("play_block"):
			target.play_block()

	# ── ② 入血结算 ──
	health.take_damage(final_amount, p.inflictor)
	# Kill(isHeadShot) 语义：爆头致死打标记，死亡处理播 Death-Headshot 专属动画
	# （普通死亡与爆头死亡在原版是两条动画，见 stickman_entity._on_died）
	if p.is_head_shot and health.is_dead() and "died_from_headshot" in health:
		health.died_from_headshot = true

	# ── ③ 反伤链：暴击自伤（critBonusDamageInflictedToSelf）──
	# 原版暴击不是纯增益——暴击者自己也要吃伤害（Swordwrath 暴击会崩断剑）。
	# 自伤走 apply 单入口，但强制 is_crit=false / is_blockable=false，避免递归与"挡自己的暴击"。
	if p.is_crit and p.crit_self_damage > 0.0 and p.inflictor != null \
			and is_instance_valid(p.inflictor) and p.inflictor != target:
		var self_p: Params = Params.new(p.crit_self_damage, null)
		self_p.type = DAMAGE_TYPE.REFLECT
		self_p.is_blockable = false
		self_p.is_crit = false
		apply(p.inflictor, self_p)

	# ── ④ 反伤链：ApplyDamageReflect（受击方把伤害反弹给攻击者）──
	# 反伤量是**受击方**的配置（WeaponMount.reflect_damage，原版 CanReceiveReflectDamage
	# 侧约束在攻击者）；REFLECT 类型不反弹（防自伤/反伤互相打穿递归）。
	if p.type != DAMAGE_TYPE.REFLECT and p.inflictor != null \
			and is_instance_valid(p.inflictor) and p.inflictor != target:
		_try_reflect(target, p.inflictor)

	# ── ⑤ 表现链（结算后）──
	# 受击方向动画 + 物理击退（击退量由调用方给定，SWL PushPower 语义）
	if p.knockback > 0.0 and target.has_method("apply_hit_reaction") and p.inflictor != null:
		var dir: Vector2 = (target.global_position - p.inflictor.global_position).normalized()
		target.apply_hit_reaction(dir, p.knockback)
	# 溅射（主目标已结算，对半径内其他敌方按 splash_modifier 结算）
	if p.splash_radius > 0.0 and p.inflictor != null:
		_apply_splash(target, p)

	return final_amount


## 溅射：对主目标周围（不含主目标）的敌方单位结算。
static func _apply_splash(main_target: Node, p: Params) -> void:
	var battle: Node = null
	if p.inflictor.has_method("get_battle_instance"):
		battle = p.inflictor.get_battle_instance()
	if battle == null or not battle.has_method("get_enemies_of"):
		return
	var main_faction: int = main_target.get("faction_id") if "faction_id" in main_target else 0
	# 溅射目标 = 主目标同阵营（即施法者的敌方阵营）的其他单位
	for enemy in battle.get_enemies_of(p.inflictor.get("faction_id") if "faction_id" in p.inflictor else 0):
		if enemy == null or not is_instance_valid(enemy) or enemy == main_target:
			continue
		if "faction_id" in enemy and enemy.faction_id != main_faction:
			continue
		var d: float = enemy.global_position.distance_to(main_target.global_position)
		if d <= p.splash_radius:
			var sub: Params = Params.new(p.amount * p.splash_modifier, p.inflictor)
			sub.type = DAMAGE_TYPE.SPLASH
			sub.is_blockable = false
			apply(enemy, sub)


## 雕像判定（is_in_group("statue") 或 has_method("is_statue")）
static func _is_statue(target: Node) -> bool:
	return target.is_in_group("statue") or (target.has_method("is_statue") and target.is_statue())


## 巨型单位判定（group "massive" 或 mass 阈值字段）
static func _is_massive(target: Node) -> bool:
	return target.is_in_group("massive") or (target.has_method("is_massive") and target.is_massive())


## 格挡尝试：委托目标 WeaponMount 的姿态格挡（持盾 + 举盾姿态 + 正面 + 概率）。
## 成功后通知 WeaponMount 启动 blockResetInterval 冷却。
static func _try_block(target: Node, incoming_dir: Vector2) -> bool:
	var wm: Node = target.get_node_or_null("WeaponMount")
	if wm == null or not wm.has_method("is_shield_blocking"):
		return false
	var blocked: bool = wm.is_shield_blocking(incoming_dir)
	if blocked and wm.has_method("notify_block_succeeded"):
		wm.notify_block_succeeded()
	return blocked


## 反伤尝试（原版 Unit.ApplyDamageReflect）：受击方 WeaponMount 配了 reflect_damage
## 时，把等量伤害反弹给攻击者。攻击者免疫条件走 CanReceiveReflectDamage 虚方法
## 语义（缺省可被反伤）；反伤本身 REFLECT 类型、不可格挡、不可暴击。
static func _try_reflect(target: Node, inflictor: Node) -> void:
	var wm: Node = target.get_node_or_null("WeaponMount")
	if wm == null or not "reflect_damage" in wm:
		return
	var amount: float = float(wm.get("reflect_damage"))
	if amount <= 0.0:
		return
	if inflictor.has_method("can_receive_reflect_damage") \
			and not inflictor.can_receive_reflect_damage():
		return
	var p: Params = Params.new(amount, target)
	p.type = DAMAGE_TYPE.REFLECT
	p.is_blockable = false
	p.is_crit = false
	apply(inflictor, p)
