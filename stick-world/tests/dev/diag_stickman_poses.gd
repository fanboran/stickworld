extends Node
## 火柴人多姿态截图 driver：挂 unit_action_gallery（真实 AnimationTree 管线），
## 依次驱动 站立/奔跑/攻击挥砍/死亡倒地 四姿态，每姿态截
## 全景（zoom 1.0）+ 单兵特写（zoom 2.0 / 3.0 躯干近景），
## 供臂-躯干分隔修复的修前/修后对比验收（同场景同机位，只差渲染代码）。
## 运行（弹窗 ~15s 自动退出）：
##   godot --path stick-world res://tests/dev/diag_stickman_poses.tscn -- --outdir=F:/shots_b3 --prefix=before

const _GalleryScene: PackedScene = preload("res://tests/dev/unit_action_gallery.tscn")

var _outdir: String = "user://shots"
var _prefix: String = "pose"

var _gallery: Node = null
var _cam: Camera2D = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--outdir="):
			_outdir = arg.trim_prefix("--outdir=")
		elif arg.begins_with("--prefix="):
			_prefix = arg.trim_prefix("--prefix=")
	DirAccess.make_dir_recursive_absolute(_outdir)
	_gallery = _GalleryScene.instantiate()
	add_child(_gallery)
	_cam = Camera2D.new()
	_cam.name = "ShotCamera"
	add_child(_cam)
	_cam.make_current()
	await _frames(90)  # 单位出生 + 站姿动画进入稳态
	await _shot_pose("idle")
	_gallery.call("_on_action_pressed", "run")
	await _frames(40)  # 跑步循环中段（原地循环，地面约束钉住不位移）
	await _shot_pose("run")
	_gallery.call("_on_action_pressed", "attack")
	await _frames(12)
	await _shot_pose("attack_wind")  # 起手
	await _frames(10)
	await _shot_pose("attack_swing")  # 挥砍中段
	await _frames(12)
	await _shot_pose("attack_follow")  # 收势
	_gallery.call("_on_action_pressed", "dead")
	await _frames(100)  # 倒地动画播完进入终态
	await _shot_pose("dead")
	get_tree().quit(0)


## 一个姿态截四张：全景 zoom1.0 / 剑士特写 zoom2.0 / 躯干近景 zoom3.0 /
## 剑士肩部微距 zoom5.0（臂-躯干交界细节，分隔线与肩部融合的验收机位）。
## 剑士 = 陈列最左单位（x=180），脚线 y=800、肩部 y≈590。
func _shot_pose(pose: String) -> void:
	await _snap("%s/%s_pose_%s_panorama.png" % [_outdir, _prefix, pose], 1.0, Vector2(960, 640))
	await _snap("%s/%s_pose_%s_closeup.png" % [_outdir, _prefix, pose], 2.0, Vector2(180, 640))
	await _snap("%s/%s_pose_%s_torso.png" % [_outdir, _prefix, pose], 3.0, Vector2(180, 600))
	await _snap("%s/%s_pose_%s_shoulder.png" % [_outdir, _prefix, pose], 5.0, Vector2(180, 655))


func _snap(path: String, zoom: float, pos: Vector2) -> void:
	_cam.zoom = Vector2(zoom, zoom)
	_cam.position = pos
	await _frames(3)  # 等相机变换生效
	var img: Image = get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[StickPoses] %s (err=%d)" % [path, err])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
