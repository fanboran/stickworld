extends Control
func _ready() -> void:
	theme = StickTheme.create()
	var b := SketchButton.new()
	b.text = "测试 NORMAL"
	b.custom_minimum_size = Vector2(0, 44)
	position = Vector2(200, 200)
	add_child(b)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[txt] 常态 font_color=", b.get_theme_color("font_color"), " is_hovered=", b.is_hovered())
	# 模拟 StickKit 工厂完整顺序（含 hover 缩放 lambda 是否碰字色）
	var b2 := SketchButton.new()
	b2.text = "工厂顺序"
	b2.custom_minimum_size = Vector2(0, 44)
	b2.position = Vector2(200, 260)
	StickKit._setup_button(b2, Callable(), StickKit.ButtonKind.NORMAL)
	add_child(b2)
	await get_tree().process_frame
	print("[txt] 工厂序 font_color=", b2.get_theme_color("font_color"))
	get_tree().quit()
