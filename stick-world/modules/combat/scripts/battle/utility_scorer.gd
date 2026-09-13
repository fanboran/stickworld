class_name UtilityScorer
extends RefCounted
## 效用打分选择器（A4 · 设计文档12号 C7，CoH tactics.ai demand 系统同构机制、原创代码；
## W1 融合 WorldBox 个体 AI 内核的 softmax 轮盘选优与冷却）。
##
## CoH 逆向锚点（docs/审计/英雄连AI逆向_2026-09-11.md §3.5）：
##   每个小队技能/行为由三件套函数构成——
##   - TacticFilter_*（资格过滤：能不能用，情境谓词 AND 组合）
##   - TacticDemand_*（情境打分：命中 +s_demand_increment(50)，否则 -50）
##   - SquadTargetFilter_* / PositionTargetFilter_*（选目标/选落点）
##   demand_variance（0.80）给打分加随机扰动防齐套——多小队同拍同局面不挤同一行为。
##
## 消费对象：组织的 default_behavior 字段（v2 范式——批次 3 落地时是自由透传字典，
## 本类定义其 v2 schema【提案/待定】，无配置/解析为空 = 无候选 = 调用方走既有兜底）：
##   {
##     "candidates": [
##       {
##         "name": "advance",          # 行为名（映射 TacticalOrders.OrderType，见 BEHAVIOR_ORDERS）
##         "filter": { <谓词字典> },   # 全过（AND）才有资格，缺省 = 恒过
##         "demand": { "rules": [ {"when": {<谓词字典>}, "score": 1.0}, ... ] },
##                             # 命中 +demand_increment×score，未命中 -demand_increment×score
##                             # （score 缺省 1.0 = CoH ±50 基准倍率；无 rules = 0 中性候选）
##         "target": { "mode": "enemy_centroid" },  # 目标解析模式，缺省 own_centroid
##         "weight": 2.0,          # W1：静态基础权重（WorldBox w 域 0.05~5）；缺省 0
##         "weight_rules": [       # W1：状态调制（weight_calculate 委托的数据化等价物）
##           {"when": {<谓词字典>}, "weight": 0.3},   # 命中第一条规则取该权重
##           {"when": {...}, "weight": 2.0},          # 全不命中回退 weight（再缺省 0）
##         ],
##         "cooldown": 60.0,       # W1：冷却时长秒（缺省 0 = 不冷却）
##         "cooldown_on_launch_failure": true,  # W1：launch 失败也入冷却（缺省 true）
##       }, ...
##     ]
##   }
##
## 谓词字典（filter 与 demand.when 共用词汇；key = 谓词名，value = 参数）：
##   enemy_within: float        敌存活单位距小队 < N px
##   enemy_present: bool        存在敌方存活单位（false = 无敌）
##   no_enemy: bool             无敌方存活单位（enemy_present 的反义糖）
##   threatened: bool           本方正遭投射物袭击（TeamAi 快照窗口内登记）
##   own_strength_ratio_min/max: float  本方力量/初始基线比值下/上限（基线缺失按 1.0）
##   未知谓词 = fail-closed（该候选判不合格）——配置笔误不致意外激进行为，safe 方向。
##
## 方差扰动（收敛红线·咬合④）：三游戏统一走 personality.demand_variance 单旋钮，
## 本类是 L2 层消费端——score += U(-1,1) × demand_variance × demand_increment。
## 按小队错峰：RNG 种子 = hash(base_seed + squad_id)——同时触发的小队各掷各的，
## 同小队同局面跨拍确定性一致（battle_sim 可复现、单测可锁）。
##
## W1 · WorldBox 个体 AI 内核（逆向笔记 docs/审计/worldbox-reverse/1-个体AI内核.md §二 M2/M6/M7）
## 把 A4 的 argmax 选优升级为 softmax 轮盘赌，并补两个配套机制：
##   - M2 轮盘（默认开）：权重 w 是**软优先级**，高权重也会偶尔输给低权重（杜绝行为僵化）。
##     CoH 分数量纲（±demand_increment）经 softmax_weight_scale 归一到 WorldBox w 域（0.05~5），
##     再除 softmax_temperature（>1 更均匀）。求份额时先减 max(w) 再 exp——数学等价且永不溢出。
##     轮盘在候选循环之后单独掷一次（不边算边掷）。
##   - M7 权重委托：候选静态 weight / weight_rules 分段权重（"饿时主业 2→1→0.3" 即此形态，
##     写成状态分段而非阈值 if 链）；weight_calculate_enabled=false = 忽略权重只用 demand 分。
##   - M6 launch 失败入冷却：候选冷却以"行为名下上次触发世界时刻"记账（读档零成本），
##     冷却中候选等价 filter 不合格；launch 探测失败且 cooldown_on_launch_failure 时同样入冷却，
##     防反复探测昂贵条件。本类保持 RefCounted 纯逻辑，冷却登记由调用方决定（pick_behavior
##     选中不自动记账；便捷入口 pick_behavior_and_commit 才记账）。
##
## 设计原则对账：
##   - 原则④ 决策有节拍：本类无自转，pick_behavior 由调用方（TeamAi 号令下发时刻）驱动；
##   - 原则⑤ 任务槽解耦：本类只消费配置与快照上下文，不点名单位、不持组织引用；
##   - 原则⑦ 数值进档案：demand_increment / demand_variance / softmax_enabled /
##     softmax_weight_scale / softmax_temperature / weight_calculate_enabled /
##     cooldown_enabled 全档案化（代码默认仅兜底）。

