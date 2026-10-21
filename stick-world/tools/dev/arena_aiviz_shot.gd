extends Node
## AI 决策观察窗验收出图 driver（--aiviz）：观察场就绪后自动开窗 → 等切换
## 日志积累 → 连拍 2 张 PNG（间隔 4s，验证详情/列表实时在动）→ 打印门禁数字
##（切换单位数/日志条数）→ 退出。产物 user://shots/aiviz_<tag>_<i>.png。
## headless 不可跑（要 viewport 像素），带窗运行（arena_shot_boot 同款约束）。

## 开窗后等待（s）：窗口 0.25s 刷新节拍 × 数拍 + 切换日志积累
const SETTLE_SECS := 6.0
## 两张截图间隔（s）
const SHOT_GAP_SECS := 4.0


func run(_tag: String, _preset: int, _secs: int, _every: int) -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[AiVizShot] 看门狗超时强制退出")
		get_tree().quit())
	# 等观察场就绪（同 arena_burstcapture：_attacker 非空 = 单位已出生）
	var arena: Node = null
	for i in 3600:
		await get_tree().process_frame
		arena = get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and (arena.get("_attacker") as Array).size() > 0:
			break
	if arena == null or not is_instance_valid(arena):
		print("[AiVizShot] 观察场未就绪，退出")
		get_tree().quit()
		return
	# 等接战起来（战斗进行中切换日志才有内容）
	await get_tree().create_timer(SETTLE_SECS).timeout
	# 开 AI 观察窗（观察场 _ai_viz_window 引用；open = StickWindow 公共出口）
	var win: Control = arena.get("_ai_viz_window")
	if win == null or not is_instance_valid(win):
		print("[AiVizShot] 观察窗未找到，退出")
		get_tree().quit()
		return
	win.open()
	print("[AiVizShot] 观察窗已开 f=%d" % Engine.get_process_frames())
	await get_tree().create_timer(SETTLE_SECS).timeout
	var dir := "user://shots"
	DirAccess.make_dir_recursive_absolute(dir)
	for i in 2:
		var drawn := false
		var cb := func() -> void: drawn = true
		RenderingServer.frame_post_draw.connect(cb, CONNECT_ONE_SHOT)
		for k in 40:
			if drawn:
				break
			await get_tree().process_frame
		if not drawn:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		if img != null and not img.is_empty():
			img.save_png("%s/aiviz_%s_%02d.png" % [dir, _tag, i])
			print("[AiVizShot] 已存 %s/aiviz_%s_%02d.png" % [dir, _tag, i])
		if i == 0:
			await get_tree().create_timer(SHOT_GAP_SECS).timeout
	# 门禁数字：切换单位数 / 日志总条数 / 窗口行数（切换信号链路活性的可打印证据）
	var logs: Dictionary = win.get("_logs")
	var total: int = 0
	for iid in logs.keys():
		total += (logs[iid] as Array).size()
	print("[AiVizShot] 门禁: 切换单位数=%d 日志总条数=%d 行控件数=%d"
			% [logs.size(), total, (win.get("_rows") as Dictionary).size()])
	get_tree().quit()
