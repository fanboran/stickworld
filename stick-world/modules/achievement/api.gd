## Achievement 模块公共接口契约（骨架占位）
##
## 成就图章骨架：四档稀有度占位表注册表 + 幂等解锁记录 + 落档（图章存档绑定）。
## 结构/机制边界与升格路径见 AchievementManager 类头；设计真相源 =
## docs/设计/系统/07-成就系统.md（逐枚清单待创始人）。
##
## 外部模块经本契约交互（禁 preload 模块内部脚本；存档走模块自订阅
## game_saving/game_loaded 直写 world_state 模块行——inventory/WorldState 同款契约）：
##   - AchievementAPI.unlock(def_id, empire_snapshot) -> Dictionary
##       解锁一枚图章（幂等；Result；时刻取 WorldState.game_time）。
##   - AchievementAPI.is_unlocked(def_id) -> bool
##   - AchievementAPI.get_achievement_defs()/get_achievement_def(def_id)
##   - AchievementAPI.get_records()
##   - AchievementAPI.get_save_data()/load_save_data(data)/reset_for_new_run()
class_name AchievementAPI
extends RefCounted

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有解锁记录（图章存档绑定，覆盖存档重新收集）；读档经 game_loaded 回调
## 重置、新开局经 reset_for_new_run 重置（新游戏流程的接线随内容批次落——
## 骨架期无生产写入方，无残留态风险）。存档事件在单例首建时挂接（数据只能经
## 单例产生 ⇒ 有数据 ⇒ 已挂接），reset 时对称摘除连接，不留僵尸订阅。
static var _mgr: AchievementManager = null


static func _instance() -> AchievementManager:
	if _mgr == null:
		_mgr = AchievementManager.new()
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


## 解锁一枚图章（生产入口：时刻取 WorldState.game_time；条件判定机制待逐枚
## 清单定稿，骨架期由调用方显式给 id）。
static func unlock(def_id: String, empire_snapshot: Dictionary = {}) -> Dictionary:
	return _instance().unlock(def_id, WorldState.game_time, empire_snapshot)


static func is_unlocked(def_id: String) -> bool:
	return _instance().is_unlocked(def_id)


static func get_achievement_defs() -> Array:
	return _instance().get_achievement_defs()


static func get_achievement_def(def_id: String) -> Dictionary:
	return _instance().get_achievement_def(def_id)


static func get_records() -> Array:
	return _instance().get_records()


static func get_save_data() -> Dictionary:
	return _instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	_instance().from_dict(data)