## 同模块号令脚本（行为名 -> OrderType 映射消费；combat 域内 preload 惯例）
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

# ─────────────────────── W1 档案键代码默认（真值在 personality.tres，仅兜底）───────────────────────
## softmax_enabled=false 走 argmax 退化路径（与升级前逐位一致）
const DEFAULT_SOFTMAX_ENABLED: bool = true
## CoH 分数量纲 -> WorldBox 权重域归一（1/50 = 1/demand_increment，防 exp 溢出）
const DEFAULT_SOFTMAX_WEIGHT_SCALE: float = 0.02
## 温度：>1 分布更均匀、<1 更集中于高权重
const DEFAULT_SOFTMAX_TEMPERATURE: float = 1.0
## 候选静态/规则权重开关（false = 忽略权重只用 demand 分）
const DEFAULT_WEIGHT_CALCULATE_ENABLED: bool = true
## 冷却判定开关（false = 全跳过，零回归退化闸门）
const DEFAULT_COOLDOWN_ENABLED: bool = true
## 非有限轮盘权重的 fail-closed 哨兵（该候选份额归零，不污染整轮轮盘）
const _WEIGHT_SENTINEL: float = -1.0e18

# ─────────────────────────────── 状态 ────────────────────────────────
## 参数档案（TeamAi._p 同引用；demand_increment / demand_variance 经档案注入，原则⑦）
var _p: Dictionary = {}
## 方差扰动随机源（pick_behavior 每次按 squad_id 重播种，见类头"按小队错峰"）
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## 冷却登记（W1 · M6）：行为名 -> {"at": 上次触发世界时刻, "cd": 冷却时长秒}。
## 存"世界时刻"而非剩余秒——读档/跨拍零成本（WorldBox 同口径）。
var _cooldowns: Dictionary = {}
## 候选冷却参数缓存（行为名 -> 秒）：note_launched/note_launch_failure 只收行为名 +
## 时刻，冷却时长须在解析期按名缓存，回调侧不反查候选。
var _cd_span: Dictionary = {}
## 候选 launch 失败入冷却开关缓存（行为名 -> bool；缺省 true）
var _cd_on_launch_failure: Dictionary = {}


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 装配：注入参数档案引用（TeamAi._p 同实例——档案/覆盖重挂即生效）
func setup(profile: Dictionary) -> void:
	_p = profile


# ─────────────────────────────── 解析（schema v2【提案/待定】）────────────────────────────────

