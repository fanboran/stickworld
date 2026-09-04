extends Node
## Demo 目标链全流程验证（dev 层，不进 CI）。
##
## 用法：godot --headless --path stick-world res://tests/dev/verify_quest.tscn
##
## 模拟玩家走完四个阶段目标（采集→建造→编队→战斗），断言：
## 1. DemoQuest 装配存在且初始指向第 1 个目标
## 2. 采集 60 木后目标推进
## 3. 建造/编队/战斗事件逐个推进
## 4. 全部完成后 VictoryOverlay 出现且可见

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null
var _fails: int = 0


func _ready() -> void:
	await _run()
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(_fails)


func _run() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	# 等装配（含 deferred 队列：construction → resources → demo_quest）
	for i in 20:
		await get_tree().process_frame

	var quest: Node = _game_root.get_node_or_null("DemoQuest")
	if quest == null:
		return _fail("DemoQuest 未装配")
	_pass("DemoQuest 已装配")

	var res_api: Node = get_tree().current_scene.find_child("ResourcesApi", true, false)
	if res_api == null:
		return _fail("ResourcesApi 未找到")

	# 阶段 1：采集 60 木（基线法：直接 produce 60 即视为采集增量）
	var idx0: int = int(quest.get("_index"))
	if idx0 != 0:
		_fail("初始目标不是第 1 个（_index=%d）" % idx0)
	else:
		_pass("初始目标 = 采集资源")
	res_api.produce("res_wood", 60.0, "test_region", "验证采集")
	await get_tree().process_frame
	if int(quest.get("_index")) != 1:
		_fail("采集完成后未推进到建造目标（_index=%d）" % int(quest.get("_index")))
	else:
		_pass("采集目标完成 → 推进到建造")

	# 阶段 2：建造完工事件
	var c_api: Node = _game_root.get("get_construction_api").call()
	if c_api == null or not c_api.has_signal("building_completed"):
		_fail("ConstructionApi 缺 building_completed 信号")
	else:
		c_api.building_completed.emit("b_verify", "test_region")
		await get_tree().process_frame
		if int(quest.get("_index")) != 2:
			_fail("建造完成后未推进（_index=%d）" % int(quest.get("_index")))
		else:
			_pass("建造目标完成 → 推进到编队")

	# 阶段 3：编队创建事件（EventBus）
	EventBus.squad_created.emit("sq_verify", [])
	await get_tree().process_frame
	if int(quest.get("_index")) != 3:
		_fail("编队完成后未推进（_index=%d）" % int(quest.get("_index")))
	else:
		_pass("编队目标完成 → 推进到战斗")

	# 阶段 4：战斗胜利事件
	EventBus.battle_ended.emit("bt_verify", true)
	await get_tree().process_frame
	if not bool(quest.get("_victory_shown")):
		_fail("战斗胜利后未触发胜利结算")
	else:
		_pass("战斗目标完成 → 胜利结算触发")

	# 胜利画面挂载检查
	var ui_root: Node = _game_root.get("ui_root") if "ui_root" in _game_root else null
	var victory: Node = ui_root.get_node_or_null("ModalOverlay/VictoryOverlay") if ui_root != null else null
	if victory == null:
		_fail("VictoryOverlay 未挂载到 ModalOverlay")
	elif not victory.visible:
		_fail("VictoryOverlay 已挂载但不可见")
	else:
		_pass("VictoryOverlay 挂载且可见")


func _fail(msg: String) -> void:
	_fails += 1
	print("[FAIL] ", msg)


func _pass(msg: String) -> void:
	print("[OK] ", msg)
