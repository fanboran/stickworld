extends SceneTree
## dev 冒烟：Hotbar 图标接线目检——按真实 Hotbar 布局摆 10 格（装备镜像+
## 物品 1-4+动作组），渲染两帧后截图到 temp/hotbar_wiring_check.png。
## 运行：godot --path . --script res://tests/dev/_diag_hotbar_shot.gd

const OUT := "res://../temp/hotbar_wiring_check.png"

func _initialize() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.14, 0.16)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.set_anchors_preset(Control.PRESET_CENTER)
	row.add_child(_cell(ItemStack.new(&"wpn_sword_001"), "左键"))
	row.add_child(_cell(ItemStack.new(&"shd_wood_001"), "右键"))
	for pair in [[&"con_bandage", 3], [&"mat_stone", 12], [&"mat_diamond", 2], [&"arm_chest_leather", 1]]:
		row.add_child(_cell(ItemStack.new(pair[0], pair[1]), ""))
	for action_id in ["interact", "unstuck", "inventory", "stats"]:
		var w := ItemSlotWidget.new(ItemSlotWidget.Mode.ACTION)
		w.action_id = action_id
		w.caption = {"interact": "F", "unstuck": "H", "inventory": "E", "stats": "C"}[action_id]
		row.add_child(w)
	root.add_child.call_deferred(row)
	_shot()

func _cell(stack: ItemStack, cap: String) -> ItemSlotWidget:
	var w := ItemSlotWidget.new(ItemSlotWidget.Mode.HOTBAR_ITEM)
	w.stack = stack
	w.caption = cap
	return w

func _shot() -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	# 1920x1080 基座下行居中（~610x67）：裁图标带放大目检
	var band := Rect2i(950, 460, 700, 160)
	img = img.get_region(band)
	img.save_png(ProjectSettings.globalize_path(OUT))
	print("SHOT-SAVED ", OUT)
	quit(0)
