## Blueprint 模块公共接口契约（骨架占位）
##
## 构筑谱系骨架：蓝图节点定名/退役/重新启用 CRUD + DAG 不变量校验 + 落档
## （谱系存档绑定、不跨档继承）。结构/机制边界与升格路径见 BlueprintManager
## 类头；设计真相源 = GDD §6.8 与 docs/设计/系统/11-构筑谱系系统.md
## （调优杆全 [PLACEHOLDER] 待定）。
##
## 外部模块经本契约交互（禁 preload 模块内部脚本；存档走模块自订阅
## game_saving/game_loaded 直写 world_state 模块行——inventory/WorldState 同款契约）：
##   - BlueprintAPI.create_blueprint(display_name, kind, parents) -> Dictionary
##       定名（Result；parents = 母本 id 列表，DAG 加边校验内置）。
##   - BlueprintAPI.retire_blueprint(id)/reactivate_blueprint(id)
##       退役归荣誉档案（不删除）/重新启用（受槽位上限约束）。
##   - BlueprintAPI.derive_blueprint(...)/fuse_blueprint(...)
##       骨架守卫（待 11 号调优杆定稿）。
##   - BlueprintAPI.is_acyclic() -> bool / get_blueprints()/active_count()
##   - BlueprintAPI.get_save_data()/load_save_data(data)/reset_for_new_run()
class_name BlueprintAPI
extends RefCounted

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有蓝图节点表；读档经 game_loaded 回调重置、新开局经 reset_for_new_run
## 重置（新游戏流程的接线随内容批次落——骨架期无生产写入方，无残留态风险）。
## 存档事件在单例首建时挂接（数据只能经单例产生 ⇒ 有数据 ⇒ 已挂接），
## reset 时对称摘除连接，不留僵尸订阅。
static var _mgr: BlueprintManager = null


static func _instance() -> BlueprintManager:
	if _mgr == null:
		_mgr = BlueprintManager.new()
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


static func create_blueprint(display_name: String, kind: BlueprintNode.Kind,
		parents: Array = []) -> Dictionary:
	return _instance().create_blueprint(display_name, kind, parents)


static func retire_blueprint(blueprint_id: String) -> Dictionary:
	return _instance().retire_blueprint(blueprint_id)


static func reactivate_blueprint(blueprint_id: String) -> Dictionary:
	return _instance().reactivate_blueprint(blueprint_id)


static func derive_blueprint(parent_id: String, display_name: String) -> Dictionary:
	return _instance().derive_blueprint(parent_id, display_name)


static func fuse_blueprint(parent_a: String, parent_b: String, display_name: String) -> Dictionary:
	return _instance().fuse_blueprint(parent_a, parent_b, display_name)


static func is_acyclic() -> bool:
	return _instance().is_acyclic()


static func get_blueprints(include_retired := true) -> Array:
	return _instance().get_blueprints(include_retired)


static func active_count() -> int:
	return _instance().active_count()


static func get_save_data() -> Dictionary:
	return _instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	_instance().from_dict(data)
