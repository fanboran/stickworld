## 验收拼页：扫描产物目录全部 PNG，统一高度后按网格拼页（纸色底），输出一页浏览图。
##   godot --path stick-world --script res://tools/building_pipeline/accept/sheet.gd -- [--dir=res://temp/buildings] [--out=res://temp/buildings_sheet.png]
extends SceneTree

const COLS := 4
const CELL_H := 420
const PAD := 18
const PAPER_BG := Color(0.949, 0.925, 0.867)


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var dir := "res://temp/buildings"
	var out_path := "res://temp/buildings_sheet.png"
	var only: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.substr(6)
		elif a.begins_with("--out="):
			out_path = a.substr(6)
		elif a.begins_with("--defs="):
			for dd in a.substr(7).split(","):
				if dd.strip_edges() != "":
					only.append(dd.strip_edges())

	var abs_dir := ProjectSettings.globalize_path(dir)
	var files: Array = []
	var d := DirAccess.open(abs_dir)
	if d == null:
		printerr("[sheet] 目录不存在 " + abs_dir)
		quit(1)
		return
	for f in d.get_files():
		if f.ends_with(".png") and not f.ends_with("_sheet.png"):
			if not only.is_empty() and not _match_only(String(f), only):
				continue
			files.append(f)
	files.sort()

	if files.is_empty():
		printerr("[sheet] 无产物 PNG：" + abs_dir)
		quit(1)
		return

	# 统一高度缩放
	var imgs: Array = []
	var max_w := 0
	for f_v in files:
		var img := Image.load_from_file(abs_dir + "/" + String(f_v))
		if img == null:
			printerr("[sheet] 读取失败 " + String(f_v))
			continue
		var scale := float(CELL_H - PAD * 2) / float(img.get_height())
		img.resize(maxi(1, int(img.get_width() * scale)), CELL_H - PAD * 2, Image.INTERPOLATE_LANCZOS)
		imgs.append({"name": String(f_v), "img": img})
		max_w = maxi(max_w, img.get_width())

	var cell_w := max_w + PAD * 2
	var rows := ceili(float(imgs.size()) / float(COLS))
	var sheet := Image.create(cell_w * COLS, CELL_H * rows, false, Image.FORMAT_RGBA8)
	sheet.fill(PAPER_BG)

	for i in imgs.size():
		var e: Dictionary = imgs[i]
		var cx := (i % COLS) * cell_w + PAD
		var cy := (i / COLS) * CELL_H + PAD
		var img: Image = e["img"]
		sheet.blend_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(cx, cy))

	var out_abs := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(out_abs.get_base_dir())
	var err := sheet.save_png(out_abs)
	if err != OK:
		printerr("[sheet] 保存失败 " + out_abs)
		quit(1)
		return
	print("[sheet] 拼页 %d 枚 → %s" % [imgs.size(), out_abs])
	print("[sheet] 顺序：")
	for i in imgs.size():
		print("  [%d] %s" % [i, String(imgs[i]["name"])])
	quit(0)


static func _match_only(fname: String, only: Array) -> bool:
	for o in only:
		if fname.begins_with(String(o) + "_w"):
			return true
	return false
