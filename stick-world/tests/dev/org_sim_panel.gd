extends Control
## 组织系统数值模拟台（组织本位可行性研究工装；tests/dev 惯例：不进 CI）。
##
## 纯数值面板、零美术：人口/建筑/组织是面板自带的假实体层（字典），机制层全走
## 真代码——槽位板/明面前提(OrgPrereqs)/技能台账(SkillAPI)/训练推进器(TrainingPost)。
## 可行性研究三看点：
##   - 明面前提：加「科研」槽逐条 ✓/✗（在编有人会/属性达标——特例制，至多一两条）
##   - 隐形前提：拆掉训练营 → 训练停摆不报错（运转物理，不以「不许建」表现）
##   - 组织对组织训练：班训排可、班训营拒（受训层级 ≤ 训练层级+1）；
##     属性 0~10 内部进度制（越高越难涨），技能习得记教学教官
## 数值全占位 [待定]；生产 UI 不在此建。
## _ready 与正片装配同口径重置进程级单例（本场景即一个独立"局"）。

const TRAIN_FUNCTION := "训练"
const RESEARCH_FUNCTION := "科研"
const EXPERT_SKILL := "placeholder_skill_org_01"
const USE_SKILL := "placeholder_skill_use_01"
## 职能→建筑占位映射（待内容；未映射职能无建筑要求）
const FUNCTION_BUILDINGS := {"训练": "训练营"}

var _post: TrainingPost
var _people: Array = []       # [{id, name, attrs{str/int/agi/cft/cmd}, org}]
var _orgs: Dictionary = {}    # {org_id: {name, tier, personnel: [id...]}}
var _buildings := {"训练营": 0}
var _speed := 0               # 0=暂停 / 1 / 10 / 100
var _hours := 0.0
var _person_seq := 0
var _org_seq := 0
var _trainer_id := ""         # 末建的 L2 训练组织
var _army_id := ""            # 末建的 L3 步兵排
var _far_id := ""             # 末建的 L4 远征营
var _refresh_cd := 0.0


func _ready() -> void:
	_reset_singletons()
	_post = TrainingPost.new()  # 不进树：面板自管模拟时钟（advance 直调）
	_post.setup(_org_info, _building_present, _attr_read, _attr_write)
	_post.training_completed.connect(_on_training_completed)
	_post.arrangement_cancelled.connect(_on_arrangement_cancelled)
	var pairs: Array = [
		["VB/TimeRow/BtnPause", _speed_pause], ["VB/TimeRow/BtnX1", _speed_1],
		["VB/TimeRow/BtnX10", _speed_10], ["VB/TimeRow/BtnX100", _speed_100],
		["VB/Body/PeopleBox/BtnPerson", _add_person], ["VB/Body/PeopleBox/BtnExpert", _add_expert],
		["VB/Body/BuildBox/BtnBuild", _build], ["VB/Body/BuildBox/BtnRaze", _raze],
		["VB/Body/OrgBox/BtnOrgTrainer", _org_trainer], ["VB/Body/OrgBox/BtnOrgArmy", _org_army],
		["VB/Body/OrgBox/BtnOrgFar", _org_far], ["VB/Body/OrgBox/BtnDisband", _org_disband],
		["VB/Body/SlotBox/BtnSlotTrain", _slot_train], ["VB/Body/SlotBox/BtnSlotResearch", _slot_research],
		["VB/Body/SlotBox/BtnTeacherIn", _teacher_in], ["VB/Body/SlotBox/BtnPrereqPeek", _prereq_peek],
		["VB/Body/TrainBox/BtnArrStr", _arr_str], ["VB/Body/TrainBox/BtnArrSkill", _arr_skill],
		["VB/Body/TrainBox/BtnArrFar", _arr_far], ["VB/Body/TrainBox/BtnArrCancel", _arr_cancel],
	]
	for pair in pairs:
		var btn: Button = get_node_or_null(pair[0])
		if btn != null:
			btn.pressed.connect(pair[1])
	_log("就绪——按 ①→⑤ 顺序点：人口 → 盖训练营 → 建组织 → 开槽派教官 → 发起训练，再开 10×/100× 观演。")
	_refresh()


func _process(delta: float) -> void:
	if _speed > 0:
		var dt := delta * float(_speed)
		_hours += dt
		_post.advance(dt)
		_refresh_cd -= delta
		if _refresh_cd <= 0.0:
			_refresh_cd = 0.25
			_refresh()


# ─────────────────────────── 时间 ────────────────────────────

