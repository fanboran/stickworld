extends SceneTree
## 水晶闪光 GIF 帧序列工具 —— 连续截帧供 PIL 拼动图。
##
## 背景：闪烁是时间维度效果（size 脉冲 0→峰→硬切，寿命 0.72~1.7s），
## 12fps 采样每颗粒子只有 ~9 帧/周期，观感频闪；静态 PNG 更验收不了脉动。
## 采集规则（2026-08-29 审计后）：
##   - 30fps：引擎 60fps 每 2 帧取 1（按帧对齐，不用墙钟定时器，无漂移）
##   - 帧先全部驻留内存（Image 缩到 720p），采集结束后统一落盘——
##     采集期间 save_png（1080p 约 20-50ms/张）会阻塞主线程，
##     造成模拟慢动作+掉帧（"帧率低"的观感来源之一）
##   - 双场景：day = 原版水晶洞风格（浅褐羊皮纸底 + 中灰矿石带 + 多簇水晶，
##     对齐 2026-08-29 原版截图调研）；night = 游戏内夜间（USHADED 保色验收）
##
## 用法（弹窗约 15 秒，自动退出）：
##   godot --path stick-world --script tools/fx_gif.gd
## 输出：F:/MyMy/图片/Work/fx_gif_frames/{day,night}_*.png（再用 PIL 拼 GIF）
##
## 无 autoload 依赖（纯 class_name），可在任意工程状态下运行。

const OUT_DIR := "F:/MyMy/图片/Work/fx_gif_frames"
## 舞台坐标系 = 实际窗口视口（1920×1080）；GIF 输出时再缩到 OUT
const STAGE := Vector2(1920, 1080)
const OUT := Vector2(1280, 720)
const FPS := 30             # 采样帧率 = 引擎 60fps ÷ 2（每 2 帧 1 采样，帧对齐）
const CAPTURE_SEC := 3.0    # 每场景采集时长
const FRAMES := int(CAPTURE_SEC * FPS)

## 各场景相机缩放（closeup 放大 2x 让十字星形可辨）
var _camera_zoom := {
	"day": Vector2.ONE,
	"night": Vector2.ONE,
	"closeup": Vector2(2.0, 2.0),
	"authentic": Vector2.ONE,
}

var _stage: Node2D = null


func _init() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	# 清理上一轮的旧帧，避免拼接时混入
	for f in DirAccess.get_files_at(OUT_DIR):
		if f.begins_with("day_") or f.begins_with("night_"):
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
	await _capture_scene("day", _build_day_stage)
	await _capture_scene("night", _build_night_stage)
	await _capture_scene("closeup", _build_closeup_stage)
	await _capture_scene("authentic", _build_authentic_stage)
	print("GIF FRAMES DONE -> %s" % OUT_DIR)
	quit(0)


## 单场景采集：预热稳态 → 30fps 采样入内存 → 结束后统一落盘
func _capture_scene(prefix: String, builder: Callable) -> void:
	_clear_stage()
	# 相机状态随场景重置（closeup 用 2x zoom 放大星形细节）
	var cams: Array = []
	for child in _stage.get_children():
		if child is Camera2D:
			cams.append(child)
	var cam: Camera2D = cams[0] if cams.size() > 0 else null
	cam.zoom = _camera_zoom.get(prefix, Vector2.ONE)
	cam.position = STAGE * 0.5
	builder.call()
	# preprocess 预热 + 粒子进入稳态
	for i in 30:
		await process_frame
	var imgs: Array[Image] = []
	for f in FRAMES:
		await process_frame
		await process_frame  # 60fps 引擎每 2 帧取 1 = 30fps，帧对齐无漂移
		await RenderingServer.frame_post_draw
		var img := root.get_viewport().get_texture().get_image()
		if img.get_width() != int(OUT.x):
			img.resize(int(OUT.x), int(OUT.y), Image.INTERPOLATE_LANCZOS)
		imgs.append(img)
	# 采集结束后统一落盘（采集期间 save_png 会阻塞主线程 → 慢动作/掉帧）
	for i in imgs.size():
		var err := imgs[i].save_png("%s/%s_%03d.png" % [OUT_DIR, prefix, i])
		if err != OK:
			print("SAVE FAILED %s_%03d" % [prefix, i])
	print("  %s: %d frames @%dfps" % [prefix, imgs.size(), FPS])


