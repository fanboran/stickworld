extends Node
## 采集闭环功能验证（dev 层，不进 CI）——验证"E 采集资源点 → ResourcesApi 入库"链路。
##
## 用法：
##   godot --headless --path stick-world res://tests/dev/verify_harvest.tscn
##
## 验证内容：
## 1. 村庄加载后 resource_node 组非空（程序化生成正常）
## 2. 直接调用玩家交互控制器的采集方法 → 对应资源库存增加
## 3. 采空一个资源点 → 节点自毁（is_depleted / queue_free）

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	var failures: int = 0
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	for i in 15:
		await get_tree().process_frame

	# 1) 资源点已生成
	var nodes: Array = get_tree().get_nodes_in_group("resource_node")
	if nodes.is_empty():
		_fail("资源点组为空：程序化生成未跑或组名变了", failures)
		_quit(1)
		return
	_pass("资源点生成正常：%d 个" % nodes.size())

	# 2) 找玩家（possessed 实体）与其交互控制器
	var player: Node2D = _find_player()
	if player == null:
		_fail("未找到附身玩家实体", failures)
		_quit(1)
		return
	var interaction: Node = player.get_node_or_null("InteractionController")
	if interaction == null:
		_fail("玩家没有 InteractionController 子节点（节点名不对？）", failures)
		_quit(1)
		return

	var api: Node = get_tree().current_scene.find_child("ResourcesApi", true, false)
	if api == null:
		_fail("未找到 ResourcesApi 节点", failures)
		_quit(1)
		return

	# 挑一个非耗尽资源点，记录采集前库存
	var rn: Node2D = null
	for n in nodes:
		if n is Node2D and is_instance_valid(n) and not (n as Node2D).is_in_group("resource_node") == false:
			var candidate := n as Node2D
			if not candidate.has_method("is_depleted") or not candidate.is_depleted():
				rn = candidate
				break
	if rn == null:
		_fail("没有可采集的资源点", failures)
		_quit(1)
		return
	var rid: String = String(rn.get_resource_id())
	var before: float = float(api.get_stock(rid, ""))

	# 直接调用采集（绕过按键；_try_harvest_resource_node 不含距离检查）
	interaction._try_harvest_resource_node(rn)
	await get_tree().process_frame
	var after: float = float(api.get_stock(rid, ""))
	if after <= before:
		_fail("采集后库存未增加：%s before=%f after=%f" % [rid, before, after], failures)
	else:
		_pass("采集入库正常：%s +%d（%f → %f）" % [rid, int(after - before), before, after])

	# 3) 连续采到耗尽 → 节点应自毁
	var amount_left: int = int(rn.amount) if is_instance_valid(rn) else 0
	var guard: int = 0
	while is_instance_valid(rn) and guard < 50:
		interaction._try_harvest_resource_node(rn)
		guard += 1
		await get_tree().process_frame
	if is_instance_valid(rn):
		_fail("采空后节点未自毁（剩余 %d，guard=%d）" % [int(rn.amount), guard], failures)
	else:
		_pass("资源点采空自毁正常（共 %d 次采集）" % guard)

	_quit(failures)


# ─────────────────────────────── 工具 ────────────────────────────────

func _find_player() -> Node2D:
	var map: Node2D = _game_root.get_current_map()
	if map == null or not map.has_method("get_entities"):
		return null
	for e in map.get_entities():
		var ent := e as Node2D
		if ent != null and ent.has_method("is_possessed") and ent.is_possessed():
			return ent
	return null


func _fail(msg: String, _n: int) -> void:
	print("[FAIL] ", msg)


func _pass(msg: String) -> void:
	print("[OK] ", msg)


func _quit(code: int) -> void:
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(code)
