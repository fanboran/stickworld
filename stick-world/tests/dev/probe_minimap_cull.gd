extends Node
## 诊断探针：烘焙剔除层为什么漏火柴人/云。
##   1. 打印实体 billboard 的父节点链（是否在 _char_host 下）
##   2. 打印烘焙相机 cull_mask、云/卡的 layers（排除 pass 是否标到位）
##   3. cull_mask=0 再烘一张 → 若仍有内容 = 相机剔除在本视口根本不生效
## 运行：godot --path stick-world res://tests/dev/probe_minimap_cull.tscn

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const OUT_DIR := "res://../temp/shots_c"


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	var gr: Node = GameRootScene.instantiate()
	add_child(gr)
	var map: Node2D = null
	for i in 1800:
		if gr.get("_boot_world_phase") == false and gr.get_current_map() != null:
			map = gr.get_current_map()
			break
		await get_tree().process_frame
	if map == null:
		print("[PROBE] 世界未就绪")
		return _finish()
	for i in 30:
		await get_tree().process_frame

	var hd: Node = map.get("_hd")
	print("═══ 1. hd2d_world 直接子节点（找实体 billboard 宿主）═══")
	for c in hd.get_children():
		var n: int = c.get_child_count()
		print("  %-24s %-22s 子节点 %d" % [str(c.name), str(c.get_class()), n])

	print("═══ 2. 排除根与烘焙相机真值 ═══")
	var cam: Camera3D = hd.get("_bake_cam")
	print("  _bake_cam.cull_mask = ", cam.cull_mask if cam != null else "null(未建)")
	for root_name in ["_char_host", "_cloud_root", "_prop_root"]:
		var r: Node = hd.get(root_name)
		if r == null:
			print("  %s = null" % root_name)
			continue
		print("  %s（%s，子 %d）首两子：", [root_name, r.get_class(), r.get_child_count()])
		for c in r.get_children().slice(0, 2):
			var layers: Variant = (c as GeometryInstance3D).layers if c is GeometryInstance3D else "-"
			print("    %-20s %-18s layers=%s" % [str(c.name), str(c.get_class()), str(layers)])

	# 烘一次让 _ensure_bake_rig 建好 + 排除 pass 跑过，再看标记结果
	var size := Vector2i(780, 240)
	var out: Dictionary = await map.bake_minimap_base(size.x, size.y)
	cam = hd.get("_bake_cam")   # rig 懒建：首烘后才存在，重取
	print("═══ 3. 首烘后：排除 pass 标记结果 ═══")
	print("  _bake_cam.cull_mask = ", cam.cull_mask if cam != null else "null")
	for root_name in ["_char_host", "_cloud_root"]:
		var r: Node = hd.get(root_name)
		if r == null:
			continue
		for c in r.get_children().slice(0, 2):
			var layers: Variant = (c as GeometryInstance3D).layers if c is GeometryInstance3D else "-"
			print("    %s/%-18s layers=%s" % [root_name, str(c.name), str(layers)])
	if not out.is_empty():
		_save(out["texture"].get_image(), "cull_probe_normal.png")

	print("═══ 4. cull_mask=0 复烘（应全空——否则相机剔除不生效）═══")
	cam.cull_mask = 0
	var out2: Dictionary = await map.bake_minimap_base(size.x, size.y)
	if not out2.is_empty():
		var img: Image = out2["texture"].get_image()
		var non_empty := 0
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).a > 0.01:
					non_empty += 1
		print("  cull_mask=0 下非透明像素 = %d / %d" % [non_empty, img.get_width() * img.get_height()])
		_save(img, "cull_probe_zero.png")
	_finish()


func _save(img: Image, file_name: String) -> void:
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + file_name
	img.save_png(path)
	print("[SHOT] ", path)


func _finish() -> void:
	get_tree().quit(0)