## 组织 default_behavior 字典 -> 规范化候选数组（保留配置序；argmax 退化路径平局取序首位）。
## 非法条目（缺 name / 行为名不可映射 OrderType / 非字典）静默丢弃——透传字典里
## 可能混有 v1 语义的任意键（如 {"stance": "hold"}），无 candidates 键即无候选。
## W1 追加键（weight / weight_rules / cooldown / cooldown_on_launch_failure）类型校验后透传，
## 缺省值在此补齐（weight 缺省 = 键缺席 = 权重 0 基线）。
static func parse_candidates(behavior: Variant) -> Array:
	var result: Array = []
	if behavior is not Dictionary:
		return result
	var raw: Variant = behavior.get("candidates", null)
	if raw is not Array:
		return result
	for entry in raw:
		if entry is not Dictionary:
			continue
		var name := str(entry.get("name", ""))
		if name.is_empty() or order_type_of(name) < 0:
			continue
		var filter_v: Variant = entry.get("filter", {})
		var demand_v: Variant = entry.get("demand", {})
		var target_v: Variant = entry.get("target", {})
		var parsed: Dictionary = {
			"name": name,
			"filter": filter_v if filter_v is Dictionary else {},
			"demand": demand_v if demand_v is Dictionary else {},
			"target": target_v if target_v is Dictionary else {},
		}
		if entry.has("weight"):
			parsed["weight"] = float(entry.get("weight", 0.0))
		if entry.get("weight_rules", null) is Array:
			parsed["weight_rules"] = entry["weight_rules"]
		parsed["cooldown"] = maxf(float(entry.get("cooldown", 0.0)), 0.0)
		parsed["cooldown_on_launch_failure"] = bool(entry.get("cooldown_on_launch_failure", true))
		result.append(parsed)
	return result


## 行为名 -> TacticalOrders.OrderType（不可映射返回 -1；retreat 名义可映射，
## 但自主撤退语义归 A3 概率调制管辖，default_behavior 配置侧不建议使用）
static func order_type_of(behavior_name: String) -> int:
	match behavior_name:
		"advance":
			return ScriptTacticalOrders.OrderType.ADVANCE_ALL
		"sprint":
			return ScriptTacticalOrders.OrderType.SPRINT
		"hold":
			return ScriptTacticalOrders.OrderType.HOLD_POSITION
		"retreat":
			return ScriptTacticalOrders.OrderType.RETREAT
		"take_cover":
			return ScriptTacticalOrders.OrderType.TAKE_COVER
		"rally":
			return ScriptTacticalOrders.OrderType.RALLY
		_:
			return -1


# ─────────────────────────────── 三件套之一：filter（资格过滤）────────────────────────────────

## 资格过滤（TacticFilter_* 同构）：谓词字典全过（AND）才 true；空字典恒过。
## 未知谓词 fail-closed（见类头——safe 方向，笔误配置不会放开激进行为）。
func filter_passes(candidate: Dictionary, ctx: Dictionary) -> bool:
	return predicates_pass(candidate.get("filter", {}), ctx)


## 谓词求值（filter 与 demand.when 共用；公开供测试断言）
func predicates_pass(preds: Variant, ctx: Dictionary) -> bool:
	if preds is not Dictionary:
		return false
	for key in preds:
		var val: Variant = preds[key]
		match key:
			"enemy_within":
				if not _enemy_within(float(val), ctx):
					return false
			"enemy_present":
				if bool(val) != _enemy_present(ctx):
					return false
			"no_enemy":
				if bool(val) != (not _enemy_present(ctx)):
					return false
			"threatened":
				if bool(val) != bool(ctx.get("threatened", false)):
					return false
			"own_strength_ratio_min":
				if _own_ratio(ctx) < float(val):
					return false
			"own_strength_ratio_max":
				if _own_ratio(ctx) > float(val):
					return false
			_:
				return false
	return true


# ─────────────────────────────── 三件套之二：demand（±分）────────────────────────────────

