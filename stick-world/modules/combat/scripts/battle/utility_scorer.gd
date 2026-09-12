class_name UtilityScorer
extends RefCounted
## 效用打分选择器（A4 · 设计文档12号 C7，CoH tactics.ai demand 系统同构机制、原创代码）。
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
## 设计原则对账：
##   - 原则④ 决策有节拍：本类无自转，pick_behavior 由调用方（TeamAi 号令下发时刻）驱动；
##   - 原则⑤ 任务槽解耦：本类只消费配置与快照上下文，不点名单位、不持组织引用；
##   - 原则⑦ 数值进档案：demand_increment / demand_variance 全档案化（代码默认仅兜底）。

## 同模块号令脚本（行为名 -> OrderType 映射消费；combat 域内 preload 惯例）
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

# ─────────────────────────────── 状态 ────────────────────────────────
## 参数档案（TeamAi._p 同引用；demand_increment / demand_variance 经档案注入，原则⑦）
var _p: Dictionary = {}
## 方差扰动随机源（pick_behavior 每次按 squad_id 重播种，见类头"按小队错峰"）
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 装配：注入参数档案引用（TeamAi._p 同实例——档案/覆盖重挂即生效）
func setup(profile: Dictionary) -> void:
	_p = profile


# ─────────────────────────────── 解析（schema v2【提案/待定】）────────────────────────────────

## 组织 default_behavior 字典 -> 规范化候选数组（保留配置序，argmax 平局取序首位）。
## 非法条目（缺 name / 行为名不可映射 OrderType / 非字典）静默丢弃——透传字典里
## 可能混有 v1 语义的任意键（如 {"stance": "hold"}），无 candidates 键即无候选。
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
		result.append({
			"name": name,
			"filter": filter_v if filter_v is Dictionary else {},
			"demand": demand_v if demand_v is Dictionary else {},
			"target": target_v if target_v is Dictionary else {},
		})
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


# ─────────────────────────────── 主入口：三件套串联 argmax ────────────────────────────────

## 选行为：parse -> filter 资格过滤 -> demand ±分 + 方差扰动 -> argmax -> target 解析。
## squad_id 参与扰动种子（按小队错峰防齐套）；base_seed 传战斗随机种子（TeamAi._rng.seed）
## ——同战斗同小队同局面结果确定（可复现），不同小队各掷各的（去同步）。
## 全员不合格 / 无候选 -> {}（调用方走既有兜底）；平局取配置序首位（确定性）。
## 返回 {"name", "order_type", "target", "score"（未扰动原始分）, "perturbed"}。
func pick_behavior(behavior: Dictionary, ctx: Dictionary, squad_id: String, base_seed: int) -> Dictionary:
	var candidates := parse_candidates(behavior)
	if candidates.is_empty():
		return {}
	_rng.seed = hash(str(base_seed) + ":" + squad_id)
	var best: Dictionary = {}
	var best_perturbed: float = -1.0e18
	for c in candidates:
		if not filter_passes(c, ctx):
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
