## Skill 模块公共接口契约（技能台账，骨架占位）
##
## 技能本位（04-科技系统 v2）：科技=长在具体火柴人身上的技能（制造/使用/组织
## 三类，会/不会二元）；无阵营科技池——"我国会什么"是台账的派生查询。
## 机制面（训练/研究的组织职能、死亡移除、需技能标注消费、组织前置接线）
## 待内容批次实装，见 SkillManager 类头。
##
## 外部模块经本契约交互（禁 preload 模块内部脚本；存档走模块自订阅
## game_saving/game_loaded 直写 world_state 模块行——inventory/WorldState 同款契约）：
##   - SkillAPI.learn_skill(skill_id, holder_id, source, teacher_holder_id) -> Dictionary
##       习得（Result；已会拒绝；时刻取 WorldState.game_time）。
##   - SkillAPI.knows(holder_id, skill_id) -> bool
##   - SkillAPI.faction_knows(skill_id) -> bool     # 存在持有者即会（派生视图）
##   - SkillAPI.holders_of(skill_id) -> Array       # 谁会
##   - SkillAPI.skills_of(holder_id) -> Array       # 某人会什么
##   - SkillAPI.get_skills()/get_skill(id)/get_skills_of_category(cat)
##   - SkillAPI.get_records()                       # 台账本体
##   - SkillAPI.get_save_data()/load_save_data(data)/reset_for_new_run()
class_name SkillAPI
extends RefCounted

## static var 生命周期（原型转正门槛③）：进程级单例（ItemDB 同模式）——运行态
## 只有习得记录台账；读档经 game_loaded 回调重置、新开局经 reset_for_new_run
## 重置（新游戏流程的接线随内容批次落——骨架期无生产写入方，无残留态风险）。
## 存档事件在单例首建时挂接（数据只能经单例产生 ⇒ 有数据 ⇒ 已挂接），
## reset 时对称摘除连接，不留僵尸订阅。
static var _mgr: SkillManager = null


static func _instance() -> SkillManager:
	if _mgr == null:
		_mgr = SkillManager.new()
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


## 习得一项技能（生产入口：时刻取 WorldState.game_time）。
static func learn_skill(skill_id: String, holder_id: String, source: SkillRecord.Source,
		teacher_holder_id := "") -> Dictionary:
	return _instance().learn_skill(skill_id, holder_id, source,
			teacher_holder_id, WorldState.game_time)


## 某人是否会某技能。
static func knows(holder_id: String, skill_id: String) -> bool:
	return _instance().knows(holder_id, skill_id)


## 阵营是否会某技能（存在活着的持有者即会；在场性归物流与组织判定）。
static func faction_knows(skill_id: String) -> bool:
	return _instance().faction_knows(skill_id)


## 某技能的全部持有者 id。
static func holders_of(skill_id: String) -> Array:
	return _instance().holders_of(skill_id)


## 某人的全部已会技能。
static func skills_of(holder_id: String) -> Array:
	return _instance().skills_of(holder_id)


static func get_skills() -> Array:
	return _instance().get_skills()


static func get_skill(skill_id: String) -> Dictionary:
	return _instance().get_skill(skill_id)


static func get_skills_of_category(category: String) -> Array:
	return _instance().get_skills_of_category(category)


static func get_records() -> Array:
	return _instance().get_records()


static func get_save_data() -> Dictionary:
	return _instance().to_dict()


static func load_save_data(data: Dictionary) -> void:
	_instance().from_dict(data)
