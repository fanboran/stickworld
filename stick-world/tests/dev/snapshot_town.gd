extends Node
## 热闹小镇视觉快照（dev 层，不进 CI）——批次 4"人口扩充与配比"验收用。
##
## 用法（不要 --headless，真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_town.tscn
##
## 内容：village_a 加载后正片 spawn 10 村民（spawn_npcs 配比分配：铁匠 1 /
## 伐木 3 / 矿工 3 / 待业 3，[提案/待定] 配额见 professions.tres quota）；
## 村内补摆树×3 / 矿×3（village_a 硬化区+城墙净空带内无自然资源点，摆点
## 供伐木/挖矿劳作可见）。白天 12 点等村民到岗后：
##   - 右簇镜头（玩家 @1400）：铁匠占位工位打铁 + 伐木工伐木 + 矿工挖矿
##     + 闲逛混合 → town_overview_0..2.png
##   - 左簇镜头（玩家 @-600）：左簇矿工挖矿 + 待业村民闲逛 → town_left_0..2.png
## stdout 打印配比统计（spawn_npcs）+ 逐帧行为/位置证据。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const ScriptResourceNode := preload("res://modules/world/scripts/map/resource_node.gd")

## 村内摆点（右簇树/矿 + 左簇矿；避开出生点与占位工位 1120）
const TREE_XS: Array = [1430.0, 1560.0, 1690.0]
const ORE_RIGHT_XS: Array = [1780.0]
const ORE_LEFT_XS: Array = [-420.0, -560.0]
const WORK_WAIT_SEC := 18.0
const SHOT_COUNT := 3
const SHOT_INTERVAL := 1.0
const DAY_HOUR := 12.0
## 两个镜头位（右簇 = 铁匠工位/伐木区；左簇 = 左侧矿工/待业闲逛区）
const CAM_RIGHT_X := 1400.0
const CAM_LEFT_X := -600.0


func _ready() -> void:
	_run()


func _run() -> void:
	var game_root: Node = GameRootScene.instantiate()
	add_child(game_root)
	var map: Node2D = null
	for i in 120:
		map = game_root.get_current_map()
		if map != null:
			break
		await get_tree().process_frame
	if map == null:
		push_error("[SNAPSHOT] 地图未加载")
		get_tree().quit(1)
		return
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	var layer: Node = map.get("decoration_layer")
	var env: Node = game_root.get_node_or_null("EnvironmentSystem")

	# 村内摆资源点（village_a 净空带内无自然资源点，摆点供劳作可见）
	for x_v in TREE_XS:
		_spawn_node(layer, ScriptResourceNode.ResourceType.WOOD, float(x_v), spawn_y, 500)
	for x_v in ORE_RIGHT_XS:
		_spawn_node(layer, ScriptResourceNode.ResourceType.METAL, float(x_v), spawn_y, 400)
	for x_v in ORE_LEFT_XS:
		_spawn_node(layer, ScriptResourceNode.ResourceType.METAL, float(x_v), spawn_y, 400)

	# 时钟钉正午（工作时段；每帧截图前重钉防自然推进越过 19 点收工线）
	_pin_clock(env, DAY_HOUR)
	await get_tree().create_timer(3.0).timeout

	# 等村民走到劳作点进入劳作循环
	for i in int(WORK_WAIT_SEC):
		await get_tree().create_timer(1.0).timeout
		_pin_clock(env, DAY_HOUR)

	# ── 右簇镜头：铁匠打铁 + 伐木/挖矿 + 闲逛混合 ──
	_teleport_player(game_root, map, CAM_RIGHT_X, spawn_y)
	for i in SHOT_COUNT:
		_pin_clock(env, DAY_HOUR)
		print("[SNAPSHOT] === 右簇镜头（%.1f 点，工位/伐木/挖矿/闲逛混合）===" % _hour(env))
		_dump_villagers(map, "right")
		_save_shot("res://tests/dev/town_overview_%d.png" % i)
		await get_tree().create_timer(SHOT_INTERVAL).timeout

	# ── 左簇镜头：左侧矿工 + 待业村民闲逛 ──
	_teleport_player(game_root, map, CAM_LEFT_X, spawn_y)
	_pin_clock(env, DAY_HOUR)
	await get_tree().create_timer(1.5).timeout
	for i in SHOT_COUNT:
		_pin_clock(env, DAY_HOUR)
		print("[SNAPSHOT] === 左簇镜头（%.1f 点，矿工/待业闲逛）===" % _hour(env))
		_dump_villagers(map, "left")
		_save_shot("res://tests/dev/town_left_%d.png" % i)
		await get_tree().create_timer(SHOT_INTERVAL).timeout
	get_tree().quit(0)


## 玩家传送到指定 X（镜头跟随），对齐地面线
func _teleport_player(game_root: Node, map: Node2D, x: float, spawn_y: float) -> void:
	var player: Node2D = _find_player(map)
	var cam_rig: Variant = game_root.get("camera_rig")
	if player != null:
		player.global_position = Vector2(x, spawn_y - player.foot_offset)
		if cam_rig != null and cam_rig.has_method("snap_to_follow_target"):
			cam_rig.snap_to_follow_target()


func _pin_clock(env: Node, hour: float) -> void:
	if env != null and env.has_method("set_time_of_day"):
		env.set_time_of_day(hour)


func _hour(env: Node) -> float:
	if env != null and env.has_method("get_time_of_day"):
		return env.get_time_of_day()
	return -1.0


func _save_shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[SNAPSHOT] saved: ", path)


func _spawn_node(layer: Node, type: int, x: float, y: float, amount: int) -> void:
	if layer == null:
		return
	var node: Node2D = ScriptResourceNode.new()
	node.resource_type = type
	node.amount = amount
	node.position = Vector2(x, y)
	layer.add_child(node)


func _find_player(map: Node2D) -> Node2D:
	var host: Node2D = map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return null
	for u in host.get_children():
		if u.has_method("is_possessed") and u.is_possessed():
			return u
	return null


## 全村民行为/位置证据（含待业——待业村民应呈 idle/wander 而非罚站缺失）
func _dump_villagers(map: Node2D, phase: String) -> void:
	var host: Node = map.get_node_or_null("EntityHost")
	if host == null:
		return
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if not u.has_method("get_profession") or not bool(u.get("is_villager")):
			continue
		var prof: String = String(u.get_profession())
		var tag: String = prof if not prof.is_empty() else "<待业>"
		var ctl: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		var behavior: String = ctl.get_current_behavior() if ctl != null else "?"
		print("[VILLAGER:%s] pos=(%.0f, %.0f) profession='%s' behavior='%s'" % [
			phase, u.global_position.x, u.global_position.y, tag, behavior])
