extends Node
## 按钮变体系统验收（批次 C 验收辅助）：真渲染三屏 + 变体陈列截图
##   1. 主菜单（PAPER/PRIMARY 变体 + 母题角标 + 半透明纸面）
##   2. 游戏内 HUD（顶栏按钮，鼠标悬停一枚呈现 hover 态）
##   3. 设置面板（游戏内经 toggle_settings_menu 开启）
##   4. sketch_compare 陈列（DARK/ACCENT/DANGER/PAPER/PRIMARY/ICON_SQUARE 全族）
## 运行（不要 --headless，headless 是哑渲染截不出图）：
##   godot --path stick-world res://tests/dev/verify_button_variants.tscn
## 截图输出 worktree 下 temp/shots_c/；SHOT_SUFFIX 环境变量区分改造前后
## （如 SHOT_SUFFIX=before godot ...），默认 after。
## 退出码：0 截图完成，1 世界未就绪

const MainMenuScene := preload("res://modules/ui_global/scenes/menus/main_menu.tscn")
const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const SketchCompareScene := preload("res://tests/dev/sketch_compare.tscn")

## 截图输出目录（worktree 下 temp/shots_c/，gitignored）
const OUT_DIR := "res://../temp/shots_c"
const BOOT_TIMEOUT_FRAMES := 900

var _suffix: String = "after"


func _ready() -> void:
	_suffix = OS.get_environment("SHOT_SUFFIX")
	if _suffix.is_empty():
		_suffix = "after"
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame

	# ── 1. 主菜单 ──
	var menu := MainMenuScene.instantiate()
	add_child(menu)
	for i in 75:  # 等标题进场 + 背景装配稳定
		await get_tree().process_frame
	await _shot("menu_%s.png" % _suffix)
	menu.queue_free()
	await get_tree().process_frame

	# ── 2/3. 游戏内 HUD + 设置面板 ──
	var game_root := GameRootScene.instantiate()
	add_child(game_root)
	var map: Node2D = null
	for i in BOOT_TIMEOUT_FRAMES:
		map = game_root.get_current_map()
		if map != null:
			break
		await get_tree().process_frame
	if map == null:
		push_error("[FAIL] 世界未就绪（BOOT_TIMEOUT_FRAMES 内地图未加载）")
		get_tree().quit(1)
		return
	for i in 40:
		await get_tree().process_frame
	# 顶栏悬停态：鼠标移到「编制」钮上（hover 贴图可观感）
	var hud: Control = game_root.ui_root.get_slot("GlobalHUD")
	var probe: Button = hud.get_node_or_null("MarginContainer/HBoxContainer/FormationButton") if hud != null else null
	if probe != null:
		Input.warp_mouse(probe.get_global_rect().get_center())
		for i in 10:
			await get_tree().process_frame
	await _shot("hud_%s.png" % _suffix)
	# 设置面板（模态开启）
	game_root.toggle_settings_menu()
	for i in 30:
		await get_tree().process_frame
	await _shot("settings_%s.png" % _suffix)
	# 关闭设置面板（再 toggle），防模态遮罩盖住下一段的变体陈列
	game_root.toggle_settings_menu()
	for i in 15:
		await get_tree().process_frame

	# ── 4. 变体陈列（sketch_compare 全族：含 PAPER/ICON_SQUARE 档）──
	# 游戏世界保持存活作背景（单独起画廊会只剩清屏色，无参照）。
	# 画廊必须挂 CanvasLayer：世界相机的 canvas transform 会把 layer 0 的
	# Control 拖出视野，CanvasLayer 是屏幕空间不受相机影响
	SketchTextures.animation_enabled = true
	SketchTextures.ensure_driver(get_tree())
	var gallery_layer := CanvasLayer.new()
	gallery_layer.layer = 100
	add_child(gallery_layer)
	var gallery := SketchCompareScene.instantiate()
	gallery_layer.add_child(gallery)
	# 陈列场根锚点在 CanvasLayer 下未产生尺寸（size=0）——脚本侧强制全屏
	if gallery is Control:
		(gallery as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		(gallery as Control).size = get_viewport().get_visible_rect().size
	for i in 30:
		await get_tree().process_frame
	await _shot("variants_%s.png" % _suffix)
	gallery.queue_free()
	gallery_layer.queue_free()
	game_root.queue_free()
	await get_tree().process_frame

	print("=== 按钮变体验收截图完成（suffix=%s） ===" % _suffix)
	get_tree().quit(0)


func _shot(file_name: String) -> void:
	# 等一帧真渲染完成再取视口纹理
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + file_name
	var err := img.save_png(path)
	print("[SHOT] ", path, " ", img.get_size(), " err=", err)
