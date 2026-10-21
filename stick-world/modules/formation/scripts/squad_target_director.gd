extends RefCounted
## 队伍级目标决策助手 —— 从 formation_system.gd 拆出的共享集火目标子域
## （反编译参考实装 D-B）。
##
## 每 SQUAD_DECISION_INTERVAL 秒为每个战斗小队选一个**共享攻击目标**
##（决策 → 队员执行），队员在攻击行为里优先用队伍目标（集火），否则各自寻敌。
## 参考遗产 TeamAi / 传奇单位组目标同步。
## 决策权归属（军衔重排后）：排内班 = 排长（排长缺口 → 该排失去集火号令）；
## 独立班（无排）= 班长，失效退化第一个存活队员（旧口径）。
##
## 纪律：_squad_targets/_squad_decision_timer 全部留宿主（get_squad_target 查询、
## 排长阵亡清目标等跨域消费），经 _host 回引读写；本类无自持状态。

## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）
var _host = null

## 小队共享目标选型内核（tactics TargetFinder；显式 preload 走 tactics/api.gd
## 契约出口，headless 防御惯例）。缺省 opts 语义 = 最近存活敌人（faction_id
## 阵营口径 + battle 存活列表）。
const ScriptTargetFinder: GDScript = preload("res://modules/tactics/api.gd").Finder


func _init(host) -> void:
	_host = host


## 小队共享目标选型：tactics TargetFinder（缺省 opts = 最近存活敌人；
## 候选口径见 target_finder._collect_enemies——faction_id 阵营 + battle 存活列表）。
func pick_squad_target(rep: Node, battle: Node) -> Node:
	return ScriptTargetFinder.find_target(rep, { "battle": battle })


## 队伍级目标决策：每 SQUAD_DECISION_INTERVAL 秒为每个战斗小队选共享攻击目标。
## 决策权（军衔重排后）：排内班 = 排长（排长缺口 = 该排失去集火号令，不退化）；
## 独立班 = 班长，失效退化第一个存活队员（旧口径）。
func decide_squad_targets(delta: float) -> void:
	if _host._squads.is_empty():
		_host._squad_targets.clear()
		return
	_host._squad_decision_timer += delta
	if _host._squad_decision_timer < _host.SQUAD_DECISION_INTERVAL:
		return
	_host._squad_decision_timer = 0.0
	for squad_id in _host._squads.keys():
		if not _host.is_combat_squad(squad_id):
			_host._squad_targets.erase(squad_id)
			continue
		var rep: Node = null
		var pid: String = _host.get_platoon_of_squad(squad_id)
		if not pid.is_empty() and _host._platoons.has(pid):
			# 排内班：集火决策权归排长；排长缺口 = 指挥链断，失去集火号令
			#（不退化到班长/队员——排级缺口语义，到战斗结束）
			rep = _host._platoons[pid]["leader"]
			if rep == null or not is_instance_valid(rep) \
					or (rep.has_method("is_dead") and rep.is_dead()):
				_host._squad_targets.erase(squad_id)
				continue
		else:
			# 独立班：班长决策，失效时退化到第一个存活队员（旧口径不变）
			rep = _host.get_squad_leader(squad_id)
			if rep == null or not is_instance_valid(rep) \
					or (rep.has_method("is_dead") and rep.is_dead()):
				rep = null
				for u in _host._squads[squad_id]["units"]:
					if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
						rep = u
						break
		if rep == null:
			_host._squad_targets.erase(squad_id)
			continue
		# 经队员拿 battle（不持有 battle 引用，避免耦合）；无 battle 不选目标
		var battle: Node = rep.get_battle_instance() if rep.has_method("get_battle_instance") else null
		if battle == null or not is_instance_valid(battle):
			_host._squad_targets.erase(squad_id)
			continue
		var target: Node = pick_squad_target(rep, battle)
		if target == null:
			# 脱离接触：清共享目标，contact 上报的"首次"状态随之重置（再接敌再报）
			_host._squad_targets.erase(squad_id)
		else:
			# contact 上报挂点（§4.4）：小队首次获得敌方共享目标（每场接敌一次）
			if not _host._squad_targets.has(squad_id):
				_host._file_squad_report(squad_id, "contact", {
					"enemy_count": _host._squad_contact_enemy_count(squad_id),
					"position": target.global_position if is_instance_valid(target) else Vector2.ZERO,
				})
			_host._squad_targets[squad_id] = target
	# 编队动态跟队（SWL MoveInFormationBehindAnotherFormation 直译）：锚定小队落点维持
	_host._update_squad_follows()
