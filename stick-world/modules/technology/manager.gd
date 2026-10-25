class_name TechnologyManager
extends RefCounted
## 科技骨架管理器 —— 征服获得制：三分类占位表注册表 + 授予/获得记录。
##
## 口径（04-科技系统属 AI 草稿非定稿，本类只锚 GDD §6.4 断言）：
##   - 获得即拥有、无研究状态机（ui_global tech_tree 占位面板文案同口径）；
##   - 知识随人走：每笔获得记来源（征服/人才/事件）与携带者（见 TechGrant）；
##   - 解锁池 = WorldState.unlocks（容器与存档已存在）——授予时 unlocks 字典
##     由调用方传入（api 层取 WorldState，单测注入自备字典，不依赖 autoload）。
## 机制面（待创始人科技设计定稿，本类不实现）：征服 → 自动授予规则（哪场仗给
## 哪个科技=策划）、人才流失吊销、大科学工程、法术法力消耗口径。
## 旧研制口径 config/tech/techs.tres 不消费（research_cost 字段与征服制冲突），
## 归属待科技设计定稿处置。

signal tech_granted(tech_id: String, source: int)

## 三分类锚点（04 §一：制造 → manufacturing / 法术 → spell_techs / 管理 → admin_techs）
const MANUFACTURING_PATH := "res://config/manufacturing/manufacturing.tres"
const SPELL_TECHS_PATH := "res://config/tech/spell_techs.tres"
const ADMIN_TECHS_PATH := "res://config/tech/admin_techs.tres"

## 来源表 → 科技主分类（分类是结构：三张表即 GDD 三分类的锚点事实）
const _TABLE_CATEGORY := {
	MANUFACTURING_PATH: "manufacturing",
	SPELL_TECHS_PATH: "spell",
	ADMIN_TECHS_PATH: "admin",
}

var _techs: Dictionary = {}  # {tech_id: 行 Dictionary（含 category 来源分类）}
var _grants: Array = []      # TechGrant 获得时序
var _tables_loaded := false


# ─────────────────────────── 注册表 ────────────────────────────

func get_techs() -> Array:
	_ensure_loaded()
	return _techs.values()


func get_tech(tech_id: String) -> Dictionary:
	_ensure_loaded()
	return _techs.get(tech_id, {})


func has_tech(tech_id: String, unlocks: Dictionary) -> bool:
	return unlocks.has(tech_id)


func _ensure_loaded() -> void:
	if _tables_loaded:
		return
	_tables_loaded = true
	for path: String in _TABLE_CATEGORY:
		for row in _load_rows(path):
			var tech_id := String(row.get("id", ""))
			if tech_id.is_empty():
				continue
			if _techs.has(tech_id):
				push_warning("[TechnologyManager] 科技 id 跨表重复，先表生效: %s" % tech_id)
				continue
			# 拷贝行并盖上来源分类（分类随表，不占策划列）
			var merged: Dictionary = row.duplicate()
			merged["category"] = _TABLE_CATEGORY[path]
			_techs[tech_id] = merged


## 装载占位表（ProfessionRegistry 同款：直读 .tres 不依赖 autoload 顺序）
static func _load_rows(path: String) -> Array:
	if not ResourceLoader.exists(path):
		push_warning("[TechnologyManager] 占位表不存在: %s" % path)
		return []
	var res: Resource = load(path)
	if res == null or not (res is BalanceResource):
		push_warning("[TechnologyManager] 占位表加载失败: %s" % path)
		return []
	return BalanceResource.sanitized_rows(res)


# ─────────────────────────── 授予（征服获得制） ────────────────────────────

## 授予一笔科技：写解锁池（unlocks 由调用方传入）+ 记获得来源与携带者。
## 幂等方向：重复授予拒绝（获得即拥有——已拥有无须再获得）。
func grant_tech(tech_id: String, source: TechGrant.Source,
		carrier_stickman_id: String, unlocks: Dictionary,
		granted_at := 0.0) -> Dictionary:
	_ensure_loaded()
	if not _techs.has(tech_id):
		return {"ok": false, "error": "未知科技 id: %s" % tech_id}
	if unlocks.has(tech_id):
		return {"ok": false, "error": "已拥有该科技: %s" % tech_id}
	unlocks[tech_id] = true
	var grant := TechGrant.new()
	grant.tech_id = tech_id
	grant.source = source
	grant.carrier_stickman_id = carrier_stickman_id
	grant.granted_at = granted_at
	_grants.append(grant)
	tech_granted.emit(tech_id, source)
	return {"ok": true, "grant": grant.to_dict()}


func get_grants() -> Array:
	return _grants


# ─────────────────────────── 存档 round-trip ────────────────────────────

## 获得记录落档（解锁池本体在 WorldState.unlocks 自带存档，此处只记来源明细）。
func to_dict() -> Dictionary:
	var grants: Array = []
	for grant in _grants:
		grants.append(grant.to_dict())
	return {"grants": grants}


func from_dict(data: Dictionary) -> void:
	_grants.clear()
	for d in data.get("grants", []):
		if not (d is Dictionary):
			continue
		_grants.append(TechGrant.from_dict(d))


# ─────────────────────────── 存档行（inventory/WorldState 同款契约） ────────────────────────────

const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'technology'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'technology'"

## 存档回调：获得记录写 world_state 模块行（解锁池本体在 WorldState.unlocks
## 自带存档，此处只落来源明细；由 TechnologyAPI 单例首建时挂接）。
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "technology",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[TechnologyManager] 存档行写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


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
