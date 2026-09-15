extends Node
## 框位实测探针（渲染最终验证）：起真实 GameRoot（HD-2D 街）→ 选中最近的
## 角色 + 鼠标悬停其上 → 开 F3 → 截屏落盘。用于测量选中框/悬浮框/蓝碰撞箱
## 与角色 billboard 的实际像素关系（创始人报告错位的地面真相）。
## 运行：godot --path . res://tests/dev/probe_brackets.tscn （窗口模式，约 8s 退出）

const GAME_ROOT_SCENE: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const OUT := "res://temp/probe_brackets.png"


func _ready() -> void:
	var game_root: Node = GAME_ROOT_SCENE.instantiate()
	add_child(game_root)
	# 等地图就绪 + 实体生成
	var map: Node2D = null
	for i in 900:
		await get_tree().process_frame
		if game_root.has_method("get_current_map") and game_root.get_current_map() != null:
			map = game_root.get_current_map()
			if map.has_method("get_entities") and map.get_entities().size() >= 2:
				break
	print("[probe] map=", map)
	# 再等 1.5s 让 billboard/相机稳定
	for i in 90:
		await get_tree().process_frame
	var ents: Array = map.get_entities()
	# 玩家（第一个实体）+ 离玩家最近的 NPC
	var player: Node2D = ents[0] as Node2D
	var nearest: Node2D = null
	var best := 1e9
	for e in ents:
		var n2d := e as Node2D
		if n2d == null or n2d == player:
			continue
		var d := n2d.global_position.distance_to(player.global_position)
		if d < best:
			best = d
			nearest = n2d
	print("[probe] player=", player.global_position, " nearest=", nearest.global_position if nearest else Vector2.ZERO)
	# 只选中玩家（静止目标，镜头跟随不漂）；悬停玩家
	var sel: Node = game_root._selection_system
	sel.select_units([player])
	var map_has_remap: bool = map.has_method("remap_fx_pos")
	var xform: Transform2D = get_viewport().get_canvas_transform()
	var hover_screen: Vector2 = xform * (map.remap_fx_pos(player.global_position) if map_has_remap else player.global_position)
	Input.warp_mouse(hover_screen - Vector2(0, 40))
	# 等悬停扫描（10Hz 节流）+ 稳定帧，截屏前重取坐标（相机可能微移）
	for i in 25:
		await get_tree().process_frame
	xform = get_viewport().get_canvas_transform()
	var foot_screen: Vector2 = xform * (map.remap_fx_pos(player.global_position) if map_has_remap else player.global_position)
	print("[probe] final_foot_screen=", foot_screen)
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(ProjectSettings.globalize_path(OUT))
	print("[probe] saved ", OUT, " err=", err)
	get_tree().quit(0)
