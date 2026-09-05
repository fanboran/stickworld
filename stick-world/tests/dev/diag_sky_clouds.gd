extends Node2D
## 诊断：天空云密度/分布观察 —— SkyDecor 开阔机位截图。
## 运行（必须带显示）：
##   godot --path stick-world res://tests/dev/diag_sky_clouds.tscn --resolution 1920x1080
## 产物：user://shots/diag_sky_clouds.png

const SHOT_DIR := "user://shots"

var _frames: int = 0


func _ready() -> void:
	var sky := SkyDecor.new()
	sky.name = "SkyDecor"
	add_child(sky)
	var cam := Camera2D.new()
	cam.name = "DiagCam"
	add_child(cam)
	cam.make_current()
	cam.position = Vector2(960, 400)  # 地平线 810：天空占上 3/4 + 一条地面
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 60:
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/diag_sky_clouds.png" % SHOT_DIR)
		print("[DiagSky] diag_sky_clouds.png")
		get_tree().quit(0)
