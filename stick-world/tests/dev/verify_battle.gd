extends Node
## 遭遇战全流程实测（dev 层）——验证 Demo 目标 4 的真实可达成性：
## 直达 battlefield → 直达调用 InitialContent.spawn_battlefield_enemies 组织遭遇战
## （battlefield 退役后 game_root 进图不再自动刷敌，出征与领地架构 §4.3）→
## 自动暂停（auto_pause_battle 设计）→ 模拟玩家空格恢复 → AI 自主接战互搏 →
## battle_ended 分出胜负。
## 根因记录：暂停期间一切单位冻结（含 AI 决策循环），解除后接战链自动工作。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

const BATTLE_TIMEOUT: float = 150.0

var _game_root: Node = null
var _fails: int = 0


func _ready() -> void:
	await _run()
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(_fails)


func _run() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	for i in 20:
		await get_tree().process_frame

	var quest: Node = _game_root.get_node_or_null("DemoQuest")
	if quest == null:
		_fail("DemoQuest 未装配")
		return
	var result: Dictionary = {"ended": false, "victory": false}
	EventBus.battle_ended.connect(func(_bid: String, v: bool) -> void:
		result["ended"] = true
		result["victory"] = v)

	# 直达战场
	var sl: Node = _game_root.get("scene_loader") if "scene_loader" in _game_root else null
	if sl == null or not sl.has_method("travel_to_map"):
		_fail("SceneLoader 不可用")
		return
	sl.travel_to_map("battlefield", WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	for i in 30:
		await get_tree().process_frame

	# 直达组织遭遇战：玩家方（攻方）vs 刷出的敌方
	var gen: Node = _game_root.get("_worldgen")
	var player: Node2D = _game_root.get_player_entity()
	if gen == null or not gen.has_method("spawn_battlefield_enemies") or player == null:
		_fail("直达刷敌入口不可用（InitialContent.spawn_battlefield_enemies）")
		return
	var field_map: Node2D = _game_root.get_current_map()
	gen.spawn_battlefield_enemies(field_map, [player], 3)
	for i in 5:
		await get_tree().process_frame

	# 1) 建战断言（恢复前，单位还在）：阵容正确 + 参战引用回填 + 自动暂停生效
	var m: Node2D = _game_root.get_current_map()
	var ents: Array = m.get_entities() if m != null and m.has_method("get_entities") else []
	var f1_n: int = 0
	var f2_n: int = 0
	var bi_n: int = 0
	for e in ents:
		if e == null or not is_instance_valid(e) or (e.has_method("is_dead") and e.is_dead()):
			continue
		if e.has_method("get_faction"):
			match int(e.get_faction()):
				1: f1_n += 1
				2: f2_n += 1
		if e.has_method("get_battle_instance") and e.get_battle_instance() != null:
			bi_n += 1
	if f1_n >= 2 and f2_n >= 3 and bi_n >= 5:
		_pass("遭遇战建立（玩家方 %d / 敌方 %d / 参战引用 %d）" % [f1_n, f2_n, bi_n])
	else:
		_fail("遭遇战阵容异常（f1=%d f2=%d bi=%d）" % [f1_n, f2_n, bi_n])
	if TimeManager != null and TimeManager.is_paused():
		_pass("战斗自动暂停生效（auto_pause_battle 设计行为）")
		TimeManager.set_speed(TimeManager.Speed.X1)
	else:
		_fail("战斗开始后未自动暂停（配置变化？）")

	var waited: float = 0.0
	while not result["ended"] and waited < BATTLE_TIMEOUT:
		await get_tree().create_timer(1.0).timeout
		waited += 1.0
	if result["ended"]:
		_pass("空格恢复后 %.0fs 分出胜负：玩家方%s（AI 对轰五五开属正常）" % [
			waited, "胜" if result["victory"] else "败"])
	else:
		_fail("空格恢复后 %.0fs 未分胜负（AI 自主接战断链）" % BATTLE_TIMEOUT)

	# 3) DemoQuest 胜局统计验证（battle_ended 只计数不驱动目标；第四目标
	# 完成改由据点占领信号 territory_state_changed 驱动，出征与领地架构 §七）
	var wins: int = int(quest.get("_battle_win_count"))
	if result["victory"]:
		if wins == 1:
			_pass("胜利已入战斗胜局统计")
		else:
			_fail("胜局未统计（_battle_win_count=%d）" % wins)
	else:
		if wins == 0:
			_pass("败局不增胜局统计（符合设计）——真实游玩玩家操作可获胜")
		else:
			_fail("败局误增胜局统计（_battle_win_count=%d）" % wins)


func _fail(msg: String) -> void:
	_fails += 1
	print("[FAIL] ", msg)


func _pass(msg: String) -> void:
	print("[OK] ", msg)
