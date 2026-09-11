extends SceneTree
## dev 对照：plain Button 挂 icon 的三种方式（icon_max_width 18），排查 HUD 顶栏图标不显示。
## A=icon+text+expand_icon+maxw（global_hud 现用） B=icon+text+maxw  C=icon-only+expand（齿轮 tscn 模式）

func _initialize() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.17, 0.19)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.set_anchors_preset(Control.PRESET_CENTER)
	root.add_child(row)
	var tex: Texture2D = load("res://assets/icons/战鼓_64.png")
	var a := Button.new()
	a.text = "编制"; a.icon = tex; a.expand_icon = true
	a.add_theme_constant_override("icon_max_width", 18)
	row.add_child(a)
	var b := Button.new()
	b.text = "编制"; b.icon = tex
	b.add_theme_constant_override("icon_max_width", 18)
	row.add_child(b)
	var c := Button.new()
	c.icon = tex; c.expand_icon = true
	c.custom_minimum_size = Vector2(40, 30)
	row.add_child(c)
	print("TEX=", tex, " SIZE=", tex.get_size() if tex else Vector2())
	_shot.call_deferred()

func _shot() -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://../temp/btn_icon_test.png"))
	print("SAVED")
	quit(0)
