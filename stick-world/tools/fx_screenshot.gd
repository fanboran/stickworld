extends SceneTree
## 特效效果图截图工具 —— 自动搭建舞台、驱动特效、逐张保存 PNG。
##
## 用法（会弹一个游戏窗口约 20 秒，自动退出）：
##   godot --path stick-world --script tools/fx_screenshot.gd
## 输出：F:/MyMy/图片/Work/*.png
##
## 覆盖：水晶闪光（白天/夜间）、星芒贴图特写、打击火花、建造尘土、采集飘屑。
## 无 autoload 依赖（纯 class_name），可在任意工程状态下运行。

const OUT_DIR := "F:/MyMy/图片/Work"
const VIEW := Vector2(1920, 1080)

var _stage: Node2D = null


func _init() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_stage = Node2D.new()
	root.add_child(_stage)
	# make_current 要求节点已在树内且树已就绪：_init 阶段直接调用会报
	# "!enabled || !is_inside_tree()"，故等一帧再建相机
	await process_frame
	var cam := Camera2D.new()
	cam.position = VIEW * 0.5
	_stage.add_child(cam)
	cam.make_current()
	await process_frame
	await _day_sparkle_shot()
	await _night_sparkle_shot()
	await _sparkle_closeup_shot()
	await _star_closeup_shot()
	await _burst_shots()
	print("SCREENSHOTS DONE -> %s" % OUT_DIR)
	quit(0)


# ─────────────────────────────── 场景构件 ────────────────────────────────

func _add_bg(color: Color) -> void:
	var bg := Polygon2D.new()
	bg.polygon = PackedVector2Array([Vector2.ZERO, Vector2(VIEW.x, 0),
			Vector2(VIEW.x, VIEW.y), Vector2(0, VIEW.y)])
	bg.color = color
	bg.z_index = -100
	_stage.add_child(bg)


## 程序化水晶（菱形双色切面），返回宿主节点
func _make_crystal(pos: Vector2, size: float, base: Color) -> Node2D:
	var n := Node2D.new()
	n.position = pos
	var body := Polygon2D.new()
	body.polygon = PackedVector2Array([
		Vector2(-size * 0.34, size * 0.5), Vector2(-size * 0.5, 0),
		Vector2(0, -size * 0.55), Vector2(size * 0.42, -size * 0.05),
		Vector2(size * 0.32, size * 0.5)])
	body.color = base
	n.add_child(body)
	var facet := Polygon2D.new()
	facet.polygon = PackedVector2Array([
		Vector2(-size * 0.34, size * 0.5), Vector2(-size * 0.5, 0),
		Vector2(0, -size * 0.55), Vector2(-size * 0.08, size * 0.48)])
	facet.color = base.lightened(0.25)
	n.add_child(facet)
	_stage.add_child(n)
	return n


func _capture(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print(("SAVED " if err == OK else "SAVE FAILED ") + path)


func _clear_stage() -> void:
	for child in _stage.get_children():
		if child is Camera2D:
			continue  # 相机常驻，避免清场后镜头丢失
		_stage.remove_child(child)
		child.queue_free()


func _wait_frames(n: int) -> void:
	for i in n:
		await process_frame


# ─────────────────────────────── 各镜头 ────────────────────────────────

## 01 白天水晶闪光：三颗不同尺寸/主题色的水晶（面积驱动密度差异 + 药工"每材料一色"）
func _day_sparkle_shot() -> void:
	_clear_stage()
	_add_bg(Color(0.62, 0.58, 0.50))
	_make_crystal(Vector2(480, 620), 90, Color(0.45, 0.55, 0.75))
	_make_crystal(Vector2(960, 560), 140, Color(0.50, 0.62, 0.78))
	_make_crystal(Vector2(1450, 650), 65, Color(0.42, 0.58, 0.70))
	var themes := ["gold", "sky", "mint"]
	# 档位必须是 TIER_TABLE 键（1/2/3/6/8/20）
	var tiers := [6, 8, 3]
	var i := 0
	for n in _stage.get_children():
		if n is Node2D and (n as Node2D).get_child_count() > 0:
			CrystalSparkles.attach_to(n, WorldZ.OVERLAY_HINT, themes[i], tiers[i])
			i += 1
	# preprocess 已在组件内预热 1s；再多跑几帧让多颗闪进入中段
	await _wait_frames(50)
	await _capture("01_水晶闪光_白天")


## 02 夜间水晶闪光：压暗环境 + 玩家灯笼光（暖光打在中间水晶上）
func _night_sparkle_shot() -> void:
	_clear_stage()
	_add_bg(Color(0.16, 0.17, 0.24))
	var cm := CanvasModulate.new()
	cm.color = Color(0.30, 0.33, 0.48)
	_stage.add_child(cm)
	_make_crystal(Vector2(480, 620), 90, Color(0.45, 0.55, 0.75))
	var mid := _make_crystal(Vector2(960, 560), 140, Color(0.50, 0.62, 0.78))
	_make_crystal(Vector2(1450, 650), 65, Color(0.42, 0.58, 0.70))
	var themes := ["violet", "sky", "mint"]
	var tiers := [6, 8, 3]
	var i := 0
	for n in _stage.get_children():
		if n is Node2D and (n as Node2D).get_child_count() > 0 and not (n is CanvasModulate):
			CrystalSparkles.attach_to(n, WorldZ.OVERLAY_HINT, themes[i], tiers[i])
			i += 1
	# 灯笼光（玩家携带光源的等价演示）
	var lamp := PointLight2D.new()
	var tex := GradientTexture2D.new()
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 512
	tex.height = 512
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.82, 0.55, 0.9))
	grad.set_color(1, Color(1.0, 0.75, 0.45, 0.0))
	tex.gradient = grad
	lamp.texture = tex
	lamp.texture_scale = 3.0
	lamp.energy = 1.1
	lamp.position = Vector2(960, 600)
	_stage.add_child(lamp)
	await _wait_frames(50)
	await _capture("02_水晶闪光_夜间加灯光")


