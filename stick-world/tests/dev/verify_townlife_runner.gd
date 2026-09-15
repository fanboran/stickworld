extends Node
## 实机验证流程（挂在 SceneTree.root，跨场景存活）：主街村民读档恢复劳作
## town_life 批次 5 端到端——新游戏直连主街 → 等村民上工 → 证据+截图 →
## save_game(9) → boot 读档（boot_load_slot 路径 = 读档恢复修复目标）→
## 等恢复后上工 → 证据+截图 → 清档退出。
## 跑法：godot --path stick-world res://tests/dev/verify_townlife_restore.tscn
## 产物：user://shots/townlife_{newgame,restored}_*.png + stdout 逐人证据。

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const SHOT_DIR := "user://shots"
const SLOT := 9
const SETTLE_SEC := 45.0   # 世界就绪后等待时长（村民出城门通勤 + 天亮）


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	await _frames(5)
	# ── 新游戏：启动直连主街（boot_load_slot=-1 → 新游戏开局）──
	get_tree().change_scene_to_file(GAME_ROOT_SCENE)
	await _wait_world(90.0)
	await _settle(SETTLE_SEC)
	_dump("NEWGAME")
	await _focus_shot("townlife_newgame_a")
	await _settle(20.0)
	await _focus_shot("townlife_newgame_b")
	# ── 存档 → boot 读档（读档路径 = 修复目标：_restore_entities 回填职业/标志）──
	SaveManager.save_game(SLOT)
	SaveManager.boot_load_slot = SLOT
	get_tree().change_scene_to_file(GAME_ROOT_SCENE)
	await _wait_world(120.0)
	await _settle(SETTLE_SEC)
	_dump("RESTORED")
	await _focus_shot("townlife_restored_a")
	await _settle(20.0)
	await _focus_shot("townlife_restored_b")
	if SaveManager.has_method("delete_game"):
		SaveManager.delete_game(SLOT)
	print("=== TOWNLIFE VERIFY DONE ===")
	get_tree().quit()


## 等世界加载完成（地图 + 玩家实体就绪），超时只告警不中断
func _wait_world(timeout: float) -> void:
	var t := 0.0
	while t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
		var gr := get_tree().current_scene
		if gr != null and gr.has_method("get_current_map") and gr.has_method("get_player_entity"):
			if gr.get_current_map() != null and gr.get_player_entity() != null:
				await _frames(10)
				return
	print("[Verify] WARN: 等世界超时 %.0fs" % timeout)


func _settle(sec: float) -> void:
	var t := 0.0
	while t < sec:
		await get_tree().process_frame
		t += get_process_delta_time()


## stdout 逐人证据：职业/行为/位置 + 在岗统计
func _dump(tag: String) -> void:
	var gr := get_tree().current_scene
	var map: Node2D = gr.get_current_map() if gr != null and gr.has_method("get_current_map") else null
	if map == null:
		print("[Verify:%s] 无地图" % tag)
		return
	var n_villager := 0
	var n_active := 0
	for e in map.get_entities():
		if not is_instance_valid(e) or not bool(e.get("is_villager")):
			continue
		n_villager += 1
		var prof := String(e.call("get_profession"))
		var behav := _behavior_of(e)
		var pos: Vector2 = e.global_position
		print("[Verify:%s] %s 职业='%s' 行为=%s pos=(%.0f, %.0f)" % [tag, e.name, prof, behav, pos.x, pos.y])
		if prof != "" and behav in ["harvest", "work", "haul", "walk"]:
			n_active += 1
	print("[Verify:%s] 村民 %d 人，劳作/通勤中 %d 人" % [tag, n_villager, n_active])


func _behavior_of(e: Node2D) -> String:
	if not e.has_method("get_ai_controller"):
		return "?"
	var ai: Node = e.call("get_ai_controller")
	if ai == null or not is_instance_valid(ai):
		return "?"
	var sm: Variant = ai.get("_state_machine")
	if sm == null or not is_instance_valid(sm):
		return "?"
	if sm.has_method("get_current_behavior_name"):
		return str(sm.call("get_current_behavior_name"))
	return "?"


## 截图前把镜头平移到一名在岗/通勤村民（2D 相机 x → 3D 相机逐帧镜像）；
## 无在岗村民则落默认机位。镜头跟随是死区跟随，短暂直设可保持到出画。
func _focus_shot(shot_name: String) -> void:
	var gr := get_tree().current_scene
	var map: Node2D = gr.get_current_map() if gr != null and gr.has_method("get_current_map") else null
	var target: Node2D = null
	if map != null:
		for e in map.get_entities():
			if not is_instance_valid(e) or not bool(e.get("is_villager")):
				continue
			var prof := String(e.call("get_profession"))
			var behav := _behavior_of(e)
			if prof != "" and behav in ["harvest", "work", "haul"]:
				target = e
				if behav == "harvest":
					break   # 正在挥工具的最优先
			elif target == null and prof != "":
				target = e
	var rig: Variant = gr.get("camera_rig") if gr != null else null
	if target != null and rig != null and rig is Node2D:
		var cam: Node2D = rig
		cam.global_position.x = target.global_position.x
		await _frames(12)   # 等 3D 相机镜像 + 死区稳定
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[Verify] %s.png（target=%s）" % [shot_name, target.name if target != null else "default"])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
