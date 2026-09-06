extends Control
func _ready() -> void:
	theme = StickTheme.create()
	var col := VBoxContainer.new()
	col.position = Vector2(100, 100)
	add_child(col)
	# 复刻 StickKit 工厂调用顺序：new → _setup_button（含字色 override）→ add_child
	var b := SketchButton.new()
	b.text = "暂停菜单同款 NORMAL"
	b.custom_minimum_size = Vector2(0, 44)
	StickKit._setup_button(b, Callable(), StickKit.ButtonKind.NORMAL)
	col.add_child(b)
	var b2 := SketchButton.new()
	b2.text = "同款 ACCENT"
	b2.custom_minimum_size = Vector2(0, 44)
	StickKit._setup_button(b2, Callable(), StickKit.ButtonKind.ACCENT)
	col.add_child(b2)
	await get_tree().process_frame
	await get_tree().process_frame
	for pair in [["NORMAL", b], ["ACCENT", b2]]:
		var btn: SketchButton = pair[1]
		print("[hover-diag] %s 常态字色=%s" % [pair[0], btn.get_theme_color("font_color")])
		btn._apply_text_colors.call_deferred()
		await get_tree().process_frame
		print("[hover-diag] %s apply后常态字色=%s" % [pair[0], btn.get_theme_color("font_color")])
	get_tree().quit()
