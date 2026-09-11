class_name TaskBoard
extends RefCounted
## 任务槽系统（A2 · 设计文档 12 号 C3/C4，CoH 战略层内核直译机制、原创代码）。
##
## CoH 逆向锚点（docs/审计/英雄连AI逆向_2026-09-11.md §3.3）：
##   - 战略 AI（team_ai）只**创建/杀任务槽**（攻/防），从不指定哪支小队——
##     小队匹配归执行侧（本类 match_groups，"槽 ↔ 原子单元 1:1"）；
##   - 槽带集结点（rally）/超时（rally 超时杀槽、目标超时重评分）/评分权重；
##   - 目标评分四因子 threat / avoid_clumps / distance / inertia（防振荡），
##     权重真值：score_threat 5.0 / avoid_clumps 10.0 / distance 5.0+5.0 / inertia 1.4。
##
## 设计原则对账：
##   - 原则⑤ 任务槽解耦：下令方只声明意图槽（数量+目标），匹配与执行归下层；
##   - 原则④ 决策有节拍：本类无自转——tick 由 TeamAi 决策节拍驱动（不逐帧）；
##   - 原则⑦ 数值进档案：全部参数经 setup(profile) 注入（BalanceConfig category=ai）。
##
## 与 3-F2 的关系（设计文档 §四）：槽是「同级直控小队」的意图载体；组织化编制
## 由 TeamAi 下令时经 issue_to_org 走指挥链（本类不感知组织，匹配以原子单元组为单位）。

# ─────────────────────────────── 常量 ────────────────────────────────
## 槽类型（攻/防；CoH military 任务组 Attack/Defend 二分）
const KIND_ATTACK: int = 0
const KIND_DEFEND: int = 1

# ─────────────────────────────── 状态 ────────────────────────────────
## 参数档案（TeamAi._p 同引用；权重/超时/半径全档案化，原则⑦）
var _p: Dictionary = {}
## 全部槽（id -> TaskSlot）
var _slots: Dictionary = {}
## 槽 id 序列器（atk_N / def_N，稳定可断言）
var _seq_attack: int = 0
var _seq_defend: int = 0
## 执行侧匹配表（squad_id -> slot_id；match_groups 重建）
var _squad_slot: Dictionary = {}


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 装配：注入参数档案引用（TeamAi._p，同一 Dictionary 实例——档案重建即整体重挂）。
func setup(profile: Dictionary) -> void:
	_p = profile
	reset()


## 清空全部槽与匹配（战斗重开/复用重置）。
func reset() -> void:
	_slots.clear()
	_squad_slot.clear()
	_seq_attack = 0
	_seq_defend = 0


# ─────────────────────────────── 战略侧：槽增删（只动空槽，不点名小队）────────────────────────────────

## 槽同步（CoH strategy_military.execute 同构）：把 kind 类槽位数量调到 desired。
## 新建槽带 target/rally 与创建时刻；超额从最新开始杀（保最旧 = 保目标惯性稳定，
## 创建序即优先序）。现存槽不在此重定位——目标重评分只发生在目标超时（tick），
## 防逐拍振荡。
func sync_slots(kind: int, desired: int, target: Vector2, rally: Vector2, now: float) -> void:
	desired = maxi(desired, 0)
	var current := _slots_by_kind(kind)
	while current.size() > desired:
		var slot: TaskSlot = current.pop_back()  # 杀最新保最旧：老槽目标惯性不丢
		_kill_slot(slot.id)
	while current.size() < desired:
		var slot := TaskSlot.new()
		if kind == KIND_ATTACK:
			_seq_attack += 1
			slot.id = "atk_%03d" % _seq_attack  # 零填充：id 序 = 创建序（字典序安全）
			slot.kind = KIND_ATTACK
		else:
			_seq_defend += 1
			slot.id = "def_%03d" % _seq_defend
			slot.kind = KIND_DEFEND
		slot.target = target
		slot.rally = rally
		slot.created_at = now
		slot.last_retarget_at = now
		_slots[slot.id] = slot
		current.append(slot)