## 需求评分（TacticDemand_* 同构，无方差扰动——扰动在 pick_behavior 统一施加）：
## 每条规则命中 +demand_increment×score、未命中 -demand_increment×score，求和。
## 无 rules / 无 demand = 0（中性候选，凭方差扰动与平局序参与竞争）。
func score_candidate(candidate: Dictionary, ctx: Dictionary) -> float:
	var demand: Variant = candidate.get("demand", {})
	if demand is not Dictionary:
		return 0.0
	var rules: Variant = demand.get("rules", null)
	if rules is not Array:
		return 0.0
	var total: float = 0.0
	for rule in rules:
		if rule is not Dictionary:
			continue
		var hit := predicates_pass(rule.get("when", {}), ctx)
		var weight := absf(float(rule.get("score", 1.0)))
		total += _increment() * weight if hit else -_increment() * weight
	return total


# ─────────────────────────────── 三件套之三：target（目标解析）────────────────────────────────

## 目标解析（SquadTargetFilter_* 同构的 v1 简化：mode 字符串映射，不做火力锥/掩体校验）：
##   enemy_centroid  敌方质心（指向敌群）
##   enemy_nearest   距小队最近敌单位
##   own_centroid    本方质心（聚合防线，缺省/未知模式的兜底语义）
##   garrison_anchor 己方侧锚点
##   squad_pos       原地（小队当前位置）
func resolve_target(candidate: Dictionary, ctx: Dictionary) -> Vector2:
	var target: Variant = candidate.get("target", {})
	var mode := str(target.get("mode", "own_centroid")) if target is Dictionary else "own_centroid"
	match mode:
		"enemy_centroid":
			return ctx.get("enemy_centroid", Vector2.ZERO)
		"enemy_nearest":
			return _nearest_enemy(ctx)
		"garrison_anchor":
			return ctx.get("anchor", Vector2.ZERO)
		"squad_pos":
			return ctx.get("squad_pos", Vector2.ZERO)
		_:
			return ctx.get("own_centroid", Vector2.ZERO)


# ─────────────────────────── 主入口：三件套串联（W1 softmax 轮盘 / argmax 退化）───────────────

## 选行为：parse -> filter 资格过滤（+ W1 冷却跳过）-> demand ±分 + 方差扰动 -> 轮盘/argmax
## -> target 解析。squad_id 参与扰动种子（按小队错峰防齐套）；base_seed 传战斗随机种子
## （TeamAi._rng.seed）——同战斗同小队同局面结果确定（可复现），不同小队各掷各的（去同步）。
## now = 决策时刻（世界秒，W1 冷却判定用；默认 0.0 = 不判冷却，既有调用方零回归）。
## 全员不合格 / 无候选 -> {}（调用方走既有兜底）。
## 返回 softmax 路径 {"name","order_type","target","score"（未扰动原始分）,"perturbed",
## "weight"（归一到 WorldBox 权重域的轮盘指数 w，含温度）,"weight_share"（选中概率份额 0~1）}；
## softmax_enabled=false 时返回升级前 argmax 原样五键结构（逐位一致，见 _pick_argmax）。
func pick_behavior(behavior: Dictionary, ctx: Dictionary, squad_id: String, base_seed: int,
		now: float = 0.0) -> Dictionary:
	var candidates := parse_candidates(behavior)
	if candidates.is_empty():
		return {}
	_rng.seed = hash(str(base_seed) + ":" + squad_id)
	if not _softmax_enabled():
		return _pick_argmax(candidates, ctx, now)
	return _pick_softmax(candidates, ctx, now)


