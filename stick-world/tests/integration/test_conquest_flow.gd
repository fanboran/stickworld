extends Node
## 集成测试：出征与领地循环（批次 C5）——launch_campaign 接敌开战 → 胜仗占领入账
## → 已臣服再进不刷军 → 败仗车轮战回村 → 全图占领通关判定。
##
## 验收门（交接档批次 C5）：
##   1. 打完一场（黑石营地）：WorldState.territories 状态转 CAPTURED + 资源奖励入账
##      （res_wood +30 / res_stone +20）+ territory_state_changed / region_owner_changed 广播；
##   2. 已臣服据点再进不刷军、不开战，launch_campaign 拒征（返回 false）；
##   3. 败仗（赤岭寨）：守军战损持久化 garrison_losses=2（state 仍 HOSTILE），
##      玩家残部传回村A，可再次出征（launch_campaign 返回 true）；
##   4. 三座据点全占 → ExpansionApi.conquest_completed 恰发一次（captured 3/3 统计），
##      占领不清战损记录。
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_conquest_flow.tscn
## 退出码：0 全部通过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptGarrisonSpawner := preload("res://modules/expansion/scripts/garrison_spawner.gd")

const TID_1 := "ter_bandit_camp_01"  # 黑石营地：l1_settlement_02，守军 3 + 敌将
const TID_2 := "ter_bandit_camp_02"  # 赤岭寨：l1_settlement_03，守军 5 + 敌将
const TID_3 := "ter_warlord_keep_01"  # 铁腕要塞：l1_settlement_04
const MAP_1 := "l1_settlement_02"
const MAP_2 := "l1_settlement_03"
const HOME_MAP := "village_a"
## 战斗结束/回村轮询节奏：0.25s 步进（战斗结束超时 30s，回村轮询 20s）
const POLL_INTERVAL := 0.25
const BATTLE_TIMEOUT := 30.0
const HOME_TIMEOUT := 20.0

var _runner: TestRunner
var _game_root: Node = null
var _manager: Node = null
var _api: Node = null
var _combat: Node = null
var _resources: Node = null

## 信号捕获（Callable 存成员变量，_cleanup 统一断连，防断言路径提前退出泄漏）
var _cb_state: Callable
var _cb_owner: Callable
var _cb_done: Callable
var _sig_state: Array = []
var _sig_owner: Array = []
var _sig_done: Array = []


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("出征接敌：launch_campaign 开据点战", Callable(self, "_test_campaign_engage"), true)
	_runner.add_test("胜仗占领与收益：状态变+资源入账+广播", Callable(self, "_test_victory_capture"), true)
	_runner.add_test("已臣服再进不刷军", Callable(self, "_test_captured_no_respawn"), true)
	_runner.add_test("败仗车轮战：战损持久化+回村可再征", Callable(self, "_test_defeat_attrition"), true)
	_runner.add_test("通关判定：3/3 全占 conquest_completed", Callable(self, "_test_conquest_completed"), true)
	_run_tests()


