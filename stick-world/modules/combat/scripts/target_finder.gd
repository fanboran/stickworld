class_name TargetFinder
extends RefCounted
## 公共目标选择核心（反编译参考实装 A）。
##
## 参考：传奇包 `external/decompiled/legend/dump/legend_AI_core.cs`
##   —— `TargetFinder.FindTarget(Frame, Side, FPVector3, Shape3D)`：按阵营+位置+形状找目标，
##      被 Melee/Ranged/Ability 等所有攻击系统复用；目标规则用组件叠加表达
##      （AiTargeter / OnlyTargetStatue / IgnoreMaxAttackersTargeterAi / Fixate / GuardUnit）。
## 本项目落地：把 behavior_attack 内嵌的 `battle.get_nearest_enemy(entity)` 抽为公共核心，
##   规则用 opts 链式过滤 + 排序表达，供攻击/压制/技能等行为复用。
##
## 用法：
##   var t: Node = TargetFinder.find_target(entity, { battle = _battle, prefer_low_hp = true })
##
## opts 支持：
##   - battle: Node           战斗实例（缺省取 unit.get_battle_instance()）
##   - enemies: Array         直接提供候选敌人数组（覆盖 battle 枚举）
##   - range: float           最大目标距离（-1 = 无限，缺省 -1）
##   - prefer_low_hp: bool    优先残血目标（排序时低血加权）
##   - prefer_large: float    大目标偏好权重（SWL ArcherAi.AttackLargeTarget；max_hp 越大
##                            距离分扣得越多，0=关）
##   - prefer_statue: bool    只选雕像/建筑类目标（按 is_in_group("statue") 或 has_method("is_statue") 判定）
##   - fixate_on: Node        盯防指定目标（存活且在 range 内则直接返回它）
##   - ignore_current_attackers: bool  忽略正被围攻的目标（battle.register_attacker 记录；防集火重叠）
##   - max_attackers_per_target: int   每目标最多攻击者数（配合上者，缺省 3）
##
## find_targets_in_arc() 额外支持（原版 MeleeAttack.NumberOfUnitsThatCanHit 的 AOE 挥击）：
##   - facing: Vector2        挥击朝向（单位向量；缺省按 unit.get_facing() 取 ±x）
##   - half_angle: float      扇形半角（度）
##   - max_count: int         最多返回几个目标
##   - force_first: Node      强制排在首位的单位（玩家/AI 锁定的主目标）

# ─────────────────────────────── 常量 ────────────────────────────────
## 残血优先时的 HP 权重（score = distance + (1 - hp_ratio) * HP_WEIGHT）
const HP_WEIGHT: float = 300.0
## 大目标偏好：每点 max_hp 抵扣的距离分（prefer_large=1 时 200hp 巨物 ≈ -60px 距离偏好）
const LARGE_HP_WEIGHT: float = 0.3


