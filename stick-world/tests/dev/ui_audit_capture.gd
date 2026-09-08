extends Node
## 临时审计截图脚本（用完即删）：逐个实例化 UI 模板，等待渲染后截屏存 PNG。
## 用法：godot --path . res://tests/dev/ui_audit_capture.tscn（需真实渲染，不能 headless）

const SHOTS := [
	["component_gallery", "res://modules/ui_global/scenes/templates/component_gallery.tscn"],
	["main_menu", "res://modules/ui_global/scenes/menus/main_menu.tscn"],
	["hud_template", "res://modules/ui_global/scenes/templates/hud_template.tscn"],
	["settings_template", "res://modules/ui_global/scenes/templates/settings_template.tscn"],
	["workspace_template", "res://modules/ui_global/scenes/templates/workspace_template.tscn"],
]
const OUT_DIR := "res://tests/dev/ui_audit"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for shot in SHOTS:
		var pack: PackedScene = load(shot[1])
		if pack == null:
			print("SKIP ", shot[0], " 加载失败")
			continue
		var node := pack.instantiate()
		get_tree().root.add_child.call_deferred(node)
		await get_tree().process_frame
		# 等渲染稳定：字体/布局/沸腾首轮
		for i in 12:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot[0]]
		img.save_png(ProjectSettings.globalize_path(path))
		print("SHOT ", path, " ", img.get_size())
		node.queue_free()
		await get_tree().process_frame
	get_tree().quit()
