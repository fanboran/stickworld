class_name TrainingPost
extends Node
## 训练推进器（04-科技系统 §三：训练=组织对组织）——常驻 GameRoot 的 Node
## （RecruitManager 同款装配，组织系统装配步内挂载）。
##
## 训练安排 =（训练组织, 训练职能槽, 受训组织, 目标）：
##   - 训练组织是普通组织：教官占其训练职能槽（≥1 人）；目标为技能时，
##     教学来源从槽上会该技能的教官中取（无人会则安排无从建立——知识来源的自然事实）
##   - 受训方是整只编制组织"开过来"受训（物理移动归行军/物流域，安排建立=就位）；
##     受训者 = 受训组织全体在编人员
##   - 层级对齐（01 §一）：受训组织 tier ≤ 训练组织 tier + 1——班训排、排训连
##   - 推进条件 = 职能运转（隐形前提，01 §2.5）：槽激活 × 对应建筑在场；
##     缺建筑 = 停摆不报错（进度保留）
##   - 内部进度制（17 §二）：每（受训者, 目标）进度 0~100，速率 = 基础 × 修正；
##     满 100 → 属性 +1（钳 0~10）或经 SkillAPI 习得（TRAINING 来源，记教学教官）
##   - 中断 = 停涨不丢；先满者留批（不再推进，散批条件 [待定]）；
##     任一方组织解散 → 安排取消
##
## 数值全占位 [待定]（数值模拟台可调观察）：BASE_RATE/DIMINISH 等。
## 依赖经注入（organization 零出向装配外依赖）：org_info/building/attr 读写
## 四 provider 由装配层注入；单测/模拟台直注假实现。

signal training_completed(arrangement_id: String, holder_id: String,
		target_kind: String, target_id: String)
signal arrangement_cancelled(arrangement_id: String, reason: String)

## 内部进度制常量（17 §二；数值占位 [待定]——模拟台观察后定稿）
const PROGRESS_PER_STEP := 100.0   # 每涨 1 点属性/得 1 项技能所需进度
const BASE_RATE := 10.0            # 基础速率（进度点/游戏小时）
const DIMINISH := 0.08             # 属性当前值每高 1 点的速率折减（越高越难涨）
const MIN_RATE_MODIFIER := 0.2     # 速率折减下限（线性增长≈修正 1.0 的对照锚）
## 基础属性键（stickman_entity.attributes 同键；17 §一）
const ATTR_KEYS: Array[String] = ["str", "int", "agi", "cft", "cmd"]

## 注入面（装配层/单测注入；组织模块零出向）：
##   org_info_provider(org_id) -> {ok, tier, personnel}（组织存在性与在编）
##   building_provider(function_name) -> bool（该职能对应建筑在场否——隐形前提）
##   attr_read(holder_id, attr_key) -> float / attr_write(holder_id, attr_key, +1) -> float（新值）
var _org_info: Callable = Callable()
var _building: Callable = Callable()
var _attr_read: Callable = Callable()
var _attr_write: Callable = Callable()

## [{id, trainer_org, function, trainee_org, target_kind, target_id,
##   teacher_holder_id, progress: {holder_id: 进度}}]
var _arrangements: Array = []
var _next_id: int = 1
var _last_game_time: float = -1.0


func setup(org_info_provider: Callable, building_provider: Callable,
		attr_read: Callable, attr_write: Callable) -> void:
	_org_info = org_info_provider
	_building = building_provider
	_attr_read = attr_read
	_attr_write = attr_write


# ─────────────────────────── 安排 CRUD ────────────────────────────

