class_name BlueprintManager
extends RefCounted
## 蓝图谱系骨架管理器 —— 定名/退役/重新启用 CRUD + DAG 校验（程序先行骨架）。
##
## 结构面（GDD §6.8 / 11-构筑谱系 §二与边缘情况）：定名（封存自建物为蓝图）、
## 退役（不删除，归荣誉档案）、重新启用；槽位满时定名必须先退役；树形 DAG
## 不变量校验；谱系存档绑定、不跨档继承。
## 机制面（待 11 §三调优杆定稿，本类不实现，占位方法走未实现守卫）：
## 派生/融合（变异区间/熟练度清零）、熟练度成长、纹章生成算法
## （hash 契约注释见 BlueprintNode 类头）。

signal blueprint_created(blueprint_id: String)
signal blueprint_retired(blueprint_id: String)

## 蓝图槽位上限（占位 10——11 §三调优杆 [PLACEHOLDER]，定稿后改表驱动）
const SLOT_LIMIT_PLACEHOLDER := 10

var _nodes: Dictionary = {}  # {blueprint_id: BlueprintNode}（含退役——荣誉档案不删除）
var _next_seq := 1


# ─────────────────────────── 定名 / 退役 / 重启 ────────────────────────────

## 定名一枚蓝图（占位入口：正式入口 = 从组织预设/建筑型号/章程"封存"，随各域实装）。
func create_blueprint(display_name: String, kind: BlueprintNode.Kind,
		parents: Array = []) -> Dictionary:
	if display_name.is_empty():
		return {"ok": false, "error": "定名不能为空"}
	if active_count() >= SLOT_LIMIT_PLACEHOLDER:
		return {"ok": false, "error": "蓝图槽位已满——须先退役一枚旧蓝图（11 §边缘情况）"}
	var parent_ids: Array[String] = []
	for v in parents:
		parent_ids.append(String(v))
	for pid in parent_ids:
		if not _nodes.has(pid):
			return {"ok": false, "error": "母本蓝图不存在: %s" % pid}
	var node := BlueprintNode.new()
	node.id = "bp_%03d" % _next_seq
	_next_seq += 1
	node.display_name = display_name
	node.kind = kind
	node.parents = parent_ids
	node.generation = _max_generation(parent_ids) + 1
	_nodes[node.id] = node
	# 加边后 DAG 不变量兜底（正常入口造不出环，防表结构外写入成环）
	if not is_acyclic():
		_nodes.erase(node.id)
		_next_seq -= 1
		return {"ok": false, "error": "加入后破坏 DAG 不变量"}
	blueprint_created.emit(node.id)
	return {"ok": true, "blueprint_id": node.id}


## 退役：不删除，归档进荣誉档案（11 §二）——母本退役子代保留，源流线指向档案。
func retire_blueprint(blueprint_id: String) -> Dictionary:
	var node: BlueprintNode = _nodes.get(blueprint_id, null)
	if node == null:
		return {"ok": false, "error": "蓝图不存在: %s" % blueprint_id}
	if node.state == BlueprintNode.State.RETIRED:
		return {"ok": false, "error": "蓝图已在荣誉档案: %s" % blueprint_id}
	node.state = BlueprintNode.State.RETIRED
	blueprint_retired.emit(blueprint_id)
	return {"ok": true}


## 重新启用（11 §二"退役"行：蓝图可重新启用）——受槽位上限约束。
func reactivate_blueprint(blueprint_id: String) -> Dictionary:
	var node: BlueprintNode = _nodes.get(blueprint_id, null)
	if node == null:
		return {"ok": false, "error": "蓝图不存在: %s" % blueprint_id}
	if node.state == BlueprintNode.State.ACTIVE:
		return {"ok": false, "error": "蓝图已在役: %s" % blueprint_id}
	if active_count() >= SLOT_LIMIT_PLACEHOLDER:
		return {"ok": false, "error": "蓝图槽位已满——须先退役一枚旧蓝图"}
	node.state = BlueprintNode.State.ACTIVE
	return {"ok": true}


