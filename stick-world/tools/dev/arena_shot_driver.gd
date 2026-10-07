extends Node
## 观察场快照 driver——由 arena_shot_boot 挂到 SceneTree.root（跨场景存活）。
## 先等开场遮罩撤除（=战场装配+相机对位+部队出生完成，diag_arena_25d_driver
## 同口径；上限 ~70s，超时也照截——截到什么诊断什么），再按真实秒表定时截图。
## 截图调用复刻 diag 已验证链：get_viewport().get_texture().get_image()，
## 采前等一帧渲染完成。


const SHOT_DIR := "user://shots"
const COVER_WAIT_FRAMES := 4200  # ~70s @60fps：boot 30s + 战场装配余量


func run(tag: String, preset: int, secs: int, every: int) -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	# 等揭幕：ArenaCover 撤除 = _reveal 已跑。等不到也继续（截到什么诊断什么）。
	var waited := false
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			waited = true
			break
	print("[ArenaWorkbench] cover gone=%s" % waited)
	# 等旧图退场（arena"旧图延迟销毁"：遮罩撤除后旧村图还挂几帧，
	# 截图/采样落在窗内会把村舍残影当战场）——揭幕后稳定一小段再动作
	for i in 12:
		await get_tree().process_frame
	var t0 := Time.get_ticks_msec() / 1000.0
	for t in range(0, secs + 1, maxi(every, 1)):
		var target := t0 + float(t)
		while Time.get_ticks_msec() / 1000.0 < target:
			await get_tree().process_frame
		# 双视角（批4 验收口径）：前半 0.46 全景（观察场默认）、后半 1.0 游玩缩放
		# ——观感验收不能只看全景广角，正常游玩视角的构图/比例须对照
		_set_zoom(0.46 if t < secs / 2 else 1.0)
		await get_tree().process_frame   # 当帧渲染完成后再采（diag 同口径）
		var img := get_viewport().get_texture().get_image()
		var name := "%s_p%d_t%d" % [tag, preset, t]
		img.save_png("%s/%s.png" % [SHOT_DIR, name])
		print("[ArenaWorkbench] shot %s/%s.png" % [SHOT_DIR, name])
	while Time.get_ticks_msec() / 1000.0 < t0 + float(secs):
		await get_tree().process_frame
	print("[ArenaWorkbench] done preset=%d secs=%d" % [preset, secs])
	get_tree().quit(0)


## 切观察场相机缩放（duck：rig 经 game_root 持有；找不到静默跳过）
func _set_zoom(z: float) -> void:
	var arena := get_tree().current_scene
	if arena == null or not is_instance_valid(arena):
		return
	var root: Node = arena.get("_game_root")
	if root == null or not is_instance_valid(root):
		return
	var rig: Node = root.get("camera_rig")
	if rig != null and is_instance_valid(rig) and rig.has_method("set_user_zoom"):
		rig.set_user_zoom(z)
