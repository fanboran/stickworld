## 城市街景渲染器：**围墙中的城市** —— 高耸城墙作背景（含塔楼/垛口/箭窗），
## 左右两侧近景城墙转角，城内单层排布的建筑按功能区展开，地面按规模档铺装。
##   godot --headless --script res://tools/building_pipeline/accept/city_view.gd -- [--dir=] [--tier=town] [--seed=3] [--out=]
extends SceneTree

const SCALE := 4          # 产物烘焙分辨率
const TextureBank := preload("res://tools/building_pipeline/draw/texture_bank.gd")
const CityPlan := preload("res://tools/building_pipeline/city_plan.gd")

const GROUND_BAND := 150  # 地面带高（1x）
const SIDE_WALL_W := 190  # 左右近景城墙转角宽
const GAP := 18           # 建筑间距（1x）


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var dir := "res://temp/buildings"
	var out_path := "res://temp/city_view.png"
	var tier := "town"
	var seed_val := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		elif a.begins_with("--tier="):
			tier = a.substr(7)
		elif a.begins_with("--seed="):
			seed_val = int(a.substr(7))
	var abs_dir := ProjectSettings.globalize_path(dir)

	var plan := CityPlan.plan(tier, seed_val)
	if not plan.has("buildings"):
		printerr("[city] 计划生成失败")
		quit(1)
		return

	# ---- 载入建筑（4x → 1x 降采样）----
	var items: Array = []
	var max_h := 0
	for b_v in plan["buildings"]:
		var b: Dictionary = b_v
		var path := "%s/%s_w%d.png" % [abs_dir, String(b["def"]), int(b["w"])]
		var img := Image.load_from_file(path)
		if img == null:
			printerr("[city] 缺产物 " + path)
			quit(1)
			return
		img.resize(img.get_width() / SCALE, img.get_height() / SCALE, Image.INTERPOLATE_LANCZOS)
		items.append({"img": img, "def": String(b["def"]), "zone": String(b["zone"])})
		max_h = maxi(max_h, img.get_height())

	# ---- 画布尺寸 ----
	var wall_h := int(plan["wall_h"])
	var body_w := 0
	for it_v in items:
		body_w += int((it_v as Dictionary)["img"].get_width()) + GAP
	body_w -= GAP
	var canvas_w := body_w + SIDE_WALL_W * 2 + 80
	var ground_y := maxi(max_h + 60, wall_h + 90)
	var canvas_h := ground_y + GROUND_BAND
	var sky_top := ground_y - wall_h

	var canvas := Image.create(canvas_w, canvas_h, false, Image.FORMAT_RGBA8)
	# 天空（城墙之上的窄带）
	for y in sky_top:
		var t := float(y) / maxf(1.0, float(sky_top))
		canvas.fill_rect(Rect2i(0, y, canvas_w, 1), Color(0.78, 0.85, 0.92).lerp(Color(0.93, 0.92, 0.87), t))

	# ---- 背景城墙（高耸，占屏约 2/3）----
	_draw_city_wall(canvas, canvas_w, sky_top, ground_y, wall_h, int(plan["wall_tier"]))

	# ---- 城内地面 ----
	_draw_ground(canvas, canvas_w, ground_y, String(plan["ground"]))

	# ---- 建筑排布（从左到右，底对齐地面线）----
	var x := SIDE_WALL_W + 40
	for it_v in items:
		var it: Dictionary = it_v
		var img: Image = it["img"]
		canvas.blend_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(x, ground_y - img.get_height()))
		x += img.get_width() + GAP

	# ---- 左右近景城墙转角（压住画面两端）----
	_draw_side_wall(canvas, Rect2i(0, sky_top - 40, SIDE_WALL_W, ground_y - sky_top + 40), true)
	_draw_side_wall(canvas, Rect2i(canvas_w - SIDE_WALL_W, sky_top - 40, SIDE_WALL_W, ground_y - sky_top + 40), false)

	var out_abs := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
	var err := canvas.save_png(out_abs)
	if err != OK:
		printerr("[city] 保存失败 " + out_abs)
		quit(1)
		return
	print("[city] %s（%s）%dx%d → %s｜建筑 %d 栋" % [String(plan["label"]), tier, canvas_w, canvas_h, out_abs, items.size()])
	quit(0)