func get_blueprint(blueprint_id: String) -> BlueprintNode:
	return _nodes.get(blueprint_id, null)


## 蓝图清单（默认含荣誉档案；谱系展示用——退役折叠是 UI 行为，数据层全量给）。
func get_blueprints(include_retired := true) -> Array:
	var out: Array = []
	for node in _nodes.values():
		if not include_retired and node.state == BlueprintNode.State.RETIRED:
			continue
		out.append(node)
	return out


func active_count() -> int:
	var count := 0
	for node in _nodes.values():
		if node.state == BlueprintNode.State.ACTIVE:
			count += 1
	return count


# ─────────────────────────── DAG 不变量 ────────────────────────────

## 沿 parents 边做环检测（树形是 DAG 而非链——11 §二断言的不变量）。
func is_acyclic() -> bool:
	var visited: Dictionary = {}
	var visiting: Dictionary = {}
	for id: String in _nodes:
		if not _visit_acyclic(id, visited, visiting):
			return false
	return true


func _visit_acyclic(id: String, visited: Dictionary, visiting: Dictionary) -> bool:
	if visiting.has(id):
		return false
	if visited.has(id):
		return true
	visiting[id] = true
	var node: BlueprintNode = _nodes[id]
	for pid in node.parents:
		if _nodes.has(pid) and not _visit_acyclic(pid, visited, visiting):
			return false
	visiting.erase(id)
	visited[id] = true
	return true


func _max_generation(parent_ids: Array[String]) -> int:
	var max_gen := -1
	for pid in parent_ids:
		var node: BlueprintNode = _nodes.get(pid, null)
		if node != null:
			max_gen = maxi(max_gen, node.generation)
	return max_gen


# ─────────────────────────── 待定机制守卫 ────────────────────────────

## 派生（骨架守卫）：继承 + 受控变异、代数惩罚——11 §三调优杆定稿后实装。
func derive_blueprint(_parent_id: String, _display_name: String) -> Dictionary:
	return {"ok": false, "error": "骨架占位：派生待 11 号调优杆定稿"}


## 融合（骨架守卫）：双母本插值、熟练度清零——11 §三调优杆定稿后实装。
func fuse_blueprint(_parent_a: String, _parent_b: String, _display_name: String) -> Dictionary:
	return {"ok": false, "error": "骨架占位：融合待 11 号调优杆定稿"}


# ─────────────────────────── 存档 round-trip ────────────────────────────

func to_dict() -> Dictionary:
	var nodes: Array = []
	for node in _nodes.values():
		nodes.append(node.to_dict())
	return {"nodes": nodes, "next_seq": _next_seq}


func from_dict(data: Dictionary) -> void:
	_nodes.clear()
	for d in data.get("nodes", []):
		if not (d is Dictionary):
			continue
		var node := BlueprintNode.from_dict(d)
		if not node.id.is_empty():
			_nodes[node.id] = node
	_next_seq = int(data.get("next_seq", _nodes.size() + 1))


# ─────────────────────────── 存档行（inventory/WorldState 同款契约） ────────────────────────────

const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'blueprint'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'blueprint'"

## 存档回调：蓝图节点写 world_state 模块行（谱系存档绑定、不跨档继承；
## 由 BlueprintAPI 单例首建时挂接）。
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "blueprint",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[BlueprintManager] 存档行写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


## 读档回调：无行 = 旧档空态；坏 JSON 按空恢复（inventory 同口径）。
func _on_game_loaded(slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	if db == null:
		return
	var rows: Array = []
	if db.query_with_bindings(_SQL_ROW_SELECT, [slot_index]):
		rows = db.query_result
	if rows.is_empty():
		return
	var parsed: Variant = JSON.parse_string(str(rows[0].get("data", "")))
	if parsed is Dictionary:
		from_dict(parsed)
