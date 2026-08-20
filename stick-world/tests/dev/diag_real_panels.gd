extends Control
## 诊断：真实主菜单 / 真实 ESC 暂停菜单（StickScreen 装配路径）渲染截图。
## 运行（弹窗 ~2s 自动截图退出）：
##   godot --path stick-world res://tests/dev/diag_real_panels.tscn -- --shot=F:/out.png

const _MainMenuScene: PackedScene = preload("res://modules/ui_global/scenes/menus/main_menu.tscn")
const _PauseMenuPanelScript: GDScript = preload("res://modules/ui_global/scripts/panels/pause_menu_panel.gd")
const _UIKitScript: GDScript = preload("res://modules/ui_global/scripts/UIKit.gd")

var _frames: int = 0
var _shot_path: String = ""
var _stage: int = 0
const SHOT_FRAME: int = 45


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
	# 舞台 0：真实主菜单
	var menu: Control = _MainMenuScene.instantiate()
	menu.name = "StageMainMenu"
	add_child(menu)
	# 舞台 1：真实 ESC 暂停菜单（按 SystemSetup 装配：full_rect + 挂父节点 + setup + open）
	var pp := UIKit.full_rect(_PauseMenuPanelScript, "PauseMenuPanel")
	pp.setup(null)
	pp.visible = false
	add_child(pp)
	pp.set_anchors_preset(Control.PRESET_FULL_RECT)
	pp.visible = false


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == SHOT_FRAME:
		_save_shot("shot_main_menu")
	elif _frames == SHOT_FRAME + 6:
		# 切舞台：藏主菜单，开暂停菜单
		var menu := get_node_or_null("StageMainMenu")
		if menu != null:
			menu.visible = false
		var pp := get_node_or_null("PauseMenuPanel")
		if pp != null and pp.has_method("open"):
			pp.open()
	elif _frames == SHOT_FRAME * 2 + 6:
		_save_shot("shot_pause_menu")
	elif _frames > SHOT_FRAME * 2 + 12:
		get_tree().quit(0)


func _save_shot(tag: String) -> void:
	if _shot_path.is_empty():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var path: String = _shot_path.replace(".png", "_%s.png" % tag)
	var err: int = img.save_png(path)
	print("[diag] %s 截图保存: %s (err=%d)" % [tag, path, err])
