extends Node
## 验证探针：HD-2D 街景图作为游戏地图加载（GameRoot 完整装配链）。
##   godot --path stick-world res://tests/dev/verify_hd2d_map.tscn
## 流程：实例化 GameRoot → 等地图就绪 → 切 hd2d_street → 等玩家生成 → 截图 → 退出。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

func _ready() -> void:
	var gr: Node = GameRootScene.instantiate()
	add_child(gr)
	# 等 GameRoot 装配完成 + 初始地图加载（村A）
	await _wait(6.0)
	var sl: Node = gr.get("scene_loader")
	if sl == null or not sl.has_method("load_map"):
		push_error("[verify_hd2d] scene_loader 不可用")
		get_tree().quit(1)
		return
	print("[verify_hd2d] 切换到 hd2d_street …")
	sl.load_map("hd2d_street")
	await _wait(6.0)
	var player: Node2D = gr.get("_player_entity") if "_player_entity" in gr else null
	if player == null:
		var ents: Array = sl.get_current_map().get_entities() if sl.get_current_map() != null else []
		print("[verify_hd2d] 地图实体数=%d" % ents.size())
	print("[verify_hd2d] 地图=%s" % (sl.get_current_map().name if sl.get_current_map() != null else "无"))
	await _shot()
	print("[verify_hd2d] DONE")
	await _wait(0.5)
	get_tree().quit(0)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://temp/proto_hd2d/verify_hd2d_map.png")
	print("[verify_hd2d] shot -> temp/proto_hd2d/verify_hd2d_map.png")
