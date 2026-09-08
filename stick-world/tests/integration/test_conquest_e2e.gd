extends Node
## 端到端 smoke 测试（C7）：出征与领地循环全链路一条龙锁死。
##
## 与 test_conquest_flow（C5 分环节验证）的差别：本测试不打断流程、不直达
## capture_territory——四场真实据点战全部走 launch_campaign → map_loaded 接敌
## → BattleInstance 收束 → ConquestManager 收链的玩家路径，最后一站断言
## 通关结算 UI 弹出。任何一环被后续改造弄断，本套件立刻红灯（架构 §八 C7）。
##
## 全循环剧本（交接档批次 6）：
##   新开局（落村A、领地表空、api 骨架就绪）
##   → 征伐黑石营地（守军 3+敌将，全灭收束）→ 占领 + 资源入账 + 广播
##   → 征伐赤岭寨（杀 2 守军后玩家侧全灭 = 败仗）→ 守军战损持久化 + 自动回村
##   → 再征赤岭寨（车轮战扣减：实刷 3 守军 + 敌将）→ 占领 + 解锁广播
##   → 征伐铁腕要塞 → 3/3 全占 → conquest_completed → 通关结算卡弹出可见。
##
## 确定性手法（批次 4/5 测试坑总结，同 test_conquest_flow）：
##   - 开战自动暂停（TimeManager.auto_pause_battle）：每场战斗开始后须
##     set_speed(X1) 模拟玩家恢复，否则暂停门禁不 tick、胜负判定永不执行；
##   - 胜负不靠真实交战：take_damage(99999) 直达制造确定胜负；
##   - 败仗回村是 call_deferred travel，须轮询 map_id 等待。
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_conquest_e2e.tscn
## 退出码：0 全部通过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptGarrisonSpawner := preload("res://modules/expansion/scripts/garrison_spawner.gd")

const TID_1 := "ter_bandit_camp_01"  # 黑石营地：l1_settlement_02，守军 3 + 敌将
const TID_2 := "ter_bandit_camp_02"  # 赤岭寨：l1_settlement_03，守军 5 + 敌将
const TID_3 := "ter_warlord_keep_01"  # 铁腕要塞：l1_settlement_04，守军 8 + 敌将
const HOME_MAP := "village_a"
## 战斗结束/回村轮询节奏：0.25s 步进（战斗结束超时 30s，回村轮询 20s）
const POLL_INTERVAL := 0.25
const BATTLE_TIMEOUT := 30.0
const HOME_TIMEOUT := 20.0
## Boot 等待：地图生成 + deferred 装配（DemoQuest 等）就绪
const BOOT_TIMEOUT := 20.0

var _runner: TestRunner
var _game_root: Node = null
var _manager: Node = null
var _api: Node = null
var _combat: Node = null
var _resources: Node = null
var _ui_root: Node = null

## 信号捕获（Callable 存成员变量，_cleanup 统一断连，防断言路径提前退出泄漏）
var _cb_state: Callable
var _cb_owner: Callable
var _cb_unlock: Callable
var _cb_done: Callable
var _sig_state: Array = []
var _sig_owner: Array = []
var _sig_unlock: Array = []
var _sig_done: Array = []


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("新开局：落村A + 领地表空 + api 骨架就绪", Callable(self, "_test_new_run_skeleton"), true)
	_runner.add_test("征伐第 1 座：黑石营地占领入账广播", Callable(self, "_test_first_capture"), true)
	_runner.add_test("再征第 2 座：赤岭寨车轮战扣减生效", Callable(self, "_test_attrition_recapture"), true)
	_runner.add_test("征伐第 3 座：全占通关 + 结算弹出", Callable(self, "_test_completion_overlay"), true)
	_run_tests()