## 槽生命周期推进（TeamAi 决策节拍驱动调用；纯函数式，无自转）：
##   - 集结超时（created_at 起算）→ 杀槽（CoH "rally 超时 3min 杀不活跃任务"；
##     战略侧 sync_slots 下拍按 desired 重建 = kill→recreate 循环）；
##   - 目标超时（last_retarget_at 起算）→ rescore 回调重定位 + 记脏
##     （CoH "目标超时 30s 重评分"；rescore(slot) -> Vector2）。
## 返回被重定位的**攻击**槽 id 数组（下令方据此重发号令；防守槽重定位只刷数据不重发，
## 维持既有 DEFEND 不重发号令口径的零回归）。
func tick(now: float, rescore: Callable) -> Array:
	var retargeted: Array = []
	for id in _slots.keys().duplicate():
		var slot: TaskSlot = _slots.get(id)
		if slot == null:
			continue
		if now - slot.created_at >= _rally_timeout(slot.kind):
			_kill_slot(slot.id)
			continue
		if now - slot.last_retarget_at >= _target_timeout(slot.kind):
			if rescore.is_valid():
				var new_target: Variant = rescore.call(slot)
				if new_target is Vector2:
					slot.target = new_target
			slot.last_retarget_at = now
			if slot.kind == KIND_ATTACK:
				retargeted.append(slot.id)
	return retargeted


# ─────────────────────────────── 执行侧：小队匹配 ────────────────────────────────

## 小队匹配（CoH 引擎侧匹配的同构落点）：groups = [{key, squads}]（TeamAi 原子单元
## 分组：组织化编制作一组、散兵各一组；key 供调试）。序位在前 attack 槽数的组绑攻击槽，
## 其余组绑防守槽；组内全部小队记绑定。槽不足的组不绑定（号令走防守位兜底）。
## 返回 {squad_id: slot_id}（未绑定 = ""）。
func match_groups(groups: Array) -> Dictionary:
	_squad_slot.clear()
	var mapping: Dictionary = {}
	var atk := _slots_by_kind(KIND_ATTACK)
	var def := _slots_by_kind(KIND_DEFEND)
	for i in groups.size():
		var g: Dictionary = groups[i]
		var slot: TaskSlot = null
		if i < atk.size():
			slot = atk[i]
		elif (i - atk.size()) < def.size():
			slot = def[i - atk.size()]
		var slot_id: String = slot.id if slot != null else ""
		for sid_v in g.get("squads", []):
			var sid := str(sid_v)
			if slot != null:
				_squad_slot[sid] = slot_id
			mapping[sid] = slot_id
	return mapping


## 查小队绑定槽 id（未绑定 = ""）
func slot_of_squad(squad_id: String) -> String:
	return str(_squad_slot.get(squad_id, ""))


## 查槽（不存在返回 null）
func get_slot(slot_id: String) -> TaskSlot:
	return _slots.get(slot_id)


## 是否存在攻击槽（槽驱动姿态的核心查询）
func has_attack_slots() -> bool:
	return not _slots_by_kind(KIND_ATTACK).is_empty()


## 某类槽位数（调试/测试断言）
func slot_count(kind: int) -> int:
	return _slots_by_kind(kind).size()


## 全部槽快照（调试 HUD / 测试断言；只读视图）
func get_slots(kind: int) -> Array:
	return _slots_by_kind(kind).duplicate()


# ─────────────────────────────── C4：目标评分四因子 ────────────────────────────────

## 单候选评分（四因子加权，语义映射初值见 personality.tres 行描述）：
##   score = threat × w_threat − clump × w_clump − d_squad × w_ds − d_base × w_db + inertia × w_in
##   threat   候选点周边敌军力量 / 本方力量（钳 0~1）：攻击高威胁目标优先；
##   clump    无威胁时（threat=0）候选点落在敌群内的聚集惩罚（CoH
##            avoid_clumps_at_no_threat：没仗打就别扎进人堆）；
##   distance 距小队（本方质心）/距基地（本方锚点）归一惩罚：近者优先；
##   inertia  与上次目标一致（容差内）给满分奖励：重评分时防目标振荡。
## ctx = {squad_pos, base_pos, enemies: [{pos, weight}], own_strength, last_target}
func score_target(pos: Vector2, ctx: Dictionary) -> float:
	var enemies: Array = ctx.get("enemies", [])
	var own_ref: float = maxf(float(ctx.get("own_strength", 0.0)), float(_p.get("ratio_empty_enemy_sentinel", 10.0)))
	# 因子一 threat：目标周边敌军力量密度（归一 0~1）
	var threat: float = clampf(_strength_near(pos, enemies, float(_p.get("score_threat_radius", 260.0))) / own_ref, 0.0, 1.0)
	# 因子二 avoid_clumps：仅无威胁时惩罚聚集（有仗打不避人堆）
	var clump: float = 0.0
	if threat <= 0.0:
		clump = clampf(_strength_near(pos, enemies, float(_p.get("score_clump_radius", 300.0))) / own_ref, 0.0, 1.0)
	# 因子三 distance：距小队/基地归一惩罚
	var norm: float = maxf(float(_p.get("score_distance_norm", 1200.0)), 1.0)
	var squad_pos: Vector2 = ctx.get("squad_pos", pos)
	var base_pos: Vector2 = ctx.get("base_pos", pos)
	var d_squad: float = clampf(pos.distance_to(squad_pos) / norm, 0.0, 1.0)
	var d_base: float = clampf(pos.distance_to(base_pos) / norm, 0.0, 1.0)
	# 因子四 inertia：与上次目标一致（容差内）满分奖励，防振荡
	var last_target: Vector2 = ctx.get("last_target", Vector2.INF)
	var inertia: float = 1.0 if pos.distance_to(last_target) <= float(_p.get("score_inertia_tolerance", 120.0)) else 0.0
	return float(_p.get("score_threat", 5.0)) * threat \
			- float(_p.get("score_avoid_clumps_at_no_threat", 10.0)) * clump \
			- float(_p.get("score_distance_to_squad", 5.0)) * d_squad \
			- float(_p.get("score_distance_to_base", 5.0)) * d_base \
			+ float(_p.get("score_inertia", 1.4)) * inertia


