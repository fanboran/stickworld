## Logistics 模块公共接口契约（骨架占位）
##
## 运输层骨架：载体/道路占位表注册表 + 运输计划 CRUD（计划挂组织节点）+ 落档。
## 结构/机制边界与升格路径见 LogisticsManager 类头；设计真相源 =
## docs/设计/系统/06-物流系统.md（调优杆全 [PLACEHOLDER] 待定）。
##
## 外部模块经本契约交互（禁 preload 模块内部脚本；存档走模块自订阅
## game_saving/game_loaded 直写 world_state 模块行——inventory/WorldState 同款契约）：
##   - LogisticsAPI.get_carriers()/get_roads() -> Array
##       占位表全行（BalanceResource 行式，内容待策划；载体/载具已并一表）。
##   - LogisticsAPI.add_transport_plan(owner_org_id, ...) -> Dictionary
##       运输计划增（计划依附组织节点——手操挂玩家直辖、委任挂运输队；
##       Result：{"ok": true, "plan_id": ...} / {"ok": false, "error": ...}）。
##   - LogisticsAPI.remove_transport_plan(plan_id) / get_transport_plans()
##   - LogisticsAPI.assign_carrier(plan_id, stickman_iid) -> Dictionary
##       骨架守卫（承运人派工待 06 号设计实装）。
##   - LogisticsAPI.get_save_data()/load_save_data(data)/reset_for_new_run()
class_name LogisticsAPI
extends RefCounted

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有运输计划表；读档经 game_loaded 回调重置、新开局经 reset_for_new_run
## 重置（新游戏流程的接线随内容批次落——骨架期无生产写入方，无残留态风险）。
## 存档事件在单例首建时挂接（数据只能经单例产生 ⇒ 有数据 ⇒ 已挂接），
## reset 时对称摘除连接，不留僵尸订阅。
static var _mgr: LogisticsManager = null


static func _instance() -> LogisticsManager:
	if _mgr == null:
		_mgr = LogisticsManager.new()
		_hook_save_events()
	return _mgr


static func reset_for_new_run() -> void:
	if _mgr != null:
		_unhook_save_events()
		_mgr = null


static func _hook_save_events() -> void:
	if EventBus != null and EventBus.has_signal("game_saving"):
		EventBus.game_saving.connect(_mgr._on_game_saving)
	if EventBus != null and EventBus.has_signal("game_loaded"):
		EventBus.game_loaded.connect(_mgr._on_game_loaded)


static func _unhook_save_events() -> void:
	if EventBus == null or _mgr == null:
		return
	if EventBus.game_saving.is_connected(_mgr._on_game_saving):
		EventBus.game_saving.disconnect(_mgr._on_game_saving)
	if EventBus.game_loaded.is_connected(_mgr._on_game_loaded):
		EventBus.game_loaded.disconnect(_mgr._on_game_loaded)


static func get_carriers() -> Array:
	return _instance().get_carriers()


static func get_roads() -> Array:
	return _instance().get_roads()


static func get_carrier(carrier_id: String) -> Dictionary:
	return _instance().get_carrier(carrier_id)


static func add_transport_plan(owner_org_id: String, origin: String, destination: String,
		cargo_id: String, cargo_kind: TransportPlan.CargoKind, amount: int,
		frequency_days: int, priority: TransportPlan.Priority) -> Dictionary:
	return _instance().add_transport_plan(owner_org_id, origin, destination, cargo_id,
			cargo_kind, amount, frequency_days, priority)


static func remove_transport_plan(plan_id: String) -> Dictionary:
	return _instance().remove_transport_plan(plan_id)


static func get_transport_plans() -> Array:
	return _instance().get_transport_plans()


static func assign_carrier(plan_id: String, stickman_iid: int) -> Dictionary:
	return _instance().assign_carrier(plan_id, stickman_iid)


static func get_save_data() -> Dictionary:
	return _instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	_instance().from_dict(data)