func _run_tests() -> void:
	_game_root = (load("res://modules/world/scenes/game_root.tscn") as PackedScene).instantiate()
	add_child(_game_root)
	# 新开局契约在此刻已生效（GameRoot._load_start_village → WorldState.start_new_run）
	if not await _await_boot():
		print(_runner.summary())
		_cleanup()
		get_tree().quit(1)
		return
	_manager = _game_root.get_conquest_manager()
	_api = _game_root.get_node("ExpansionApi")
	_combat = _game_root.get_combat_api()
	_resources = _game_root.get_resources_api()
	_ui_root = _game_root.get("ui_root")
	await _runner.run_async()
	print(_runner.summary())
	_cleanup()
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

## 用例 1「新开局」：GameRoot 新游戏分支跑完（start_new_run 重置领地表）、
## expansion api 骨架装配齐、3 座据点全部 HOSTILE 可征
func _test_new_run_skeleton() -> void:
	_runner.assert_true(_map_id() == HOME_MAP, "新开局应落村A，实得 %s" % _map_id())
	_runner.assert_true(WorldState.territories.is_empty(),
			"start_new_run 应清空领地表（实得 %d 条）" % WorldState.territories.size())
	_runner.assert_not_null(_manager, "ConquestManager 装配就绪")
	_runner.assert_not_null(_api, "ExpansionApi 装配就绪")
	_runner.assert_false(_combat.has_active_battle(), "开局无战斗")
	_runner.assert_equal(_manager.get_active_campaign_count(), 0, "开局无进行中征伐")
	var targets: Array[Dictionary] = _api.list_targets()
	_runner.assert_equal(targets.size(), 3, "可征伐据点 3 座")
	if targets.size() != 3:
		return
	# territories.tres 守军编成 3/5/8（不含敌将），新开局无车轮战扣减
	_runner.assert_equal(int(targets[0].get("garrison_count", -1)), 3, "黑石营地守军 3")
	_runner.assert_equal(int(targets[1].get("garrison_count", -1)), 5, "赤岭寨守军 5")
	_runner.assert_equal(int(targets[2].get("garrison_count", -1)), 8, "铁腕要塞守军 8")
	for t in targets:
		_runner.assert_false(bool(t.get("captured", true)), "%s 应为 HOSTILE" % String(t.get("id", "")))
	_runner.assert_false(_api.is_all_captured(), "开局不应判通关")