## 背景城墙：石砌墙身 + 垛口 + 凸出塔楼 + 箭窗 + 墙基阴影。
func _draw_city_wall(canvas: Image, w: int, top_y: int, ground_y: int, wall_h: int, tier: int) -> void:
	var stone := TextureBank.bake("stone_light", tier + 1)
	var stone_dark := TextureBank.bake("stone_dark", tier + 2)
	var moss := TextureBank.bake("moss", 5)
	# 墙身
	_tile(canvas, stone, Rect2i(0, top_y, w, ground_y - top_y))
	# 苔藓斑（下半部）
	_tile_masked(canvas, moss, Rect2i(0, top_y + (ground_y - top_y) / 2, w, (ground_y - top_y) / 2), 0.26)
	# 墙基压暗（渐变叠加）
	var base_shade := Image.create(w, 40, false, Image.FORMAT_RGBA8)
	for i in 40:
		base_shade.fill_rect(Rect2i(0, i, w, 1), Color(0.1, 0.09, 0.08, float(i) / 40.0 * 0.25))
	canvas.blend_rect(base_shade, Rect2i(0, 0, w, 40), Vector2i(0, ground_y - 40))
	# 塔楼（等距凸出）
	var tower_step := 980
	var tx := 420
	while tx < w - 200:
		_draw_tower(canvas, Rect2i(tx, top_y - 76, 168, ground_y - top_y + 76), stone, stone_dark)
		tx += tower_step + int(_hash01(tx, 7) * 320.0)
	# 箭窗（两排）
	var y1 := top_y + int(float(ground_y - top_y) * 0.18)
	var y2 := top_y + int(float(ground_y - top_y) * 0.5)
	var wx := 90
	while wx < w - 60:
		_arrow_slit(canvas, Vector2i(wx, y1))
		_arrow_slit(canvas, Vector2i(wx, y2))
		wx += 170 + int(_hash01(wx, 3) * 90.0)
	# 垛口（墙顶齿列）
	var merlon_w := 30
	var gap_w := 20
	var mx := 0
	while mx < w:
		var mw := mini(merlon_w, w - mx)
		canvas.fill_rect(Rect2i(mx, top_y - 22, mw, 22), Color(0.62, 0.6, 0.55, 1.0))
		canvas.fill_rect(Rect2i(mx, top_y - 22, mw, 3), Color(0.74, 0.72, 0.66, 1.0))
		canvas.fill_rect(Rect2i(mx, top_y - 4, mw, 4), Color(0.3, 0.29, 0.26, 0.5))
		mx += merlon_w + gap_w
	# 墙顶压顶线
	for y in range(top_y, top_y + 6):
		canvas.fill_rect(Rect2i(0, y, w, 1), Color(0.52, 0.5, 0.46, 0.3))


func _draw_tower(canvas: Image, r: Rect2i, stone: Image, stone_dark: Image) -> void:
	_tile(canvas, stone_dark, r)
	canvas.fill_rect(Rect2i(r.position.x, r.position.y, 6, r.size.y), Color(0.3, 0.29, 0.27, 0.5))
	canvas.fill_rect(Rect2i(r.end.x - 8, r.position.y, 8, r.size.y), Color(0.22, 0.21, 0.2, 0.45))
	# 塔垛口
	var mx := r.position.x
	while mx < r.end.x:
		var mw := mini(30, r.end.x - mx)
		canvas.fill_rect(Rect2i(mx, r.position.y - 20, mw, 20), Color(0.58, 0.56, 0.52, 1.0))
		canvas.fill_rect(Rect2i(mx, r.position.y - 20, mw, 3), Color(0.7, 0.68, 0.63, 1.0))
		mx += 30 + 18
	# 箭窗
	_arrow_slit(canvas, Vector2i(r.position.x + r.size.x / 2 - 11, r.position.y + 60))
	for k in 3:
		_arrow_slit(canvas, Vector2i(r.position.x + r.size.x / 2 - 11, r.position.y + 130 + k * 110))


func _arrow_slit(canvas: Image, at: Vector2i) -> void:
	canvas.fill_rect(Rect2i(at.x, at.y, 22, 40), Color(0.12, 0.11, 0.1, 1.0))
	canvas.fill_rect(Rect2i(at.x + 4, at.y - 6, 14, 8), Color(0.12, 0.11, 0.1, 1.0))
	canvas.fill_rect(Rect2i(at.x, at.y, 22, 3), Color(0.55, 0.53, 0.49, 0.6))
	canvas.fill_rect(Rect2i(at.x - 4, at.y - 8, 30, 3), Color(0.55, 0.53, 0.49, 0.55))
	canvas.fill_rect(Rect2i(at.x, at.y + 40, 22, 3), Color(0.55, 0.53, 0.49, 0.5))


