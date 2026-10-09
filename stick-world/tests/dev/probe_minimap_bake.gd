extends Node
## 小地图烘焙可行性探针 —— 全宽取景整条街 → 隐藏天幕/背景排 → 关后处理 → 截图，
## 并把「前排顶 → 行走带前沿」裁出来降采样成小地图尺寸，看"照片式（真渲染）小地图"能不能用。
##
## 注：正式管线已落地（`hd2d_world.bake_minimap_strip()` + 共享 World3D 的
## SubViewport，见 docs/技术/架构/场景与战斗/UI.md §10.4.8）；本探针保留为
## "单帧主视口"路线的对照实验（它截主视口，会连 UI/加载屏一起拍进去——
## 这正是正式管线改走 SubViewport 的原因）。
##
## 实测结论（2026-10，本机 1920×1080 画布 / 2x 实拍）：
##   - **可行**：`set_cam_zoom(0.25)`（可视宽 320 格 = 7680px ≥ 地图 7080）一帧装下整条街；
##     关 DOF/辉光后清晰，真实建筑美术与比例直接落到图上（无需近似色表）。
##   - 必做前提（四条，缺一不可）：
##     ① 摄像每帧被 CameraRig 镜像覆盖 → 烘焙期须停地图 `_process`（或用专口接管）；
##     ② 后处理会糊掉整幅（DOF 远焦起点锚在世界线）→ 烘焙期关 DOF/辉光/雾；
##     ③ 天幕 quad 可隐藏，但环境清屏色/日盘/云仍是天空 → "去天空"要另做遮罩或换底；
##     ④ 画布恒 1920×1080（stretch=canvas_items），实拍分辨率 = 窗口分辨率——
##        正式实现应用 SubViewport 定死烘焙分辨率，否则小地图纹理质量随玩家窗口大小变。
##   - 已知副作用：光照被冻结（昼夜需重烘）、前景杂物卡贴图缺失（白块）会现形。
##
## 运行（要窗口）：godot --path stick-world res://tests/dev/probe_minimap_bake.tscn
## 出图：res://../temp/shots_c/bake_full.png（整幅）+ bake_minimap_candidate.png（候选小地图）

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const OUT_DIR := "res://../temp/shots_c"
## 烘焙取景：可视宽 320 格 = 7680px ≥ 地图 7080（正交 KEEP_WIDTH 下 size 即可视宽·格）
const BAKE_UZ := 0.25
## 候选小地图宽度（与顶部小地图同量级）
const CANDIDATE_W := 787

