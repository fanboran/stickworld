class_name AchievementManager
extends RefCounted
## 成就骨架管理器 —— 图章占位表注册表 + 幂等解锁记录（程序先行骨架）。
##
## 结构面（07-成就系统）：四档稀有度（§1.2）；解锁记录带获得时刻与帝国状态
## 快照（§四 史诗图章的历史记录，见 AchievementRecord）；图章存档绑定（边缘
## 情况——记录随档走，覆盖存档重新收集）。
## 机制面（待创始人——逐枚清单与实现方式都待定，本类不实现）：解锁条件判定、
## 图章墙 UI、主菜单最近获得轮播、Steam 同步、模组图章"非官方"标记
## （UI 接入点见 ui_global collection 占位预设的 note）。

signal achievement_unlocked(def_id: String)

## 占位表路径（BalanceResource 行数组；逐枚清单待创始人，行内容占位）
const ACHIEVEMENTS_PATH := "res://config/achievements/achievements.tres"

## 四档稀有度（07 §1.2；表列 rarity 与此对齐，校验以此为准）
const RARITIES: Array[String] = ["common", "rare", "epic", "hidden"]

var _defs: Array = []
var _records: Dictionary = {}  # {def_id: AchievementRecord}
var _tables_loaded := false


# ─────────────────────────── 注册表 ────────────────────────────

func get_achievement_defs() -> Array:
	_ensure_loaded()
	return _defs


func get_achievement_def(def_id: String) -> Dictionary:
	if def_id.is_empty():
		return {}
	for row in get_achievement_defs():
		if row is Dictionary and String(row.get("id", "")) == def_id:
			return row
	return {}


func _ensure_loaded() -> void:
	if _tables_loaded:
		return
	_tables_loaded = true
	if not ResourceLoader.exists(ACHIEVEMENTS_PATH):
		push_warning("[AchievementManager] 占位表不存在: %s" % ACHIEVEMENTS_PATH)
		return
	var res: Resource = load(ACHIEVEMENTS_PATH)
	if res == null or not (res is BalanceResource):
		push_warning("[AchievementManager] 占位表加载失败: %s" % ACHIEVEMENTS_PATH)
		return
	_defs = BalanceResource.sanitized_rows(res)


# ─────────────────────────── 解锁（幂等记录） ────────────────────────────

## 解锁一枚图章：幂等（已获得再次调用 = 无操作、不重发信号——收藏不膨胀）。
## 快照存副本——解锁后调用方改原字典不影响档内记录。
func unlock(def_id: String, unlocked_at := 0.0, empire_snapshot := {}) -> Dictionary:
	var def := get_achievement_def(def_id)
	if def.is_empty():
		return {"ok": false, "error": "未知成就 id: %s" % def_id}
	if _records.has(def_id):
		return {"ok": true, "already": true}
	var rarity := String(def.get("rarity", ""))
	if not RARITIES.has(rarity):
		return {"ok": false, "error": "稀有度档位非法: %s（%s）" % [rarity, def_id]}
	var record := AchievementRecord.new()
	record.def_id = def_id
	record.rarity = rarity
	record.unlocked_at = unlocked_at
	record.empire_snapshot = empire_snapshot.duplicate()
	_records[def_id] = record
	achievement_unlocked.emit(def_id)
	return {"ok": true, "record": record.to_dict()}


func is_unlocked(def_id: String) -> bool:
	return _records.has(def_id)


func get_records() -> Array:
	return _records.values()


# ─────────────────────────── 存档 round-trip ────────────────────────────

func to_dict() -> Dictionary:
	var records: Array = []
	for record in _records.values():
		records.append(record.to_dict())
	return {"records": records}


func from_dict(data: Dictionary) -> void:
	_records.clear()
	for d in data.get("records", []):
		if not (d is Dictionary):
			continue
		var record := AchievementRecord.from_dict(d)
		if not record.def_id.is_empty():
			_records[record.def_id] = record


# ─────────────────────────── 存档行（inventory/WorldState 同款契约） ────────────────────────────

const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'achievement'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'achievement'"

## 存档回调：解锁记录写 world_state 模块行（图章存档绑定；由 AchievementAPI
## 单例首建时挂接）。
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "achievement",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[AchievementManager] 存档行写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


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