func _clear_stage() -> void:
	for child in _stage.get_children():
		if child is Camera2D:
			continue  # 相机常驻，避免清场后镜头丢失
		_stage.remove_child(child)
		child.queue_free()


# ─────────────────────────────── 场景 ────────────────────────────────

## day：原版水晶洞风格——浅褐羊皮纸底 + 中灰矿石环带 + 多簇水晶（一簇一色）。
## 原版密度靠"多对象各挂小块"叠加，单簇本身稀疏（5~15 亮点），所以摆多颗小水晶
func _build_day_stage() -> void:
	# 羊皮纸底（原版洞底浅褐，不是黑底——闪光处于中等对比环境）
	_add_rect(Polygon2D.new(), Rect2(Vector2.ZERO, STAGE), Color(0.76, 0.68, 0.52))
	# 中灰矿石环带（水晶生长带，比底色深一档）
	_add_rect(Polygon2D.new(), Rect2(0, STAGE.y * 0.30, STAGE.x, STAGE.y * 0.46),
			Color(0.47, 0.46, 0.44))
	# 晶簇布局：三簇各一色（紫簇 / 蓝白簇 / 金簇），大中小混合。
	# 原版单簇 = 多个子对象各挂闪光系统叠加出密度（视觉验收：每簇 5~15 亮点），
	# 簇内对象太少会出现"全暗瞬间"（相位巧合全体处于小尺寸段）
	var specs := [
		# 左：violet 簇（1 大 4 小）
		{"pos": Vector2(360, 700), "size": 150, "theme": "violet", "tier": 8},
		{"pos": Vector2(250, 620), "size": 70, "theme": "violet", "tier": 6},
		{"pos": Vector2(480, 600), "size": 55, "theme": "violet", "tier": 3},
		{"pos": Vector2(300, 780), "size": 60, "theme": "violet", "tier": 6},
		{"pos": Vector2(450, 770), "size": 48, "theme": "violet", "tier": 2},
		# 中：sky 簇（1 大 4 小，原版冷白蓝主体）
		{"pos": Vector2(960, 640), "size": 190, "theme": "sky", "tier": 8},
		{"pos": Vector2(830, 560), "size": 80, "theme": "sky", "tier": 6},
		{"pos": Vector2(1100, 580), "size": 65, "theme": "sky", "tier": 3},
		{"pos": Vector2(1010, 760), "size": 60, "theme": "sky", "tier": 2},
		{"pos": Vector2(860, 740), "size": 55, "theme": "sky", "tier": 6},
		# 右：gold 簇（1 大 5 小）
		{"pos": Vector2(1520, 680), "size": 130, "theme": "gold", "tier": 8},
		{"pos": Vector2(1400, 590), "size": 60, "theme": "gold", "tier": 3},
		{"pos": Vector2(1650, 600), "size": 75, "theme": "gold", "tier": 6},
		{"pos": Vector2(1440, 760), "size": 55, "theme": "gold", "tier": 6},
		{"pos": Vector2(1620, 740), "size": 50, "theme": "gold", "tier": 2},
		{"pos": Vector2(1740, 660), "size": 45, "theme": "gold", "tier": 3},
	]
	for s in specs:
		_make_crystal(s["pos"], s["size"], s["theme"], s["tier"])
	# 顶部岩壁带挂 rainbow（对齐原版 CrystalSparksBase 通用盘：岩壁五彩 vs 矿石单色）
	_make_wall(Rect2(120, 60, 1680, 110), 8)


## night：游戏内夜间场景——压暗 + 灯笼暖光（USHADED 保色验收：夜色不吞主题色）
func _build_night_stage() -> void:
	_add_rect(Polygon2D.new(), Rect2(Vector2.ZERO, STAGE), Color(0.16, 0.17, 0.24))
	var cm := CanvasModulate.new()
	cm.color = Color(0.30, 0.33, 0.48)
	_stage.add_child(cm)
	var specs := [
		{"pos": Vector2(480, 630), "size": 160, "theme": "violet", "tier": 6},
		{"pos": Vector2(620, 720), "size": 60, "theme": "violet", "tier": 3},
		{"pos": Vector2(960, 570), "size": 250, "theme": "sky", "tier": 8},
		{"pos": Vector2(1140, 700), "size": 70, "theme": "sky", "tier": 6},
		{"pos": Vector2(1440, 650), "size": 115, "theme": "gold", "tier": 6},
		{"pos": Vector2(1560, 730), "size": 55, "theme": "gold", "tier": 3},
	]
	for s in specs:
		_make_crystal(s["pos"], s["size"], s["theme"], s["tier"])
	# 玩家灯笼：挂在晶簇之间的空地上（不压在水晶上——亮面会把白点对比度吃掉，
	# 夜间验收场景只验 USHADED 保色，不需要灯光艺术效果）
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
	lamp.energy = 0.9
	lamp.position = Vector2(1290, 900)
	_stage.add_child(lamp)