## 用例 2「征伐第 1 座」：launch_campaign 全自动接敌开战 → 守军全灭 →
## 状态转 CAPTURED + 资源入账 + 三路广播（state/owner/api 查询面）
func _test_first_capture() -> void:
	_runner.assert_true(_manager.launch_campaign(TID_1), "黑石营地应可出征")
	var b: Node = await _await_battle("进黑石营地应自动开战")
	if b == null:
		return
	_runner.assert_equal(b.get_player_faction(), 1, "玩家为攻方 faction 1")
	_runner.assert_not_null(b.get_team_ai(2), "守军阵营挂敌将撤仗评估 TeamAi")
	_runner.assert_equal(b.get_alive_count(2), 4, "守军 3 + 敌将 = 4")
	TimeManager.set_speed(TimeManager.Speed.X1)
	var wood0: float = _resources.get_stock("res_wood")
	var stone0: float = _resources.get_stock("res_stone")
	_connect_capture_signals()
	for u in _garrison_units(_game_root.get_current_map()):
		_kill(u)
	var ended: bool = await _await_battle_end()
	_runner.assert_true(ended, "守军全灭后战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	for i in 10:
		await get_tree().process_frame
	_disconnect_capture_signals()
	var rec: Dictionary = WorldState.territories.get(TID_1, {})
	_runner.assert_equal(int(rec.get("state", -1)), 1, "黑石营地应转 CAPTURED(1)")
	_runner.assert_approx(_resources.get_stock("res_wood") - wood0, 30.0, 0.001, "木奖励 +30 入账")
	_runner.assert_approx(_resources.get_stock("res_stone") - stone0, 20.0, 0.001, "石奖励 +20 入账")
	var state_ok := false
	for sig in _sig_state:
		if sig.size() == 2 and sig[0] == TID_1 and int(sig[1]) == 1:
			state_ok = true
	_runner.assert_true(state_ok, "territory_state_changed 捕获 (%s, 1)，实得 %s" % [TID_1, str(_sig_state)])
	var owner_ok := false
	for sig in _sig_owner:
		if sig.size() == 2 and sig[0] == "city_1035" and sig[1] == "player":
			owner_ok = true
	_runner.assert_true(owner_ok, "region_owner_changed 捕获 (city_1035, player)，实得 %s" % [str(_sig_owner)])
	_runner.assert_true(_target_captured(TID_1), "list_targets 中黑石营地 captured=true")
	_runner.assert_false(_api.is_all_captured(), "尚有 2 座未占，不应判通关")


## 用例 3「再征第 2 座（车轮战）」：赤岭寨先打一场败仗（杀 2 守军后玩家侧全灭）
## → garrison_losses=2 持久化 + 自动回村；再征时实刷守军 5-2=3（+敌将）→ 全灭占领 + 解锁广播
func _test_attrition_recapture() -> void:
	# —— 第一场：败仗制造车轮战战损 ——
	_runner.assert_true(_manager.launch_campaign(TID_2), "赤岭寨应可出征")
	var b: Node = await _await_battle("进赤岭寨应自动开战")
	if b == null:
		return
	TimeManager.set_speed(TimeManager.Speed.X1)
	var map: Node2D = _game_root.get_current_map()
	var normals: Array = []
	for u in _garrison_units(map):
		if bool(u.get_meta(ScriptGarrisonSpawner.META_GARRISON_COMMANDER, false)):
			continue
		normals.append(u)
	_runner.assert_true(normals.size() >= 2, "普通守军应 >= 2（配置 5 + 敌将）")
	for i in mini(2, normals.size()):
		_kill(normals[i])
	for i in 2:
		await get_tree().process_frame
	for u in _player_side_units(map):
		_kill(u)
	var ended: bool = await _await_battle_end()
	_runner.assert_true(ended, "玩家侧全灭后战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	_runner.assert_true(await _await_map_id(HOME_MAP), "败仗应自动传回村A，当前 id=%s" % _map_id())
	var rec: Dictionary = WorldState.territories.get(TID_2, {})
	_runner.assert_equal(int(rec.get("garrison_losses", -1)), 2, "守军战损 2 持久化")
	_runner.assert_equal(int(rec.get("state", -1)), 0, "败仗不占领（仍 HOSTILE=0）")
	_runner.assert_equal(_target_garrison_count(TID_2), 3, "list_targets 守军余量 5-2=3")
	# —— 第二场：再征，车轮战扣减在 spawn 层生效 ——
	_runner.assert_true(_manager.launch_campaign(TID_2), "败仗不判负，可再征")
	var b2: Node = await _await_battle("再进赤岭寨应再开战")
	if b2 == null:
		return
	_runner.assert_equal(b2.get_alive_count(2), 4, "实刷守军 5-2=3 + 敌将 = 4（车轮战扣减）")
	TimeManager.set_speed(TimeManager.Speed.X1)
	var wood0: float = _resources.get_stock("res_wood")
	var iron0: float = _resources.get_stock("res_iron_ingot")
	_connect_capture_signals()
	_sig_unlock.clear()
	_cb_unlock = func(unlock_id: String) -> void: _sig_unlock.append(unlock_id)
	EventBus.unlock_granted.connect(_cb_unlock)
	for u in _garrison_units(_game_root.get_current_map()):
		_kill(u)
	var ended2: bool = await _await_battle_end()
	_runner.assert_true(ended2, "守军全灭后战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	for i in 10:
		await get_tree().process_frame
	_disconnect_capture_signals()
	if _cb_unlock.is_valid() and EventBus.unlock_granted.is_connected(_cb_unlock):
		EventBus.unlock_granted.disconnect(_cb_unlock)
	_runner.assert_equal(int(WorldState.territories.get(TID_2, {}).get("state", -1)), 1,
			"赤岭寨应转 CAPTURED(1)")
	_runner.assert_approx(_resources.get_stock("res_wood") - wood0, 40.0, 0.001, "木奖励 +40 入账")
	_runner.assert_approx(_resources.get_stock("res_iron_ingot") - iron0, 20.0, 0.001, "铁锭奖励 +20 入账")
	_runner.assert_true(_sig_unlock.has("unlock_arrow_tower"),
			"unlock_granted 应广播 unlock_arrow_tower，实得 %s" % str(_sig_unlock))


## 用例 4「征伐第 3 座 → 通关」：铁腕要塞占领 → conquest_completed 恰发一次
## （统计 3/3、含玩家伤亡）→ 通关结算卡 ConquestVictoryOverlay 挂 ModalOverlay 且可见
func _test_completion_overlay() -> void:
	_runner.assert_true(_manager.launch_campaign(TID_3), "铁腕要塞应可出征")
	var b: Node = await _await_battle("进铁腕要塞应自动开战")
	if b == null:
		return
	TimeManager.set_speed(TimeManager.Speed.X1)
	_sig_done.clear()
	_cb_done = func(stats: Dictionary) -> void: _sig_done.append(stats.duplicate())
	_api.conquest_completed.connect(_cb_done)
	for u in _garrison_units(_game_root.get_current_map()):
		_kill(u)
	var ended: bool = await _await_battle_end()
	_runner.assert_true(ended, "守军全灭后战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	for i in 10:
		await get_tree().process_frame
	_runner.assert_equal(int(WorldState.territories.get(TID_3, {}).get("state", -1)), 1,
			"铁腕要塞应转 CAPTURED(1)")
	_runner.assert_true(_api.is_all_captured(), "3/3 全占判定 true")
	_runner.assert_equal(_sig_done.size(), 1, "conquest_completed 应恰发 1 次，实得 %d" % _sig_done.size())
	if not _sig_done.is_empty():
		var stats: Dictionary = _sig_done[0]
		_runner.assert_equal(int(stats.get("captured", -1)), 3, "统计 captured 3/3")
		_runner.assert_equal(int(stats.get("total", -1)), 3, "统计 total 3")
		_runner.assert_true(int(stats.get("player_losses", -1)) >= 1,
				"统计含玩家伤亡（赤岭寨败仗至少折损 1，实得 %d）" % int(stats.get("player_losses", -1)))
		_runner.assert_true(stats.has("game_time"), "统计含 game_time 键")
	# 通关结算弹出（C6：conquest_completed → demo_quest 动态建 ConquestVictoryOverlay
	# 挂 UIRoot.ModalOverlay 槽，show_conquest 置 visible——弹链全程同步，此处直接断言）
	var overlay: Control = _ui_root.get_node_or_null("ModalOverlay/ConquestVictoryOverlay") if _ui_root != null else null
	_runner.assert_not_null(overlay, "通关结算卡 ConquestVictoryOverlay 应挂 ModalOverlay 槽")
	if overlay != null:
		_runner.assert_true(overlay.visible, "通关结算卡应可见（show_conquest 已弹出）")


# ─────────────────────────────── 工具 ────────────────────────────────

## Boot 就绪：当前地图非空 + DemoQuest 已装配（deferred 队列消费完）
func _await_boot() -> bool:
	var elapsed := 0.0
	while elapsed < BOOT_TIMEOUT:
		var map: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
		if map != null and _game_root.get_node_or_null("DemoQuest") != null:
			return true
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
	push_error("[conquest_e2e] boot 超时：map=%s DemoQuest=%s"
			% [str(_map_id()), str(_game_root.get_node_or_null("DemoQuest") != null)])
	return false


## 等待据点战开启并返回战斗实例（超时断言失败返回 null）。
## 开战后让出 3 帧：接敌开战与守军 spawn 同帧完成（launch_campaign 同步链），
## spawn 帧排队的 deferred 武器校准若在击杀后才跑、且无死体防护，会把尸体奶活
## （同帧击杀踩过：hp 0→满血复活，守军战损丢失）——先等 deferred 队列冲刷完再动手
func _await_battle(msg: String) -> Node:
	var elapsed := 0.0
	while not _combat.has_active_battle() and elapsed < 10.0:
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
	var battles: Array = _combat.get_active_battles()
	_runner.assert_true(not battles.is_empty(), msg)
	if not battles.is_empty():
		for i in 3:
			await get_tree().process_frame
	return battles[0] if not battles.is_empty() else null


## 等全部战斗结束：0.25s 步进轮询，超时返回 false
func _await_battle_end() -> bool:
	var elapsed := 0.0
	while _combat.has_active_battle() and elapsed < BATTLE_TIMEOUT:
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
	return not _combat.has_active_battle()


## 轮询当前地图 id（败仗回村是 deferred travel，异步完成）
func _await_map_id(target: String) -> bool:
	var elapsed := 0.0
	while elapsed < HOME_TIMEOUT:
		if _map_id() == target:
			return true
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
	return _map_id() == target


func _map_id() -> String:
	var sl: Node = _game_root.get("scene_loader")
	return String(sl.get_current_map_id()) if sl != null and sl.has_method("get_current_map_id") else ""


## EntityHost 中带守军来源标记的单位（含敌将）
func _garrison_units(map: Node2D) -> Array:
	var host: Node = map.get_node_or_null("EntityHost") if map != null else null
	var result: Array = []
	if host == null:
		return result
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if bool(u.get_meta(ScriptGarrisonSpawner.META_GARRISON_UNIT, false)):
			result.append(u)
	return result


## EntityHost 中玩家侧单位（无 garrison meta 且存活）
func _player_side_units(map: Node2D) -> Array:
	var host: Node = map.get_node_or_null("EntityHost") if map != null else null
	var result: Array = []
	if host == null:
		return result
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if bool(u.get_meta(ScriptGarrisonSpawner.META_GARRISON_UNIT, false)):
			continue
		if not u.has_method("is_dead") or u.is_dead():
			continue
		result.append(u)
	return result


## 直达击杀（get_health() 非空防御）
func _kill(u: Node) -> void:
	if not is_instance_valid(u) or not u.has_method("get_health"):
		return
	var hp: Node = u.get_health()
	if hp != null and hp.has_method("take_damage"):
		hp.take_damage(99999.0)


## list_targets 查指定据点的 captured 标记
func _target_captured(tid: String) -> bool:
	for t in _api.list_targets():
		if String(t.get("id", "")) == tid:
			return bool(t.get("captured", false))
	return false


## list_targets 查指定据点的守军余量（-1 = 未找到）
func _target_garrison_count(tid: String) -> int:
	for t in _api.list_targets():
		if String(t.get("id", "")) == tid:
			return int(t.get("garrison_count", -1))
	return -1


## 连领地状态/归属广播捕获
func _connect_capture_signals() -> void:
	_sig_state.clear()
	_sig_owner.clear()
	_cb_state = func(tid: String, st: int) -> void: _sig_state.append([tid, st])
	_cb_owner = func(rid: String, owner_id: String) -> void: _sig_owner.append([rid, owner_id])
	EventBus.territory_state_changed.connect(_cb_state)
	EventBus.region_owner_changed.connect(_cb_owner)


func _disconnect_capture_signals() -> void:
	if _cb_state.is_valid() and EventBus.territory_state_changed.is_connected(_cb_state):
		EventBus.territory_state_changed.disconnect(_cb_state)
	if _cb_owner.is_valid() and EventBus.region_owner_changed.is_connected(_cb_owner):
		EventBus.region_owner_changed.disconnect(_cb_owner)


func _cleanup() -> void:
	_disconnect_capture_signals()
	if _cb_unlock.is_valid() and EventBus.unlock_granted.is_connected(_cb_unlock):
		EventBus.unlock_granted.disconnect(_cb_unlock)
	if _cb_done.is_valid() and _api != null and _api.conquest_completed.is_connected(_cb_done):
		_api.conquest_completed.disconnect(_cb_done)
	WorldState.territories = {}
