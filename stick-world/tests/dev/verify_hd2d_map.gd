extends Node
## 验证探针：启动直连 HD-2D 主街（GameRoot 完整装配链）。
##   godot --path stick-world res://tests/dev/verify_hd2d_map.tscn
## 流程：实例化 GameRoot → 初始图应直接是 hd2d_street（2026-09-14 启动直连，
## 不再先进村A再切换）→ 等玩家生成 → 断言资源点/出口触发器/碰撞 → 截图 → 退出。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _fails: int = 0


func _ready() -> void:
	var gr: Node = GameRootScene.instantiate()
	add_child(gr)
	# 等 GameRoot 装配完成 + 初始地图加载（启动直连：开局即主街）
	await _wait(6.0)
	var sl: Node = gr.get("scene_loader")
	if sl == null or not sl.has_method("load_map"):
		push_error("[verify_hd2d] scene_loader 不可用")
		get_tree().quit(1)
		return
	var map_id: String = String(sl.get("current_map_id"))
	_check(map_id == "hd2d_street", "初始图应直接是 hd2d_street（实得 %s，不得先进旧图再切）" % map_id)
	var map: Node2D = sl.get_current_map()
	_check(map != null, "地图实例存在")
	if map == null:
		get_tree().quit(1)
		return
	print("[verify_hd2d] 地图=%s" % map.name)
	# 玩家生成（附身实体）
	var player: Node2D = map.get_possessed_entity()
	_check(player != null, "玩家附身实体已生成")
	# 资源点（树/矿采集交互）：resource_node 组
	var nodes := get_tree().get_nodes_in_group("resource_node")
	_check(nodes.size() >= 10, "采集资源点已布置（实得 %d）" % nodes.size())
	# 出口触发器（东西村口）
	var triggers: Node2D = map.get_node_or_null("ChunkTriggers")
	_check(triggers != null and triggers.get_child_count() >= 2,
			"东西出口触发器存在（实得 %s）" % (str(triggers.get_child_count()) if triggers != null else "无"))
	# 碰撞墙（前排建筑/树矿挡人）
	var solids: Node = map.get_node_or_null("HD2DSolids")
	_check(solids != null and solids.get_child_count() >= 5,
			"碰撞墙已生成（实得 %s）" % (str(solids.get_child_count()) if solids != null else "无"))
	print("[verify_hd2d] 断言完成：%d 失败" % _fails)
	await _shot()
	print("[verify_hd2d] DONE")
	await _wait(0.5)
	get_tree().quit(0 if _fails == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("[verify_hd2d] OK  " + what)
	else:
		_fails += 1
		push_error("[verify_hd2d] FAIL  " + what)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://temp/proto_hd2d/verify_hd2d_map.png")
	print("[verify_hd2d] shot -> temp/proto_hd2d/verify_hd2d_map.png")