## 城内地面：按规模档铺装 + 一条主路 + 近处暗角。
func _draw_ground(canvas: Image, w: int, ground_y: int, kind: String) -> void:
	var h := canvas.get_height() - ground_y
	var tex := TextureBank.bake(kind, 11)
	_tile(canvas, tex, Rect2i(0, ground_y, w, h))
	# 主路（建筑前的横向路面，稍亮）
	var road := Rect2i(0, ground_y + 8, w, 46)
	var road_tex := TextureBank.bake("dirt" if kind != "dirt" else "cobble", 13)
	_tile(canvas, road_tex, road)
	# 路缘阴影
	var curb := Image.create(w, 8, false, Image.FORMAT_RGBA8)
	for i in 8:
		curb.fill_rect(Rect2i(0, i, w, 1), Color(0.2, 0.18, 0.15, 0.22 - float(i) * 0.02))
	canvas.blend_rect(curb, Rect2i(0, 0, w, 8), Vector2i(0, ground_y))
	# 越往下越暗（近景压暗，半透明叠加）
	var shade := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for i in h:
		shade.fill_rect(Rect2i(0, i, w, 1), Color(0.16, 0.14, 0.12, float(i) / float(maxi(1, h)) * 0.06))
	canvas.blend_rect(shade, Rect2i(0, 0, w, h), Vector2i(0, ground_y))


## 左右近景城墙转角（画面两端的"侧墙"，比背景墙更高更暗，表示被墙围住）。
func _draw_side_wall(canvas: Image, r: Rect2i, is_left: bool) -> void:
	var stone := TextureBank.bake("stone", 21)
	_tile(canvas, stone, r)
	# 内侧压暗 + 高光棱
	if is_left:
		canvas.fill_rect(Rect2i(r.end.x - 26, r.position.y, 26, r.size.y), Color(0.14, 0.13, 0.12, 0.4))
		canvas.fill_rect(Rect2i(r.position.x, r.position.y, 10, r.size.y), Color(0.78, 0.76, 0.7, 0.28))
	else:
		canvas.fill_rect(Rect2i(r.position.x, r.position.y, 26, r.size.y), Color(0.14, 0.13, 0.12, 0.4))
		canvas.fill_rect(Rect2i(r.end.x - 10, r.position.y, 10, r.size.y), Color(0.78, 0.76, 0.7, 0.28))
	# 顶部垛口
	var mx := r.position.x
	while mx < r.end.x:
		var mw := mini(30, r.end.x - mx)
		canvas.fill_rect(Rect2i(mx, r.position.y, mw, 26), Color(0.5, 0.48, 0.44, 1.0))
		canvas.fill_rect(Rect2i(mx, r.position.y, mw, 4), Color(0.64, 0.62, 0.57, 1.0))
		mx += 30 + 18
	# 箭窗
	var yy := r.position.y + 70
	while yy < r.end.y - 60:
		_arrow_slit(canvas, Vector2i(r.position.x + r.size.x / 2 - 11, yy))
		yy += 190


# ---------- 图像工具 ----------

func _solid(w: int, h: int, c: Color) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


## 平铺纹理到区域（块操作，自动裁剪边缘）。
func _tile(canvas: Image, tex: Image, rect: Rect2i) -> void:
	var tw := tex.get_width()
	var th := tex.get_height()
	var y := rect.position.y
	while y < rect.end.y:
		var x := rect.position.x
		while x < rect.end.x:
			var w := mini(tw, rect.end.x - x)
			var h := mini(th, rect.end.y - y)
			if w > 0 and h > 0:
				canvas.blend_rect(tex, Rect2i(0, 0, w, h), Vector2i(x, y))
			x += tw
		y += th


## 稀疏平铺（跳格叠加，用于苔藓等 overlay）。
func _tile_masked(canvas: Image, tex: Image, rect: Rect2i, keep: float) -> void:
	var tw := tex.get_width()
	var th := tex.get_height()
	var y := rect.position.y
	var row := 0
	while y < rect.end.y:
		var x := rect.position.x
		var col := 0
		while x < rect.end.x:
			if _hash01(x * 7 + y * 13, 29) < keep:
				var w := mini(tw, rect.end.x - x)
				var h := mini(th, rect.end.y - y)
				if w > 0 and h > 0:
					canvas.blend_rect(tex, Rect2i(0, 0, w, h), Vector2i(x, y))
			x += tw
			col += 1
		y += th
		row += 1


func _hash01(v: int, salt: int) -> float:
	var h := (v * 1103515245 + salt * 12345) & 0x7fffffff
	return float((h >> 8) & 0xffff) / 65535.0
