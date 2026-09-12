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

## 目标评分明细的**求和项**键名（total = 这四项之和，顺序即求和顺序）。
## 明细里其余键（distance_squad/distance_base/*_norm）是解释用分解，不参与求和——
## 消费端（调试面板/测试）须用本常量逐项求和，勿"遍历字典全部数值键"，防止距离双计。
const SCORE_FACTOR_KEYS := ["threat", "avoid_clumps", "distance", "inertia"]

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
## 最近一次目标评分留痕快照（W6 决策依据留痕；pick_target 写入，只读查询见
## get_last_score_trace。始终是键齐的 Dictionary，形态见 _make_trace）
var _last_score_trace: Dictionary = {}


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
	_last_score_trace = _make_empty_trace()


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

## 单候选评分·明细版（W6 决策依据留痕：WorldBox KingdomOpinion.results 同构——把评分
## 拆成具名因子逐项和，UI/调试面板据此回答"为什么打这个点"，而不只给一个坐标）。
##
## 本函数是四因子算法的**唯一实现**：score_target 与 pick_target 都消费它的 total，
## 不存在"留痕一套、评分另一套"的双写漂移（留痕是同一计算顺带导出，不重算）。
##
## 返回键义（值 = 加权后的实际贡献，可直接相加）：
##   threat        +w_threat × threat_norm        威胁：周边敌力/本方力归一，∈[0, w]
##   avoid_clumps  −w_clump × clump_norm          无威胁时敌群聚集惩罚，∈[−w, 0]
##   distance      distance_squad + distance_base 距小队/距基地**双计**合成，∈[−2w, 0]
##   inertia       +w_inertia × (1|0)             与上次目标一致的防振荡奖励，∈[0, w]
##   total         threat + avoid_clumps + distance + inertia
## 诊断键（**不参与求和**，勿并入 total——距离双计的两个来源在此可分别读账）：
##   distance_squad / distance_base  两段距离各自的加权贡献
##   threat_norm / clump_norm / d_squad_norm / d_base_norm  归一原值（0~1）
##   inertia_hit                     惯性是否命中（bool）
## ctx 同 score_target：{squad_pos, base_pos, enemies: [{pos, weight}], own_strength, last_target}
func score_target_detail(pos: Vector2, ctx: Dictionary) -> Dictionary:
	var enemies: Array = ctx.get("enemies", [])
	var own_ref: float = maxf(float(ctx.get("own_strength", 0.0)), float(_p.get("ratio_empty_enemy_sentinel", 10.0)))
	# 因子一 threat：目标周边敌军力量密度（归一 0~1）
	var threat_norm: float = clampf(_strength_near(pos, enemies, float(_p.get("score_threat_radius", 260.0))) / own_ref, 0.0, 1.0)
	# 因子二 avoid_clumps：仅无威胁时惩罚聚集（有仗打不避人堆）
	var clump_norm: float = 0.0
	if threat_norm <= 0.0:
		clump_norm = clampf(_strength_near(pos, enemies, float(_p.get("score_clump_radius", 300.0))) / own_ref, 0.0, 1.0)
	# 因子三 distance：距小队/基地归一惩罚（双计：两来源各记一份，明细分开可读）
	var norm: float = maxf(float(_p.get("score_distance_norm", 1200.0)), 1.0)
	var squad_pos: Vector2 = ctx.get("squad_pos", pos)
	var base_pos: Vector2 = ctx.get("base_pos", pos)
	var d_squad_norm: float = clampf(pos.distance_to(squad_pos) / norm, 0.0, 1.0)
	var d_base_norm: float = clampf(pos.distance_to(base_pos) / norm, 0.0, 1.0)
	# 因子四 inertia：与上次目标一致（容差内）满分奖励，防振荡
	var last_target: Vector2 = ctx.get("last_target", Vector2.INF)
	var inertia_hit: bool = pos.distance_to(last_target) <= float(_p.get("score_inertia_tolerance", 120.0))
	var inertia_norm: float = 1.0 if inertia_hit else 0.0
	# 加权（求和顺序固定：threat + avoid_clumps + distance + inertia）
	var threat_term: float = float(_p.get("score_threat", 5.0)) * threat_norm
	var clump_term: float = -float(_p.get("score_avoid_clumps_at_no_threat", 10.0)) * clump_norm
	var dist_squad_term: float = -float(_p.get("score_distance_to_squad", 5.0)) * d_squad_norm
	var dist_base_term: float = -float(_p.get("score_distance_to_base", 5.0)) * d_base_norm
	var distance_term: float = dist_squad_term + dist_base_term
	var inertia_term: float = float(_p.get("score_inertia", 1.4)) * inertia_norm
	return {
		"threat": threat_term,
		"avoid_clumps": clump_term,
		"distance": distance_term,
		"inertia": inertia_term,
		"total": threat_term + clump_term + distance_term + inertia_term,
		"distance_squad": dist_squad_term,
		"distance_base": dist_base_term,
		"threat_norm": threat_norm,
		"clump_norm": clump_norm,
		"d_squad_norm": d_squad_norm,
		"d_base_norm": d_base_norm,
		"inertia_hit": inertia_hit,
	}


