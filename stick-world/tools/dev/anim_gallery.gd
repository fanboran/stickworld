extends Node2D
## 动画姿势审查工位——把 stick_rig 全部动画逐个抽帧渲染成剪影网格图，
## 供「动画名 ↔ 姿势内容」肉眼对账（语义错配一次清完的防线；arrive 举手
## 穿帮两次后立的工具）。用法：
##   godot --path . res://tools/dev/anim_gallery.tscn --resolution 1920x1080
## 帧图落 user://animgallery/，由 anim_gallery.sh 归集并 PIL 拼网格 + 打绝对路径。
## 渲染要点：带窗口跑（headless 无 viewport 纹理）；AnimationPlayer 直控
##（不走状态机 travel——审查要精确到帧，不掺状态机过渡）。

const Anims := preload("res://modules/stick_rig/scripts/stickman_anims.gd")
const RIG_SCENE: PackedScene = preload("res://modules/stick_rig/scenes/stickman_test.tscn")
const OUT_DIR := "user://animgallery"
## 每动画抽帧位置（动画时长比例）
const SEEKS: Array = [0.25, 0.55, 0.85]


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	# 相机：对准原点，放大看姿势细节
	var cam := Camera2D.new()
	cam.position = Vector2(0, -90)
	cam.zoom = Vector2(3.2, 3.2)
	add_child(cam)
	# rig 实例：根上的交互控制器脚本置空（其 _ready 会建调试 label 混进截图），
	# 子树（骨架+AnimationPlayer）原样保留
	var test: Node2D = RIG_SCENE.instantiate()
	test.set_script(null)
	add_child(test)
	var player: AnimationPlayer = test.find_children("AnimationPlayer", "AnimationPlayer", true, false)[0] \
			as AnimationPlayer
	Anims.setup_player(player)
	# 库外补装：文件系统全部 .tres（dead 变体等不在 setup_player 清单里）
	var lib := player.get_animation_library("")
	var dir := DirAccess.open("res://modules/stick_rig/animations")
	for f in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		var name := f.get_basename()
		if not lib.has_animation(name):
			lib.add_animation(name, load("res://modules/stick_rig/animations/%s" % f))
	_run(player)


func _run(player: AnimationPlayer) -> void:
	await get_tree().process_frame
	var names: Array = []
	for n in player.get_animation_library("").get_animation_list():
		if not names.has(n):
			names.append(n)
	names.sort()
	var count := 0
	for n in names:
		var anim: Animation = player.get_animation_library("").get_animation(n)
		for si in SEEKS.size():
			player.play(n)
			player.seek(anim.length * SEEKS[si], true)
			player.pause()
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			img.save_png("%s/%s_%d.png" % [OUT_DIR, n, si])
		count += 1
		print("[AnimGallery] %d/%d %s" % [count, names.size(), n])
	print("[AnimGallery] done %d 动画 × %d 帧 → user://%s" % [count, SEEKS.size(), OUT_DIR])
	get_tree().quit(0)
