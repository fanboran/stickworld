## Technology 模块公共接口契约（骨架占位）
##
## 科技层骨架（征服获得制）：三分类占位表注册表 + 授予/获得记录。
## 口径只锚 GDD §6.4 断言（04-科技系统属 AI 草稿非定稿）；机制边界与升格路径
## 见 TechnologyManager 类头。
##
## 外部模块经本契约交互（禁 preload 模块内部脚本；存档走模块自订阅
## game_saving/game_loaded 直写 world_state 模块行——inventory/WorldState 同款契约）：
##   - TechnologyAPI.has_tech(tech_id) -> bool
##       科技拥有查询（解锁池 = WorldState.unlocks，含开局基线；获得即拥有）。
##   - TechnologyAPI.grant_tech(tech_id, source, carrier_stickman_id) -> Dictionary
##       授予（Result；解锁池/时刻取 WorldState，单测走 TechnologyManager 注入）。
##   - TechnologyAPI.get_techs()/get_tech(tech_id)/get_grants()
##   - TechnologyAPI.get_save_data()/load_save_data(data)/reset_for_new_run()
class_name TechnologyAPI
extends RefCounted

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有获得记录（解锁池本体在 WorldState.unlocks 自带存档）；读档经 game_loaded
## 回调重置、新开局经 reset_for_new_run 重置（新游戏流程的接线随内容批次落——
## 骨架期无生产写入方，无残留态风险）。存档事件在单例首建时挂接（数据只能经
## 单例产生 ⇒ 有数据 ⇒ 已挂接），reset 时对称摘除连接，不留僵尸订阅。
static var _mgr: TechnologyManager = null


static func _instance() -> TechnologyManager:
	if _mgr == null:
		_mgr = TechnologyManager.new()
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


## 科技拥有查询（获得即拥有：解锁池含开局基线 WorldState.has_unlock）。
static func has_tech(tech_id: String) -> bool:
	return WorldState.has_unlock(tech_id)


## 授予一笔科技（生产入口：解锁池 = WorldState.unlocks，时刻 = WorldState.game_time）。
## 征服 → 自动授予的规则（哪场仗给哪个科技）属策划内容，骨架期由调用方显式给 id。
static func grant_tech(tech_id: String, source: TechGrant.Source,
		carrier_stickman_id := "") -> Dictionary:
	return _instance().grant_tech(tech_id, source, carrier_stickman_id,
			WorldState.unlocks, WorldState.game_time)


static func get_techs() -> Array:
	return _instance().get_techs()


static func get_tech(tech_id: String) -> Dictionary:
	return _instance().get_tech(tech_id)


static func get_grants() -> Array:
	return _instance().get_grants()


static func get_save_data() -> Dictionary:
	return _instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	_instance().from_dict(data)
