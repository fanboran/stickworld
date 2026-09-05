extends Control
## 手绘自绘皮肤预览 + 像素探针自检（血条同源 boiling 自绘路线）。
##
## 探针：
##   P1 手绘波动：SketchPanel 顶边描边 σ ∈ (0.12, 3)px（非直线、非乱线）
##   P2 沸腾动画：间隔 0.15s 两帧描边中心线有位移（真逐帧重画）
##   P3 边框不合并：30px 矮按钮顶/底描边线间距 ≥ 22px（九宫格挤压回归）
##   P4 字体：SketchFonts.hand() 加载成功且能量测中文
##   P5 焦点描边：SketchLineEdit focus 后琥珀描边出现
## 用法（必须带显示）：godot --path stick-world res://tests/dev/sketch_preview.tscn

var _panel: SketchPanel
var _btn_row: SketchButton
var _edit: SketchLineEdit
var _fails: PackedStringArray = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 手写字体挂根（游戏内 = ui_root 槽主题挂字体，这里等价模拟）
	var hand := SketchFonts.hand()
	if hand != null:
		add_theme_font_override("font", hand)
	_build()
	await get_tree().process_frame
	await get_tree().process_frame
	var img1 := get_viewport().get_texture().get_image()
	await get_tree().create_timer(0.15).timeout
	var img2 := get_viewport().get_texture().get_image()
	img1.save_png("user://shots/sketch_f0.png")
	img2.save_png("user://shots/sketch_f1.png")
	print("[SketchPreview] saved sketch_f0/f1.png")
	_probe(img1, img2)
	for f in _fails:
		print("[SketchPreview] FAIL: ", f)
	if _fails.is_empty():
		print("[SketchPreview] ALL PROBES PASS")
	get_tree().quit()


func _build() -> void:
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_TOP_LEFT)
	col.offset_left = 40
	col.offset_top = 30
	col.offset_right = 760
	col.add_theme_constant_override("separation", 12)
	add_child(col)

	var title := Label.new()
	title.text = "手绘自绘皮肤（血条同源 boiling + StickHand 字体）"
	title.add_theme_font_size_override("font_size", 26)
	col.add_child(title)

	# 主面板 + 按钮族
	_panel = SketchPanel.new()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_panel.add_child(v)
	_label(v, "深色面板 DARK", StickTokens.ACCENT, 15)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	_btn_row = StickKit.sketch_button(row, "普通", Callable(), StickKit.ButtonKind.NORMAL, 30)
	StickKit.sketch_button(row, "强调", Callable(), StickKit.ButtonKind.ACCENT, 30)
	StickKit.sketch_button(row, "危险", Callable(), StickKit.ButtonKind.DANGER, 30)
	var dis := StickKit.sketch_button(row, "禁用", Callable(), StickKit.ButtonKind.NORMAL, 30)
	dis.disabled = true
	StickKit.sketch_button(v, "大按钮 LG", Callable(), StickKit.ButtonKind.ACCENT, StickTokens.BTN_H_LG)
	col.add_child(_panel)

	var sep := SketchSeparator.new()
	sep.direction = SketchSeparator.Dir.HORIZONTAL
	col.add_child(sep)

	# 输入 + 进度
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 12)
	col.add_child(row2)
	_edit = SketchLineEdit.new()
	_edit.text = "手绘输入框"
	_edit.custom_minimum_size = Vector2(200, 34)
	row2.add_child(_edit)
	var pb := SketchProgress.new()
	pb.value = 63
	pb.custom_minimum_size = Vector2(240, 24)
	pb.show_percentage = true
	row2.add_child(pb)

	# 超宽面板（长边扰动密度）
	var wide := SketchPanel.new()
	wide.tone = SketchPanel.Tone.LIGHT
	wide.custom_minimum_size = Vector2(700, 44)
	_label(wide, "超宽 LIGHT 面板：长边按 18px/段采样，不折线", StickTokens.TEXT_DIM, 13)
	col.add_child(wide)

	# 字体梯度
	var fl := VBoxContainer.new()
	fl.add_theme_constant_override("separation", 2)
	col.add_child(fl)
	for s in [34, 22, 14, 11]:
		var l := Label.new()
		l.text = "火柴人帝国 %dpx StickHand" % s
		l.add_theme_font_size_override("font_size", s)
		fl.add_child(l)


func _label(parent: Control, text: String, color: Color, size: int) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	parent.add_child(l)