## 全候选评估快照（公开：单测断言份额/采样一致性；调用方做决策解释/调试 HUD 亦可消费）。
## 与 pick_behavior 同播种、同 RNG 消耗序，故同一 (base_seed, squad_id) 下两者的逐候选
## score/perturbed/weight/share 一致。返回数组元素键同 pick_behavior；空 = 无合格候选。
## 注意：本方法恒按 softmax 权重口径计算（不随 softmax_enabled 变），退化路径锁测需要它。
func evaluate_candidates(behavior: Dictionary, ctx: Dictionary, squad_id: String, base_seed: int,
		now: float = 0.0) -> Array:
	var candidates := parse_candidates(behavior)
	if candidates.is_empty():
		return []
	_rng.seed = hash(str(base_seed) + ":" + squad_id)
	return _evaluate_entries(candidates, ctx, now)


## 选中并提交（W1 便捷入口）：选中即 note_launched；target 解析结果非有限 =
## launch 失败 -> note_launch_failure，返回字典额外带 "launch_failed": true。
## 需要"选中"与"真的发出"分离的调用方直接用 pick_behavior + note_* 自行记账。
func pick_behavior_and_commit(behavior: Dictionary, ctx: Dictionary, squad_id: String, base_seed: int,
		now: float) -> Dictionary:
	var pick := pick_behavior(behavior, ctx, squad_id, base_seed, now)
	if pick.is_empty():
		return pick
	var target: Vector2 = pick.get("target", Vector2.ZERO)
	if not target.is_finite():
		note_launch_failure(str(pick.get("name", "")), now)
		pick["launch_failed"] = true
		return pick
	note_launched(str(pick.get("name", "")), now)
	return pick


## softmax 轮盘（WorldBox M2）：归一化份额累加命中。
## 份额在 _evaluate_entries 内一次性算好，此处只掷一次（不在候选循环里边算边掷）。
func _pick_softmax(candidates: Array, ctx: Dictionary, now: float) -> Dictionary:
	var entries := _evaluate_entries(candidates, ctx, now)
	if entries.is_empty():
		return {}
	var roll := _rng.randf()
	var acc: float = 0.0
	for e in entries:
		acc += float(e["weight_share"])
		if roll < acc:
			return e
	return entries[entries.size() - 1]  # Σshare = 1 的浮点尾部兜底


## argmax 退化路径（softmax_enabled=false）：与升级前实现逐位一致（含 RNG 消耗序与五键返回结构），
## 仅追加"冷却中候选等价 filter 不合格"的跳过（cooldown_enabled=false 或候选无冷却时为空操作）。
func _pick_argmax(candidates: Array, ctx: Dictionary, now: float) -> Dictionary:
	var best: Dictionary = {}
	var best_perturbed: float = -1.0e18
	for c in candidates:
		if not filter_passes(c, ctx):
			continue
		if _is_cooldown_blocked(c, now):
			continue
		var raw := score_candidate(c, ctx)
		var perturbed := raw + _rng.randf_range(-1.0, 1.0) * _variance() * _increment()
		if perturbed > best_perturbed:
			best_perturbed = perturbed
			best = {
				"name": c["name"],
				"order_type": order_type_of(str(c["name"])),
				"target": resolve_target(c, ctx),
				"score": raw,
				"perturbed": perturbed,
			}
	return best


## 候选评估与份额计算（filter 资格 + 冷却跳过 -> demand ±分 + 方差扰动 -> 候选权重 -> 数值稳定 softmax）。
## 按候选序消耗 RNG（每合格候选一次扰动掷骰），份额计算不掷骰——RNG 序与 argmax 路径前段一致。
func _evaluate_entries(candidates: Array, ctx: Dictionary, now: float) -> Array:
	var entries: Array = []
	var max_w: float = -1.0e308
	for c in candidates:
		_cache_cooldown_params(c)
		if not filter_passes(c, ctx):
			continue
		if _is_cooldown_blocked(c, now):
			continue
		var raw := score_candidate(c, ctx)
		var perturbed := raw + _rng.randf_range(-1.0, 1.0) * _variance() * _increment()
		var w := _roulette_weight(perturbed, _candidate_weight(c, ctx))
		if not is_finite(w):
			w = _WEIGHT_SENTINEL  # fail-closed：非有限权重份额归零，不污染整轮
		entries.append({
			"name": c["name"],
			"order_type": order_type_of(str(c["name"])),
			"target": resolve_target(c, ctx),
			"score": raw,
			"perturbed": perturbed,
			"weight": w,
			"weight_share": 0.0,
		})
		max_w = maxf(max_w, w)
	if entries.is_empty():
		return entries
	# 数值稳定 softmax：exp(w - max) ∈ (0,1]，最大项恒 1 —— demand_increment 再大也不溢出
	var chances: Array = []
	var total: float = 0.0
	for e in entries:
		var ch := exp(float(e["weight"]) - max_w)
		if not is_finite(ch):
			ch = 0.0
		chances.append(ch)
		total += ch
	if total <= 0.0:
		# 全零退化（理论不可达：max 项 = 1）：等权兜底，绝不产生 NaN
		total = float(entries.size())
		for i in entries.size():
			chances[i] = 1.0
	for i in entries.size():
		entries[i]["weight_share"] = float(chances[i]) / total
	return entries


