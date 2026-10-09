extends Node
## 小地图几何真值探针 —— 打印投影参数、行走带、建筑占地、实体位置到小地图坐标的换算。
##
## 为什么需要：小地图的"位置/比例对不对"只能靠**数值对账**（世界 px → 小地图 px），
## 肉眼在两个域里比距离不可靠。怀疑"点/块位置不对""比例不对"时先跑本探针：
## 拿横向/纵向比例尺（px/px）、各世界线（天地分界 / 行走带前后沿 / 地面带底）的
## 落点、每栋建筑的真占地（宽 × 纵深）与实体落点，再判断问题在数据还是落笔。
##
## 运行（要窗口）：godot --path stick-world res://tests/dev/probe_minimap_geom.tscn

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
var _gr: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	_gr = GameRootScene.instantiate()
	add_child(_gr)
	var map: Node2D = null
	for i in 1800:
		map = _gr.get_current_map()
		if map != null:
			break
		await get_tree().process_frame
	for i in 30:
		await get_tree().process_frame
	if map == null:
		print("[FAIL] 地图未就绪")
		get_tree().quit(1)
		return

	var mm: Control = _gr.ui_root.get_node_or_null("HudOverlay/Minimap")
	var info: Array = mm.get_map_info()
	var w: float = mm.get_map_width_px()
	print("=== 小地图 %.1f×120  地图 x[%.1f, %.1f] w=%.1f ===" % [w, info[0], info[1], info[1] - info[0]])
	print("[投影] ground_y=%.1f ground_bottom=%.1f 深度=%.1f  比例=%s" % [
			info[2], map.get_ground_bottom(), map.get_ground_bottom() - info[2], info[3]])
	print("[HD] walk_back_y=%.1f walk_front_y=%.1f（行走带 %.1f 深）" % [
			map.walk_back_y, map.walk_front_y, map.walk_front_y - map.walk_back_y])
	print("[世界↔小地图] 横向 %.3f px/px，纵向(地面带 %.1f px 装 %.1f 世界px) %.3f px/px"
			% [(info[1] - info[0]) / w, 120.0 * (1.0 - float(info[3])),
			map.get_ground_bottom() - info[2],
			(map.get_ground_bottom() - info[2]) / (120.0 * (1.0 - float(info[3])))])
	var poly := MinimapPainter.build_snapshot(map, info)
	var rect := Rect2(Vector2.ZERO, Vector2(w, 120.0))
	# 关键世界线 → 小地图 y
	for pair in [["天地分界", float(info[2]) - 0.0], ["行走带后沿(walk_back)", map.walk_back_y],
			["行走带前沿(walk_front)", map.walk_front_y], ["地面带底", map.get_ground_bottom()]]:
		print("  y %-22s 世界 %.1f → 小地图 %.1f" % [pair[0], pair[1],
				MinimapPainter.world_to_y(pair[1], rect, poly)])

	# 建筑占地带：get_building_rects() = [x0格,x1格,y0px,y1px,基线px,可视高px,...]
	var rects: Array = map.get_building_rects() if map.has_method("get_building_rects") else []
	print("=== 前排建筑 %d 栋（前 6 栋）===" % rects.size())
	for i in mini(6, rects.size()):
		var r: Array = rects[i]
		var x0: float = float(r[0]) * 24.0
		var x1: float = float(r[1]) * 24.0
		var base: float = float(r[4])
		var depth: float = float(r[3]) - float(r[2])
		var mw: float = (x1 - x0) / (info[1] - info[0]) * w
		var my0: float = MinimapPainter.world_to_y(base - depth, rect, poly)
		var my1: float = MinimapPainter.world_to_y(base, rect, poly)
		print("  #%d 世界 x[%.0f, %.0f] 宽%.0fpx 基线y%.0f 深%.0fpx → 小地图 宽%.1f 纵[%.1f, %.1f]（高%.1f）"
				% [i, x0, x1, x1 - x0, base, depth, mw, my0, my1, my1 - my0])

	# 玩家 / 全实体
	var ents: Array = map.get_entities()
	print("=== 实体 %d 个 ===" % ents.size())
	for e in ents:
		if not is_instance_valid(e):
			continue
		var p: Vector2 = (e as Node2D).global_position
		print("  %-16s 世界(%.0f, %.0f) → 小地图(%.1f, %.1f)  possessed=%s" % [
				e.name, p.x, p.y,
				MinimapPainter.world_to_x(p.x, rect, poly),
				MinimapPainter.world_to_y(p.y, rect, poly),
				e.has_method("is_possessed") and e.is_possessed()])
	# 相机可视范围 → 小地图
	var rig: Node = _gr.camera_rig
	if rig != null and rig.has_method("get_viewport_rect_world"):
		var vpw: Rect2 = rig.get_viewport_rect_world()
		print("[相机] 世界 x[%.0f, %.0f] → 小地图 x[%.1f, %.1f]" % [vpw.position.x, vpw.end.x,
				MinimapPainter.world_to_x(vpw.position.x, rect, poly),
				MinimapPainter.world_to_x(vpw.end.x, rect, poly)])
	get_tree().quit(0)