## 选取最优目标。无可选目标返回 null。
static func find_target(unit: Node, opts: Dictionary = {}) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null

	var battle: Node = opts.get("battle", null)
	if battle == null and unit.has_method("get_battle_instance"):
		battle = unit.get_battle_instance()
	if battle == null:
		return null

	# 盯防：指定目标存活且在范围内则锁定
	var fixate_on: Node = opts.get("fixate_on", null)
	if fixate_on != null and is_instance_valid(fixate_on) and not _is_dead(fixate_on):
		var range_ck: float = opts.get("range", -1.0)
		if range_ck < 0.0 or unit.global_position.distance_to(fixate_on.global_position) <= range_ck:
			return fixate_on

	# 候选敌人：优先显式传入，否则按阵营从 battle 取
	var enemies: Array = opts.get("enemies", [])
	if enemies.is_empty():
		enemies = _collect_enemies(unit, battle)
	if enemies.is_empty():
		return null

	var range: float = opts.get("range", -1.0)
	var prefer_low_hp: bool = opts.get("prefer_low_hp", false)
	var prefer_large: float = float(opts.get("prefer_large", 0.0))
	var prefer_statue: bool = opts.get("prefer_statue", false)
	var ignore_attackers: bool = opts.get("ignore_current_attackers", false)
	var max_attackers: int = opts.get("max_attackers_per_target", 3)

	var best: Node = null
	var best_score: float = INF
	for e in enemies:
		if e == null or not is_instance_valid(e) or _is_dead(e):
			continue
		var d: float = unit.global_position.distance_to(e.global_position)
		if range > 0.0 and d > range:
			continue
		if prefer_statue and not _is_statue(e):
			continue
		# 防集火重叠：正被 ≥max_attackers 个单位围攻的目标跳过（除非无其他选择时兜底放宽）
		if ignore_attackers and battle.has_method("get_attacker_count") \
				and battle.get_attacker_count(e) >= max_attackers:
			continue
		# 距离为主，残血优先时按低血加权（残血分值更低 → 更可能被选中）
		var score: float = d
		if prefer_low_hp:
			score = d + (1.0 - _hp_ratio(e)) * HP_WEIGHT
		# 大目标偏好（SWL AttackLargeTarget）：max_hp 越大距离分扣越多 → 弓手优先射巨物
		if prefer_large > 0.0:
			score -= _max_hp_of(e) * LARGE_HP_WEIGHT * prefer_large
		if score < best_score:
			best_score = score
			best = e
	# 兜底：全部目标都被围攻时，允许选最靠近的（避免无人攻击）
	if best == null and ignore_attackers:
		return _nearest_enemy(unit, enemies, range)
	return best



## 候选敌人枚举（显式 opts.enemies 为空时按阵营从 battle 取）
static func _collect_enemies(unit: Node, battle: Node) -> Array:
	if battle == null or not battle.has_method("get_enemies_of"):
		return []
	var faction: int = unit.faction_id if "faction_id" in unit else 0
	return battle.get_enemies_of(faction)


## AOE 挥击目标查询（原版 MeleeAttack_Prototype.NumberOfUnitsThatCanHit 语义）：
## 一次挥击打中身前**扇形**内的多个敌人，返回按距离升序的目标数组。
##
## 语义澄清：NumberOfUnitsThatCanHit 是"一次挥击能打中几人"（AOE），
## 不是"最多几个人同时围攻同一个目标"（防集火）——后者是本文件
## max_attackers_per_target 的职责，两者曾在本项目被混为一谈。
##
## opts 见文件头 find_target() 说明；max_count <= 0 时不限制人数。
static func find_targets_in_arc(unit: Node, opts: Dictionary = {}) -> Array:
	var out: Array = []
	if unit == null or not is_instance_valid(unit):
		return out
	var battle: Node = opts.get("battle", null)
	if battle == null and unit.has_method("get_battle_instance"):
		battle = unit.get_battle_instance()
	var enemies: Array = opts.get("enemies", [])
	if enemies.is_empty():
		enemies = _collect_enemies(unit, battle)
	if enemies.is_empty():
		return out

	var range: float = opts.get("range", -1.0)
	var max_count: int = opts.get("max_count", 1)
	var half_angle: float = opts.get("half_angle", 55.0)
	var facing: Vector2 = opts.get("facing", Vector2.ZERO)
	if facing == Vector2.ZERO:
		var f: int = unit.get_facing() if unit.has_method("get_facing") else 1
		facing = Vector2(float(f), 0.0)
	facing = facing.normalized()
	var cos_limit: float = cos(deg_to_rad(half_angle))

	# 主目标强制排首位（玩家/AI 锁定的人必须在结算名单里，否则"打不到我盯的人"）
	var force_first: Node = opts.get("force_first", null)
	if force_first != null and is_instance_valid(force_first) and not _is_dead(force_first):
		if facing.dot((force_first.global_position - unit.global_position).normalized()) >= cos_limit:
			out.append(force_first)

	var scored: Array = []
	for e in enemies:
		if e == null or not is_instance_valid(e) or _is_dead(e) or e == force_first:
			continue
		var to_e: Vector2 = e.global_position - unit.global_position
		var d: float = to_e.length()
		if range > 0.0 and d > range:
			continue
		if to_e.normalized().dot(facing) < cos_limit:
			continue
		scored.append([d, e])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	for pair in scored:
		out.append(pair[1])
	if max_count > 0 and out.size() > max_count:
		out = out.slice(0, max_count)
	return out