## 轮盘指数权重（WorldBox w 域，M7）：demand 分（±increment 域）×softmax_weight_scale
## 归一到权重域，与候选静态权重（本就在 w 域）相加，再除温度（>1 更均匀）。
## 等价于"final = perturbed + base_weight / scale，再 w = final × scale / temperature"。
func _roulette_weight(perturbed: float, base_weight: float) -> float:
	var w := perturbed * _weight_scale() + base_weight
	var t := _temperature()
	if t > 0.0:
		w /= t
	return w


## 候选权重（W1 · M7）：weight_rules 命中第一条取该权重，全不命中回退静态 weight，
## 再缺省 0.0（0 = 完全由 demand ±分决定，即①纯 softmax 基线）。
## weight_calculate_enabled=false = 忽略权重只用 demand 分。
func _candidate_weight(candidate: Dictionary, ctx: Dictionary) -> float:
	if not _weight_calculate_enabled():
		return 0.0
	var rules: Variant = candidate.get("weight_rules", null)
	if rules is Array:
		for rule in rules:
			if rule is not Dictionary:
				continue
			if predicates_pass(rule.get("when", {}), ctx):
				return float(rule.get("weight", 0.0))
	return float(candidate.get("weight", 0.0))


# ─────────────────────────── W1 · M6 冷却（行为名记账）─────────────────────────

## 冷却中？（cooldown_enabled=false 恒 false；无登记/冷却时长 ≤0 恒 false）
func is_on_cooldown(behavior_name: String, now: float) -> bool:
	if not _cooldown_enabled():
		return false
	if not _cooldowns.has(behavior_name):
		return false
	var rec: Dictionary = _cooldowns[behavior_name]
	var cd := float(rec.get("cd", 0.0))
	if cd <= 0.0:
		return false
	return now - float(rec.get("at", 0.0)) < cd


## 登记一次成功触发（调用方按自己语义决定是否记账——pick_behavior 不自动记账）
func note_launched(behavior_name: String, now: float) -> void:
	_note_cooldown(behavior_name, now)


## 登记一次 launch 失败（仅当候选 cooldown_on_launch_failure 为真；缺省真）——
## 防反复探测昂贵条件（WorldBox DecisionAsset.cs:8,30 + UBDS.cs:131-138）
func note_launch_failure(behavior_name: String, now: float) -> void:
	if not bool(_cd_on_launch_failure.get(behavior_name, true)):
		return
	_note_cooldown(behavior_name, now)


func _note_cooldown(behavior_name: String, now: float) -> void:
	var cd := float(_cd_span.get(behavior_name, 0.0))
	if cd <= 0.0:
		return  # 无冷却配置 = 不记账（不产生"永不冷却"之外的第二语义）
	_cooldowns[behavior_name] = {"at": now, "cd": cd}


## 冷却中候选等价 filter 不合格（cooldown_enabled=false 跳过全判定）
func _is_cooldown_blocked(candidate: Dictionary, now: float) -> bool:
	return is_on_cooldown(str(candidate.get("name", "")), now)


