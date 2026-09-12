## 城市街景拼装：把产物 PNG 流式排成中世纪城镇街景（后排远景 + 前排近景），
## 加天空渐变、远山剪影、地面色带，输出一张宽幅全景图。
##   godot --headless --script res://tools/building_pipeline/accept/city_view.gd -- [--dir=res://temp/buildings] [--out=res://temp/city_view.png]
extends SceneTree

const SCALE := 2          # 产物为 2x 烘焙
const MARGIN := 32
const SKY_H := 470
const GROUND_H := 190
const BACK_LIFT := 96     # 后排相对前排地面线上抬（远景）
const GAP := 26           # 建筑间距（px，2x 域）

const ROWS := [
	[  # 前排
		{"def": "wall_seg", "w": 3}, {"def": "gatehouse", "w": 8}, {"def": "cottage", "w": 4},
		{"def": "house", "w": 6}, {"def": "tavern", "w": 8}, {"def": "shop", "w": 4},
		{"def": "market_stall", "w": 4}, {"def": "well", "w": 3}, {"def": "bakery", "w": 6},
		{"def": "smithy4", "w": 8}, {"def": "stable", "w": 6}, {"def": "barn", "w": 8},
		{"def": "house", "w": 8}, {"def": "townhouse", "w": 6}, {"def": "plaster_house", "w": 6},
		{"def": "smithy2", "w": 6}, {"def": "house", "w": 4}, {"def": "wall_seg", "w": 3},
	],
	[  # 后排
		{"def": "tower", "w": 4}, {"def": "church", "w": 12}, {"def": "smithy3", "w": 6},
		{"def": "windmill", "w": 4}, {"def": "guildhall", "w": 12}, {"def": "chapel", "w": 6},
		{"def": "church", "w": 10}, {"def": "tower", "w": 5}, {"def": "smithy1", "w": 6},
	],
]


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var dir := "res://temp/buildings"
	var out_path := "res://temp/city_view.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
	var abs_dir := ProjectSettings.globalize_path(dir)

	# 载入各行建筑
	var rows: Array = []
	var max_w := 0
	for r in ROWS.size():
		var items: Array = []
		var x := 0
		for it_v in ROWS[r]:
			var it: Dictionary = it_v
			var w := int(it["w"])
			var path := "%s/%s_w%d.png" % [abs_dir, String(it["def"]), w]
			var img := Image.load_from_file(path)
			if img == null:
				printerr("[city] 缺产物 " + path)
				quit(1)
				return
			items.append({"img": img, "x": x})
			x += img.get_width() + GAP
		items.append({"total_w": x - GAP})
		max_w = maxi(max_w, x - GAP)
		rows.append(items)

	var canvas_w := max_w + MARGIN * 2
	var ground_y := SKY_H + GROUND_H          # 前排地面线
	var canvas_h := ground_y + 24
	var canvas := Image.create(canvas_w, canvas_h, false, Image.FORMAT_RGBA8)

	# 天空渐变
	for y in SKY_H:
		var t := float(y) / float(SKY_H)
		var c := Color(0.80, 0.87, 0.92).lerp(Color(0.94, 0.93, 0.88), t)
		canvas.fill_rect(Rect2i(0, y, canvas_w, 1), c)
	# 远山剪影（两层折线）
	_hills(canvas, canvas_w, SKY_H, 0.0, Color(0.72, 0.76, 0.76), 46.0, 200.0)
	_hills(canvas, canvas_w, SKY_H, 1.7, Color(0.62, 0.68, 0.68), 30.0, 320.0)
	# 地面色带 + 横向纹理
	for y in range(SKY_H, canvas_h):
		var t := float(y - SKY_H) / maxf(1.0, float(canvas_h - SKY_H))
		canvas.fill_rect(Rect2i(0, y, canvas_w, 1), Color(0.83, 0.77, 0.64).lerp(Color(0.74, 0.67, 0.54), t))
	for i in 26:
		var gy := SKY_H + 12 + i * 7
		if gy >= canvas_h:
			break
		canvas.fill_rect(Rect2i(0, gy, canvas_w, 1), Color(0.68, 0.61, 0.48, 0.25))

	# 后排（远景，先贴，压一层空气透视薄雾）
	_compose_row(canvas, rows[1], MARGIN, ground_y - BACK_LIFT)
	var haze := Image.create(canvas_w, canvas_h - SKY_H, false, Image.FORMAT_RGBA8)
	haze.fill(Color(0.86, 0.88, 0.90, 0.22))
	canvas.blend_rect(haze, Rect2i(0, 0, canvas_w, canvas_h - SKY_H), Vector2i(0, SKY_H))
	# 前排（近景）
	_compose_row(canvas, rows[0], MARGIN, ground_y)

	var out_abs := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
	var err := canvas.save_png(out_abs)
	if err != OK:
		printerr("[city] 保存失败 " + out_abs)
		quit(1)
		return
	print("[city] 街景 %dx%d → %s（前排 %d 栋 / 后排 %d 栋）" % [canvas_w, canvas_h, out_abs, rows[0].size() - 1, rows[1].size() - 1])
	quit(0)


## 一行建筑按各自 PNG 宽流式排布，底边对齐 baseline_y。
func _compose_row(canvas: Image, items: Array, x0: int, baseline_y: int) -> void:
	for it_v in items:
		var it: Dictionary = it_v
		if not it.has("img"):
			continue
		var img: Image = it["img"]
		var y := baseline_y - img.get_height()
		canvas.blend_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(x0 + int(it["x"]), y))


## 远山剪影：两条低频正弦叠加，向上取高。
func _hills(canvas: Image, w: int, base_y: int, phase: float, color: Color, amp: float, wave: float) -> void:
	var heights := PackedInt32Array()
	heights.resize(w)
	for x in w:
		var fx := float(x)
		var h := amp * (0.6 + 0.4 * sin(fx / wave + phase) + 0.35 * sin(fx / (wave * 0.37) + phase * 2.1))
		heights[x] = base_y - maxi(6, int(h) + 30)
	# 逐列填到地平线
	for x in w:
		canvas.fill_rect(Rect2i(x, heights[x], 1, base_y - heights[x]), color)
