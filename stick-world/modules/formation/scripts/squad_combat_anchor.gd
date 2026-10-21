extends RefCounted
## 战斗驻防锚助手 —— 从 formation_system.gd 拆出的远程槽位锚定子域（批5）。
##
## SWL 阵地战真相：远程组（CASTERS/ARCHERS）接战后按 Formation 槽位**原地成排**
## 齐射，阵线 x 由队伍 GetFormationPositionX 外生给定——不从成员实时质心回引
##（后列归位会把质心越拖越退，方阵整体后爬不收敛）。本层等价：
##   - 接战冻结：任一成员主手射程内有敌 → 以当刻班质心+平均面向冻结锚（外生锚）；
##   - 危险重冻结：敌方压近锚线（< 成员最短射程 × COMBAT_ANCHOR_DANGER_RATIO）→
##     以当前质心重冻结——方阵整体有序后撤（MoveInFormation 队伍平移语义）；
##   - 脱战清除：全员射程内无敌 → 清锚，下次接战在新战线重冻结；
##   - 消费方：BehaviorAttack 远程射程内分支按宿主 get_unit_combat_slot 走位收拢方阵。
##
## 纪律：锚状态挂 _squads[squad_id]["combat_anchor"]（随班存亡，宿主持有）；
## _combat_anchor_timer/combat_anchor_enabled/槽位几何（_slot_world/_squad_anchor）
## 全留宿主，经 _host 回引读写；本类无自持状态。

var _host  ## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）


func _init(host) -> void:
	_host = host


## 战斗锚 tick（宿主 _process 驱动，COMBAT_ANCHOR_TICK 节流）。
func tick_combat_anchors(delta: float) -> void:
	_host._combat_anchor_timer -= delta
	if _host._combat_anchor_timer > 0.0:
		return
	_host._combat_anchor_timer = _host.COMBAT_ANCHOR_TICK
	for squad_id in _host._squads.keys():
		var squad: Dictionary = _host._squads[squad_id]
		var engaged: bool = false
		var min_range: float = 1.0e9
		var probe: Node = null
		for u in squad["units"]:
			if not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
				continue
			if _host._member_enemy_in_range(u):
				engaged = true
			var w: Node = u.get_weapon() if u.has_method("get_weapon") else null
			if w != null and "attack_range" in w:
				min_range = minf(min_range, float(w.attack_range))
			probe = u
		if not engaged:
			if squad.has("combat_anchor"):
				squad.erase("combat_anchor")
			continue
		var anchor: Dictionary = squad.get("combat_anchor", {})
		if not anchor.is_empty() and anchor_in_danger(anchor["pos"], probe, min_range):
			# 危险重冻结回落纯质心（不带走射程前置）：前置是给"首停者在最大
			# 射程"的初冻结补纵深预算的；重冻结若再 +depth，锚每拍向敌前爬
			# 一格纵深——被近战压住时整班被吸进绞肉团（slotv2 探针蓝班实录）
			var back: Dictionary = _host._squad_anchor(squad_id)
			squad["combat_anchor"] = {"pos": back["centroid"], "facing": back["facing"]}
			continue
		if anchor.is_empty():
			var fr: Dictionary = _host._squad_anchor(squad_id)
			if fr["facing"] == Vector2.ZERO:
				continue  # 无可计成员（全桩无位置），不冻结
			squad["combat_anchor"] = {
				"pos": combat_anchor_pos(squad_id, fr),
				"facing": fr["facing"],
			}


## 锚线是否已被敌方压近（危险重冻结判定）：锚点到最近存活敌 < min_range × 比。
## probe 取班内任一存活成员（借道其战斗实例查敌列表）；无战斗/无武器档跳过。
func anchor_in_danger(pos: Vector2, probe: Node, min_range: float) -> bool:
	if probe == null or min_range >= 1.0e9:
		return false
	if not probe.has_method("get_battle_instance"):
		return false
	var bi: Node = probe.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_enemies_of"):
		return false
	var faction: int = probe.get_faction() if probe.has_method("get_faction") else 0
	if faction == 0:
		return false
	var danger: float = min_range * _host.COMBAT_ANCHOR_DANGER_RATIO
	for e in bi.get_enemies_of(faction):
		if e == null or not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if pos.distance_to(e.global_position) < danger:
			return true
	return false


## 战斗锚落点（批5 视觉修正：方阵整体入射程）：槽位前列贴锚、后列沿面向反侧
## 退纵深——若锚冻在最前接战成员位（= 首停者的射程线），末列再退纵深就掉出
## 射程哑火站桩。落法：锚（前列线）= 班内最前投影 + 面向×纵深，让**末列**恰贴
## 射程线、前列更近照样打；横向（垂直面向）分量取班质心。
func combat_anchor_pos(squad_id: String, fr: Dictionary) -> Vector2:
	var facing: Vector2 = fr["facing"]
	var depth: float = squad_block_depth(squad_id)
	var front_proj: float = -1.0e9
	if _host._squads.has(squad_id):
		for u in _host._squads[squad_id]["units"]:
			if not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
				continue
			if not ("global_position" in u):
				continue
			front_proj = maxf(front_proj, u.global_position.dot(facing))
	if front_proj <= -1.0e8:
		return fr["centroid"]
	return fr["centroid"] + facing * (front_proj + depth - fr["centroid"].dot(facing))


## 班方阵纵深（px）：槽位最大列 × 列间距（无槽位/单列 = 0）
func squad_block_depth(squad_id: String) -> float:
	if not _host._squads.has(squad_id):
		return 0.0
	var max_col: int = -1
	for slot in (_host._squads[squad_id].get("slots", {}) as Dictionary).values():
		max_col = maxi(max_col, (slot as Vector2i).x)
	return float(maxi(max_col, 0)) * _host.ROW_GAP


## 单位的战斗驻防槽位（BehaviorAttack 远程射程内分支消费；宿主壳委托）：
## 战线优先（组级方阵，SWL 阵线语义），无战线回落班战斗锚。
## 无班/无锚/无槽位/总闸关闭返回 Vector2.INF（消费方回落原站桩语义）。
func unit_combat_slot(unit: Node) -> Vector2:
	var line_slot: Vector2 = _host.get_unit_line_slot(unit)
	if not is_inf(line_slot.x):
		return line_slot
	if not _host.combat_anchor_enabled:
		return Vector2.INF
	if unit == null or not is_instance_valid(unit):
		return Vector2.INF
	var squad_id: String = _host._unit_to_squad.get(unit.get_instance_id(), "")
	if squad_id.is_empty() or not _host._squads.has(squad_id):
		return Vector2.INF
	var squad: Dictionary = _host._squads[squad_id]
	var anchor: Dictionary = squad.get("combat_anchor", {})
	if anchor.is_empty():
		return Vector2.INF
	var slot: Vector2i = (squad.get("slots", {}) as Dictionary).get(
			unit.get_instance_id(), Vector2i(-1, -1))
	if slot.x < 0:
		return Vector2.INF
	return _host._slot_world(slot, anchor["pos"], anchor["facing"], squad_id)