func _run_tests() -> void:
	_game_root = (load("res://modules/world/scenes/game_root.tscn") as PackedScene).instantiate()
	add_child(_game_root)
	for i in 10:
		await get_tree().process_frame
	_manager = _game_root.get_conquest_manager()
	_api = _game_root.get_node("ExpansionApi")
	_combat = _game_root.get_combat_api()
	_resources = _game_root.get_resources_api()
	await _runner.run_async()
	print(_runner.summary())
	_cleanup()
	get_tree().quit(0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

## 用例 1「出征接敌」：launch_campaign 进据点图自动开战，攻守双方阵营注册齐备
func _test_campaign_engage() -> void:
	WorldState.territories = {}
	_runner.assert_true(_manager.launch_campaign(TID_1), "黑石营地应可出征")
	for i in 10:
		await get_tree().process_frame
	_runner.assert_true(_combat.has_active_battle(), "进据点图应自动开战")
	var battles: Array = _combat.get_active_battles()
	_runner.assert_true(not battles.is_empty(), "活跃战斗列表非空")
	if battles.is_empty():
		return
	var b: Node = battles[0]
	_runner.assert_equal(b.get_player_faction(), 1, "玩家为攻方 faction 1")
	_runner.assert_not_null(b.get_team_ai(2), "守军阵营应注册撤仗评估 TeamAi")
	_runner.assert_equal(b.get_alive_count(2), 4, "守军方 3 守军 + 敌将 = 4")
	_runner.assert_true(b.get_alive_count(1) >= 1, "玩家侧在攻方（>=1）")
	# 负路径：未知领地拒征
	_runner.assert_false(_manager.launch_campaign("ter_unknown_xx"), "未知领地拒征")


## 用例 2「胜仗占领与收益」（接用例 1 的战斗）：杀光守军方 → victory → 自动占领入账
func _test_victory_capture() -> void:
	WorldState.territories = {}
	var map: Node2D = _game_root.get_current_map()
	# 开战自动暂停（TimeManager auto_pause_battle，玩家观察窗 UX）：
	# 测试模拟玩家恢复 X1，否则 BattleInstance 暂停门禁不 tick、胜负判定不执行
	TimeManager.set_speed(TimeManager.Speed.X1)
	var wood0: float = _resources.get_stock("res_wood")
	var stone0: float = _resources.get_stock("res_stone")
	_connect_capture_signals()
	# 杀光守军方全部单位（garrison meta 单位，含敌将）
	for u in _garrison_units(map):
		_kill(u)
	var ended: bool = await _await_battle_end()
	_runner.assert_true(ended, "守军全灭后战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	# capture 在 battle_ended 回调同步执行，多等几帧稳妥
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
	var captured_flag := false
	for t in _api.list_targets():
		if String(t.get("id", "")) == TID_1:
			captured_flag = bool(t.get("captured", false))
	_runner.assert_true(captured_flag, "list_targets 中黑石营地 captured=true")
	_runner.assert_false(_api.is_all_captured(), "尚有 2 座未占，不应判通关")


## 用例 3「已臣服再进不刷军」：拒征 + 友化空图
func _test_captured_no_respawn() -> void:
	var home: Node2D = await _travel_to(HOME_MAP, WorldAPI.EntrySide.RIGHT)
	_runner.assert_true(home != null, "回村 travel 成功")
	_runner.assert_false(_manager.launch_campaign(TID_1), "已臣服拒征（launch_campaign=false）")
	var map: Node2D = await _travel_to(MAP_1, WorldAPI.EntrySide.LEFT)
	_runner.assert_true(map != null, "再进据点图成功")
	_runner.assert_false(_combat.has_active_battle(), "已臣服再进不开战")
	_runner.assert_equal(_garrison_units(map).size(), 0, "已臣服据点 EntityHost 无 garrison 单位")


## 用例 4「败仗车轮战」（赤岭寨）：杀 2 守军 → 玩家侧全灭 → 战损持久化 + 回村可再征
func _test_defeat_attrition() -> void:
	# 只擦本用例目标领地——整表清空会连带抹掉用例 2 的占领记录，用例 5 通关判定就永远差一座
	WorldState.territories.erase(TID_2)
	var map: Node2D = await _travel_to(MAP_2, WorldAPI.EntrySide.LEFT)
	_runner.assert_true(map != null, "赤岭寨图加载成功")
	_runner.assert_true(_combat.has_active_battle(), "进赤岭寨应自动开战")
	# 恢复 X1（开战自动暂停，同用例 2 口径），否则战斗不 tick
	TimeManager.set_speed(TimeManager.Speed.X1)
	# 杀恰好 2 个普通守军（跳过敌将；防御性取 min 防越界）
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
	# 杀光玩家侧单位（无 garrison meta 且存活的 EntityHost 子节点）
	for u in _player_side_units(map):
		_kill(u)
	var ended: bool = await _await_battle_end()
	_runner.assert_true(ended, "玩家侧全灭后战斗应在 %.0fs 内结束" % BATTLE_TIMEOUT)
	# 败仗回村是 call_deferred travel，再给 travel 几帧
	for i in 15:
		await get_tree().process_frame
	var rec: Dictionary = WorldState.territories.get(TID_2, {})
	_runner.assert_true(WorldState.territories.has(TID_2), "败仗应写领地记录")
	_runner.assert_equal(int(rec.get("garrison_losses", -1)), 2, "守军战损 2 持久化")
	_runner.assert_equal(int(rec.get("state", -1)), 0, "败仗不占领（仍 HOSTILE=0）")
	# 回村轮询：scene_loader.current_map_id 在 travel 流程同步赋值，get_current_map_id() 可靠
	_runner.assert_true(await _await_map_id(HOME_MAP), "败仗应传回村A（轮询 %.0fs），当前 id=%s" % [HOME_TIMEOUT, _game_root.get("scene_loader").get_current_map_id()])
	_runner.assert_true(_manager.launch_campaign(TID_2), "败仗不判负，可再征")


## 用例 5「通关判定」：补占 2 座 → 3/3 → conquest_completed 恰发一次，战损记录保留
func _test_conquest_completed() -> void:
	_sig_done.clear()
	_cb_done = func(stats: Dictionary) -> void: _sig_done.append(stats.duplicate())
	_api.conquest_completed.connect(_cb_done)
	_api.capture_territory(TID_2)
	_api.capture_territory(TID_3)
	_runner.assert_equal(_sig_done.size(), 1, "conquest_completed 应恰发 1 次，实得 %d" % _sig_done.size())
	if _sig_done.is_empty():
		return
	var stats: Dictionary = _sig_done[0]
	_runner.assert_equal(int(stats.get("captured", -1)), 3, "captured 3/3")
	_runner.assert_equal(int(stats.get("total", -1)), 3, "total 3")
	_runner.assert_true(typeof(stats.get("player_losses")) == TYPE_INT \
			and int(stats.get("player_losses")) >= 0, "player_losses 为 int >= 0")
	_runner.assert_true(stats.has("game_time"), "stats 含 game_time 键")
	_runner.assert_true(_api.is_all_captured(), "全占判定 true")
	_runner.assert_equal(int(WorldState.territories.get(TID_2, {}).get("garrison_losses", -1)), 2,
			"占领不清战损记录（garrison_losses 仍 2）")


# ─────────────────────────────── 工具 ────────────────────────────────

## travel 到指定地图并等待就绪（先例：await 帧数，比较 map.name 不稳定），返回当前地图实例
func _travel_to(map_id: String, side: int = WorldAPI.EntrySide.LEFT) -> Node2D:
	var sl: Node = _game_root.get("scene_loader")
	sl.travel_to_map(map_id, WorldAPI.TravelMode.WALK, side)
	for i in 10:
		await get_tree().process_frame
	return _game_root.get_current_map()


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


## 等全部战斗结束：0.25s 步进轮询，超时返回 false
func _await_battle_end() -> bool:
	var elapsed := 0.0
	while _combat.has_active_battle() and elapsed < BATTLE_TIMEOUT:
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
	return not _combat.has_active_battle()


## 轮询当前地图 id（scene_loader.get_current_map_id()，travel 流程同步赋值）
func _await_map_id(target: String) -> bool:
	var sl: Node = _game_root.get("scene_loader")
	var elapsed := 0.0
	while elapsed < HOME_TIMEOUT:
		if sl.get_current_map_id() == target:
			return true
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
	return sl.get_current_map_id() == target


## 连领地状态/归属广播捕获（用例 2）
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
	if _cb_done.is_valid() and _api != null and _api.conquest_completed.is_connected(_cb_done):
		_api.conquest_completed.disconnect(_cb_done)
	WorldState.territories = {}