func _speed_pause() -> void: _set_speed(0, "暂停")
func _speed_1() -> void: _set_speed(1, "1×")
func _speed_10() -> void: _set_speed(10, "10×")
func _speed_100() -> void: _set_speed(100, "100×")


func _set_speed(v: int, label: String) -> void:
	_speed = v
	(get_node("VB/TimeRow/BtnPause") as Button).button_pressed = v == 0
	_log("[时间] %s" % label)
	_refresh()


# ─────────────────────────── ① 人口 ────────────────────────────

func _add_person() -> void:
	_person_seq += 1
	_people.append({
		"id": "sim_p%02d" % _person_seq,
		"name": "村民%02d" % _person_seq,
		"attrs": _roll_attrs(),
		"org": "",
	})
	_refresh()


func _add_expert() -> void:
	_person_seq += 1
	var pid := "sim_p%02d" % _person_seq
	_people.append({"id": pid, "name": "行家%02d" % _person_seq,
			"attrs": _roll_attrs(), "org": ""})
	var r := SkillAPI.learn_skill(EXPERT_SKILL, pid, SkillRecord.Source.BIRTH)
	_log("[人口] +行家（自带 %s）→ %s" % [EXPERT_SKILL, "已会" if r.get("ok") else str(r)])
	_refresh()


func _roll_attrs() -> Dictionary:
	var out := {}
	for key in TrainingPost.ATTR_KEYS:
		out[key] = randi() % 11  # 0~10 均匀占位 [待定]
	return out


func _person(pid: String) -> Dictionary:
	for p in _people:
		if String(p.get("id")) == pid:
			return p
	return {}


# ─────────────────────────── ② 建筑 ────────────────────────────

func _build() -> void:
	_buildings["训练营"] = int(_buildings.get("训练营", 0)) + 1
	_log("[建筑] +训练营（训练职能的隐形前提：在场才运转）")
	_refresh()


func _raze() -> void:
	_buildings["训练营"] = maxi(int(_buildings.get("训练营", 0)) - 1, 0)
	_log("[建筑] -训练营（在场 %d → 训练将停摆，进度不丢）" % _buildings["训练营"])
	_refresh()


# ─────────────────────────── ③ 组织 ────────────────────────────

func _org_trainer() -> void:
	var idle := _idle_ids()
	if idle.is_empty():
		_log("[组织] 无待业人口，先 ① 加人")
		return
	_org_seq += 1
	var org_id := "sim_trainer%02d" % _org_seq
	_orgs[org_id] = {"name": "训练组织%02d(L2)" % _org_seq, "tier": 2, "personnel": [idle[0]]}
	_set_org(idle[0], org_id)
	_trainer_id = org_id
	_log("[组织] 建训练组织 L2（%s 收编 1 人当教官候选）" % org_id)
	_refresh()


func _org_army() -> void:
	_make_army(3, "步兵排", "_army_id")


func _org_far() -> void:
	_make_army(4, "远征营", "_far_id")


func _make_army(tier: int, label: String, slot: String) -> void:
	var idle := _idle_ids()
	if idle.is_empty():
		_log("[组织] 无待业人口，先 ① 加人")
		return
	_org_seq += 1
	var org_id := "sim_army%02d" % _org_seq
	_orgs[org_id] = {"name": "%s%02d(L%d)" % [label, _org_seq, tier],
			"tier": tier, "personnel": idle.duplicate()}
	for pid in idle:
		_set_org(pid, org_id)
	set(slot, org_id)
	_log("[组织] 建%s L%d（%s 收编待业 %d 人整建制）" % [label, tier, org_id, idle.size()])
	_refresh()


func _org_disband() -> void:
	if _orgs.is_empty():
		return
	var org_id: String = String(_orgs.keys().back())
	for pid in _orgs[org_id].personnel:
		_set_org(pid, "")
	_orgs.erase(org_id)
	OrgSlotSystem.on_org_removed(org_id)  # 与正片 api 同口径：槽位随组织清理
	for key in ["_trainer_id", "_army_id", "_far_id"]:
		if String(get(key)) == org_id:
			set(key, "")
	_log("[组织] 解散 %s（人员回池，槽位与机构引用随之清理）" % org_id)
	_refresh()


# ─────────────────────────── ④ 职能槽（明面前提） ────────────────────────────

