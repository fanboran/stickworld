## Law 模块公共接口契约（骨架占位）
##
## 法律骨架：占位法律表注册表 + 颁布/废除 CRUD + 落档。法律树独立于科技树
## （GDD §七 / 04-科技系统 §四）；结构/机制边界与升格路径见 LawManager 类头。
##
## 外部模块经本契约交互（禁 preload 模块内部脚本；存档走模块自订阅
## game_saving/game_loaded 直写 world_state 模块行——inventory/WorldState 同款契约）：
##   - LawAPI.enact_law(law_id)/repeal_law(law_id) -> Dictionary
##       颁布/废除（Result；废除的代价机制见 get_repeal_cost 守卫）。
##   - LawAPI.is_enacted(law_id) -> bool / get_enacted_laws()
##   - LawAPI.get_laws()/get_law(law_id)
##   - LawAPI.get_repeal_cost(law_id) -> Dictionary
##       骨架守卫（废除代价机制待法律设计定稿）。
##   - LawAPI.get_save_data()/load_save_data(data)/reset_for_new_run()
class_name LawAPI
extends RefCounted

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有颁布集；读档经 game_loaded 回调重置、新开局经 reset_for_new_run 重置
## （新游戏流程的接线随内容批次落——骨架期无生产写入方，无残留态风险）。
## 存档事件在单例首建时挂接（数据只能经单例产生 ⇒ 有数据 ⇒ 已挂接），
## reset 时对称摘除连接，不留僵尸订阅。
static var _mgr: LawManager = null


static func _instance() -> LawManager:
	if _mgr == null:
		_mgr = LawManager.new()
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


static func enact_law(law_id: String) -> Dictionary:
	return _instance().enact_law(law_id)


static func repeal_law(law_id: String) -> Dictionary:
	return _instance().repeal_law(law_id)


static func is_enacted(law_id: String) -> bool:
	return _instance().is_enacted(law_id)


static func get_enacted_laws() -> Array:
	return _instance().get_enacted_laws()


static func get_laws() -> Array:
	return _instance().get_laws()


static func get_law(law_id: String) -> Dictionary:
	return _instance().get_law(law_id)


static func get_repeal_cost(law_id: String) -> Dictionary:
	return _instance().get_repeal_cost(law_id)


static func get_save_data() -> Dictionary:
	return _instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	_instance().from_dict(data)
