extends Control
## 诊断：确认框高度 bug（面板曾被撑到 434 高）。
## 路径 A：直接实例化 StickConfirmDialog；路径 B：复刻 ui_shots 剧本
## （真实主菜单 → quit 确认框），各打印 _dim/_window 尺寸与四边 offset。
## 运行：
##   godot --headless --path stick-world res://tests/dev/diag_confirm_size.tscn

const _MainMenuScene: PackedScene = preload("res://modules/ui_global/scenes/menus/main_menu.tscn")

var _frames: int = 0
var _dialog: Control = null
var _stage: int = 0


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	# 路径 A：直接实例化
	var dialog := StickConfirmDialog.new()
	dialog.name = "DiagConfirm"
	dialog.setup("退出游戏", "确定要退出吗？未保存的进度将丢失。",
			Callable(), "退出", StickKit.ButtonKind.DANGER)
	add_child(dialog)
	_dialog = dialog
	dialog.open()
	_dump("A. add_child 直后（同步）")


func _process(_delta: float) -> void:
	_frames += 1
	if _stage == 0:
		_dump("A. 帧 %d" % _frames)
		if _frames >= 3:
			# 切路径 B：真实主菜单的退出确认框（ui_shots 同款剧本）
			_dialog.queue_free()
			var menu: Control = _MainMenuScene.instantiate()
			menu.name = "StageMainMenu"
			add_child(menu)
			await get_tree().process_frame
			menu._on_menu_pressed({"id": "quit"})
			_stage = 1
			_frames = 0
			_dump("B. 主菜单 quit 直后（同步）")
	elif _stage == 1:
		if _frames == 3:
			_dump("B. 帧 3")
			get_tree().quit(0)


func _dump(tag: String) -> void:
	if _stage == 1 and _dialog == null:
		var menu := get_node_or_null("StageMainMenu")
		_dialog = _find_dialog(menu) if menu != null else null
		if _dialog == null:
			print("[%s] 主菜单下未找到确认框" % tag)
			return
	var dim: Control = _dialog.get_node_or_null("Dim")
	if dim == null:
		print("[%s] 无 Dim" % tag)
		return
	var win: Control = null
	for c in dim.get_children():
		if c is PanelContainer:
			win = c
			break
	if win == null:
		print("[%s] Dim 下无 PanelContainer 子节点" % tag)
		return
	var box: Control = win.get_child(0) if win.get_child_count() > 0 else null
	print("[%s] dim.size=%s | win.size=%s offs(L%.0f T%.0f R%.0f B%.0f) win.rect=%s | box.size=%s" % [
		tag, dim.size, win.size,
		win.offset_left, win.offset_top, win.offset_right, win.offset_bottom,
		win.get_global_rect(), box.size if box else Vector2.ZERO])


func _find_dialog(root: Node) -> Control:
	if root is StickConfirmDialog:
		return root
	for c in root.get_children():
		var hit := _find_dialog(c)
		if hit != null:
			return hit
	return null