## 02b 闪光密度/配色特写：单颗大水晶 tier8，检验 5 子系统（白/主色/金/青/粉）叠加密度
func _sparkle_closeup_shot() -> void:
	_clear_stage()
	_add_bg(Color(0.12, 0.13, 0.18))
	var cm := CanvasModulate.new()
	cm.color = Color(0.45, 0.48, 0.62)
	_stage.add_child(cm)
	var big := _make_crystal(Vector2(960, 560), 420, Color(0.46, 0.58, 0.76))
	CrystalSparkles.attach_to(big, WorldZ.OVERLAY_HINT, "sky", 8)
	var subs := 0
	var amount_sum := 0
	for child in big.get_children():
		if child is CrystalSparkles:
			subs += 1
			amount_sum += (child as CrystalSparkles).amount
	print("  子系统数=%d  在世粒子总量=%d" % [subs, amount_sum])
	await _wait_frames(60)
	await _capture("02b_闪光密度特写_5子系统")


## 03 星芒贴图特写（放大的单颗闪光本体）
func _star_closeup_shot() -> void:
	_clear_stage()
	_add_bg(Color(0.10, 0.11, 0.16))
	for spec in [
		{"pos": Vector2(760, 540), "size": 24, "scale": 8.0},
		{"pos": Vector2(1060, 480), "size": 24, "scale": 5.0},
		{"pos": Vector2(920, 720), "size": 24, "scale": 3.0},
	]:
		var spr := Sprite2D.new()
		spr.texture = FxLibrary._star4(spec["size"])
		spr.position = spec["pos"]
		spr.scale = Vector2.ONE * spec["scale"]
		spr.modulate = Color(1.0, 0.97, 0.85)
		_stage.add_child(spr)
	await _wait_frames(4)
	await _capture("03_星芒贴图特写")


## 04-06 三种爆发特效各自的最佳帧
func _burst_shots() -> void:
	_clear_stage()
	_add_bg(Color(0.55, 0.52, 0.45))
	# 参考物：一块石墩当发射源
	var rock := _make_crystal(Vector2(960, 620), 110, Color(0.5, 0.5, 0.52))

	# 04 建造尘土：峰值约 0.25~0.35s
	var dust := FxLibrary.create_burst(FxLibrary.BUILD_DUST)
	_stage.add_child(dust)
	dust.global_position = Vector2(960, 600)
	dust.emitting = true
	await _wait_frames(20)
	await _capture("04_建造尘土")
	dust.queue_free()
	await _wait_frames(2)

	# 05 采集飘屑：抛物线中段约 0.4s
	var debris := FxLibrary.create_burst(FxLibrary.GATHER_DEBRIS)
	_stage.add_child(debris)
	debris.global_position = Vector2(960, 600)
	debris.emitting = true
	await _wait_frames(24)
	await _capture("05_采集飘屑")
	debris.queue_free()
	await _wait_frames(2)

	# 06 打击火花：峰值极早（0.1s 左右）
	var spark := FxLibrary.create_burst(FxLibrary.HIT_SPARK)
	_stage.add_child(spark)
	spark.global_position = Vector2(960, 580)
	spark.emitting = true
	await _wait_frames(7)
	await _capture("06_打击火花")
	spark.queue_free()
