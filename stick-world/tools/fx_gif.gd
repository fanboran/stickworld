extends SceneTree
## 水晶闪光 GIF 帧序列工具 —— 连续截帧供 PIL 拼动图。
##
## 背景：CrystalSparks 的"亮晶晶"是时间维度效果（size 脉冲 + Additive 叠加），
## 静态截图恰好抓到粒子的小尺寸阶段，看不出闪烁感——动图才是验收基准。
##
## 用法（弹窗约 8 秒，自动退出）：
##   godot --path stick-world --script tools/fx_gif.gd
## 输出：F:/MyMy/图片/Work/fx_gif_frames/frame_*.png（再用 PIL 拼 GIF）
##
## 无 autoload 依赖（纯 class_name），可在任意工程状态下运行。

const OUT_DIR := "F:/MyMy/图片/Work/fx_gif_frames"
## 舞台坐标系 = 实际窗口视口（1920×1080）；GIF 输出时再缩到 OUT
const STAGE := Vector2(1920, 1080)
const OUT := Vector2(1280, 720)
## 采样帧率与帧数（12fps × 4s：覆盖 tier8 寿命 0.72s 的多轮脉冲 + 抖动变化）
const FPS := 12
const FRAMES := 48

var _stage: Node2D = null


func _init() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	# 清理上一轮的旧帧，避免拼接时混入
	for f in DirAccess.get_files_at(OUT_DIR):
		if f.begins_with("frame_"):
			DirAccess.remove_absolute(OUT_DIR + "/" + f)
	_stage = Node2D.new()
	root.add_child(_stage)
	# make_current 需节点在树内且树就绪（同 fx_screenshot 的时序坑）
	await process_frame
	var cam := Camera2D.new()
	cam.position = STAGE * 0.5
	_stage.add_child(cam)
	cam.make_current()
	await process_frame
	_build_night_stage()
	# 等 preprocess 预热的粒子进入稳态、叠几帧
	for i in 40:
		await process_frame
	for f in FRAMES:
		await create_timer(1.0 / float(FPS)).timeout
		await RenderingServer.frame_post_draw
		var img := root.get_viewport().get_texture().get_image()
		if img.get_width() != OUT.x:
			img.resize(OUT.x, OUT.y, Image.INTERPOLATE_LANCZOS)
		var path := "%s/frame_%03d.png" % [OUT_DIR, f]
		var err := img.save_png(path)
		print(("SAVED " if err == OK else "SAVE FAILED ") + path)
	print("GIF FRAMES DONE -> %s" % OUT_DIR)
	quit(0)


## 夜间水晶舞台：暗背景 + CanvasModulate 压暗 + 三色水晶 + 暖灯光
## （Additive 发光在暗背景最明显，是"亮晶晶"的验收环境）
func _build_night_stage() -> void:
	var bg := Polygon2D.new()
	bg.polygon = PackedVector2Array([Vector2.ZERO, Vector2(STAGE.x, 0),
			Vector2(STAGE.x, STAGE.y), Vector2(0, STAGE.y)])
	bg.color = Color(0.16, 0.17, 0.24)
	bg.z_index = -100
	_stage.add_child(bg)
	var cm := CanvasModulate.new()
	cm.color = Color(0.30, 0.33, 0.48)
	_stage.add_child(cm)
	var specs := [
		{"pos": Vector2(480, 630), "size": 160, "base": Color(0.45, 0.55, 0.75), "theme": "violet", "tier": 6},
		{"pos": Vector2(960, 570), "size": 250, "base": Color(0.50, 0.62, 0.78), "theme": "sky", "tier": 8},
		{"pos": Vector2(1440, 650), "size": 115, "base": Color(0.42, 0.58, 0.70), "theme": "gold", "tier": 3},
	]
	for s in specs:
		var n := Node2D.new()
		n.position = s["pos"]
		var body := Polygon2D.new()
		body.polygon = PackedVector2Array([
			Vector2(-s["size"] * 0.34, s["size"] * 0.5), Vector2(-s["size"] * 0.5, 0),
			Vector2(0, -s["size"] * 0.55), Vector2(s["size"] * 0.42, -s["size"] * 0.05),
			Vector2(s["size"] * 0.32, s["size"] * 0.5)])
		body.color = s["base"]
		n.add_child(body)
		var facet := Polygon2D.new()
		facet.polygon = PackedVector2Array([
			Vector2(-s["size"] * 0.34, s["size"] * 0.5), Vector2(-s["size"] * 0.5, 0),
			Vector2(0, -s["size"] * 0.55), Vector2(-s["size"] * 0.08, s["size"] * 0.48)])
		facet.color = (s["base"] as Color).lightened(0.25)
		n.add_child(facet)
		_stage.add_child(n)
		CrystalSparkles.attach_to(n, WorldZ.OVERLAY_HINT, s["theme"], s["tier"])
	# 玩家灯笼光（暖光打在中间水晶上）
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
	lamp.texture_scale = 3.4
	lamp.energy = 1.1
	lamp.position = Vector2(960, 630)
	_stage.add_child(lamp)
