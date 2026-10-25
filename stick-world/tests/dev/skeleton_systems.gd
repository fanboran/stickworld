extends Control
## 程序先行骨架的灰盒验收台（tests/dev 惯例：不进 CI，主菜单开发构建自动收录）。
##
## 每列一个模块：按钮触发骨架做实的操作（占位表装载/CRUD/习得/颁布/定名），
## 日志面板打印 Result；守卫按钮演示"机制面待设计定稿"的拒绝口径。
## 内容全为占位（id placeholder 前缀/数值统一 10）——策划与美术内容一概未填。
## 生产 UI 不建：正式界面接入点见 ui_global 占位面板（placeholder_presets.gd）。

var _lgx_seq := 0
var _bp_seq := 0


func _ready() -> void:
	var pairs: Array = [
		["VB/Modules/LogisticsBox/BtnLgxAdd", _lgx_add],
		["VB/Modules/LogisticsBox/BtnLgxRemove", _lgx_remove],
		["VB/Modules/LogisticsBox/BtnLgxTables", _lgx_tables],
		["VB/Modules/LogisticsBox/BtnLgxAssign", _lgx_assign],
		["VB/Modules/SkillBox/BtnSkillLearn", _skill_learn],
		["VB/Modules/SkillBox/BtnSkillDup", _skill_learn_dup],
		["VB/Modules/SkillBox/BtnSkillLedger", _skill_ledger],
		["VB/Modules/AchBox/BtnAchUnlock", _ach_unlock],
		["VB/Modules/AchBox/BtnAchAgain", _ach_unlock_again],
		["VB/Modules/AchBox/BtnAchRecords", _ach_records],
		["VB/Modules/BpBox/BtnBpCreate", _bp_create],
		["VB/Modules/BpBox/BtnBpRetire", _bp_retire],
		["VB/Modules/BpBox/BtnBpDerive", _bp_derive],
		["VB/Modules/BpBox/BtnBpDag", _bp_dag],
		["VB/Modules/LawBox/BtnLawEnact", _law_enact],
		["VB/Modules/LawBox/BtnLawRepeal", _law_repeal],
		["VB/Modules/LawBox/BtnLawList", _law_list],
	]
	for pair in pairs:
		var btn: Button = get_node_or_null(pair[0])
		if btn != null:
			btn.pressed.connect(pair[1])
	_log("就绪——点按钮触发各模块做实操作；内容全占位，守卫按钮演示待设计拒绝。")


# ─────────────────────────── 物流 ────────────────────────────

func _lgx_add() -> void:
	_lgx_seq += 1
	var r := LogisticsAPI.add_transport_plan("占位运输队01", "占位矿山%02d" % _lgx_seq,
			"占位仓库", "mat_stone", TransportPlan.CargoKind.ITEM, 10, 10,
			TransportPlan.Priority.MEDIUM)
	_log("[物流] +运输计划（挂占位运输队01）→ %s" % str(r))


func _lgx_remove() -> void:
	var plans: Array = LogisticsAPI.get_transport_plans()
	if plans.is_empty():
		_log("[物流] 无计划可删")
		return
	var r := LogisticsAPI.remove_transport_plan(plans[plans.size() - 1].id)
	_log("[物流] -最后计划 → %s" % str(r))


func _lgx_tables() -> void:
	_log("[物流] 占位表：载体 %d 行（载体/载具并一）/ 道路 %d 行；计划 %d 条" % [
		LogisticsAPI.get_carriers().size(), LogisticsAPI.get_roads().size(),
		LogisticsAPI.get_transport_plans().size()])


func _lgx_assign() -> void:
	_log("[物流] 承运人派工（守卫）→ %s" % str(LogisticsAPI.assign_carrier("tp_001", 0)))


# ─────────────────────────── 技能台账 ────────────────────────────

func _skill_learn() -> void:
	var sid := _first_skill_id()
	var r := SkillAPI.learn_skill(sid, "占位角色01", SkillRecord.Source.TRAINING, "占位师傅")
	_log("[技能] 习得 %s（占位角色01，训练/师承占位师傅）→ %s" % [sid, str(r)])


func _skill_learn_dup() -> void:
	var sid := _first_skill_id()
	SkillAPI.learn_skill(sid, "占位角色02", SkillRecord.Source.BIRTH)
	var r := SkillAPI.learn_skill(sid, "占位角色02", SkillRecord.Source.BIRTH)
	_log("[技能] 重复习得 %s → %s（会/不会二元，已会拒绝）" % [sid, str(r)])


