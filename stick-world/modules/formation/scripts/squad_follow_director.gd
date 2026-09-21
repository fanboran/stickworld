extends RefCounted
## 编队动态跟队助手 —— 从 formation_system.gd 拆出的锚定跟随子域
## （SWL MoveInFormationBehindAnotherFormation + GapBetweenFormationGroups 直译）。
##
## 职责：
## - update_follows：锚定小队落点维持（每 0.5s tick，与队伍目标决策共用节拍）；
## - update_follow：单个锚定小队的落点计算与成员号令下发；
## - follow_chain_has：锚定链防环检查（设 A→B 前检查 B 的前向链是否回到 A）。
##
## 落点语义（update_follow 内）：
##   1. 前队解散/全灭 → 解除锚定，后队转自主决策（SWL 前队全灭不再跟队）
##   2. 落点 = 前队质心 − 行进方向 × gap；行进方向取"后队质心 → 前队质心"
##      （停驻接敌时依然稳定，不依赖速度采样，天然左右军镜像）
##   3. 前队接敌 → 后队越过 gap 推进到战线支援（不带 hold 驻留，到位/接敌即
##      交还战斗决策）——否则前队缠斗时后队永远钉在 gap 处"全员卡死"
##   4. 未接战成员超出死区 → 重下 move 号令（hold_on_arrive 驻留 +
##      engage_in_range：敌进射程即 finish 交还战斗行为）
##
## 纪律：_squads 状态留宿主经 _host 动态回引；几何 var 参数（follow_default_gap/
## catchup_run_dist）由宿主壳每次调用传当前值（balance 可覆盖，严禁缓存快照）；
## FOLLOW_DEADZONE 为宿主常量，经 _host 读同一真相源。号令下发经宿主既有
## 查询/判定出口（get_squad_dest/_formation_position_is_stable/_member_enemy_in_range），
## 信号与号令副作用落点语义不变。

var _host  ## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）


func _init(host) -> void:
	_host = host


## 锚定小队落点维持（每 0.5s tick，与队伍目标决策共用节拍）：
## 逐队检查 follow_squad_id，锚定中的小队交 update_follow 维持。
func update_follows(follow_default_gap: float, catchup_run_dist: float) -> void:
	for squad_id in _host._squads.keys():
		if _host._squads[squad_id].get("follow_squad_id", "") != "":
			update_follow(squad_id, follow_default_gap, catchup_run_dist)


## 单个锚定小队的落点计算与成员号令下发。
func update_follow(squad_id: String, follow_default_gap: float, catchup_run_dist: float) -> void:
	var squad: Dictionary = _host._squads.get(squad_id, {})
	if squad.is_empty():
		return
	# 与"跟随玩家"模式互斥（跟随玩家由 BehaviorFollow 决策，锚定号令会打断它）
	if squad.get("follow_player", false):
		return
	var front_id: String = squad.get("follow_squad_id", "")
	if front_id.is_empty():
		return
	# 前队解散 → 解除锚定
	if not _host._squads.has(front_id):
		_host.clear_squad_follow(squad_id)
		return
	# 前队质心（仅存活成员；全灭 → 解除锚定转自主决策）
	var front_centroid := Vector2.ZERO
	var front_n: int = 0
	for u in _host._squads[front_id]["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			front_centroid += u.global_position
			front_n += 1
	if front_n == 0:
		_host.clear_squad_follow(squad_id)
		return
	front_centroid /= float(front_n)
	# 前队是否接敌（任一存活成员射程内有敌）：接敌 → 后队推进支援，不再钉在 gap 处
	var front_engaged: bool = false
	for u in _host._squads[front_id]["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()) \
				and _host._member_enemy_in_range(u):
			front_engaged = true
			break
	# 后队存活成员与质心
	var members: Array = []
	var my_centroid := Vector2.ZERO
	for u in squad["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			members.append(u)
			my_centroid += u.global_position
	if members.is_empty():
		return
	my_centroid /= float(members.size())
	# 行进方向：后队质心 → 前队质心（退化 = 两队重叠，维持原位不推；
	# 支援模式重叠时仍要推进，不提前返回）
	var dir: Vector2 = front_centroid - my_centroid
	if not front_engaged and dir.length_squared() < 1.0:
		return
	var anchor: Vector2 = front_centroid
	if not front_engaged:
		anchor = front_centroid - dir.normalized() * float(squad.get("follow_gap", follow_default_gap))
	# 成员号令下发（接战/撤退/找掩体/被附身成员不打断；玩家号令不覆盖）
	for u in members:
		if u.has_method("is_possessed") and u.is_possessed():
			continue
		var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		if ai == null:
			continue
		if ai.has_method("get_current_behavior") \
				and ai.get_current_behavior() in ["retreat", "seek_cover"]:
			continue  # 士气驱动行为，不拽回队列
		if _host._member_enemy_in_range(u):
			continue  # 射程内有敌（含风筝窗口），交还给战斗行为
		var slot: Vector2 = _host.get_squad_dest(squad_id, u, anchor, "formation")
		# 落点稳定（SWL FormationPositionIsStable 直译，11b）：已在槽位死区内
		# 不重发号令（无令也不发，防号令空转/动画重播）
		if _host._formation_position_is_stable(u, slot):
			continue
		# 已有他人号令（无 follow_order 标记 = 玩家/上级号令）→ 不覆盖
		if ai.has_method("has_order") and ai.has_order():
			if not (ai.has_method("get_ordered_params")
					and ai.get_ordered_params().get("follow_order", false)):
				continue
			# 已有跟队号令且落点未漂出死区 → 不重复下发（防 travel 重入重播 arrive 动画）
			if ai.has_method("get_ordered_behavior") and ai.get_ordered_behavior() == "move" \
					and ai.get_ordered_params().get("target", Vector2.ZERO).distance_to(slot) <= _host.FOLLOW_DEADZONE:
				continue
		# 追赶状态（SWL UpdateCatchingUpToFormation 直译，11b）：距槽位过远转
		# 奔跑追赶（behavior_move 收盾疾跑，落定后恢复端盾）
		var catching_up: bool = u.global_position.distance_to(slot) > catchup_run_dist
		ai.set_order("move", {
			"target": slot,
			"engage_in_range": true,
			"run": catching_up,
			"catching_up": catching_up,
			# 行军跟队驻留待命；支援推进不驻留——到位即 finish 交还战斗决策
			"hold_on_arrive": not front_engaged,
			"follow_order": true,
		})


## 锚定链是否已包含 squad_id（防成环：设 A→B 前检查 B 的前向链是否回到 A）。
func follow_chain_has(squad_id: String, target_id: String) -> bool:
	var cur: String = target_id
	var hops: int = 0
	while not cur.is_empty() and hops < 16:
		if cur == squad_id:
			return true
		if not _host._squads.has(cur):
			return false
		cur = _host._squads[cur].get("follow_squad_id", "")
		hops += 1
	return false