## closeup：2x 特写——单簇大水晶（矿石单色柔点+星形）+ 彩虹岩壁带（五彩），
## 相机拉近后十字星形与多彩抽色肉眼可辨
func _build_closeup_stage() -> void:
	_add_rect(Polygon2D.new(), Rect2(Vector2.ZERO, STAGE), Color(0.76, 0.68, 0.52))
	# 岩壁带（横贯画面下部）挂 rainbow——原版 CrystalSparksBase 通用盘
	_make_wall(Rect2(300, 700, 1320, 160), 8)
	# 大水晶（蓝白矿石簇）+ 两颗邻簇
	_make_crystal(Vector2(700, 560), 200, "sky", 8)
	_make_crystal(Vector2(460, 620), 90, "violet", 6)
	_make_crystal(Vector2(1220, 600), 80, "gold", 6)


# ─────────────────────────────── 构件 ────────────────────────────────

func _add_rect(poly: Polygon2D, rect: Rect2, color: Color) -> void:
	poly.polygon = PackedVector2Array([rect.position,
			Vector2(rect.end.x, rect.position.y), rect.end,
			Vector2(rect.position.x, rect.end.y)])
	poly.color = color
	poly.z_index = -100
	_stage.add_child(poly)


## 程序化水晶（菱形双色切面）+ 挂 CrystalSparkles（一簇一色）
func _make_crystal(pos: Vector2, size: float, theme: String, tier: int) -> void:
	var n := Node2D.new()
	n.position = pos
	var base := Color(0.50, 0.60, 0.76)
	match theme:
		"violet": base = Color(0.62, 0.52, 0.78)
		"gold":   base = Color(0.80, 0.66, 0.34)
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
	CrystalSparkles.attach_to(n, WorldZ.OVERLAY_HINT, theme, tier)


## 岩壁长条（深灰岩石多边形）挂 rainbow 通用盘——原版"岩壁五彩"对应物
func _make_wall(rect: Rect2, tier: int) -> void:
	var n := Node2D.new()
	var wall := Polygon2D.new()
	wall.polygon = PackedVector2Array([rect.position,
			Vector2(rect.end.x, rect.position.y), rect.end,
			Vector2(rect.position.x, rect.end.y)])
	wall.color = Color(0.42, 0.41, 0.39)
	n.add_child(wall)
	_stage.add_child(n)
	CrystalSparkles.attach_to(n, WorldZ.OVERLAY_HINT, "rainbow", tier)


