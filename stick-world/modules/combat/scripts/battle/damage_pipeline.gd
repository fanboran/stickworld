class_name DamagePipeline
extends RefCounted
## SWL 式单入口伤害管线（复刻 Unit.Damage(amount, direction, inflictor, isHeadShot,
## isBlockable, damageType, isCrit) 语义）。
##
## 与原版一致的分层：
##   ① 入参打包 DamageParameters（伤害来源上下文）
##   ② 修饰链（结算前）：爆头加成 / 格挡减免 / 单位类型减伤（雕像 0.3、巨人 0.66）
##   ③ 入血结算：HealthComponent.take_damage（伴随士气下降）
##   ④ 表现链（结算后）：受击方向动画 / 血溅 / 音效钩子 / 死亡处理
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
	## 是否可被格挡（法术/反伤不可格挡）
	var is_blockable: bool = true
	## 伤害类型
	var type: DAMAGE_TYPE = DAMAGE_TYPE.MELEE
	## 是否暴击
	var is_crit: bool = false
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
	# 爆头加成：箭矢头部命中（原版 headShotBonusDamage 为加值；此处按 1.5x 实现，
	# 待武器数据表落地后改为读表）
	if p.is_head_shot:
		final_amount *= 1.5
	# 暴击
	if p.is_crit:
		final_amount *= 2.0
	# 单位类型减伤（原版：雕像 0.3 / 巨人 0.66，仅对可格挡类直伤生效）
	if p.type != DAMAGE_TYPE.REFLECT:
		if _is_statue(target):
			final_amount *= DAMAGE_REDUCTION_TO_STATUE
		elif _is_massive(target):
			final_amount *= DAMAGE_REDUCTION_TO_MASSIVE
	# 格挡判定（持盾概率格挡：减伤 85%，播放格挡动画；不可格挡类型跳过）
	if p.is_blockable and _try_block(target):
		final_amount *= 0.15
		if target.has_method("play_block"):
			target.play_block()

	# ── ② 入血结算 ──
	health.take_damage(final_amount, p.inflictor)

	# ── ③ 表现链（结算后）──
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


## 格挡尝试：委托目标 WeaponMount 的概率格挡
static func _try_block(target: Node) -> bool:
	var wm: Node = target.get_node_or_null("WeaponMount")
	if wm != null and wm.has_method("is_shield_blocking"):
		return wm.is_shield_blocking()
	return false
