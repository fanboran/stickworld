extends RefCounted
## 权威值择班市场助手 —— 从 formation_system.gd 拆出的"士兵自主换班"评估子域
## （A9+ 权威值自主跳槽，R4 行为落地；评分内核与滞回判定仍留宿主）。
##
## 已落地的评分内核（宿主 §权威值择班：get_squad_authority / should_switch_squad）
## 只回答"哪个班更有权威"，本助手把它接上"士兵自己换班"：对每个已注册战斗小队的
## 成员周期性比较当前班权威值（+ 已在玩家班的黏性加成）与邻近可投奔班权威值
## （+ 玩家班吸引力加成），用宿主 should_switch_squad 的 authority_margin 滞回判定，
## 够格才转投（走宿主 add_unit：组织同步 / 角色 / 槽位 / 征用互斥全部复用）。
##
## 落点取舍（为何择班评估在 formation_system 而不在 ai_controller / team_ai）：
##   择班是"编制成员构成"的变化，权威值的三个计价项（班长 / 组织指挥官 / 玩家光环）
##   全部由宿主持有（_squads.leader、_org_api、is_possessed），迁移动作也只有宿主
##   能一次做全（org 分配 + 槽位重算）。放 L1 控制器会让每个单位各自查班、各自迁移，
##   产生重复迁移动线与组织侧失步。
##
## 节拍取舍：挂宿主 _process 的 L2 基础节拍扫描（authority_scan_interval 0.5s，与
## _decide_squad_targets / _tick_phase_plans 同源）——不为人事市场另立定时器/节点；
## 单单位评估间隔（authority_eval_interval）+ 确定性错峰相位，保证不同拍评估。
##
## 为何独立档案 ai.formation_authority 而不并入 ai.squad_phase_plan：
##   相位计划是号令驱动的战术推进（有明确起止，开闸看队形节奏），权威值跳槽是常驻的
##   自主人事市场（独立开闸 / 独立节拍 / 独立冷却）。两者必须能独立开合——开相位计划
##   不等于要开士兵换班；合并会把两张闸门焊死，且一处数值改动同时扰动两个机制。
##
## 纪律：全部状态（_authority_params/_authority_clock/_authority_next_eval/
## _authority_cooldown_until/_authority_ordinal/_authority_ordinal_seq/
## _authority_last_eval_count）留宿主，经 _host 动态回引读写；本助手无自持状态。

var _host  ## 宿主 FormationSystem（动态回引；状态唯一真相源在宿主）


func _init(host) -> void:
	_host = host


## 单拍评估：收集"够格转投"的成员后统一迁移（先收集后应用——迭代中改 _squads 的
## 成员数组不安全，且便于"单拍单来源班限流"统计）。
func evaluate_switches(beat: float) -> void:
	prune_registry()
	var eval_interval: float = maxf(float(_host._authority_params.get("authority_eval_interval", 2.0)), beat)
	var cooldown: float = maxf(float(_host._authority_params.get("authority_switch_cooldown", 20.0)), 0.0)
	var radius: float = maxf(float(_host._authority_params.get("authority_candidate_radius", 800.0)), 0.0)
	var stay_bonus: float = float(_host._authority_params.get("authority_stay_in_player_squad_bonus", 0.5))
	var player_bonus: float = float(_host._authority_params.get("authority_player_squad_bonus", 0.2))
	var per_squad_cap: int = maxi(int(_host._authority_params.get("authority_max_switches_per_squad_tick", 1)), 0)
	# 班权威与玩家班标记同拍预计算（同拍内班构成不变，省重复组织查询）
	var authority_of: Dictionary = {}
	var player_squad: Dictionary = {}
	for squad_id_v in _host._squads.keys():
		var sid := str(squad_id_v)
		authority_of[sid] = _host.get_squad_authority(sid)
		player_squad[sid] = is_player_squad(sid)
	var moves: Array = []
	var taken_from: Dictionary = {}
	var eval_count: int = 0
	for squad_id_v in _host._squads.keys():
		var from_id := str(squad_id_v)
		# 只评估战斗班（来源与去向都限战斗职责：把劳工/建造队卷进人事市场会打断生产职责）
		if not _host.is_combat_squad(from_id):
			continue
		var squad: Dictionary = _host._squads[from_id]
		var current_authority: float = float(authority_of[from_id])
		if bool(player_squad[from_id]):
			current_authority += stay_bonus
		var members: Array = (squad.get("units", []) as Array).duplicate()
		for u in members:
			if not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
				continue
			var iid: int = u.get_instance_id()
			# 首次登记：排定确定性错峰相位（之后每评估一次推进 eval_interval）
			var next_at: float = next_eval_at(u, eval_interval)
			# 冷却窗内不评估（单次跳槽后有冷却，防每拍横跳）
			if _host._authority_clock < float(_host._authority_cooldown_until.get(iid, -INF)):
				continue
			if _host._authority_clock < next_at:
				continue
			_host._authority_next_eval[iid] = _host._authority_clock + eval_interval
			eval_count += 1
			# 「不该动的别动」守卫（班长/指挥官、溃逃/被压制、接战中、玩家号令保护期）
			if not may_switch(u, from_id):
				continue
			# 邻近可投奔班择优：班长在场（归属感来源）+ 玩家班吸引力加成
			var best_id := ""
			var best_authority: float = -INF
			for cand_id_v in _host._squads.keys():
				var cand_id := str(cand_id_v)
				if cand_id == from_id or not _host.is_combat_squad(cand_id):
					continue
				var cand_leader: Node = _host.get_squad_leader(cand_id)
				if cand_leader == null or not is_instance_valid(cand_leader) \
						or (cand_leader.has_method("is_dead") and cand_leader.is_dead()):
					continue
				if u.global_position.distance_to(cand_leader.global_position) > radius:
					continue
				var cand_authority: float = float(authority_of[cand_id])
				if bool(player_squad[cand_id]):
					cand_authority += player_bonus
				if cand_authority > best_authority:
					best_authority = cand_authority
					best_id = cand_id
			if best_id.is_empty():
				continue
			# 既有滞回判定（R4 内核；权威差须超 authority_margin 才动）
			if not _host.should_switch_squad(current_authority, best_authority):
				continue
			# 单拍单来源班限流：防"整班雪崩式投奔"的观感突变
			if int(taken_from.get(from_id, 0)) >= per_squad_cap:
				continue
			taken_from[from_id] = int(taken_from.get(from_id, 0)) + 1
			moves.append({ "unit": u, "to": best_id })
	_host._authority_last_eval_count = eval_count
	# 统一迁移（既有 add_unit：组织同步 / 角色 / 槽位 / 征用互斥）
	for m in moves:
		var unit: Node = m["unit"]
		if not is_instance_valid(unit):
			continue
		if _host.add_unit(str(m["to"]), unit):
			var iid: int = unit.get_instance_id()
			_host._authority_cooldown_until[iid] = _host._authority_clock + cooldown
			_host._authority_next_eval[iid] = _host._authority_clock + eval_interval


