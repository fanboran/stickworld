extends Node
## 连帧爆拍探针（--burstcapture）：战斗中段连拍 N 帧同屏 PNG（post_draw 同步，
## 供视觉逐帧对比「血条/身体闪烁消失、描边忽粗忽细」的第一手证据——像素统计
## 探针在低帧率下会失真，人眼看图不会）。产物 user://shots/burst_<tag>_<i>.png。
## headless 不可跑（要 viewport 像素），带窗运行。

const FRAMES := 12
## 开拍等待：战斗中段（开拔+接战已起）
const SETTLE_SECS := 5.0


func run(_tag: String, _preset: int, _secs: int, _every: int) -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[Burst] 看门狗超时强制退出")
		get_tree().quit())
	var arena: Node = null
	for i in 3600:
		await get_tree().process_frame
		arena = get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and (arena.get("_attacker") as Array).size() > 0:
			break
	if arena == null or not is_instance_valid(arena):
		print("[Burst] 观察场未就绪，退出")
		get_tree().quit()
		return
	await get_tree().create_timer(SETTLE_SECS).timeout
	print("[Burst] 连拍开始 f=%d fps=%.0f" % [Engine.get_process_frames(), Engine.get_frames_per_second()])
	var dir := "user://shots"
	DirAccess.make_dir_recursive_absolute(dir)
	for i in FRAMES:
		if get_tree() == null:
			break
		# post_draw 同步（渲染真帧后回读）；被遮挡信号饿死时退回 process 帧
		var drawn := false
		var cb := func() -> void: drawn = true
		RenderingServer.frame_post_draw.connect(cb, CONNECT_ONE_SHOT)
		for k in 20:
			if drawn:
				break
			await get_tree().process_frame
		if not drawn:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		if img != null and not img.is_empty():
			img.save_png("%s/burst_%s_%02d.png" % [dir, _tag, i])
	print("[Burst] 连拍完成 fps=%.0f" % Engine.get_frames_per_second())
	get_tree().quit()
