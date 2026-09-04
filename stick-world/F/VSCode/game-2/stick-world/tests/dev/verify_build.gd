extends Node
## 玩家建造路径真系统验证（dev 层）——走完整链路验证 Demo 目标 2 可达成：
## BuildMenu 放置的底层 = ConstructionApi.start_construction_at → 材料扣减 →
## 施工推进（模拟玩家 E 敲击的 add_build_progress）→ building_completed 信号 →
## DemoQuest 目标推进。不 emit 假信号，全真系统。

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
	for i in 20:
		await get_tree().process_frame

	var c_api: Node = _game_root.get("get_construction_api").call() if _game_root.has_method("get_construction_api") else null
	if c_api == null:
		return _fail("ConstructionApi 未就绪")
	var quest: Node = _game_root.get_node_or_null("DemoQuest")
	var res_api: Node = get_tree().current_scene.find_child("ResourcesApi", true, false)
	if quest == null or res_api == null:
		return _fail("DemoQuest/ResourcesApi 未就绪")

	# 1) 找一个可建造的 def（注册表里第一个非 warehouse）
	var def_ids: Array = c_api.get_registered_def_ids() if c_api.has_method("get_registered_def_ids") else []
	if def_ids.is_empty():
		return _fail("建筑注册表为空")
	var target_def: String = ""
	for d in def_ids:
		if str(d) != "warehouse" and str(d) != "placeholder":
			target_def = str(d)
			break
	if target_def.is_empty():
		target_def = str(def_ids[0])
	_pass("可建造建筑 def：%s（注册 %d 种）" % [target_def, def_ids.size()])

	# 2) 记录建造前资源（验证材料扣减）
	var wood_before: float = res_api.get_stock("res_wood", "")

	# 3) 放置（玩家路径底层；cell 选一块空地——右半区 120 格）
	var result: Dictionary = c_api.start_construction_at("test_region", target_def, 120, "", -1)
	if not bool(result.get("ok", false)):
		return _fail("start_construction_at 失败：%s" % str(result.get("error", result)))
	_pass("工地创建成功（cell=120）")

	# 4) 施工推进：模拟玩家 E 敲击（每次 total_work/8，敲 10 次必完）
	var completed: bool = false
	var done_watcher: Callable = func(_bid: String, _rid: String): completed = true
	if c_api.has_signal("building_completed"):
		c_api.building_completed.connect(done_watcher)
	for hit in 12:
		# 经工地对象推进（与 interaction_controller 同路径）
		var projects: Array = c_api.get_active_projects("test_region") if c_api.has_method("get_active_projects") else []
		if projects.is_empty():
			break
		var project = projects[0]
		if project.get("is_completed") if "is_completed" in project else (project.has_method("is_completed") and project.is_completed()):
			break
		if project.has_method("needs_material") and project.needs_material():
			# 材料未到位（搬运工未跑）：手动补齐交付模拟
			if project.has_method("deliver_material"):
				project.deliver_material()
		elif project.has_method("add_build_progress"):
			project.add_build_progress(float(project.get("total_work")) / 8.0)
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	if not completed:
		_fail("12 次敲击后建筑未完工（材料链或施工链断了）")
	else:
		_pass("建筑完工信号发出（真系统链路通）")

	# 5) 资源扣减验证
	var wood_after: float = res_api.get_stock("res_wood", "")
	if wood_after >= wood_before:
		_fail("建造未消耗木材（before=%f after=%f）" % [wood_before, wood_after])
	else:
		_pass("材料扣减正常（木材 %.0f → %.0f）" % [wood_before, wood_after])

	# 6) DemoQuest 目标 2 是否推进（当前若在 build 目标应完成）
	if int(quest.get("_index")) >= 2 or bool(quest.get("_victory_shown")):
		_pass("DemoQuest 建造目标推进")
	else:
		_fail("DemoQuest 未推进到建造目标之后（_index=%d）" % int(quest.get("_index")))


func _fail(msg: String) -> void:
	_fails += 1
	print("[FAIL] ", msg)


func _pass(msg: String) -> void:
	print("[OK] ", msg)