func _slot_train() -> void:
	if _trainer_id.is_empty():
		_log("[槽位] 先建训练组织")
		return
	var r := OrgSlotSystem.add_slot(_trainer_id, TRAIN_FUNCTION)
	_log("[槽位] 开「%s」槽 → %s（未标注职能无明面前提）" % [TRAIN_FUNCTION, _r(r)])
	_refresh()


func _slot_research() -> void:
	if _trainer_id.is_empty():
		_log("[槽位] 先建训练组织")
		return
	var r := OrgSlotSystem.add_slot(_trainer_id, RESEARCH_FUNCTION)
	_log("[槽位] 开「%s」槽 → %s" % [RESEARCH_FUNCTION, _r(r)])
	_refresh()


func _teacher_in() -> void:
	if _trainer_id.is_empty():
		_log("[槽位] 先建训练组织")
		return
	var personnel: Array = _orgs[_trainer_id].personnel
	if personnel.is_empty():
		_log("[槽位] 组织无在编")
		return
	var r := OrgSlotSystem.assign_person(_trainer_id, TRAIN_FUNCTION, personnel[0])
	_log("[槽位] 教官 %s 入「%s」槽 → %s" % [personnel[0], TRAIN_FUNCTION, _r(r)])
	_refresh()


func _prereq_peek() -> void:
	if _trainer_id.is_empty():
		_log("[前提] 先建训练组织")
		return
	var r := OrgSlotSystem.check_prereqs(_trainer_id, RESEARCH_FUNCTION)
	for row in r.get("results", []):
		_log("[前提] %s %s（%s）" % ["✓" if row.get("passed") else "✗",
				row.get("label"), _trainer_id])
	if (r.get("results") as Array).is_empty():
		_log("[前提] 「%s」无明面前提行（特例制：没标注=无门槛）" % RESEARCH_FUNCTION)


# ─────────────────────────── ⑤ 训练（组织对组织） ────────────────────────────

func _arr_str() -> void: _arrange(_army_id, "attribute", "str")
func _arr_skill() -> void: _arrange(_army_id, "skill", USE_SKILL)
func _arr_far() -> void: _arrange(_far_id, "attribute", "str")


func _arrange(target_org: String, kind: String, target: String) -> void:
	if _trainer_id.is_empty() or target_org.is_empty():
		_log("[训练] 先建训练组织与目标编制组织（受训方要整建制在场）")
		return
	var r := _post.add_arrangement(_trainer_id, TRAIN_FUNCTION, target_org, kind, target)
	_log("[训练] 安排 %s ← %s（%s：%s）→ %s" % [_orgs[target_org].name,
			_orgs[_trainer_id].name, kind, target, _r(r)])
	_refresh()


func _arr_cancel() -> void:
	var arrs := _post.get_arrangements()
	if arrs.is_empty():
		return
	_post.remove_arrangement(String(arrs.back().get("id")))
	_log("[训练] -末安排")
	_refresh()


# ─────────────────────────── provider（假实体层 → 真机制） ────────────────────────────

func _org_info(org_id: String) -> Dictionary:
	if not _orgs.has(org_id):
		return {"ok": false}
	var o: Dictionary = _orgs[org_id]
	return {"ok": true, "tier": int(o.get("tier", 0)),
			"personnel": (o.get("personnel") as Array).duplicate()}


func _building_present(function_name: String) -> bool:
	var building := String(FUNCTION_BUILDINGS.get(function_name, ""))
	if building.is_empty():
		return true  # 未映射职能无建筑要求（映射表待内容）
	return int(_buildings.get(building, 0)) > 0


func _attr_read(holder_id: String, attr_key: String) -> float:
	var p := _person(holder_id)
	if p.is_empty():
		return -1.0
	return float((p.get("attrs") as Dictionary).get(attr_key, -1.0))


func _attr_write(holder_id: String, attr_key: String, delta: int) -> float:
	var p := _person(holder_id)
	if p.is_empty():
		return -1.0
	var attrs: Dictionary = p.get("attrs")
	var v := clampf(float(attrs.get(attr_key, 0.0)) + float(delta), 0.0, 10.0)
	attrs[attr_key] = v
	return v


func _idle_ids() -> Array:
	var out: Array = []
	for p in _people:
		if String(p.get("org")) == "":
			out.append(p.get("id"))
	return out


func _set_org(pid: String, org_id: String) -> void:
	var p := _person(pid)
	if not p.is_empty():
		p.org = org_id


# ─────────────────────────── 状态面板 ────────────────────────────

