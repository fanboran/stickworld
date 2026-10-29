class_name OrgPrereqs
extends RefCounted
## 职能明面前提校验（01-组织系统 §2.5）——显式标注的硬条件，一般至多一两条。
##
## 明面/隐形两层里的「明面」层：表里定义了的职能，加职能槽/塞机构时逐条校验，
## 不满足即拒绝；没定义的职能无明面前提（门槛是特例不是默认）。
## 隐形前提（对应建筑、人手占槽、支撑链）不在此处——它们以运转状态表现
## （缺建筑=空转、空槽=不运转），消费见槽位运转判定（training_post.gd）。
##
## 条件行（config/organizations/function_prereqs.tres，BalanceResource 行数组）：
##   {id, function_name, conditions: [{kind, ...参数}]}
## 条件种类：
##   {"kind": "skill", "skill_id": "..."}            在编有人会（SkillAPI.knows）
##   {"kind": "attribute", "attr": "cmd", "min": 3}  在编有人该属性 ≥ min（经属性 provider）
## 技能条件即 organization 消费 skill 模块的入口（会/不会二元，04 §二）。

const PREREQS_PATH := "res://config/organizations/function_prereqs.tres"

## static var 生命周期（原型转正门槛③）：进程级注入面，非状态单例——装配层
## （system_setup 组织系统步）每局注入实体侧实现，单测直注假 provider；
## 表缓存 _rows 只读不随档走，无需跨局重置。
static var _personnel_provider: Callable  # (org_id: String) -> Array[String]
static var _attribute_provider: Callable  # (holder_id: String, attr_key: String) -> float

static var _rows_cache: Array = []
static var _loaded: bool = false


## 装配/单测注入（在编人员查询 + 属性查询）。
static func set_providers(personnel_provider: Callable, attribute_provider: Callable) -> void:
	_personnel_provider = personnel_provider
	_attribute_provider = attribute_provider


## 某职能的明面前提条件数组（无行 = 无明面前提）。
static func get_prereqs(function_name: String) -> Array:
	for row in _ensure_rows():
		if String(row.get("function_name", "")) == function_name:
			return row.get("conditions", [])
	return []


## 校验：org_id 的在编人员是否满足职能的明面前提。
## 返回 {ok, results: [{kind, label, passed}], error?}——results 供面板逐条 ✓/✗ 展示。
static func check(org_id: String, function_name: String) -> Dictionary:
	var conditions: Array = get_prereqs(function_name)
	if conditions.is_empty():
		return {"ok": true, "results": []}
	var personnel: Array = _personnel_of(org_id)
	var results: Array = []
	var failed: Array = []
	for cond in conditions:
		var kind := String(cond.get("kind", ""))
		var label := ""
		var passed := false
		match kind:
			"skill":
				var sid := String(cond.get("skill_id", ""))
				passed = _any_holds_skill(personnel, sid)
				label = "在编有人会 %s" % sid
			"attribute":
				var attr := String(cond.get("attr", ""))
				var minimum := float(cond.get("min", 0.0))
				passed = _any_attr_at_least(personnel, attr, minimum)
				label = "在编有人 %s ≥ %d" % [attr, int(minimum)]
			_:
				label = "未知前提类型: %s" % kind
		results.append({"kind": kind, "label": label, "passed": passed})
		if not passed:
			failed.append(label)
	if not failed.is_empty():
		return {"ok": false, "results": results,
				"error": "明面前提未满足: %s（%s）" % [function_name, "；".join(failed)]}
	return {"ok": true, "results": results}


# ─────────────────────────── 内部 ────────────────────────────

static func _ensure_rows() -> Array:
	if _loaded:
		return _rows_cache
	_loaded = true
	var res: Resource = load(PREREQS_PATH)
	if res == null:
		return _rows_cache
	_rows_cache = BalanceResource.sanitized_rows(res)
	return _rows_cache


static func _personnel_of(org_id: String) -> Array:
	if not _personnel_provider.is_valid():
		return []
	var personnel: Variant = _personnel_provider.call(org_id)
	return personnel if personnel is Array else []


static func _any_holds_skill(personnel: Array, skill_id: String) -> bool:
	for holder_id in personnel:
		if SkillAPI.knows(String(holder_id), skill_id):
			return true
	return false


static func _any_attr_at_least(personnel: Array, attr: String, minimum: float) -> bool:
	if not _attribute_provider.is_valid():
		return false
	for holder_id in personnel:
		var value: Variant = _attribute_provider.call(String(holder_id), attr)
		if value is float or value is int:
			if float(value) >= minimum:
				return true
	return false