func _skill_ledger() -> void:
	var records: Array = SkillAPI.get_records()
	if records.is_empty():
		_log("[技能] 台账为空（定义表 %d 项占位技能，三类：制造/使用/组织）" % SkillAPI.get_skills().size())
		return
	var parts: Array = []
	for record in records:
		parts.append("%s会%s" % [record.holder_id, record.skill_id])
	_log("[技能] 台账 %d 条：%s；阵营会占位技能01 = %s" % [
		records.size(), "；".join(parts), str(SkillAPI.faction_knows(_first_skill_id()))])


# ─────────────────────────── 成就 ────────────────────────────

func _ach_unlock() -> void:
	var r := AchievementAPI.unlock(_first_ach_id(), {"占位快照": 10})
	_log("[成就] 解锁 %s → %s" % [_first_ach_id(), str(r)])


func _ach_unlock_again() -> void:
	var r := AchievementAPI.unlock(_first_ach_id())
	_log("[成就] 重复解锁 → %s（幂等：收藏不膨胀）" % str(r))


func _ach_records() -> void:
	var records: Array = AchievementAPI.get_records()
	if records.is_empty():
		_log("[成就] 暂无解锁（占位定义 %d 枚）" % AchievementAPI.get_achievement_defs().size())
		return
	var parts: Array = []
	for record in records:
		parts.append(record.def_id)
	_log("[成就] 已解锁 %d 枚：%s" % [records.size(), "；".join(parts)])


# ─────────────────────────── 谱系 ────────────────────────────

func _bp_create() -> void:
	_bp_seq += 1
	var parents: Array = []
	var actives: Array = BlueprintAPI.get_blueprints(false)
	if not actives.is_empty():
		parents = [actives[actives.size() - 1].id]
	var r := BlueprintAPI.create_blueprint("占位蓝图%02d" % _bp_seq,
			BlueprintNode.Kind.FORMATION_TEMPLATE, parents)
	_log("[谱系] 定名（%s）→ %s" % ["带母本" if not parents.is_empty() else "根", str(r)])


func _bp_retire() -> void:
	var actives: Array = BlueprintAPI.get_blueprints(false)
	if actives.is_empty():
		_log("[谱系] 无在役蓝图可退役")
		return
	var bid: String = actives[actives.size() - 1].id
	var r := BlueprintAPI.retire_blueprint(bid)
	_log("[谱系] 退役 %s → %s（归荣誉档案不删除）" % [bid, str(r)])


func _bp_derive() -> void:
	var actives: Array = BlueprintAPI.get_blueprints(false)
	if actives.is_empty():
		_log("[谱系] 先定名一枚母本")
		return
	var r := BlueprintAPI.derive_blueprint(actives[0].id, "占位衍生")
	_log("[谱系] 派生（守卫）→ %s" % str(r))


func _bp_dag() -> void:
	_log("[谱系] DAG 校验 = %s；在役 %d / 全量 %d（槽位占位上限 %d）" % [
		str(BlueprintAPI.is_acyclic()), BlueprintAPI.active_count(),
		BlueprintAPI.get_blueprints(true).size(), 10])


# ─────────────────────────── 法律 ────────────────────────────

func _law_enact() -> void:
	var r := LawAPI.enact_law(_first_law_id())
	_log("[法律] 颁布 %s → %s" % [_first_law_id(), str(r)])


func _law_repeal() -> void:
	var enacted: Array = LawAPI.get_enacted_laws()
	if enacted.is_empty():
		_log("[法律] 颁布集为空，无可废除")
		return
	var law_id := String(enacted[0])
	var r := LawAPI.repeal_law(law_id)
	_log("[法律] 废除 %s → %s（废除代价机制见守卫：待设计定稿）" % [law_id, str(r)])


func _law_list() -> void:
	_log("[法律] 颁布集 %d 条：%s（占位定义 %d 条）" % [
		LawAPI.get_enacted_laws().size(),
		"，".join(PackedStringArray(LawAPI.get_enacted_laws())),
		LawAPI.get_laws().size()])


# ─────────────────────────── 辅助 ────────────────────────────

func _first_skill_id() -> String:
	var defs: Array = SkillAPI.get_skills()
	return String(defs[0].get("id", "")) if not defs.is_empty() else ""


func _first_ach_id() -> String:
	var defs: Array = AchievementAPI.get_achievement_defs()
	return String(defs[0].get("id", "")) if not defs.is_empty() else ""


func _first_law_id() -> String:
	var laws: Array = LawAPI.get_laws()
	return String(laws[0].get("id", "")) if not laws.is_empty() else ""


func _log(msg: String) -> void:
	var rtl: RichTextLabel = get_node_or_null("VB/Log")
	if rtl != null:
		rtl.append_text(msg + "\n")