func _refresh() -> void:
	var clock: Label = get_node_or_null("VB/TimeRow/LblClock")
	if clock != null:
		clock.text = "模拟时钟 %.1f 游戏小时（%s）" % [_hours,
				"暂停" if _speed == 0 else "%d×" % _speed]
	var sb := ""
	sb += "── 人口（%d 待业 %d）── 建筑：%s\n" % [_people.size(), _idle_ids().size(),
			str(_buildings)]
	for p in _people:
		var skills: Array = SkillAPI.skills_of(String(p.get("id")))
		var org_label := "待业" if String(p.get("org")) == "" else String(p.get("org"))
		sb += "  %s [%s] str%d/int%d/agi%d/cft%d/cmd%d %s\n" % [p.get("name"), org_label,
				(p.get("attrs") as Dictionary).get("str"), (p.get("attrs") as Dictionary).get("int"),
				(p.get("attrs") as Dictionary).get("agi"), (p.get("attrs") as Dictionary).get("cft"),
				(p.get("attrs") as Dictionary).get("cmd"),
				("会:" + ",".join(skills)) if not skills.is_empty() else ""]
	sb += "── 组织 ──\n"
	for org_id in _orgs:
		var o: Dictionary = _orgs[org_id]
		sb += "  %s %s（在编 %d）\n" % [org_id, o.get("name"),
				(o.get("personnel") as Array).size()]
		for slot in OrgSlotSystem.get_slots(String(org_id)):
			sb += "    槽「%s」 %s 人%s 机构%s\n" % [slot.get("function"),
					"●运转" if slot.get("active") else "○空转",
					str((slot.get("persons") as Array).size()),
					String(slot.get("institution"))]
	sb += "── 训练安排 ──\n"
	var arrs := _post.get_arrangements()
	if arrs.is_empty():
		sb += "  （无——训练组织←受训组织整建制受训）\n"
	for arr in arrs:
		var trainee: Dictionary = _orgs.get(String(arr.get("trainee_org")), {})
		sb += "  %s %s:%s ← %s" % [String(arr.get("id")), arr.get("target_kind"),
				arr.get("target_id"), trainee.get("name", "?")]
		var slot_active := OrgSlotSystem.is_slot_active(String(arr.get("trainer_org")),
				String(arr.get("function")))
		var building_ok := _building_present(String(arr.get("function")))
		sb += "  %s\n" % ("运转中" if slot_active and building_ok
				else "停摆（%s）" % ("教官不在槽" if not slot_active else "缺建筑"))
		var progress: Dictionary = arr.get("progress")
		for pid in trainee.get("personnel", []):
			var bar := _bar(float(progress.get(pid, 0.0)))
			var p := _person(String(pid))
			sb += "    %s %s\n" % [p.get("name", pid) if not p.is_empty() else pid, bar]
	var status: RichTextLabel = get_node_or_null("VB/Status")
	if status != null:
		status.clear()
		status.append_text(sb)


func _bar(v: float) -> String:
	var filled := int(v / 10.0)
	return "▓".repeat(filled) + "░".repeat(10 - filled) + " %.0f/100" % v


func _reset_singletons() -> void:
	OrgSlotSystem.reset_for_new_run()
	OrgSlotSystem.instance()
	SkillAPI.reset_for_new_run()
	SkillAPI.prime()
	OrgPrereqs.set_providers(
		func(org_id: String) -> Array:
			if not _orgs.has(org_id):
				return []
			return _orgs[org_id].get("personnel", []),
		func(holder_id: String, attr_key: String) -> float: return _attr_read(holder_id, attr_key),
	)


func _r(r: Dictionary) -> String:
	return "✓" if r.get("ok") else "✗ %s" % String(r.get("error", ""))


func _on_training_completed(_arrangement_id: String, holder: String,
		kind: String, target: String) -> void:
	var p := _person(holder)
	var who := String(p.get("name", holder)) if not p.is_empty() else holder
	if kind == "attribute":
		_log("[完成] %s 练成 %s → %.0f" % [who, target, _attr_read(holder, target)])
	else:
		_log("[完成] %s 习得 %s（教学教官已记入台账）" % [who, target])
	_refresh()


func _on_arrangement_cancelled(_arrangement_id: String, reason: String) -> void:
	_log("[取消] %s" % reason)
	_refresh()


func _log(text: String) -> void:
	var log_rl: RichTextLabel = get_node_or_null("VB/Log")
	if log_rl != null:
		log_rl.append_text("%s\n" % text)
	print_verbose("[OrgSimPanel] %s" % text)