var _gr: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	# 倍分辨率烘焙：整幅 2x，裁出的街带才有足够像素可降采样
	get_window().size = Vector2i(3840, 2160)
	await get_tree().process_frame
	_gr = GameRootScene.instantiate()
	add_child(_gr)
	for i in 1800:
		if _gr.get("_boot_world_phase") == false and _gr.get_current_map() != null:
			break
		await get_tree().process_frame
	var map: Node2D = _gr.get_current_map()
	for i in 30:
		await get_tree().process_frame
	var hd: Node = map.get("_hd")
	if hd == null:
		print("[BAKE] 无 HD 世界（非 HD-2D 图）")
		get_tree().quit(1)
		return
	var cam: Camera3D = null
	for c in hd.get_children():
		if c is Camera3D:
			cam = c
	print("[BAKE] map=%s hd=%s cam=%s size=%.1f vp=%s" % [map.name, hd.name, cam, cam.size,
			cam.get_viewport().get_visible_rect().size])
	print("[BAKE] 地图 x[%.0f, %.0f] 宽 %.0f" % [map.map_left, map.map_right, map.map_right - map.map_left])

	# ① 停掉逐帧镜像（否则 set_cam_zoom 下一帧被 CameraRig 覆盖）
	map.process_mode = Node.PROCESS_MODE_DISABLED
	# ② 关后处理：DOF（挂在相机属性上）/ 辉光 / 雾（糊掉整幅的主因）
	var attrs = hd.get("_cam_attrs")
	if attrs != null:
		attrs.dof_blur_far_enabled = false
		attrs.dof_blur_near_enabled = false
	var env: Environment = hd.get("_env")
	if env != null:
		env.glow_enabled = false
		env.fog_enabled = false
		env.volumetric_fog_enabled = false
	# ③ 隐藏天幕 / 天体（相机子节点）
	for c in cam.get_children():
		if c is GeometryInstance3D:
			c.visible = false
			print("[BAKE] 隐藏相机子节点 %s" % c.name)
	# ④ 隐藏背景排（Cards 里前 N 张 = 前排，其余 = 背景排）
	var cards: Node = hd.get_node_or_null("Cards")
	var front_n: int = (hd.get("_front_occ") as Array).size()
	var hidden_bg: int = 0
	if cards != null:
		for i in cards.get_child_count():
			if i >= front_n:
				(cards.get_child(i) as Node3D).visible = false
				hidden_bg += 1
	print("[BAKE] 前排 %d 张，隐藏背景排 %d 张" % [front_n, hidden_bg])
	# ⑤ 隐藏 UI
	_gr.ui_root.visible = false
	# ⑥ 全宽取景 + 居中
	hd.call("set_cam_zoom", BAKE_UZ)
	hd.call("set_cam_x", 0.0)
	for i in 5:
		await get_tree().process_frame

	# ⑦ 算街带在屏上的 y 范围（地面 z 口径：canvas_y = 516 + z*24）
	# 注意：canvas 坐标恒 1920×1080（stretch），实拍图 = 窗口分辨率，故要乘比例
	var vp := get_viewport().get_visible_rect().size
	var img_px_scale: float = float(get_window().size.x) / vp.x
	var z_front: float = (970.5 - 516.0) / 24.0      # 行走带前沿
	var z_back: float = (356.5 - 516.0) / 24.0       # 地面带远端
	var y_front: float = cam.unproject_position(Vector3(0.0, 0.0, z_front)).y
	var y_back: float = cam.unproject_position(Vector3(0.0, 0.0, z_back)).y
	# 前排建筑卡顶（取全排最高）
	var top_y: float = y_back
	if cards != null:
		for i in mini(front_n, cards.get_child_count()):
			var mi: Node3D = cards.get_child(i)
			if mi == null or not is_instance_valid(mi):
				continue
			var h: float = (mi as MeshInstance3D).mesh.size.y * 0.5
			top_y = minf(top_y, cam.unproject_position(mi.position + Vector3(0, h, 0)).y)
	print("[BAKE] canvas 屏上：地面带 y %.1f..%.1f，前排顶 %.1f（canvas 高 %.0f / 实拍 %.0f，x%.1f）"
			% [y_back, y_front, top_y, vp.y, float(get_window().size.y), img_px_scale])

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir + "/bake_full.png")
	# ⑧ 裁「前排顶 → 行走带前沿」并降采样到小地图尺寸（787 宽）
	var y0: int = maxi(int(floor(top_y * img_px_scale)) - 6, 0)
	var y1: int = mini(int(ceil(y_front * img_px_scale)) + 6, img.get_height())
	var crop := img.get_region(Rect2i(0, y0, img.get_width(), maxi(y1 - y0, 1)))
	var mm_w: int = CANDIDATE_W
	var mm_h: int = int(round(float(crop.get_height()) * float(mm_w) / float(crop.get_width())))
	crop.resize(mm_w, mm_h, Image.INTERPOLATE_LANCZOS)
	crop.save_png(dir + "/bake_minimap_candidate.png")
	print("[BAKE] 出图 %s（原幅 %s / 裁 %s / 候选 %s）" % [dir, img.get_size(), crop.get_size(),
			Vector2i(mm_w, mm_h)])
	print("[BAKE] 取景后 cam.size=%.1f cam.pos=%s" % [cam.size, cam.position])
	get_tree().quit(0)