## 单位下一次评估时刻：首次登记时按确定性错峰相位排定（相位 ∈ [0, eval_interval)），
## 之后由评估推进。相位取数 = 派生种子 + 登记序（不用 instance_id——同一局面构造下
## 登记序稳定，结果可复现；instance_id 跨运行不同会破坏确定性）。
## 派生种子按单位所在战斗（battle_id）哈希与档案基底混合（见 phase_seed）。
func next_eval_at(u: Node, eval_interval: float) -> float:
	var iid: int = u.get_instance_id()
	if _host._authority_next_eval.has(iid):
		return float(_host._authority_next_eval[iid])
	if not _host._authority_ordinal.has(iid):
		_host._authority_ordinal[iid] = _host._authority_ordinal_seq
		_host._authority_ordinal_seq += 1
	var rng := RandomNumberGenerator.new()
	rng.seed = phase_seed(u) + int(_host._authority_ordinal[iid]) * 7919
	var phase: float = rng.randf() * eval_interval
	_host._authority_next_eval[iid] = phase
	return phase


## 错峰相位派生种子（档案键 authority_rng_seed 的新语义 = 派生基底/回落值）：
## 实际种子 = 档案基底 与 单位所在战斗 battle_id 哈希 的异或混合——
##   - 同一场战斗内 battle_id 恒定 → 种子恒定、相位序列可复现（含跨图重载同战斗）；
##   - 不同战斗 battle_id 不同 → 派生种子不同、相位模式不重复（治多局同基底的呆板同相）；
##   - 单位拿不到 battle_id（无战斗/单位桩/查询链缺环）→ 回落档案常数种子，
##     保持单测与无战斗场景的确定性基线（同种子同局面可复现）。
## 为何用异或而非直接相加：battle_id 形如 battle_<instance_id>，哈希与基底量级悬殊，
## 异或混合两位空间不重叠，且纯函数（同输入恒同输出）可复现。
func phase_seed(u: Node) -> int:
	var base: int = int(_host._authority_params.get("authority_rng_seed", 20260913))
	var bid: String = unit_battle_id(u)
	if bid.is_empty():
		return base
	return base ^ int(bid.hash())


## 单位 battle_id 查询（duck 链 get_battle_instance → get_battle_id）；
## 任一环缺失/实例失效/返回空串 → ""（调用方回落档案基底）。
func unit_battle_id(u: Node) -> String:
	if u == null or not is_instance_valid(u) or not u.has_method("get_battle_instance"):
		return ""
	var bi: Node = u.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_battle_id"):
		return ""
	return String(bi.get_battle_id())