## 单候选评分（= 明细 total 的薄封装；算法实体见 score_target_detail，单一真相源）：
##   score = threat × w_threat − clump × w_clump − d_squad × w_ds − d_base × w_db + inertia × w_in
##   threat   候选点周边敌军力量 / 本方力量（钳 0~1）：攻击高威胁目标优先；
##   clump    无威胁时（threat=0）候选点落在敌群内的聚集惩罚（CoH
##            avoid_clumps_at_no_threat：没仗打就别扎进人堆）；
##   distance 距小队（本方质心）/距基地（本方锚点）归一惩罚：近者优先；
##   inertia  与上次目标一致（容差内）给满分奖励：重评分时防目标振荡。
func score_target(pos: Vector2, ctx: Dictionary) -> float:
	return float(score_target_detail(pos, ctx)["total"])


## 候选集选优（argmax；确定性：平局取更近小队者，再平取候选序首位）。
## candidates = [Vector2, ...]；空候选返回 ctx.fallback（缺省 ZERO）。
## W6：每次调用都写最近一次评分留痕（_last_score_trace），供调试面板逐项解释
## "为什么打这个点"。评分/比较/兜底逻辑与改造前逐位相同——留痕是旁路记录，
## 不参与任何比较或排序。非 Vector2 项被过滤、不参与评分，因此也不进 trace.candidates。
func pick_target(candidates: Array, ctx: Dictionary) -> Vector2:
	var squad_pos: Vector2 = ctx.get("squad_pos", Vector2.ZERO)
	if candidates.is_empty():
		var fallback: Vector2 = ctx.get("fallback", Vector2.ZERO)
		_last_score_trace = _make_trace(fallback, [], -1, true)
		return fallback
	var best: Vector2 = candidates[0]
	var best_score: float = -1.0e18
	var best_trace_index: int = -1
	var scored: Array = []
	for c in candidates:
		if c is not Vector2:
			continue
		var pos: Vector2 = c
		var detail: Dictionary = score_target_detail(pos, ctx)
		var s: float = float(detail["total"])
		scored.append({"target": pos, "detail": detail, "chosen": false})
		if s > best_score \
				or (is_equal_approx(s, best_score) and pos.distance_to(squad_pos) < best.distance_to(squad_pos)):
			best_score = s
			best = pos
			best_trace_index = scored.size() - 1
	if best_trace_index >= 0:
		scored[best_trace_index]["chosen"] = true
	# best_trace_index < 0 = 候选里无可用 Vector2：同改造前口径原样返回首项（兜底路径）
	_last_score_trace = _make_trace(best, scored, best_trace_index, best_trace_index < 0)
	return best


# ─────────────────────────────── W6：决策依据留痕（只读消费口）────────────────────────────────

## 最近一次目标评分留痕（只读查询；深拷贝返回，消费端改写不污染内核）。
## 键恒在，无候选/未评分时是键齐空结构，**绝不返回 null**：
##   chosen        Vector2   pick_target 实际返回的目标（无候选 = ctx.fallback；reset 后 = null）
##   chosen_index  int       被选中者在 candidates 中的下标（-1 = 未评分/无有效候选）
##   candidates    Array     [{target: Vector2, detail: 明细字典, chosen: bool}, ...]
##                           （与传入候选同序；非 Vector2 项不参与评分故不入列）
##   fallback      bool      是否走了无候选兜底路径
##   at            float     记录时刻（秒）。TaskBoard 无自有时钟（纯被驱动的无自转内核），
##                           故取进程单调钟；仅作"最近一次"顺序/展示参照，不参与评分。
func get_last_score_trace() -> Dictionary:
	return _last_score_trace.duplicate(true)


## 明细 → 调试面板文案（纯函数：只读入参、不读实例状态、无副作用，可脱离战斗单测）。
## 形如：目标评分: 威胁 +5.0 · 聚集 +0.0 · 距离 -4.2 · 惯性 +1.4 = +0.2
## 四项即 SCORE_FACTOR_KEYS 的加权贡献（相加 = total），与明细同序陈列，
## 让"为什么打这个点"可逐项读账（WorldBox KingdomOpinion tooltip 同构）。
## 空明细 / 缺 total → ""（调用方据此跳过该行）。
func format_score_detail(detail: Dictionary) -> String:
	if detail.is_empty() or not detail.has("total"):
		return ""
	var labels := {
		"threat": "威胁",
		"avoid_clumps": "聚集",
		"distance": "距离",
		"inertia": "惯性",
	}
	var parts: Array[String] = []
	for key in SCORE_FACTOR_KEYS:
		parts.append("%s %s" % [labels[key], _format_signed(float(detail.get(key, 0.0)))])
	return "目标评分: %s = %s" % [" · ".join(parts), _format_signed(float(detail["total"]))]


# ─────────────────────────────── 内部 ────────────────────────────────

## 留痕快照构造（键恒在；candidates 为参与评分的候选明细，序同传入序）。
func _make_trace(chosen: Variant, candidates: Array, chosen_index: int, fallback: bool) -> Dictionary:
	return {
		"chosen": chosen,
		"chosen_index": chosen_index,
		"candidates": candidates,
		"fallback": fallback,
		"at": float(Time.get_ticks_msec()) / 1000.0,
	}


## 键齐空留痕（未评分/重置态；chosen = null 表示"尚无目标"）。
func _make_empty_trace() -> Dictionary:
	return {
		"chosen": null,
		"chosen_index": -1,
		"candidates": [],
		"fallback": false,
		"at": 0.0,
	}


## 带符号一位小数（仅展示用；负零归一为 +0.0，避免面板出现 −0.0 观感）
func _format_signed(v: float) -> String:
	var r: float = roundf(v * 10.0) / 10.0
	if is_zero_approx(r):
		r = 0.0
	return "%+.1f" % r


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
