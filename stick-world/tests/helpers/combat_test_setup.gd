extends RefCounted
## 战斗系统集成测试公共 setup。
##
## 从 test_selection_formation.gd 拆分（原 _run_tests_async / _spawn_test_units 逻辑），
## 供框选/编队/号令/战斗UI 四个测试文件复用：
## - 加载 game_root.tscn 并等待地图与实体生成
## - 取消玩家附身、切换到 BATTLE 模式
## - 获取 SelectionSystem / FormationSystem / TacticalOrders / CommandChain / UI 引用
## - 生成测试单位

const ScriptStickmanEntity := preload("res://modules/units/scripts/stickman_entity.gd")
const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")

## 测试单位起始 X
const UNIT_X_START: float = 1500.0
## 测试单位间距
const UNIT_SPACING: float = 80.0

## 加载的 GameRoot 实例
var game_root: Node = null
## 系统引用（setup 后可用）
var selection: Node = null
var formation: Node = null
var tactical: Node = null
var command_chain: Node = null
var map: Node2D = null
var battle_panel: Control = null
var minimap: Control = null
## 测试单位列表（spawn_test_units 后可用）
var units: Array = []


## 启动 GameRoot 并等待系统就绪（async）。
## host: 测试场景根节点（负责 add_child game_root）。
func start(host: Node) -> void:
	var packed := load("res://modules/world/scenes/game_root.tscn") as PackedScene
	if packed == null:
		print("[FATAL] 无法加载 game_root.tscn")
		host.get_tree().quit(1)
		return
	game_root = packed.instantiate()
	game_root.set("auto_demo_building", false)
	host.add_child(game_root)
	# 等待地图加载和实体生成
	for i in 8:
		await host.get_tree().process_frame
	# 取消玩家附身（避免干扰）
	_unpossess_player()
	# 切到 BATTLE 模式激活 SelectionSystem
	var dispatcher: Node = game_root.input_dispatcher
	if dispatcher != null:
		dispatcher.set_mode(PlayerControlAPI.Mode.BATTLE)
	for i in 2:
		await host.get_tree().process_frame
	selection = game_root.get_selection_system()
	formation = game_root.get_formation_system()
	tactical = game_root.get_tactical_orders()
	command_chain = game_root.get_command_chain()
	map = game_root.get_current_map()
	battle_panel = game_root.get_battle_panel()
	minimap = game_root.get_minimap()


## 生成 count 个测试单位（不附身，AI 接管），追加到 units。
func spawn_test_units(count: int) -> void:
	if map == null:
		return
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	for i in count:
		var x: float = UNIT_X_START + i * UNIT_SPACING
		var e: Node2D = map.spawn_entity(STICKMAN_SCENE, Vector2(x, spawn_y))
		if e == null:
			continue
		# 修正 Y：脚部对齐
		if e.get("foot_offset") != null:
			e.global_position.y = spawn_y - e.foot_offset
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		units.append(e)


## 取消玩家附身（避免输入干扰测试）
func _unpossess_player() -> void:
	if map == null:
		return
	for e in map.get_entities():
		if e is ScriptStickmanEntity and e.has_method("is_possessed") and e.is_possessed():
			e.set_possessed(false)


## 包含指定下标单位的最小世界矩形（带 padding）
func rect_for_units(indices: Array, padding: float = 25.0) -> Rect2:
	var min_x: float = INF
	var max_x: float = -INF
	var min_y: float = INF
	var max_y: float = -INF
	for i in indices:
		if i >= units.size():
			continue
		var u: Node2D = units[i]
		if not is_instance_valid(u):
			continue
		var p: Vector2 = u.global_position
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	return Rect2(min_x - padding, min_y - padding, (max_x - min_x) + padding * 2.0, (max_y - min_y) + padding * 2.0)
