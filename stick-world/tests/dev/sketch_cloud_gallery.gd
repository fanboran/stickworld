extends Control
## 手绘云候选陈列 —— 候选风格并排实时动画（供用户选型）。
## 运行（必须带显示）：
##   主菜单「测试场景」→「手绘云候选陈列」，或
##   godot --path stick-world res://tests/dev/sketch_cloud_gallery.tscn --resolution 1920x1080
## ESC 返回主菜单。自动截图仅当命令行带 --shot 时执行
##（user://shots/sketch_cloud_0.png / _1.png 两帧），日常浏览不退出。

const SHOT_DIR := "user://shots"
const _SketchCloudScript: GDScript = preload("res://modules/ui_global/scripts/sketch/sketch_cloud.gd")

## 候选行：[标签, style 枚举值, 参数字典]（4=IMPASTO 5=ANIME）
const ROWS := [
	["F1 动漫·经典月牙", 5, {"anime_shadow": 0.3}],
	["F2 动漫·深月牙", 5, {"anime_shadow": 0.45}],
	["F3 动漫·轻月牙", 5, {"anime_shadow": 0.2}],
	["E2 油画·浓郁（对照）", 4, {"impasto_density": 1.5, "impasto_thick": 1.2}],
]
const SIZES := [0.8, 1.3]

var _frames: int = 0
## 命令行 --shot 时才自动截图退出（CI/留档用）；日常浏览常驻
var _auto_shot: bool = false


func _ready() -> void:
	_auto_shot = "--shot" in OS.get_cmdline_user_args()
	# 天空底色（游戏白天与黄昏之间的中间调，白云白线均可见）
	var bg := ColorRect.new()
	bg.color = Color(0.42, 0.60, 0.76)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	for s in ROWS.size():
		var tag := StickKit.label(self, ROWS[s][0], StickKit.LabelKind.TITLE)
		tag.position = Vector2(40.0, 90.0 + 190.0 * s)
		for k in SIZES.size():
			var cloud: Node2D = _SketchCloudScript.new()
			cloud.set("style", ROWS[s][1])
			for key in ROWS[s][2]:
				cloud.set(key, ROWS[s][2][key])
			cloud.set("cloud_size", Vector2(300.0, 125.0) * SIZES[k])
			cloud.position = Vector2(360.0 + 640.0 * k, 160.0 + 190.0 * s)
			add_child(cloud)
	if _auto_shot:
		DirAccess.make_dir_recursive_absolute(SHOT_DIR)


func _process(_delta: float) -> void:
	if not _auto_shot:
		return
	_frames += 1
	# 两帧间隔 0.8s：捕捉 boiling 重掷/换姿态后的不同姿态
	if _frames == 48:
		_snap("sketch_cloud_0")
	elif _frames == 96:
		_snap("sketch_cloud_1")
	elif _frames == 102:
		get_tree().quit(0)


func _unhandled_input(event: InputEvent) -> void:
	# ESC 返回主菜单（日常浏览退出路径）
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file("res://modules/ui_global/scenes/menus/main_menu.tscn")


func _snap(shot_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[CloudGallery] %s.png" % shot_name)
