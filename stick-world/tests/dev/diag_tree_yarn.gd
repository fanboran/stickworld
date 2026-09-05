extends Node2D
## 诊断：毛线团树陈列观察 —— 终版架构（干直绘 + 侧枝算法 + 毛线团树叶）视觉验收。
## 运行（必须带显示）：
##   godot --path stick-world res://tests/dev/diag_tree_yarn.tscn --resolution 1920x1080
## 产物：user://shots/diag_tree_yarn.png（初态）+ diag_tree_yarn_t2.png（1.9s 后，
## 与初态应有像素差 = 毛线团每秒翻动生效）。

const SHOT_DIR := "user://shots"
## 摆放参数对齐 resource_node._apply_visual：scale = 750/880 × 抖动[0.85,1.25]
const SEEDS: Array = [101, 202, 303, 404, 505, 606, 707, 808]
const JITTERS: Array = [1.0, 0.92, 1.15, 1.05, 0.88, 1.2, 0.96, 1.1]
const FLIPS: Array = [1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0]

var _frames: int = 0
var _shot1: Image = null


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	# 观感背景：天空带 + 草地带（仅陈列用，非游戏内容）
	var sky := ColorRect.new()
	sky.color = Color8(126, 178, 214)
	sky.size = Vector2(1920, 900)
	add_child(sky)
	var grass := ColorRect.new()
	grass.color = Color8(106, 144, 78)
	grass.position = Vector2(0, 900)
	grass.size = Vector2(1920, 180)
	add_child(grass)
	# 一排树：种子/缩放抖动/翻转/色偏全按 resource_node 同规则
	for i in SEEDS.size():
		var painting := TreePainting.new()
		painting.setup(SEEDS[i])
		var s: float = 750.0 / 880.0 * float(JITTERS[i])
		painting.scale = Vector2(s * float(FLIPS[i]), s)
		var dv: float = [-0.03, 0.02, 0.04, -0.01, 0.03, -0.04, 0.01, 0.0][i]
		painting.modulate = Color(1.0 + dv, 1.0 + dv * 0.6, 1.0 - dv * 0.6)
		painting.position = Vector2(240.0 + float(i) * 230.0, 940.0)
		add_child(painting)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 40:
		_shot1 = get_viewport().get_texture().get_image()
		_shot1.save_png("%s/diag_tree_yarn.png" % SHOT_DIR)
		print("[DiagTreeYarn] shot1 saved (t=%.2fs)" % (40.0 / 60.0))
	if _frames == 114:
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/diag_tree_yarn_t2.png" % SHOT_DIR)
		# 断言动态：两帧冠区像素应有可见差异（毛线团每秒翻一次姿态）
		var diff := _diff_pixels(_shot1, img)
		print("[DiagTreeYarn] shot2 saved, diff_pixels=%d" % diff)
		if diff < 2000:
			print("[FAIL] 两帧几乎无差异，毛线团未翻动")
			get_tree().quit(1)
			return
		print("[PASS] 毛线团树陈列 + 每秒翻动验证通过")
		get_tree().quit(0)


func _diff_pixels(a: Image, b: Image) -> int:
	if a == null:
		return 999999
	var na := a.get_data()
	var nb := b.get_data()
	var n := mini(na.size(), nb.size())
	var count := 0
	for i in range(0, n, 4):
		if absf(float(na[i]) - float(nb[i])) > 12.0 or absf(float(na[i + 1]) - float(nb[i + 1])) > 12.0:
			count += 1
	return count