## authentic：原版美术复刻舞台——原版提取的水晶簇贴图 + 原版实机截取的岩壁带纹理，
## 粒子按贴图 alpha 轮廓发射，主题与晶簇颜色一一对应（原版"每材料一色"），
## 岩壁带以锚点网格挂 rainbow 通用盘（对齐原版"多个小块对象拼出密度"的机制）
func _build_authentic_stage() -> void:
	# 洞壁基底：原版无缝墙纹平铺 + 暖褐调（原版调色板为暖褐/深咖）
	var wall_tex: Texture2D = load("res://modules/fx/assets/demo/cave_wall_seamless.png")
	var bg := Sprite2D.new()
	bg.texture = wall_tex
	bg.centered = false
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.region_enabled = true
	bg.region_rect = Rect2(0, 0, STAGE.x, STAGE.y)
	bg.modulate = Color(0.66, 0.53, 0.40)
	bg.z_index = -100
	_stage.add_child(bg)
	# 三条岩壁带（原版实机截取纹理：上/中/下），各自铺 rainbow 锚点网格
	var band_top: Texture2D = load("res://modules/fx/assets/demo/rock_band_top.png")
	var top := Sprite2D.new()
	top.texture = band_top
	top.centered = false
	top.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	top.region_enabled = true
	top.region_rect = Rect2(0, 0, STAGE.x, band_top.get_height())
	top.position = Vector2(0, 10)
	top.z_index = -90
	_stage.add_child(top)
	_make_band_anchors(Rect2(40, 16, STAGE.x - 80, band_top.get_height() - 10), 8, 8)
	var band_tex: Texture2D = load("res://modules/fx/assets/demo/rock_band.png")
	var band := Sprite2D.new()
	band.texture = band_tex
	band.centered = false
	band.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	band.region_enabled = true
	band.region_rect = Rect2(0, 0, STAGE.x, band_tex.get_height())
	band.position = Vector2(0, 545)
	band.z_index = -90
	_stage.add_child(band)
	_make_band_anchors(Rect2(40, 545, STAGE.x - 80, band_tex.get_height()), 8, 8)
	var band_btm := Sprite2D.new()
	band_btm.texture = band_tex
	band_btm.centered = false
	band_btm.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	band_btm.region_enabled = true
	band_btm.region_rect = Rect2(0, 0, STAGE.x, 140)
	band_btm.position = Vector2(0, 935)
	band_btm.z_index = -90
	_stage.add_child(band_btm)
	_make_band_anchors(Rect2(40, 940, STAGE.x - 80, 130), 8, 6)
	# 三簇原版水晶：贴图宿主 + 对应主题窄盘，沿弧线有机排列 + 接触阴影
	_make_authentic_crystal("res://modules/fx/assets/demo/crystal_frost_sapphire.png",
			Vector2(340, 700), 1.15, "sky", 8)
	_make_authentic_crystal("res://modules/fx/assets/demo/crystal_arcane.png",
			Vector2(900, 760), 1.25, "violet", 8)
	_make_authentic_crystal("res://modules/fx/assets/demo/crystal_fire_citrine.png",
			Vector2(1500, 720), 1.2, "gold", 8)
	# 小碎晶点缀（错落）
	_make_authentic_crystal("res://modules/fx/assets/demo/crystal_frost_sapphire.png",
			Vector2(590, 545), 0.45, "sky", 3)
	_make_authentic_crystal("res://modules/fx/assets/demo/crystal_fire_citrine.png",
			Vector2(1250, 530), 0.4, "gold", 3)
	_make_authentic_crystal("res://modules/fx/assets/demo/crystal_arcane.png",
			Vector2(1120, 560), 0.5, "violet", 2)


## 岩壁带锚点网格：原版密度 = 几十个小块对象各挂闪光组叠加。
## 每个锚点一个小块宿主（面积钉在标定下限），rainbow 通用盘。
func _make_band_anchors(rect: Rect2, tier: int, cols: int) -> void:
	var rows := 3
	var step_x := rect.size.x / float(cols)
	var step_y := rect.size.y / float(rows)
	for iy in rows:
		for ix in cols:
			var anchor := Node2D.new()
			anchor.position = rect.position + Vector2(
					(ix + 0.5) * step_x + (iy % 2) * step_x * 0.25,
					(iy + 0.5) * step_y)
			var poly := Polygon2D.new()
			poly.color = Color(0, 0, 0, 0)  # 仅作发射/测量宿主，必须透明（默认白色会渲染成白块）
			var s := 36.0
			poly.polygon = PackedVector2Array([Vector2(-s, -s), Vector2(s, -s),
					Vector2(s, s), Vector2(-s, s)])
			anchor.add_child(poly)
			# 锚点位置加随机抖动消机械感
			anchor.position += Vector2(randf_range(-18, 18), randf_range(-10, 10))
			_stage.add_child(anchor)
			CrystalSparkles.attach_to(anchor, WorldZ.OVERLAY_HINT, "rainbow", tier,
					0.008)  # 恒定小块面积：钉标定下限，对齐原版单块发射 mesh 量级


## 原版贴图水晶宿主：Sprite2D 挂出土晶簇图 + 接触阴影，attach 后粒子按 alpha 轮廓发射
func _make_authentic_crystal(tex_path: String, pos: Vector2, scl: float,
		theme: String, tier: int) -> void:
	var n := Node2D.new()
	n.position = pos
	var spr := Sprite2D.new()
	spr.texture = load(tex_path)
	spr.scale = Vector2.ONE * scl
	spr.position = Vector2(0, -spr.texture.get_height() * scl * 0.5 + 24)
	var shadow := Sprite2D.new()
	shadow.texture = load("res://modules/fx/assets/demo/contact_shadow.png")
	shadow.scale = Vector2(scl * spr.texture.get_width() / 240.0, scl * 0.5)
	n.add_child(shadow)
	n.add_child(spr)
	_stage.add_child(n)
	CrystalSparkles.attach_to(n, WorldZ.OVERLAY_HINT, theme, tier)
