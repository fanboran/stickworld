extends Node
## 火柴人锯齿对比截图 driver：挂 unit_action_gallery 站姿全景，
## 三档机位各截一张（1.0 全景 / 0.5 拉远=缩视野痛点场景 / 2.0 特写），
## 供修前/修后 MSAA 对比验收（同场景同机位，只差 project.godot 抗锯齿配置）。
## 运行（弹窗 ~5s 自动退出）：
##   godot --path stick-world res://tests/dev/diag_stickman_shots.tscn -- --outdir=F:/shots --prefix=msaa_before

const _GalleryScene: PackedScene = preload("res://tests/dev/unit_action_gallery.tscn")

var _outdir: String = "user://shots"
var _prefix: String = "msaa_shot"

## 机位：gallery 陈列线脚部 y=800、7 单位间距 260（总宽 1560，中点 x≈960）
var _shots: Array = [
	{"name": "zoom_100", "zoom": 1.0, "pos": Vector2(960, 640)},
	{"name": "zoom_050", "zoom": 0.5, "pos": Vector2(960, 640)},
	{"name": "zoom_200", "zoom": 2.0, "pos": Vector2(960, 700)},
	# 肩关节特写（第一单位肩点 ≈(190,686)，4× 看描边断续）
	{"name": "zoom_400_shoulder", "zoom": 4.0, "pos": Vector2(190, 686)},
]


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--outdir="):
			_outdir = arg.trim_prefix("--outdir=")
		elif arg.begins_with("--prefix="):
			_prefix = arg.trim_prefix("--prefix=")
	DirAccess.make_dir_recursive_absolute(_outdir)
	add_child(_GalleryScene.instantiate())
	var cam := Camera2D.new()
	cam.name = "ShotCamera"
	add_child(cam)
	cam.make_current()
	await _frames(90)  # ~1.5s：单位出生、站姿动画进入稳态
	for shot in _shots:
		cam.zoom = Vector2(shot.zoom, shot.zoom)
		cam.position = shot.pos
		await _frames(3)  # 等相机变换生效
		var img: Image = get_viewport().get_texture().get_image()
		var path := "%s/%s_%s.png" % [_outdir, _prefix, shot.name]
		var err := img.save_png(path)
		print("[StickShots] %s (err=%d)" % [path, err])
	get_tree().quit(0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
