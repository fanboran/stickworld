extends Node
## 换轨验收捕获器 —— 阶段1"逐像素一致"验收的定机位截图工具。
##
## 用法（会弹一个游戏窗口约 15 秒，自动退出）：
##   godot --path stick-world res://tests/dev/capture_street.tscn -- --uz=0.75 --tag=before
## 换轨后复跑用 --uz=1.0 --tag=after（24px 轨上 zoom=1.0 与旧轨 0.75 视野等价）。
##
## 确定性措施（两条截图才可比）：
##   1. 轮询到地图装配完成立即定钟 game_time=12.0 + TimeManager PAUSED 总闸
##      ——冻结云漂移/旗帜/角色待机/粒子相位（着色器无 TIME，暂停即全静）；
##   2. 隐藏不可复现件：Cloud*/SkyDecor* 天饰、Char_*/Shadow_* 角色 billboard
##      与接地影、全部 GPUParticles（NPC 装配前 AI 行为的粒子残留相位随机）；
##   3. 机位硬定：2D 相机 x=0 + 3D 镜像 set_cam_x(0) + set_cam_zoom(uz)。
##
## 验收协议：同轨先双拍（before / before2）互 diff 确认捕获器确定性，
## 再与换轨后（uz=1.0, tag=after）diff——全部逐像素一致才算换轨等价。
##
## 产物 res://temp/unit24/<tag>_overview.png（每 tag 一张，整画面含 UI；
## 角色/粒子/天饰均已隐藏，UI 为静态布局）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const OUT_DIR := "res://temp/unit24"


func _ready() -> void:
	var uz := 0.75
	var tag := "shot"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--uz="):
			uz = float(a.get_slice("=", 1))
		elif a.begins_with("--tag="):
			tag = a.get_slice("=", 1)

	var gr: Node = GameRootScene.instantiate()
	add_child(gr)
	# 轮询装配完成（地图就位即停，压缩 NPC AI 的不可复现窗口）
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		await _wait_frames(5)
		var sl0: Node = gr.get("scene_loader")
		if sl0 != null and sl0.get_current_map() != null:
			break
	await _wait_frames(30)  # 装配尾部（镜头就位/描边预热）

	# 定钟 → 等数帧让天空/日光 _process 应用到位 → 再总闸暂停
	# （顺序不可倒：PAUSED 后 _process 不再跑，后设的钟不会渲染）
	WorldState.game_time = 12.0
	await _wait_frames(8)
	TimeManager.set_speed(TimeManager.Speed.PAUSED)
	await _wait_frames(3)

	# 天饰/角色/粒子隐藏（漂移与 AI 相位不可复现）
	_hide_prefixed(gr, ["Cloud", "SkyDecor", "Char_", "Shadow_"])
	_hide_particles(gr)
	# HUD 全隐（音乐进度条/热键栏脉冲等 UI 动画是唯一剩余不可复现源；
	# UI 布局与格常量无关，纯世界画面足以做换轨等价验收）
	_hide_canvas_layers(get_tree().root)

	# 机位硬定（2D 相机 x=0，3D 镜像手动同步；zoom 传用户档）
	var cam2d := get_viewport().get_camera_2d()
	var hd := _find_hd(gr)
	if cam2d != null:
		cam2d.global_position.x = 0.0
	if hd != null:
		if hd.has_method("set_cam_x"):
			hd.set_cam_x(0.0)
		if hd.has_method("set_cam_zoom"):
			hd.set_cam_zoom(uz)
		# 换轨诊断探针：实际正交视宽 vs 期望（24 轨 uz=1 → 1920/24=80）
		var cam3d: Camera3D = hd.get("_cam")
		if cam3d != null:
			print("[capture] cam3d.size=", cam3d.size, " keep_aspect=", cam3d.keep_aspect)
	var cam2d_dbg := get_viewport().get_camera_2d()
	if cam2d_dbg != null:
		print("[capture] cam2d.zoom=", cam2d_dbg.zoom, " base=", cam2d_dbg.get("base_zoom"),
				" user=", cam2d_dbg.get("user_zoom"), " pos=", cam2d_dbg.global_position)
	# 换轨诊断：玩家画布位置 + 3D 相机位置
	var cam3d_dbg: Camera3D = _find_camera3d(get_tree().root)
	if cam3d_dbg != null:
		print("[capture] cam3d pos=", cam3d_dbg.global_position, " size=", cam3d_dbg.size)
	var sl_dbg: Node = gr.get("scene_loader")
	if sl_dbg != null:
		var map_dbg: Node2D = sl_dbg.get_current_map()
		if map_dbg != null:
			var p: Node2D = map_dbg.get_possessed_entity()
			if p != null:
				print("[capture] player pos=", p.position, " foot_off=", p.get("foot_offset"))
	await _wait_frames(5)
	await _shot(tag + "_overview")

	print("[capture] DONE tag=%s uz=%s -> %s" % [tag, uz, OUT_DIR])
	await _wait_frames(2)
	get_tree().quit(0)


func _wait_s(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _hide_particles(root: Node) -> void:
	for child in root.get_children():
		if child is GPUParticles2D or child is GPUParticles3D or child is CPUParticles2D or child is CPUParticles3D:
			child.emitting = false
			child.visible = false
		_hide_particles(child)


func _hide_canvas_layers(root: Node) -> void:
	for child in root.get_children():
		if child is CanvasLayer:
			child.visible = false
		else:
			_hide_canvas_layers(child)


func _find_camera3d(root: Node) -> Camera3D:
	if root is Camera3D:
		return root
	for child in root.get_children():
		var found := _find_camera3d(child)
		if found != null:
			return found
	return null


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _find_hd(root: Node) -> Node:
	if root.has_method("get_building_rects"):
		return root
	for child in root.get_children():
		var found := _find_hd(child)
		if found != null:
			return found
	return null


func _hide_prefixed(root: Node, prefixes: Array) -> void:
	for child in root.get_children():
		for p in prefixes:
			if String(child.name).begins_with(p):
				child.visible = false
				break
		_hide_prefixed(child, prefixes)


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print(("[capture] SAVED " if err == OK else "[capture] SAVE FAILED ") + path)
