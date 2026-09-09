extends Node
## 工作-休息节律视觉快照（dev 层，不进 CI）——批次 3"白天在岗劳作 + 空闲走动
## 两态"验收用。
##
## 用法（不要 --headless，真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_rhythm.tscn
##
## 内容：村庄加载后摆树/矿在村民旁（白天三职业各有活干）；白天 12 点截
## rhythm_day_0..2.png（在岗劳作：铁匠工位打铁/伐木挥斧/矿工挥镐）；
## 调 23 点截 rhythm_night_0..2.png（休息态：收工 idle/概率 wander 散逛，
## 画面呈夜色）。stdout 打印每帧时间/村民职业/行为/位置作程序化证据。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const ScriptResourceNode := preload("res://modules/world/scripts/map/resource_node.gd")

## 摆点（村民出生区 1050/1250 之右净空带，寻位必命中）
const TREE_X := 1500.0
const ORE_X := 1700.0
const WORK_WAIT_SEC := 18.0
const SHOT_COUNT := 3
const DAY_SHOT_INTERVAL := 1.0
const NIGHT_SHOT_INTERVAL := 1.5
const NIGHT_SETTLE_SEC := 6.0
## 节律时钟（游戏小时）
const DAY_HOUR := 12.0
const NIGHT_HOUR := 23.0


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

	# 摆树/矿（三职业白天各有活干；铁匠走占位工位 1120）
	_spawn_node(layer, ScriptResourceNode.ResourceType.WOOD, TREE_X, spawn_y, 500)
	_spawn_node(layer, ScriptResourceNode.ResourceType.METAL, ORE_X, spawn_y, 500)

	# 补 spawn 矿工（轮转 index=2 凑三职业）
	var miner: Node2D = map.spawn_entity(UnitsAPI.STICKMAN_ENTITY_SCENE, Vector2(1150.0, spawn_y))
	if miner != null:
		miner.global_position.y = spawn_y - miner.foot_offset
		miner.set_possessed(false)
		TownLifeAPI.assign_village_job(miner, 2)

	# 时钟归正午（工作时段）并保持：等待/摆点期间自然推进（60s=1 游戏日）
	# 会越过 19 点收工线，摆点后与每帧截图前都钉回 DAY_HOUR
	_pin_clock(env, DAY_HOUR)
	await get_tree().create_timer(3.0).timeout
	_reset_villagers(map)

	# 等村民走到劳作点进入劳作循环（期间保持白天）
	for i in int(WORK_WAIT_SEC):
		await get_tree().create_timer(1.0).timeout
		_pin_clock(env, DAY_HOUR)

	# 玩家传送到劳作区（镜头面向 工位 1120 / 树 1500 / 矿 1700）
	var player: Node2D = _find_player(map)
	var cam_rig: Variant = game_root.get("camera_rig")
	if player != null:
		player.global_position = Vector2(1400.0, spawn_y - player.foot_offset)
		if cam_rig != null and cam_rig.has_method("snap_to_follow_target"):
			cam_rig.snap_to_follow_target()
	_pin_clock(env, DAY_HOUR)
	await get_tree().create_timer(0.5).timeout

	# ── 白天段：在岗劳作 ──
	for i in SHOT_COUNT:
		_pin_clock(env, DAY_HOUR)
		print("[SNAPSHOT] === 白天段（%.1f 点，在岗劳作）===" % _hour(env))
		_dump_villagers(map, "day")
		_save_shot("res://tests/dev/rhythm_day_%d.png" % i)
		await get_tree().create_timer(DAY_SHOT_INTERVAL).timeout

	# ── 夜间段：收工休息 ──
	_pin_clock(env, NIGHT_HOUR)
	await get_tree().create_timer(NIGHT_SETTLE_SEC).timeout
	for i in SHOT_COUNT:
		_pin_clock(env, NIGHT_HOUR)
		print("[SNAPSHOT] === 夜间段（%.1f 点，收工休息）===" % _hour(env))
		_dump_villagers(map, "night")
		_save_shot("res://tests/dev/rhythm_night_%d.png" % i)
		await get_tree().create_timer(NIGHT_SHOT_INTERVAL).timeout
	get_tree().quit(0)


## 把游戏时钟钉在指定小时（EnvironmentSystem 每帧推进 WorldState.game_time，
## dev 观感脚本显式管理节律时钟，防自然推进越过收工线）
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


## 全员回 idle：打断已有 harvest（可能寻在摆点前的远处资源点上），
## idle 完成后决策层重新 _try_harvest，此时摆点已就位
func _reset_villagers(map: Node2D) -> void:
	for npc in _villagers(map):
		var ctl: Node = npc.get_ai_controller() if npc.has_method("get_ai_controller") else null
		if ctl != null and ctl.get_state_machine() != null:
			ctl.get_state_machine().travel("idle")


## 村民列表（EntityHost 内非附身、有职业的实体）
func _villagers(map: Node2D) -> Array:
	var result: Array = []
	var host: Node = map.get_node_or_null("EntityHost")
	if host == null:
		return result
	for u in host.get_children():
		if u is Node2D and is_instance_valid(u) \
				and u.has_method("get_profession") and not String(u.get_profession()).is_empty() \
				and u.has_method("is_possessed") and not u.is_possessed():
			result.append(u)
	return result


func _dump_villagers(map: Node2D, phase: String) -> void:
	var host: Node = map.get_node_or_null("EntityHost")
	if host == null:
		return
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if not u.has_method("get_profession"):
			continue
		var prof: String = String(u.get_profession())
		if prof.is_empty():
			continue
		var ctl: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		var behavior: String = ctl.get_current_behavior() if ctl != null else "?"
		print("[VILLAGER:%s] pos=(%.0f, %.0f) profession='%s' behavior='%s'" % [
			phase, u.global_position.x, u.global_position.y, prof, behavior])
