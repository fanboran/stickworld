extends Node2D
## 拉弓俯仰确定性探针：单 rig 播 attack_bow_hold@Drawn（0.5s），分别在
## aim_pitch = 0 与 -0.6 截帧做像素 diff——持弓臂俯仰链（rig.set_aim_pitch →
## overlay 晚优先级 _process 采样绝对写）必须有可见姿态变化，防"写入被动画
## 应用次序踩掉"类回归（臂枢首版实锤全帧被踩、战场读数平射）。
## 带窗口跑（headless 无 viewport 纹理）：
##   godot --path . res://tools/dev/aim_pitch_probe.tscn --resolution 960x540
## 帧落 user://aimpitch_probe/，退出码 0=断言过（差异 ≥ 阈值）。

const Anims := preload("res://modules/stick_rig/scripts/stickman_anims.gd")
const RIG_SCENE: PackedScene = preload("res://modules/stick_rig/scenes/stickman_test.tscn")
const OUT := "user://aimpitch_probe"
## 差异像素占比阈值（960×540 全帧，臂+弓在 zoom 2.4 下约占屏 1%~3%）
const DIFF_FRAC_MIN := 0.002
const PITCH_MAX := -0.6


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var cam := Camera2D.new()
	cam.position = Vector2(0, -90)
	cam.zoom = Vector2(2.4, 2.4)
	add_child(cam)
	# rig 实例：根脚本置空防调试 label 混进截图（同 anim_gallery 口径）
	var test: Node2D = RIG_SCENE.instantiate()
	test.set_script(null)
	add_child(test)
	var player: AnimationPlayer = test.find_children("AnimationPlayer", "AnimationPlayer", true, false)[0] \
			as AnimationPlayer
	Anims.setup_player(player)
	var rig: Node2D = test.find_children("StickmanRig", "Skeleton2D", true, false)[0] as Node2D
	await get_tree().process_frame
	player.play("attack_bow_hold")
	player.seek(0.5, true)
	player.pause()
	rig.set_aim_pitch(0.0)
	var a: Image = await _shot("pitch0")
	rig.set_aim_pitch(PITCH_MAX)
	var b: Image = await _shot("pitchmax")
	var frac := _diff_frac(a, b)
	print("[AimPitchProbe] 差异像素占比 %.4f（阈值 ≥%.3f 判臂区有可见变化）" % [frac, DIFF_FRAC_MIN])
	var ok := frac >= DIFF_FRAC_MIN
	print("[AimPitchProbe] %s → user://%s" % ["PASS" if ok else "FAIL", OUT])
	get_tree().quit(0 if ok else 1)


func _shot(tag: String) -> Image:
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, tag])
	return img


func _diff_frac(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		push_error("[AimPitchProbe] 尺寸不一致 %s vs %s" % [a.get_size(), b.get_size()])
		return 0.0
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	var da := a.get_data()
	var db := b.get_data()
	var diff := 0
	for i in da.size():
		if absi(da[i] - db[i]) > 24:
			diff += 1
	return float(diff) / float(da.size())