## 建立训练安排（Result）。target_kind ∈ {"attribute", "skill"}；
## attribute 的 target_id ∈ ATTR_KEYS，skill 的 target_id 为技能表 id。
func add_arrangement(trainer_org_id: String, function_name: String,
		trainee_org_id: String, target_kind: String, target_id: String) -> Dictionary:
	if trainer_org_id.is_empty() or trainee_org_id.is_empty() or function_name.is_empty():
		return {"ok": false, "error": "训练组织/职能槽/受训组织不能为空"}
	if target_kind != "attribute" and target_kind != "skill":
		return {"ok": false, "error": "目标类型必须是 attribute 或 skill"}
	if target_kind == "attribute" and not ATTR_KEYS.has(target_id):
		return {"ok": false, "error": "未知属性: %s（%s）" % [target_id, "、".join(ATTR_KEYS)]}
	var trainer: Dictionary = _org(trainer_org_id)
	if not trainer.get("ok", false):
		return {"ok": false, "error": "训练组织不存在: %s" % trainer_org_id}
	var trainee: Dictionary = _org(trainee_org_id)
	if not trainee.get("ok", false):
		return {"ok": false, "error": "受训组织不存在: %s" % trainee_org_id}
	# 层级对齐（01 §一）：班训排、排训连——受训 ≤ 训练 + 1
	var trainer_tier: int = int(trainer.get("tier", 0))
	var trainee_tier: int = int(trainee.get("tier", 0))
	if trainee_tier > trainer_tier + 1:
		return {"ok": false, "error": "层级超出：L%d 训练组织至多训 L%d 编制（受训 L%d）" \
				% [trainer_tier, trainer_tier + 1, trainee_tier]}
	# 教官：职能槽必须在且有人；技能目标取会该技能的教官为教学来源
	var slot := _find_slot(trainer_org_id, function_name)
	if slot.is_empty():
		return {"ok": false, "error": "训练组织无此职能槽: %s（%s）" % [function_name, trainer_org_id]}
	var persons: Array = slot.get("persons", [])
	if persons.is_empty():
		return {"ok": false, "error": "职能槽无人（教官缺位）: %s（%s）" % [function_name, trainer_org_id]}
	var teacher := ""
	if target_kind == "skill":
		for holder_id in persons:
			if SkillAPI.knows(String(holder_id), target_id):
				teacher = String(holder_id)
				break
		if teacher.is_empty():
			return {"ok": false, "error": "槽上教官无人会 %s，无从施训" % target_id}
	var trainee_personnel: Array = trainee.get("personnel", [])
	if trainee_personnel.is_empty():
		return {"ok": false, "error": "受训组织无在编人员: %s" % trainee_org_id}
	for arr in _arrangements:
		if arr.trainer_org == trainer_org_id and arr.function == function_name \
				and arr.trainee_org == trainee_org_id and arr.target_id == target_id:
			return {"ok": false, "error": "训练安排已存在: %s（%s ← %s）" \
					% [target_id, trainer_org_id, trainee_org_id]}
	var arrangement := {
		"id": "tp_%03d" % _next_id,
		"trainer_org": trainer_org_id,
		"function": function_name,
		"trainee_org": trainee_org_id,
		"target_kind": target_kind,
		"target_id": target_id,
		"teacher_holder_id": teacher,
		"progress": {},
	}
	_next_id += 1
	_arrangements.append(arrangement)
	return {"ok": true, "arrangement": arrangement.duplicate(true)}


func remove_arrangement(arrangement_id: String) -> Dictionary:
	for i in _arrangements.size():
		if _arrangements[i].id == arrangement_id:
			_arrangements.remove_at(i)
			return {"ok": true}
	return {"ok": false, "error": "训练安排不存在: %s" % arrangement_id}


## 安排全貌（面板展示；progress 深拷贝）。
func get_arrangements() -> Array:
	return _arrangements.map(func(a): return a.duplicate(true))


# ─────────────────────────── 推进 ────────────────────────────

func _process(_delta: float) -> void:
	if WorldState == null:
		return
	var now_value: Variant = WorldState.get("game_time")
	if not (now_value is float or now_value is int):
		return
	var now := float(now_value)
	if _last_game_time < 0.0:
		_last_game_time = now
		return
	var dt := now - _last_game_time
	_last_game_time = now
	if dt > 0.0:
		advance(dt)


## 推进 dt 游戏小时（测试直调；_process 按帧喂）。返回本次完成事件数组。
func advance(dt: float) -> Array:
	var completed: Array = []
	for arrangement in _arrangements.duplicate():
		var trainer: Dictionary = _org(String(arrangement.trainer_org))
		if not trainer.get("ok", false):
			_cancel(arrangement, "训练组织已不存在")
			continue
		var trainee: Dictionary = _org(String(arrangement.trainee_org))
		if not trainee.get("ok", false):
			_cancel(arrangement, "受训组织已不存在")
			continue
		# 职能运转（隐形前提）：槽激活 × 对应建筑在场——不满足=停摆不报错（进度保留）
		if not OrgSlotSystem.is_slot_active(String(arrangement.trainer_org), String(arrangement.function)):
			continue
		if _building.is_valid() and not bool(_building.call(String(arrangement.function))):
			continue
		for holder_id in trainee.get("personnel", []).duplicate():
			var holder := String(holder_id)
			var progress := _step_holder(arrangement, holder, dt, completed)
			if progress < 0.0:
				arrangement.progress.erase(holder)  # 已训成：清进度、留批
			else:
				arrangement.progress[holder] = progress
	return completed


