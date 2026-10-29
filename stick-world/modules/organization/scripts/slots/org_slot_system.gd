class_name OrgSlotSystem
extends RefCounted
## 组织槽位系统的进程级门面 —— 槽位板单例 + 存档行 + 明面前提接线。
##
## 实现在 OrgSlotBoard（01-组织系统 §2.4 纯机制，见其类头）；本门面在纯机制之上
## 接两件事：
##   - 明面前提（01 §2.5，OrgPrereqs）：add_slot / assign_institution 先过校验，
##     表里没定义的职能无门槛（特例制）——机构塞槽按机构自身在编人员校验；
##   - 组织生命周期：api 层解散/删层成功后调 on_org_removed，槽位随组织清理。
## 存档：自订阅 game_saving/game_loaded 直写 world_state 模块行 'org_slots'
## （inventory/WorldState 同款契约；无行 = 旧档空态）。
## 装配：system_setup 组织系统步每局 reset_for_new_run + instance（消跨局残留）。

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有槽位板；读档经 game_loaded 回调重置、新开局经装配步 reset_for_new_run 重置。
## 存档事件在单例首建时挂接，reset 对称摘除。
static var _board: OrgSlotBoard = null


static func instance() -> OrgSlotBoard:
	if _board == null:
		_board = OrgSlotBoard.new()
		if EventBus != null and EventBus.has_signal("game_saving"):
			EventBus.game_saving.connect(_board._on_game_saving)
		if EventBus != null and EventBus.has_signal("game_loaded"):
			EventBus.game_loaded.connect(_board._on_game_loaded)
	return _board


static func reset_for_new_run() -> void:
	if _board != null:
		if EventBus != null:
			if EventBus.game_saving.is_connected(_board._on_game_saving):
				EventBus.game_saving.disconnect(_board._on_game_saving)
			if EventBus.game_loaded.is_connected(_board._on_game_loaded):
				EventBus.game_loaded.disconnect(_board._on_game_loaded)
		_board = null


## 明面前提查询（面板逐条 ✓/✗ 展示用，不做拦截）。
static func check_prereqs(org_id: String, function_name: String) -> Dictionary:
	return OrgPrereqs.check(org_id, function_name)


static func add_slot(org_id: String, function_name: String) -> Dictionary:
	var gate := OrgPrereqs.check(org_id, function_name)
	if not gate.get("ok", false):
		return gate
	return instance().add_slot(org_id, function_name)


static func remove_slot(org_id: String, function_name: String) -> Dictionary:
	return instance().remove_slot(org_id, function_name)


static func assign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary:
	return instance().assign_person(org_id, function_name, holder_id)


static func unassign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary:
	return instance().unassign_person(org_id, function_name, holder_id)


## 机构塞槽（01 §2.4 组织嵌套）：明面前提按**机构自身**在编人员校验。
static func assign_institution(org_id: String, function_name: String,
		institution_org_id: String) -> Dictionary:
	var gate := OrgPrereqs.check(institution_org_id, function_name)
	if not gate.get("ok", false):
		return gate
	return instance().assign_institution(org_id, function_name, institution_org_id)


static func unassign_institution(org_id: String, function_name: String) -> Dictionary:
	return instance().unassign_institution(org_id, function_name)


static func is_slot_active(org_id: String, function_name: String) -> bool:
	return instance().is_slot_active(org_id, function_name)


static func active_functions(org_id: String) -> Array:
	return instance().active_functions(org_id)


static func get_slots(org_id: String) -> Array:
	return instance().get_slots(org_id)


## 组织消失（api 层解散/删层成功后调）：槽位与全板机构引用随之清理。
static func on_org_removed(org_id: String) -> void:
	if _board != null:
		_board.on_org_removed(org_id)


static func get_save_data() -> Dictionary:
	return instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	instance().from_dict(data)
