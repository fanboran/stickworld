extends RefCounted
## 战场态势快照刷新 -- team_ai.gd 拆分件（W2 胖文件拆分，行为直搬）。
##
## 职责：每决策周期遍历双方存活单位各至多一次（O(n)），为宿主 TeamAi 重建
## 军事单位数/力量值/质心/投射物威胁/敌方单位值拷贝快照/基地半径内敌军力量。
## 逻辑在本类，快照状态（宿主字段）在宿主——refresh() 计算完逐字段回写。
##
## 拆分纪律：本类持宿主回引（_host）；不缓存跨周期单位引用（防 freed 悬挂），
## 逐引用 is_instance_valid 校验（BattleInstance 惯例）；快照字段口径与原
## team_ai.gd 逐位一致（_num_military / _num_enemy_military / _own_centroid /
## _enemy_centroid / _own_strength / _enemy_strength / _own_threatened /
## _enemy_units_snapshot / _enemy_strength_near_base）。
##
## 消费方：TeamAi 姿态编排（_refresh_snapshot 壳转发 / team_has_a_giant）、
## bench_battle_sim 直调宿主 _refresh_snapshot()（壳保证）。

## 同模块档案（显式 preload，headless 防御惯例 §七.3）
const ScriptTeamAiProfiles := preload("res://modules/combat/scripts/battle/team_ai_profiles.gd")

## 宿主 TeamAi 回引（快照状态字段/参数档案/锚点查询全在宿主）
var _host: Variant = null


## 装配：注入宿主回引（TeamAi.setup 内调用；仅持引用，无副作用）
func setup(host: Variant) -> void:
	_host = host


## 遍历双方存活单位各至多一次：军事单位数/力量值/质心/投射物威胁布尔。
## 不缓存跨周期单位引用（防 freed 悬挂）；逐引用 is_instance_valid 校验（BattleInstance 惯例）。
func refresh() -> void:
	var own_alive: int = 0
	var enemy_alive: int = 0
	var own_military: int = 0
	var enemy_military: int = 0
	var own_sum := Vector2.ZERO
	var enemy_sum := Vector2.ZERO
	var own_wsum: float = 0.0
	var enemy_wsum: float = 0.0
	var threatened: bool = false
	var now_real: float = Time.get_ticks_msec() / 1000.0
	var window: float = float(_host._p["projectile_window"])
	# A2 取数：敌方军事单位快照（C4 评分候选）+ 基地半径内敌军力量（C5 基地威胁）
	var enemy_snapshot: Array = []
	var near_base_strength: float = 0.0
	var base_dist: float = float(_host._p["enemy_close_dist"])
	var anchor: Vector2 = _host.get_garrison_anchor()

	# 本方/敌方分别取数（faction 用 1/2 编码，非对称负数；get_enemies_of 取敌方）
	var own_units: Array = []
	var enemy_units: Array = []
	if _host._battle != null and is_instance_valid(_host._battle):
		if _host._battle.has_method("get_allies_of"):
			own_units = _host._battle.get_allies_of(_host._faction)
		if _host._battle.has_method("get_enemies_of"):
			enemy_units = _host._battle.get_enemies_of(_host._faction)
	for u in own_units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		var pos: Vector2 = u.global_position if u is Node2D else Vector2.ZERO
		var weight: float = ScriptTeamAiProfiles.get_unit_weight(_host._p, weapon_type_of(u))
		own_alive += 1
		own_sum += pos
		if weight > 0.0:
			own_military += 1
			own_wsum += weight
			# 投射物来袭登记（现实秒）：窗口内被瞄准即真（暂停期 TeamAi 不 tick，混源影响可忽略）
			if not threatened and "arrow_threat_time" in u \
					and now_real - float(u.get("arrow_threat_time")) < window:
				threatened = true
	for u in enemy_units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		var pos: Vector2 = u.global_position if u is Node2D else Vector2.ZERO
		var weight: float = ScriptTeamAiProfiles.get_unit_weight(_host._p, weapon_type_of(u))
		enemy_alive += 1
		enemy_sum += pos
		if weight > 0.0:
			enemy_military += 1
			enemy_wsum += weight
			# C4 评分候选（值拷贝，不持引用）；C5 基地威胁（锚点半径内敌军力量）
			enemy_snapshot.append({"pos": pos, "weight": weight})
			if pos.distance_to(anchor) < base_dist:
				near_base_strength += weight

	_host._num_military = own_military
	_host._num_enemy_military = enemy_military
	_host._own_centroid = own_sum / float(own_alive) if own_alive > 0 else Vector2.ZERO
	_host._enemy_centroid = enemy_sum / float(enemy_alive) if enemy_alive > 0 else Vector2.ZERO
	_host._own_strength = own_wsum
	_host._enemy_strength = enemy_wsum
	_host._own_threatened = threatened
	_host._enemy_units_snapshot = enemy_snapshot
	_host._enemy_strength_near_base = near_base_strength


## duck 读取单位武器类型（无武器挂载 → 返回 PICKAXE（权重 0，非军事），不影响力量统计）
func weapon_type_of(u: Node) -> int:
	if u.has_method("get_weapon"):
		var w: Node = u.get_weapon()
		if w != null and is_instance_valid(w) and "weapon_type" in w:
			return int(w.get("weapon_type"))
	return ScriptTeamAiProfiles.PICKAXE


## 扫描某阵营存活单位是否含指定类别（TeamHasAGiant 消费；P8 巨人落地前恒假属预期）
func scan_faction_for_type(faction: int, wtype: int) -> bool:
	if _host._battle == null or not is_instance_valid(_host._battle) or not _host._battle.has_method("get_allies_of"):
		return false
	for u in _host._battle.get_allies_of(faction):
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		if weapon_type_of(u) == wtype:
			return true
	return false