## 已释放实例的相位/冷却/登记序清理（防字典随阵亡单位无界增长）。
func prune_registry() -> void:
	for iid_v in _host._authority_next_eval.keys():
		var obj: Object = instance_from_id(int(iid_v))
		if not is_instance_valid(obj):
			_host._authority_next_eval.erase(iid_v)
			_host._authority_cooldown_until.erase(iid_v)
			_host._authority_ordinal.erase(iid_v)


## 单位是否允许转投（「不该动的别动」硬守卫；任一命中即本拍不换班）：
##   1. 玩家附身单位 = 玩家本体，AI 不搬动玩家
##   2. 班长 / 组织在册指挥官本人——RWR max_leader_authority_willing_to_join_another_squad
##      语义（班长权威高于阈值才肯放人）：本班权威值高于 authority_leader_release_threshold
##      者视为骨干，不被抽走
##   3. 士气行为中（retreat / seek_cover = 溃逃 / 找掩体）：不打断士气驱动行为
##   4. 真实压制态（StatusEffects.SUPPRESSED duck 查询，与相位计划同口径）
##   5. 接战中（主手射程内有敌）：交还战斗行为，不当场换班
##   6. 玩家手动号令保护期内（复用 TeamAi 既有保护期状态）
func may_switch(u: Node, squad_id: String) -> bool:
	if u.has_method("is_possessed") and u.is_possessed():
		return false
	if is_leader_or_commander(u, squad_id):
		return false
	var ai: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
	if ai != null and is_instance_valid(ai) and ai.has_method("get_current_behavior") \
			and ai.get_current_behavior() in ["retreat", "seek_cover"]:
		return false
	if unit_suppressed(u):
		return false
	if _host._member_enemy_in_range(u):
		return false
	if is_manual_order_guarded(u, squad_id):
		return false
	return true


## 单位是否本班的骨干（班长 / 组织在册指挥官）：不被抽走。
## 班长判定按 RWR 放人阈值（本班权威值 > authority_leader_release_threshold 才认定
## 骨干——权威值本身已含班长在场项，等价于"有班长的班不放自己的班长"）。
func is_leader_or_commander(u: Node, squad_id: String) -> bool:
	var squad: Dictionary = _host._squads.get(squad_id, {})
	if squad.is_empty():
		return false
	if squad.get("leader", null) == u:
		return _host.get_squad_authority(squad_id) \
				> float(_host._authority_params.get("authority_leader_release_threshold", 0.3))
	var org: Dictionary = _host._org_data(squad_id)
	if not org.is_empty():
		var cmd := String(org.get("commander_id", ""))
		if not cmd.is_empty() and cmd == str(u.get_instance_id()):
			return true
	return false


## 真实压制态（duck 查询 StatusEffects.SUPPRESSED；组件缺失 / 压制未启用返回 false）。
func unit_suppressed(u: Node) -> bool:
	if u == null or not is_instance_valid(u) or not u.has_method("get_status_effects"):
		return false
	var se: Node = u.get_status_effects()
	if se == null or not is_instance_valid(se) or not se.has_method("has_suppressed"):
		return false
	return bool(se.has_suppressed())


## 玩家手动号令保护期查询（复用既有保护期状态，单一真相源）：
## 经 单位 → battle_instance → get_team_ai(faction) 取该阵营 TeamAi 的
## is_manual_order_guarded（保护期时间戳由 TeamAi 订阅 EventBus.order_issued tier=0 维护）。
## TeamAi 未注册（非战斗场景 / 观察场）/ 查询链缺环 → false（无保护期语义）。
func is_manual_order_guarded(u: Node, squad_id: String) -> bool:
	if u == null or not is_instance_valid(u) or not u.has_method("get_battle_instance"):
		return false
	var bi: Node = u.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_team_ai"):
		return false
	var faction: int = int(u.get_faction()) if u.has_method("get_faction") else 0
	var tai: Variant = bi.get_team_ai(faction)
	if tai == null or not is_instance_valid(tai) or not tai.has_method("is_manual_order_guarded"):
		return false
	return bool(tai.is_manual_order_guarded(squad_id))


## 玩家所在班（跳槽吸引力 / 黏性加成的判定口径）。
## 排除"班长被附身"这一情形：该情形已由宿主 get_squad_authority 的
## AUTHORITY_PLAYER_BONUS 计价，此处不重复叠加。剩余两种情形在此计价：
##   - 该班处于"跟随玩家"模式（玩家点选跟随的班）
##   - 玩家实体在该班（任一非班长成员被附身）
func is_player_squad(squad_id: String) -> bool:
	var squad: Dictionary = _host._squads.get(squad_id, {})
	if squad.is_empty():
		return false
	var leader: Node = squad.get("leader", null)
	if leader != null and is_instance_valid(leader) \
			and leader.has_method("is_possessed") and leader.is_possessed():
		return false
	if bool(squad.get("follow_player", false)):
		return true
	for u in squad.get("units", []):
		if is_instance_valid(u) and u.has_method("is_possessed") and u.is_possessed():
			return true
	return false
