extends Node
## 采集劳作视觉快照（dev 层，不进 CI）——批次 2"村里有人在干活"验收用。
##
## 用法（不要 --headless，真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_harvest.tscn
##
## 内容：村庄加载后摆树/矿在村民旁（净空带内，寻位必命中），补 spawn 矿工
## 凑齐三职业；等村民进 harvest 行为走到资源点劳作，玩家传送至劳作区，
## 相机跟随连拍 6 帧（0.6s 间隔，覆盖挥击节拍）。stdout 打印每个村民的
## 职业/当前行为/位置作程序化证据。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const ScriptResourceNode := preload("res://modules/world/scripts/map/resource_node.gd")

## 摆点与等待（与集成测试同口径：净空带内摆点，寻位确定性命中）
const TREE_X := 1500.0
const ORE_X := 1700.0
const WORK_WAIT_SEC := 18.0
const SHOT_COUNT := 6
const SHOT_INTERVAL := 0.6

var _game_root: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	# 等地图就绪（get_current_map 非空即摆点，抢在 NPC 首次采集决策之前）
	var map: Node2D = null
	for i in 120:
		map = _game_root.get_current_map()
		if map != null:
			break
		await get_tree().process_frame
	if map == null:
		push_error("[SNAPSHOT] 地图未加载")
		get_tree().quit(1)
		return
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	var layer: Node = map.get("decoration_layer")

	# 摆树/矿（村民出生区 1050/1250 之右，寻位必命中）
	_spawn_node(layer, ScriptResourceNode.ResourceType.WOOD, TREE_X, spawn_y, 500)
	_spawn_node(layer, ScriptResourceNode.ResourceType.METAL, ORE_X, spawn_y, 500)

	# 补 spawn 矿工（轮转 index=2 凑三职业）
	var miner: Node2D = map.spawn_entity(UnitsAPI.STICKMAN_ENTITY_SCENE, Vector2(1150.0, spawn_y))
	if miner != null:
		miner.global_position.y = spawn_y - miner.foot_offset
		miner.set_possessed(false)
		TownLifeAPI.assign_village_job(miner, 2)

	# 等 NPC 首轮决策落地（可能竞态寻到远处天然资源点），然后全员回 idle
	# 强制重寻位——此时摆点已在，寻位必命中劳作点（观感脚本专用，测试不依赖）
	await get_tree().create_timer(3.0).timeout
	_reset_villagers(map)

	# 等村民走到劳作点进入劳作循环
	await get_tree().create_timer(WORK_WAIT_SEC).timeout

	# 玩家传送到劳作区中央（镜头面向三劳作点：工位 1120 / 树 1500 / 矿 1700），
	# 相机跟随 + snap
	var player: Node2D = _find_player(map)
	var cam_rig: Variant = _game_root.get("camera_rig")
	if player != null:
		player.global_position = Vector2(1400.0, spawn_y - player.foot_offset)
		if cam_rig != null and cam_rig.has_method("snap_to_follow_target"):
			cam_rig.snap_to_follow_target()
	await get_tree().create_timer(0.5).timeout

	# 程序化证据：村民职业/行为/位置
	_dump_villagers(map)

	# 连拍（覆盖挥击节拍：cycle 4~5s 一拍，play_attack ~0.8s）
	for i in SHOT_COUNT:
		var img := get_viewport().get_texture().get_image()
		var path := "res://tests/dev/harvest_out_%d.png" % i
		img.save_png(path)
		print("[SNAPSHOT] saved: ", path)
		await get_tree().create_timer(SHOT_INTERVAL).timeout
	get_tree().quit(0)


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


func _dump_villagers(map: Node2D) -> void:
	var host: Node = map.get_node_or_null("EntityHost")
	if host == null:
		return
	for u in host.get_children():
		if not (u is Node2D) or not is_instance_valid(u):
			continue
		if not u.has_method("get_profession"):
			continue
		var ctl: Node = u.get_ai_controller() if u.has_method("get_ai_controller") else null
		var sm: Node = ctl.get_state_machine() if ctl != null else null
		var behavior: String = sm.get_current_behavior_name() if sm != null else "?"
		var prof: String = String(u.get_profession())
		if prof.is_empty() and not (u.has_method("is_possessed") and u.is_possessed()):
			continue
		# 劳作目标证据：harvest 行为的当前目标资源点位置
		var target := "?"
		if sm != null and behavior == "harvest":
			var hv: Node = sm.get_node_or_null("BehaviorHarvest")
			if hv != null and hv.has_method("get_target_node"):
				var tn: Node2D = hv.get_target_node()
				target = "(%.0f, %.0f)" % [tn.global_position.x, tn.global_position.y] if tn != null else "worksite"
		print("[VILLAGER] pos=(%.0f, %.0f) profession='%s' behavior='%s' anim='%s' target=%s" % [
			u.global_position.x, u.global_position.y, prof, behavior, u.get_current_anim(), target])