## 候选集选优（argmax；确定性：平局取更近小队者，再平取候选序首位）。
## candidates = [Vector2, ...]；空候选返回 ctx.fallback（缺省 ZERO）。
func pick_target(candidates: Array, ctx: Dictionary) -> Vector2:
	if candidates.is_empty():
		return ctx.get("fallback", Vector2.ZERO)
	var best: Vector2 = candidates[0]
	var best_score: float = -1.0e18
	var squad_pos: Vector2 = ctx.get("squad_pos", Vector2.ZERO)
	for c in candidates:
		if c is not Vector2:
			continue
		var pos: Vector2 = c
		var s: float = score_target(pos, ctx)
		if s > best_score \
				or (is_equal_approx(s, best_score) and pos.distance_to(squad_pos) < best.distance_to(squad_pos)):
			best_score = s
			best = pos
	return best


# ─────────────────────────────── 内部 ────────────────────────────────

## 半径内敌军力量求和（评分因子取数；enemies = [{pos, weight}]）
func _strength_near(pos: Vector2, enemies: Array, radius: float) -> float:
	var total: float = 0.0
	var r2: float = radius * radius
	for e in enemies:
		if e is Dictionary and e.get("pos", Vector2.INF).distance_squared_to(pos) <= r2:
			total += float(e.get("weight", 0.0))
	return total


func _slots_by_kind(kind: int) -> Array:
	var result: Array = []
	for id in _slots:
		var slot: TaskSlot = _slots[id]
		if slot.kind == kind:
			result.append(slot)
	result.sort_custom(func(a, b) -> bool: return a.id < b.id)
	return result


## 杀槽（解绑匹配 + 移除；"杀掉失效任务"语义）
func _kill_slot(slot_id: String) -> void:
	_slots.erase(slot_id)
	for sid in _squad_slot.keys().duplicate():
		if str(_squad_slot[sid]) == slot_id:
			_squad_slot.erase(sid)


func _rally_timeout(kind: int) -> float:
	return float(_p.get("attack_rally_timeout", 180.0)) if kind == KIND_ATTACK \
			else float(_p.get("defend_rally_timeout", 240.0))


func _target_timeout(kind: int) -> float:
	if kind == KIND_ATTACK:
		return float(_p.get("attack_target_timeout", 30.0))
	return float(_p.get("defend_target_timeout", 120.0))


# ─────────────────────────────── 槽实体 ────────────────────────────────

## 任务槽（纯数据）：CoH 任务参数的最小集——目标/集结点/时间戳/类型。
## 权重与超时不落槽（全档案化统一读取，原则⑦）。
class TaskSlot:
	extends RefCounted
	var id: String = ""
	var kind: int = KIND_ATTACK
	var target: Vector2 = Vector2.ZERO  ## 攻击目标点（评分最优敌位）/ 防守坚守点
	var rally: Vector2 = Vector2.ZERO  ## 集结点（A2 仅承载数据，A5 相位计划消费）
	var created_at: float = 0.0  ## 创建时刻（战斗秒；集结超时基准）
	var last_retarget_at: float = 0.0  ## 上次目标重定位时刻（目标超时基准）
