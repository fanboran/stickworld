class_name LogisticsManager
extends RefCounted
## 物流骨架管理器 —— 占位表装载 + 运输计划 CRUD（程序先行骨架，零机制逻辑）。
##
## 结构面（06-物流系统）：载体占位表（载体/载具并一：运输方式即造出来的载具，
## 一张表）+ 道路表装载进注册表可查询；运输计划（§2.3 字段集 + 计划依附组织
## ——挂在组织节点上，见 TransportPlan.owner_org_id）增删查 + 落档。
## 机制面（待设计定稿，本类不实现，占位方法走未实现守卫）：
##   - 网络节点/路线建模（依赖 Region 建模与 worldgen L1 地块管线）；
##   - 承运人派工（§四 组织封装递进：手操个体 → 专人委托 → 运输队 → 部门）；
##   - 路线状态（§2.2 绿=顺畅/黄=拥堵/红=中断）与补给线惩罚（§三）。
## 存档：模块自订阅 game_saving/game_loaded 直写 world_state 模块行
## （inventory/WorldState 同款契约；无行 = 旧档空态）。

signal transport_plan_added(plan_id: String)
signal transport_plan_removed(plan_id: String)

## 占位表路径（BalanceResource 行数组；行内容/数值待策划，数值统一占位 10）
const CARRIERS_PATH := "res://config/logistics/carriers.tres"
const ROADS_PATH := "res://config/logistics/roads.tres"

var _carriers: Array = []
var _roads: Array = []
var _plans: Dictionary = {}  # {plan_id: TransportPlan}
var _next_plan_seq := 1
var _tables_loaded := false


# ─────────────────────────── 占位表注册表 ────────────────────────────

func get_carriers() -> Array:
	_ensure_loaded()
	return _carriers


func get_roads() -> Array:
	_ensure_loaded()
	return _roads


func get_carrier(carrier_id: String) -> Dictionary:
	return _row_by_id(get_carriers(), carrier_id)


func get_road(road_id: String) -> Dictionary:
	return _row_by_id(get_roads(), road_id)


func _ensure_loaded() -> void:
	if _tables_loaded:
		return
	_tables_loaded = true
	_carriers = _load_rows(CARRIERS_PATH)
	_roads = _load_rows(ROADS_PATH)


## 装载占位表（ProfessionRegistry 同款：直读 .tres 不依赖 autoload 顺序，
## 配置缺失/格式不对返回空数组并告警，调用方按"无数据"降级）。
static func _load_rows(path: String) -> Array:
	if not ResourceLoader.exists(path):
		push_warning("[LogisticsManager] 占位表不存在: %s" % path)
		return []
	var res: Resource = load(path)
	if res == null or not (res is BalanceResource):
		push_warning("[LogisticsManager] 占位表加载失败: %s" % path)
		return []
	return BalanceResource.sanitized_rows(res)


static func _row_by_id(rows: Array, row_id: String) -> Dictionary:
	if row_id.is_empty():
		return {}
	for row in rows:
		if row is Dictionary and String(row.get("id", "")) == row_id:
			return row
	return {}


# ─────────────────────────── 运输计划 CRUD ────────────────────────────

func add_transport_plan(owner_org_id: String, origin: String, destination: String,
		cargo_id: String, cargo_kind: TransportPlan.CargoKind, amount: int,
		frequency_days: int, priority: TransportPlan.Priority) -> Dictionary:
	if owner_org_id.is_empty():
		return {"ok": false, "error": "运输计划必须挂在组织节点上（owner_org_id 不能为空）"}
	if origin.is_empty() or destination.is_empty():
		return {"ok": false, "error": "运输计划起点/终点不能为空"}
	if origin == destination:
		return {"ok": false, "error": "起点与终点相同"}
	if cargo_id.is_empty():
		return {"ok": false, "error": "货物 id 不能为空"}
	var plan := TransportPlan.new()
	plan.id = "tp_%03d" % _next_plan_seq
	_next_plan_seq += 1
	plan.owner_org_id = owner_org_id
	plan.origin = origin
	plan.destination = destination
	plan.cargo_id = cargo_id
	plan.cargo_kind = cargo_kind
	plan.amount = amount
	plan.frequency_days = frequency_days
	plan.priority = priority
	_plans[plan.id] = plan
	transport_plan_added.emit(plan.id)
	return {"ok": true, "plan_id": plan.id}


func remove_transport_plan(plan_id: String) -> Dictionary:
	if not _plans.has(plan_id):
		return {"ok": false, "error": "运输计划不存在: %s" % plan_id}
	_plans.erase(plan_id)
	transport_plan_removed.emit(plan_id)
	return {"ok": true}


func get_transport_plans() -> Array:
	return _plans.values()


## 承运人派工（骨架守卫）：机制归 06 §四组织封装递进——专人委托/运输队的
## 设计定稿后实装。
func assign_carrier(_plan_id: String, _stickman_iid: int) -> Dictionary:
	return {"ok": false, "error": "骨架占位：承运人派工待 06 号设计实装"}


# ─────────────────────────── 存档 round-trip ────────────────────────────

func to_dict() -> Dictionary:
	var plans: Array = []
	for plan in _plans.values():
		plans.append(plan.to_dict())
	return {"plans": plans, "next_plan_seq": _next_plan_seq}


func from_dict(data: Dictionary) -> void:
	_plans.clear()
	for d in data.get("plans", []):
		if not (d is Dictionary):
			continue
		var plan := TransportPlan.from_dict(d)
		if not plan.id.is_empty():
			_plans[plan.id] = plan
	_next_plan_seq = int(data.get("next_plan_seq", _plans.size() + 1))


# ─────────────────────────── 存档行（inventory/WorldState 同款契约） ────────────────────────────

const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'logistics'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'logistics'"

## 存档回调：运输计划写 world_state 模块行（由 LogisticsAPI 单例首建时挂接；
## 单测直测 to_dict/from_dict，不触本回调）。
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "logistics",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[LogisticsManager] 存档行写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


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