## 兜底最近目标（防集火过滤导致无目标可打时使用；跳过围攻数上限）。
static func _nearest_enemy(unit: Node, enemies: Array, range: float) -> Node:
	var nearest: Node = null
	var nearest_d: float = INF
	for e in enemies:
		if e == null or not is_instance_valid(e) or _is_dead(e):
			continue
		var d: float = unit.global_position.distance_to(e.global_position)
		if range > 0.0 and d > range:
			continue
		if d < nearest_d:
			nearest_d = d
			nearest = e
	return nearest


# ─────────────────────────────── 内部 ────────────────────────────────

## 是否已死亡（兼容无 is_dead 的单位视为存活）
static func _is_dead(e: Node) -> bool:
	return e.has_method("is_dead") and e.is_dead()


## 血量比例 0~1（无 health 组件视为满血 1.0）
static func _hp_ratio(e: Node) -> float:
	if not e.has_method("get_health"):
		return 1.0
	var health: Node = e.get_health()
	if health == null or not health.has_method("get_hp_ratio"):
		return 1.0
	return health.get_hp_ratio()


## 目标血量上限（大目标偏好用；读不到回落 0 = 无偏好加成）
static func _max_hp_of(e: Node) -> float:
	if not e.has_method("get_health"):
		return 0.0
	var health: Node = e.get_health()
	if health == null or not "max_hp" in health:
		return 0.0
	return maxf(0.0, float(health.get("max_hp")))


## 是否雕像/建筑类目标（组 "statue" 或 is_statue 方法）
static func _is_statue(e: Node) -> bool:
	if e.is_in_group("statue"):
		return true
	return e.has_method("is_statue") and e.is_statue()


## 选取血量最低的未满血友军（P7 MericAi.UpdateTarget 直译宿主）。
## 候选 = 同阵营存活 ∧ hp_ratio < 1.0；按 hp_ratio 升序，同比例取距离最近。
## 含自身（祭司可自我治疗，决策点 3）。opts: battle(必填) / range(-1=无限)。
static func find_weakest_ally(unit: Node, opts: Dictionary = {}) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	var battle: Node = opts.get("battle", null)
	if battle == null or not is_instance_valid(battle):
		if unit.has_method("get_battle_instance"):
			battle = unit.get_battle_instance()
	if battle == null or not is_instance_valid(battle) or not battle.has_method("get_allies_of"):
		return null
	var faction: int = unit.get_faction() if unit.has_method("get_faction") else 0
	if faction == 0:
		return null
	var range_limit: float = float(opts.get("range", -1.0))
	var pos: Vector2 = unit.global_position
	var best: Node = null
	var best_ratio: float = 2.0
	var best_dist: float = 0.0
	for ally in battle.get_allies_of(faction):
		if ally == null or not is_instance_valid(ally):
			continue
		if _is_dead(ally):
			continue
		var ratio: float = _hp_ratio(ally)
		if ratio >= 1.0:
			continue
		if range_limit > 0.0 and pos.distance_to(ally.global_position) > range_limit:
			continue
		var dist: float = pos.distance_to(ally.global_position)
		if ratio < best_ratio or (ratio == best_ratio and dist < best_dist):
			best = ally
			best_ratio = ratio
			best_dist = dist
	return best