# ─────────────────────────────── 探针 ────────────────────────────────

func _probe(img1: Image, img2: Image) -> void:
	# P4 字体
	var hand := SketchFonts.hand()
	if hand == null:
		_fails.append("P4 自制字体未加载")
	else:
		var w := hand.get_string_size("火柴人", HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		if w < 10.0:
			_fails.append("P4 字体量测异常 w=%.1f" % w)
	# P1/P2 面板顶边
	if _panel != null:
		var r := _panel.get_global_rect()
		print("[probe] panel rect=", r)
		var c1 := _edge_centers(img1, r)
		var c2 := _edge_centers(img2, r)
		if c1.is_empty():
			_fails.append("P1 面板顶边描边信号缺失")
			return
		var sd := _residual_sd(c1)
		print("[probe] P1 顶边波动 σ=%.3f px (n=%d)" % [sd, c1.size()])
		if sd < 0.12:
			_fails.append("P1 描边过直 σ=%.3f（无手绘感）" % sd)
		if sd > 3.0:
			_fails.append("P1 描边过乱 σ=%.3f" % sd)
		# P2 沸腾：两帧中心线差
		if c2.size() == c1.size() and not c2.is_empty():
			var move := 0.0
			for i in c1.size():
				move += absf(c1[i] - c2[i])
			move /= c1.size()
			print("[probe] P2 帧间中心线平均位移=%.3f px" % move)
			if move < 0.10:
				_fails.append("P2 无沸腾（帧间位移 %.3f）" % move)
	# P3 矮按钮上下边不合并
	if _btn_row != null:
		var br := _btn_row.get_global_rect()
		var x := int(br.position.x + br.size.x * 0.5)
		var top_y := _scan_edge(img1, x, int(br.position.y), 6)
		var bot_y := _scan_edge(img1, x, int(br.end.y), 6)
		if top_y < 0 or bot_y < 0:
			_fails.append("P3 按钮描边缺失 top=%d bot=%d" % [top_y, bot_y])
		elif bot_y - top_y < 22:
			_fails.append("P3 30px 按钮上下描边合并（间距 %d）" % (bot_y - top_y))
		else:
			print("[probe] P3 按钮上下边线间距=%d px" % (bot_y - top_y))
	# P5 聚焦描边
	if _edit != null:
		_edit.grab_focus()
		await get_tree().process_frame
		await get_tree().process_frame
		var img3 := get_viewport().get_texture().get_image()
		var er := _edit.get_global_rect()
		var found := false
		for dx in range(int(er.position.x) + 10, int(er.end.x) - 10, 6):
			var c := _scan_color(img3, Vector2(float(dx), er.position.y), 6, StickTokens.ACCENT)
			if c:
				found = true
				break
		if not found:
			_fails.append("P5 输入框聚焦琥珀描边未出现")


func _edge_centers(img: Image, r: Rect2) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var x0 := int(r.position.x) + 14
	var x1 := int(r.end.x) - 14
	var y_top := int(r.position.y)
	for x in range(x0, x1):
		out.append(_scan_edge(img, x, y_top, 6))
	return out


func _scan_edge(img: Image, x: int, y_base: int, range_px: int) -> float:
	var best := -1.0
	var best_v := 0.0
	for dy in range(-range_px, range_px + 1):
		var y := y_base + dy
		if y < 0 or y >= img.get_height() or x < 0 or x >= img.get_width():
			continue
		var c := img.get_pixel(x, y)
		var v := c.r + c.g + c.b
		if v > best_v:
			best_v = v
			best = float(y)
	return best if best_v > 0.35 else -1.0


func _scan_color(img: Image, p: Vector2, range_px: int, target: Color) -> bool:
	for dy in range(-range_px, range_px + 1):
		var y := int(p.y) + dy
		if y < 0 or y >= img.get_height() or int(p.x) >= img.get_width():
			continue
		var c := img.get_pixel(int(p.x), y)
		if absf(c.h - target.h) < 0.08 and c.s > 0.4 and c.v > 0.4:
			return true
	return false


func _residual_sd(values: PackedFloat32Array) -> float:
	var sum := 0.0
	var sum_sq := 0.0
	var n := 0
	for v in values:
		if v < 0.0:
			continue
		sum += v
		sum_sq += v * v
		n += 1
	if n < 2:
		return 0.0
	var mean := sum / n
	return sqrt(maxf(0.0, sum_sq / n - mean * mean))
