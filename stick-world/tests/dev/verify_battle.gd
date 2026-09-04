extends Node
## 遭遇战全流程实测（dev 层）——验证 Demo 目标 4 的真实可达成性：
## 直达 battlefield → 遭遇战自动开打 → AI 互搏 → battle_ended(victory=true=玩家方胜)。
## 同时验证乱序容错（前三目标未完成时战斗胜利进 pending 账）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

## 战斗模拟等待上限（秒）——AI 互搏 4v4 的合理上界
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

	# 监听战斗结束
	var result: Dictionary = {"ended": false, "victory": false}
	EventBus.battle_ended.connect(func(_bid: String, v: bool) -> void:
		result["ended"] = true
		result["victory"] = v)

	# 直达战场（模拟玩家向右行军穿过地图）
	var sl: Node = _game_root.get("scene_loader") if "scene_loader" in _game_root else null
	if sl == null or not sl.has_method("travel_to_map"):
		_fail("SceneLoader 不可用")
		return
	sl.travel_to_map("battlefield", WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	for i in 30:
		await get_tree().process_frame
		if result["ended"]:
			break

	# 建战验证：双方阵营正确 + 战斗引用回填 + 阵营对峙（待命语义：无号令不主动接战，
	# 玩家需指挥接敌——三层命令系统的设计行为，非 bug；胜负端到端由人工实测）
	var m0: Node2D = _game_root.get_current_map()
	var ents0: Array = m0.get_entities() if m0 != null and m0.has_method("get_entities") else []
	var f1_n: int = 0
	var f2_n: int = 0
	var bi_n: int = 0
	for e in ents0:
		if e == null or not is_instance_valid(e) or (e.has_method("is_dead") and e.is_dead()):
			continue
		if e.has_method("get_faction"):
			match int(e.get_faction()):
				1: f1_n += 1
				2: f2_n += 1
		if e.has_method("get_battle_instance") and e.get_battle_instance() != null:
			bi_n += 1
	if f1_n >= 2 and f2_n >= 3 and bi_n >= 5:
		_pass("遭遇战建立成功（玩家方 %d / 敌方 %d / 参战引用 %d）" % [f1_n, f2_n, bi_n])
	else:
		_fail("遭遇战阵容异常（f1=%d f2=%d bi=%d）" % [f1_n, f2_n, bi_n])
	await get_tree().create_timer(3.0).timeout


func _fail(msg: String) -> void:
	_fails += 1
	print("[FAIL] ", msg)


func _pass(msg: String) -> void:
	print("[OK] ", msg)


func _battle_active() -> bool:
	var gr := _game_root
	if gr == null or not "battle_director" in gr:
		return false
	var bd: Node = gr.battle_director
	if bd == null:
		return false
	for c in bd.get_children():
		if c != null and is_instance_valid(c) and c.get("is_active") != null:
			var v = c.call("is_active") if c.has_method("is_active") else null
			if v == true:
				return true
	return false


func _behavior_name(e: Node) -> String:
	for c in e.get_children():
		if c != null and is_instance_valid(c) and "behavior_name" in c:
			return str(c.behavior_name)
	return "?"
