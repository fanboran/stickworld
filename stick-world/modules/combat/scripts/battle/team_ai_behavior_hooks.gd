extends RefCounted
## default_behavior v2 效用打分接入 -- team_ai.gd 拆分件（W2 胖文件拆分，行为直搬；
## A4 · C7，非 dump 直译）。
##
## 职责：UtilityScorer（default_behavior v2 消费端）的接入面——组织 API duck
## 探测与只读取数、小队行为上下文快照、扰动种子、无显式号令小队的接管门禁
## （apply_default_behavior_plans）。CoH tactics.ai demand 系统同构（评分实现归
## UtilityScorer，本类只做组织配置取数 / 小队上下文快照 / 接入点门禁）。
##
## 拆分纪律：本类持宿主回引（_host）；组织 API 引用（_org_api，测试直读面）、
## 效用打分器（_utility_scorer）、选择观测面（_default_behavior_choices）、姿态
## 与快照状态全在宿主——set_org_api / get_default_behavior_choices 公共出口留
## 宿主壳。禁改组织存储格式——组织取数纯消费（模块契约：combat 不直引
## organization，经 duck api）。
##
## 消费方：team_ai_order_emitter（issue_stance_orders 内对无令小队接管）。依赖
## 同伴：team_ai_squad_query（组织根查询、小队质心）。装配序 query 先于本类。

## 同模块号令脚本（OrderType 枚举消费；combat 域内 preload 惯例）
const ScriptTacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")
## 同模块任务槽板（KIND_ATTACK 判定消费）
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")

## 宿主 TeamAi 回引（组织 API 引用/打分器/观测面/姿态/快照全在宿主）
var _host: Variant = null
## 同伴：小队/编制视图取数（组织根查询、小队存活成员质心）
var _squads: Variant = null


## 装配：注入宿主回引与同伴（TeamAi.setup 内调用；query 须先装配）
func setup(host: Variant, squads: Variant) -> void:
	_host = host
	_squads = squads


## 组织 API 同模块 duck 探测：号令系统（TacticalOrders）装配时已持 _org_api 引用，
## 不与组织模块直接碰面，经 Object.get 同模块反射读取（combat 域内私有桥；
## TacticalOrders 未来开放组织代理方法时迁移）。探测失败保持现状（散兵/测试
## 环境 = 无组织消费）。结果写回宿主 _org_api（调用方 = 宿主 setup/set_order_refs）。
func resolve_org_api() -> Node:
	if _host._org_api != null and is_instance_valid(_host._org_api):
		return _host._org_api
	if _host._orders != null and is_instance_valid(_host._orders):
		var api: Variant = _host._orders.get("_org_api")
		if api is Node and is_instance_valid(api):
			return api
	return null


## 组织 default_behavior 只读查询（org API get_organization 快照；失败/缺字段 = {}）
## 禁改组织存储格式——本方法纯消费（模块契约：combat 不直引 organization，经 duck api）
func org_default_behavior(org_id: String) -> Dictionary:
	if _host._org_api == null or not is_instance_valid(_host._org_api) \
			or not _host._org_api.has_method("get_organization"):
		return {}
	var info: Dictionary = _host._org_api.get_organization(org_id)
	if not info.get("ok", false):
		return {}
	var data: Dictionary = info.get("data", {})
	var behavior: Variant = data.get("default_behavior", {})
	return behavior if behavior is Dictionary else {}


## 小队行为上下文（UtilityScorer 消费口径；敌人取决策周期值拷贝快照，防 freed 悬挂）
func squad_behavior_ctx(squad_id: String) -> Dictionary:
	return {
		"squad_pos": _squads.squad_centroid(squad_id),
		"enemies": _host._enemy_units_snapshot,
		"own_centroid": _host._own_centroid,
		"enemy_centroid": _host._enemy_centroid,
		"anchor": _host.get_garrison_anchor(),
		"threatened": _host._own_threatened,
		"own_strength": _host._own_strength,
		"initial_own_strength": _host._initial_own_strength,
		"now": _host._now(),
	}


## default_behavior 扰动种子（按小队错峰的 base；同 setup 显式 random_seed，确定性可锁）
func behavior_seed() -> int:
	return int(_host._rng.seed)


## default_behavior v2 接入点（追加钩子，不改既有号令语义）：
## 只接管「无显式号令」的小队——攻/防姿态下未绑攻击槽、落防守兜底（ADVANCE_ALL
## 本方质心）的原子单元小队；攻击槽绑定小队有任务槽号令不接管；GARRISON（生存模式
## RALLY）与 ROUT（战役撤离）不经本钩子（ROUT 路径在 stance_update 提前返回）。
## 开关关（default_behavior_v2_enabled 默认关）/ 组织无配置 / 打分无候选 → 原样返回
## （零回归）。组织根经 squad_query 查询（同既有号令分流口径），root 缺失 = 散兵不消费。
func apply_default_behavior_plans(plan_of: Dictionary, mapping: Dictionary) -> Dictionary:
	if _host._utility_scorer == null or not bool(_host._p.get("default_behavior_v2_enabled", false)):
		return plan_of
	if _host._stance != _host.STANCE_ATTACK and _host._stance != _host.STANCE_DEFEND:
		return plan_of
	for squad_id_v in plan_of.keys():
		var squad_id := str(squad_id_v)
		var plan: Dictionary = plan_of[squad_id]
		# 只接管防守兜底小队（ADVANCE_ALL 语义）；RALLY 等其他号令一律不碰
		if int(plan.get("order_type", -1)) != ScriptTacticalOrders.OrderType.ADVANCE_ALL:
			continue
		# 攻击槽绑定 = 显式任务号令，不接管
		var slot_id := str(mapping.get(squad_id, ""))
		if not slot_id.is_empty() and _host._task_board != null:
			var slot: Variant = _host._task_board.get_slot(slot_id)
			if slot != null and int(slot.kind) == ScriptTaskBoard.KIND_ATTACK:
				continue
		var root := _squads.org_root_of(squad_id)
		if root.is_empty():
			continue
		var behavior := org_default_behavior(root)
		if behavior.is_empty():
			continue
		# W1：走提交版入口——选中即记冷却、target 解析非有限（发射失败）也记冷却，
		# 防对昂贵条件反复探测；候选无 cooldown 声明时记账为空操作（零行为变化）。
		var choice := _host._utility_scorer.pick_behavior_and_commit(behavior, squad_behavior_ctx(squad_id),
				squad_id, behavior_seed(), _host._now())
		if choice.is_empty():
			continue
		plan_of[squad_id] = {
			"order_type": int(choice["order_type"]),
			"target": choice["target"],
		}
		_host._default_behavior_choices[squad_id] = str(choice.get("name", ""))
	return plan_of
