class_name SkillManager
extends RefCounted
## 技能台账管理器 —— 技能定义注册表 + 习得记录 + 派生查询（程序先行骨架）。
##
## 结构面（04-科技系统 技能本位）：技能定义表（制造/使用/组织三类平铺清单）装载
## 注册表；习得记录 = "某人会某事"（见 SkillRecord，持有者是本体）；阵营技能 =
## 台账的派生查询（存在活着的持有者即会），无中央解锁池。
## 机制面（待内容批次，本类不实现）：训练/研究的组织职能（谁教谁、占多少编制
## 与时间）、死亡/流失时记录移除、物品/建筑/组织定义的"需技能"标注消费、
## 组织技能作为建组织前置的接线。
## 存档：模块自订阅 game_saving/game_loaded 直写 world_state 模块行
## （inventory/WorldState 同款契约；无行 = 旧档空态）。

signal skill_learned(skill_id: String, holder_id: String)

## 技能定义表路径（BalanceResource 行数组；行内容待策划——id placeholder 前缀、
## 名称「占位X」、数值统一 10、描述空）
const SKILLS_PATH := "res://config/skills/skills.tres"

## 三类技能（04 §二：制造/使用/组织——表列 category 与此对齐）
const CATEGORIES: Array[String] = ["制造", "使用", "组织"]

var _defs: Array = []
var _records: Array = []  # SkillRecord 时序（台账本体）
var _tables_loaded := false


# ─────────────────────────── 定义注册表 ────────────────────────────

func get_skills() -> Array:
	_ensure_loaded()
	return _defs


func get_skill(skill_id: String) -> Dictionary:
	if skill_id.is_empty():
		return {}
	for row in get_skills():
		if row is Dictionary and String(row.get("id", "")) == skill_id:
			return row
	return {}


## 按类查技能（制造/使用/组织）。
func get_skills_of_category(category: String) -> Array:
	var out: Array = []
	for row in get_skills():
		if String(row.get("category", "")) == category:
			out.append(row)
	return out


func _ensure_loaded() -> void:
	if _tables_loaded:
		return
	_tables_loaded = true
	if not ResourceLoader.exists(SKILLS_PATH):
		push_warning("[SkillManager] 技能定义表不存在: %s" % SKILLS_PATH)
		return
	var res: Resource = load(SKILLS_PATH)
	if res == null or not (res is BalanceResource):
		push_warning("[SkillManager] 技能定义表加载失败: %s" % SKILLS_PATH)
		return
	for row in BalanceResource.sanitized_rows(res):
		var category := String(row.get("category", ""))
		if not CATEGORIES.has(category):
			push_warning("[SkillManager] 技能类别非法，跳过: %s（category=%s）" % [
				String(row.get("id", "?")), category])
			continue
		_defs.append(row)


# ─────────────────────────── 习得（台账写入） ────────────────────────────

## 习得一项技能：会/不会二元——已会拒绝重复习得（技能无层次，重复无意义）。
func learn_skill(skill_id: String, holder_id: String, source: SkillRecord.Source,
		teacher_holder_id := "", learned_at := 0.0) -> Dictionary:
	_ensure_loaded()
	if get_skill(skill_id).is_empty():
		return {"ok": false, "error": "未知技能 id: %s" % skill_id}
	if holder_id.is_empty():
		return {"ok": false, "error": "持有者不能为空"}
	if knows(holder_id, skill_id):
		return {"ok": false, "error": "已会该技能: %s（%s）" % [holder_id, skill_id]}
	var record := SkillRecord.new()
	record.skill_id = skill_id
	record.holder_id = holder_id
	record.source = source
	record.teacher_holder_id = teacher_holder_id
	record.learned_at = learned_at
	_records.append(record)
	skill_learned.emit(skill_id, holder_id)
	return {"ok": true, "record": record.to_dict()}


# ─────────────────────────── 派生查询 ────────────────────────────

## 某人是否会某技能。
func knows(holder_id: String, skill_id: String) -> bool:
	for record in _records:
		if record.holder_id == holder_id and record.skill_id == skill_id:
			return true
	return false


## 某技能的全部持有者 id（"我国谁会这个"）。
func holders_of(skill_id: String) -> Array:
	var out: Array = []
	for record in _records:
		if record.skill_id == skill_id:
			out.append(record.holder_id)
	return out


## 阵营是否会某技能＝存在持有者（04 §五 派生视图——没有中央解锁池；
## 持有者是否在场/可达归物流与组织的物理约束判定）。
func faction_knows(skill_id: String) -> bool:
	return not holders_of(skill_id).is_empty()


## 某人的全部已会技能（技能台账的按人视图）。
func skills_of(holder_id: String) -> Array:
	var out: Array = []
	for record in _records:
		if record.holder_id == holder_id:
			out.append(record.skill_id)
	return out


func get_records() -> Array:
	return _records


# ─────────────────────────── 存档 round-trip ────────────────────────────

func to_dict() -> Dictionary:
	var records: Array = []
	for record in _records:
		records.append(record.to_dict())
	return {"records": records}


func from_dict(data: Dictionary) -> void:
	_records.clear()
	for d in data.get("records", []):
		if not (d is Dictionary):
			continue
		var record := SkillRecord.from_dict(d)
		if not record.skill_id.is_empty() and not record.holder_id.is_empty():
			_records.append(record)


# ─────────────────────────── 存档行（inventory/WorldState 同款契约） ────────────────────────────

const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'skill'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'skill'"

## 存档回调：技能台账写 world_state 模块行（由 SkillAPI 单例首建时挂接）。
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "skill",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[SkillManager] 存档行写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


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
