class_name LawManager
extends RefCounted
## 法律骨架管理器 —— 占位法律表注册表 + 颁布/废除 CRUD（程序先行骨架）。
##
## 结构面（GDD §七 / 04-科技系统 §四）：法律树独立于科技树；每条法律 = 可量化
## 效果 + 不可量化叙事后果的二元形状（表列 effect_quantifiable/effect_narrative）；
## 法律可以废除。
## 机制面（待创始人法律清单与设计定稿，本类不实现，占位方法走未实现守卫）：
## 废除代价（适应期混乱/利益集团反弹）、道德张力呈现、立法/执法组织联动
## （法律界面 = 组织呈报的报表与操作界面，归组织系统深化）。

signal law_enacted(law_id: String)
signal law_repealed(law_id: String)

## 占位表路径（BalanceResource 行数组；法律清单待创始人，行内容占位）
const LAWS_PATH := "res://config/law/law.tres"

var _laws: Array = []
var _enacted: Dictionary = {}  # {law_id: true}
var _tables_loaded := false


# ─────────────────────────── 注册表 ────────────────────────────

func get_laws() -> Array:
	_ensure_loaded()
	return _laws


func get_law(law_id: String) -> Dictionary:
	if law_id.is_empty():
		return {}
	for row in get_laws():
		if row is Dictionary and String(row.get("id", "")) == law_id:
			return row
	return {}


func _ensure_loaded() -> void:
	if _tables_loaded:
		return
	_tables_loaded = true
	if not ResourceLoader.exists(LAWS_PATH):
		push_warning("[LawManager] 占位表不存在: %s" % LAWS_PATH)
		return
	var res: Resource = load(LAWS_PATH)
	if res == null or not (res is BalanceResource):
		push_warning("[LawManager] 占位表加载失败: %s" % LAWS_PATH)
		return
	_laws = BalanceResource.sanitized_rows(res)


# ─────────────────────────── 颁布 / 废除 ────────────────────────────

## 颁布一条法律（GDD §七"法律可以废除"——颁布集是可逆状态）。
func enact_law(law_id: String) -> Dictionary:
	if get_law(law_id).is_empty():
		return {"ok": false, "error": "未知法律 id: %s" % law_id}
	if _enacted.has(law_id):
		return {"ok": false, "error": "该法律已颁布: %s" % law_id}
	_enacted[law_id] = true
	law_enacted.emit(law_id)
	return {"ok": true}


## 废除一条法律（结构断言；废除的代价机制见 get_repeal_cost 守卫）。
func repeal_law(law_id: String) -> Dictionary:
	if get_law(law_id).is_empty():
		return {"ok": false, "error": "未知法律 id: %s" % law_id}
	if not _enacted.has(law_id):
		return {"ok": false, "error": "该法律未颁布: %s" % law_id}
	_enacted.erase(law_id)
	law_repealed.emit(law_id)
	return {"ok": true}


func is_enacted(law_id: String) -> bool:
	return _enacted.has(law_id)


func get_enacted_laws() -> Array:
	return _enacted.keys()


## 废除代价（骨架守卫）：04 §四——废除有代价（适应期混乱/利益集团反弹），
## 代价机制待法律清单定稿后随内容实装。
func get_repeal_cost(_law_id: String) -> Dictionary:
	return {"ok": false, "error": "骨架占位：废除代价机制待法律设计定稿"}


# ─────────────────────────── 存档 round-trip ────────────────────────────

func to_dict() -> Dictionary:
	return {"enacted": _enacted.keys().duplicate()}


func from_dict(data: Dictionary) -> void:
	_enacted.clear()
	for v in data.get("enacted", []):
		var law_id := String(v)
		if not law_id.is_empty():
			_enacted[law_id] = true


# ─────────────────────────── 存档行（inventory/WorldState 同款契约） ────────────────────────────

const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'law'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'law'"

## 存档回调：颁布集写 world_state 模块行（由 LawAPI 单例首建时挂接）。
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "law",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[LawManager] 存档行写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


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