## 解析期按名缓存冷却参数（note_* 回调只收行为名 + 时刻，不反查候选）
func _cache_cooldown_params(candidate: Dictionary) -> void:
	var name := str(candidate.get("name", ""))
	_cd_span[name] = maxf(float(candidate.get("cooldown", 0.0)), 0.0)
	_cd_on_launch_failure[name] = bool(candidate.get("cooldown_on_launch_failure", true))


# ─────────────────────────────── 谓词取数（ctx 消费端）────────────────────────────────

## 敌存活单位距小队 < dist（enemies = [{pos, weight}] 值拷贝快照，TeamAi 口径）
func _enemy_within(dist: float, ctx: Dictionary) -> bool:
	var squad_pos: Vector2 = ctx.get("squad_pos", Vector2.ZERO)
	for e in ctx.get("enemies", []):
		if e is Dictionary and e.get("pos", Vector2.INF).distance_to(squad_pos) < dist:
			return true
	return false


func _enemy_present(ctx: Dictionary) -> bool:
	return not (ctx.get("enemies", []) as Array).is_empty()


## 本方力量/初始基线（基线缺失/为零按 1.0——无基准不判比例，与 threat_at_base 同哲学）
func _own_ratio(ctx: Dictionary) -> float:
	var initial := float(ctx.get("initial_own_strength", 0.0))
	if initial <= 0.0:
		return 1.0
	return float(ctx.get("own_strength", 0.0)) / initial


## 距小队最近敌位（无敌 -> 敌方质心兜底）
func _nearest_enemy(ctx: Dictionary) -> Vector2:
	var squad_pos: Vector2 = ctx.get("squad_pos", Vector2.ZERO)
	var best := Vector2.INF
	var best_d := 1.0e18
	for e in ctx.get("enemies", []):
		if e is not Dictionary:
			continue
		var pos: Vector2 = e.get("pos", Vector2.INF)
		if not pos.is_finite():
			continue
		var d := pos.distance_squared_to(squad_pos)
		if d < best_d:
			best_d = d
			best = pos
	if best.is_finite():
		return best
	return ctx.get("enemy_centroid", Vector2.ZERO)


# ─────────────────────────────── 档案参数（代码默认仅兜底，真值在 personality.tres global 行）─────

## ±分基准增量（CoH s_demand_increment = 50 真值）
func _increment() -> float:
	return float(_p.get("demand_increment", 50.0))


## 方差扰动单旋钮（收敛红线·咬合④；负值钳 0）
func _variance() -> float:
	return maxf(float(_p.get("demand_variance", 0.8)), 0.0)


## W1 选择规则开关（默认开；false = argmax 退化路径）
func _softmax_enabled() -> bool:
	return bool(_p.get("softmax_enabled", DEFAULT_SOFTMAX_ENABLED))


## W1 分数量纲归一尺度（≤0/非有限回退默认——防除零与 INF 权重）
func _weight_scale() -> float:
	var s := float(_p.get("softmax_weight_scale", DEFAULT_SOFTMAX_WEIGHT_SCALE))
	return s if (is_finite(s) and s > 0.0) else DEFAULT_SOFTMAX_WEIGHT_SCALE


## W1 温度（≤0/非有限回退默认——防除零与反向温度）
func _temperature() -> float:
	var t := float(_p.get("softmax_temperature", DEFAULT_SOFTMAX_TEMPERATURE))
	return t if (is_finite(t) and t > 0.0) else DEFAULT_SOFTMAX_TEMPERATURE


## W1 候选权重开关（默认开；false = 忽略 weight/weight_rules）
func _weight_calculate_enabled() -> bool:
	return bool(_p.get("weight_calculate_enabled", DEFAULT_WEIGHT_CALCULATE_ENABLED))


## W1 冷却判定开关（默认开；false = 全跳过冷却判定）
func _cooldown_enabled() -> bool:
	return bool(_p.get("cooldown_enabled", DEFAULT_COOLDOWN_ENABLED))
