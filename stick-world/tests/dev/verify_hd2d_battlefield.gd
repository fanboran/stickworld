extends Node
## 验证探针：主街东门 → HD-2D 战场图（battlefield）旅行链。
##   godot --path stick-world res://tests/dev/verify_hd2d_battlefield.tscn
## 流程：实例化 GameRoot → 等主街就绪 → travel_to_map("battlefield", WALK, LEFT)
## （与东门 ChunkTrigger 同路径同方向）→ 断言战场图装配/出口/资源/出生点 → 截图 → 退出。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _fails: int = 0


func _ready() -> void:
	var gr: Node = GameRootScene.instantiate()
	add_child(gr)
	# 等 GameRoot 装配完成 + 初始地图加载（开局直连主街）
	await _wait(6.0)
	var sl: Node = gr.get("scene_loader")
	if sl == null or not sl.has_method("travel_to_map"):
		push_error("[verify_bf] scene_loader 不可用")
		get_tree().quit(1)
		return
	_check(String(sl.get("current_map_id")) == "hd2d_street", "初始图应为 hd2d_street")
	# 东门路径：ExitRight 触发 request_map_travel("battlefield", EntrySide.LEFT)
	sl.travel_to_map("battlefield", WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	await _wait(7.0)
	var map: Node2D = sl.get_current_map()
	_check(map != null, "战场图实例存在")
	if map == null:
		get_tree().quit(1)
		return
	_check(String(sl.get("current_map_id")) == "battlefield", "当前图应为 battlefield")
	var script_path: String = str(map.get_script().resource_path)
	_check(script_path.contains("hd2d_battlefield_map"), "宿主应为 Hd2dBattlefieldMap（实得 %s）" % script_path)
	# 玩家：从主街方向进（LEFT）→ 落战场西缘入口
	var player: Node2D = map.get_possessed_entity()
	_check(player != null, "玩家附身实体已生成")
	if player != null:
		var expect_x: float = float(map.get("map_left")) + 150.0
		_check(absf(player.global_position.x - expect_x) < 10.0,
				"玩家应在西缘入口 x≈%d（实得 %d）" % [int(expect_x), int(player.global_position.x)])
	# 出口触发器：森林图清退后只剩左出回主街
	var triggers: Node2D = map.get_node_or_null("ChunkTriggers")
	_check(triggers != null and triggers.get_child_count() == 1, "战场图应只剩左出触发器")
	if triggers != null:
		var el: Node = triggers.get_node_or_null("ExitLeft")
		_check(el != null and String(el.get("target_map_id")) == "hd2d_street", "左出应回主街")
	# 大乱斗战场不产资源（树丛=杂物，创始人 2026-09-15；资源采集在主街墙外带）
	var nodes := get_tree().get_nodes_in_group("resource_node")
	_check(nodes.size() == 0, "战场应无资源点（实得 %d）" % nodes.size())
	# 战场无城墙：无门洞传送带（get_gates 空 → 无传送条）
	var portals: Node = map.get_node_or_null("GatePortals")
	var strip_count: int = portals.get_child_count() if portals != null else 0
	_check(strip_count == 0, "战场不应有城门传送条（实得 %d）" % strip_count)
	# 3D 战场卡已落（战痕散布：自然物+遗物应有实例）
	var hd: Node3D = map.get_node_or_null("HD2DWorld")
	_check(hd != null, "3D 战场世界（HD2DWorld）已挂载")
	if hd != null:
		var props: Node3D = hd.get_node_or_null("Props")
		var n_props: int = 0
		var n_nature: int = 0
		if props != null:
			for c in props.get_children():
				var nm := str(c.name)
				if nm.begins_with("Prop_"):
					n_props += 1
				elif nm.begins_with("Nature_"):
					n_nature += 1
		_check(n_props == 0, "战场应无摆件杂物（创始人 2026-09-15：清空战痕遗物；实得 %d）" % n_props)
		_check(n_nature == 0, "战场应无战痕散布（同杂物清空口径；实得 %d）" % n_nature)
	print("[verify_bf] 断言完成：%d 失败" % _fails)
	await _shot()
	print("[verify_bf] DONE")
	await _wait(0.5)
	get_tree().quit(0 if _fails == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("[verify_bf] OK  " + what)
	else:
		_fails += 1
		push_error("[verify_bf] FAIL  " + what)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/proto_hd2d"))
	img.save_png("res://temp/proto_hd2d/verify_hd2d_battlefield.png")
	print("[verify_bf] shot -> temp/proto_hd2d/verify_hd2d_battlefield.png")