## 单个受训者推进：攒速率×时长，跨过满额则落地（可能连跨多档）。
## 返回剩余进度（<0 = 该员已训成/已到顶：留批不再推进）。
func _step_holder(arrangement: Dictionary, holder: String, dt: float,
		completed: Array) -> float:
	var progress := float(arrangement.progress.get(holder, 0.0)) + _rate(arrangement, holder) * dt
	while progress >= PROGRESS_PER_STEP:
		progress -= PROGRESS_PER_STEP
		if arrangement.target_kind == "skill":
			if SkillAPI.knows(holder, String(arrangement.target_id)):
				return -1.0  # 已会（先满者）：留批不再推进
			var learned := SkillAPI.learn_skill(String(arrangement.target_id), holder,
					SkillRecord.Source.TRAINING, String(arrangement.teacher_holder_id))
			if learned.get("ok", false) or SkillAPI.knows(holder, String(arrangement.target_id)):
				completed.append({"arrangement_id": arrangement.id, "holder_id": holder,
						"target_kind": "skill", "target_id": arrangement.target_id})
				training_completed.emit(String(arrangement.id), holder,
						"skill", String(arrangement.target_id))
				return -1.0
		else:
			var value: float = float(_attr_read.call(holder, String(arrangement.target_id))) \
					if _attr_read.is_valid() else 10.0
			if float(value) >= 10.0:
				return -1.0  # 已到域顶：留批不再推进
			var new_value: Variant = _attr_write.call(holder, String(arrangement.target_id), 1) \
					if _attr_write.is_valid() else 10.0
			completed.append({"arrangement_id": arrangement.id, "holder_id": holder,
					"target_kind": "attribute", "target_id": arrangement.target_id,
					"new_value": new_value})
			training_completed.emit(String(arrangement.id), holder,
					"attribute", String(arrangement.target_id))
			if float(new_value) >= 10.0:
				return -1.0
	return progress


## 速率 = 基础 × 修正（17 §二，占位 [待定]）：属性目标随当前值递减（越高越难涨），
## 技能目标暂取基础速率。
func _rate(arrangement: Dictionary, holder: String) -> float:
	if arrangement.target_kind != "attribute":
		return BASE_RATE
	var value: Variant = _attr_read.call(holder, String(arrangement.target_id)) \
			if _attr_read.is_valid() else 0.0
	var modifier := maxf(1.0 - float(value) * DIMINISH, MIN_RATE_MODIFIER)
	return BASE_RATE * modifier


func _cancel(arrangement: Dictionary, reason: String) -> void:
	_arrangements.erase(arrangement)
	arrangement_cancelled.emit(String(arrangement.id), reason)


# ─────────────────────────── 内部 ────────────────────────────

func _org(org_id: String) -> Dictionary:
	if not _org_info.is_valid():
		return {"ok": false}
	var info: Variant = _org_info.call(org_id)
	return info if info is Dictionary else {"ok": false}


func _find_slot(org_id: String, function_name: String) -> Dictionary:
	for slot in OrgSlotSystem.get_slots(org_id):
		if String(slot.get("function", "")) == function_name:
			return slot
	return {}


# ─────────────────────────── 存档 round-trip 与模块行 ────────────────────────────

func to_dict() -> Dictionary:
	return {
		"next_id": _next_id,
		"arrangements": _arrangements.duplicate(true),
	}


func from_dict(data: Dictionary) -> void:
	_arrangements = []
	var rows: Array = data.get("arrangements", [])
	for row in rows:
		var progress := {}
		for holder_id in row.get("progress", {}):
			progress[String(holder_id)] = float(row["progress"][holder_id])
		_arrangements.append({
			"id": String(row.get("id", "")),
			"trainer_org": String(row.get("trainer_org", "")),
			"function": String(row.get("function", "")),
			"trainee_org": String(row.get("trainee_org", "")),
			"target_kind": String(row.get("target_kind", "")),
			"target_id": String(row.get("target_id", "")),
			"teacher_holder_id": String(row.get("teacher_holder_id", "")),
			"progress": progress,
		})
	_next_id = int(data.get("next_id", _arrangements.size() + 1))


const _SQL_ROW_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'org_training'"
const _SQL_ROW_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'org_training'"


func _ready() -> void:
	if EventBus != null and EventBus.has_signal("game_saving"):
		EventBus.game_saving.connect(_on_game_saving)
	if EventBus != null and EventBus.has_signal("game_loaded"):
		EventBus.game_loaded.connect(_on_game_loaded)


func _exit_tree() -> void:
	if EventBus == null:
		return
	if EventBus.game_saving.is_connected(_on_game_saving):
		EventBus.game_saving.disconnect(_on_game_saving)
	if EventBus.game_loaded.is_connected(_on_game_loaded):
		EventBus.game_loaded.disconnect(_on_game_loaded)


func _on_game_saving(slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	if db == null or slot_index < 0:
		return
	db.query_with_bindings(_SQL_ROW_DELETE, [slot_index])
	if not db.insert_row("world_state", {
		"slot_id": slot_index,
		"module_name": "org_training",
		"data": JSON.stringify(to_dict()),
	}):
		push_error("[TrainingPost] 存档行写入失败 slot=%d: %s" % [slot_index, str(db.error_message)])


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
