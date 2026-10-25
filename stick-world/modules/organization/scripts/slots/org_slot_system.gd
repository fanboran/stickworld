class_name OrgSlotSystem
extends RefCounted
## 组织槽位系统的进程级门面 —— 槽位板单例 + 存档行（骨架占位）。
##
## 实现在 OrgSlotBoard（01-组织系统 §2.4 纯机制，见其类头）；骨架期消费方仅
## 单测与灰盒验收台，直接经本类 class_name 访问——接入 organization/api.gd
## 公共面随内容批次落（该文件受行数棘轮约束，本批零增行）。
## 存档：自订阅 game_saving/game_loaded 直写 world_state 模块行 'org_slots'
## （inventory/WorldState 同款契约；无行 = 旧档空态）。

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有槽位板；读档经 game_loaded 回调重置、新开局经 reset_for_new_run 重置
## （新游戏流程的接线随内容批次落）。存档事件在单例首建时挂接，reset 对称摘除。
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


static func add_slot(org_id: String, function_name: String) -> Dictionary:
	return instance().add_slot(org_id, function_name)


static func remove_slot(org_id: String, function_name: String) -> Dictionary:
	return instance().remove_slot(org_id, function_name)


static func assign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary:
	return instance().assign_person(org_id, function_name, holder_id)


static func unassign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary:
	return instance().unassign_person(org_id, function_name, holder_id)


static func assign_institution(org_id: String, function_name: String,
		institution_org_id: String) -> Dictionary:
	return instance().assign_institution(org_id, function_name, institution_org_id)


static func unassign_institution(org_id: String, function_name: String) -> Dictionary:
	return instance().unassign_institution(org_id, function_name)


static func is_slot_active(org_id: String, function_name: String) -> bool:
	return instance().is_slot_active(org_id, function_name)


static func active_functions(org_id: String) -> Array:
	return instance().active_functions(org_id)


static func get_slots(org_id: String) -> Array:
	return instance().get_slots(org_id)


static func get_save_data() -> Dictionary:
	return instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	instance().from_dict(data)
