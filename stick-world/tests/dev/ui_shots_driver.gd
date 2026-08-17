extends Node
## UI 截图自检 Driver —— 挂在 SceneTree.root，跨场景存活，按剧本截图。
##
## 剧本：
##   01 主菜单 → 02 主菜单·设置 → 03 主菜单·读档面板 → 04 主菜单·退出确认框
##   05 继续游戏·坏档兜底（slot0 无地图信息 → 应回退新游戏且世界可见）
##   06 游戏内设置面板（含「保存并回到主菜单」）
##   07 在世界中 save_game(0) 写入好档 → 再 boot_load → 世界应恢复
## 产物写到 user://shots/；结束后自动 quit。

const SHOT_DIR := "user://shots"
const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"
const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"


func run() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	await _frames(5)
	# ── 主菜单 ──
	var menu: Control = (load(MAIN_MENU_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	await _frames(5)
	await _shot("01_menu")
	# ── 主菜单·设置 ──
	menu._open_settings_panel()
	await _frames(5)
	await _shot("02_menu_settings")
	menu._settings_panel.close()
	await _frames(2)
	# ── 主菜单·读档面板 ──
	menu._open_load_panel()
	await _frames(5)
	await _shot("03_menu_load")
	menu._load_panel.close()
	await _frames(2)
	# ── 主菜单·退出确认框 ──
	menu._on_menu_pressed({"id": "quit"})
	await _frames(5)
	await _shot("04_menu_confirm")
	menu.queue_free()
	await _frames(3)
	# ── 继续游戏·坏档兜底 ──
	if SaveManager and SaveManager.slot_exists(0):
		SaveManager.boot_load_slot = 0
		get_tree().change_scene_to_file(GAME_ROOT_SCENE)
		await _wait_world()
		await _shot("05_continue_fallback")
	# ── 游戏内设置面板 ──
	var gr := get_tree().current_scene
	if gr != null and gr.has_method("toggle_settings_menu"):
		gr.toggle_settings_menu()
		await _frames(5)
		await _shot("06_game_settings")
		gr.toggle_settings_menu()
		await _frames(2)
	# ── 写入好档 → 再启动读档验证 roundtrip ──
	if SaveManager and SaveManager.has_method("save_game"):
		SaveManager.save_game(0)
		SaveManager.boot_load_slot = 0
		get_tree().change_scene_to_file(GAME_ROOT_SCENE)
		await _wait_world()
		await _shot("07_continue_restored")
	# ── 暂停菜单（ESC 语义 + 模态遮罩应盖住右下建造按钮）──
	var gr2 := get_tree().current_scene
	if gr2 != null and gr2.has_method("_handle_escape"):
		gr2._handle_escape()
		await _frames(5)
		await _shot("11_pause_menu")
		gr2._handle_escape()
		await _frames(2)
	# ── 占位界面预览 ──
	var preview: Control = (load(
			"res://modules/ui_placeholder/scenes/ui_placeholder_preview.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(preview)
	await _frames(5)
	await _shot("08_placeholder_preview")
	UIPlaceholderPanel.open_panel(preview, "tech_tree")
	await _frames(5)
	await _shot("09_placeholder_techtree")
	UIPlaceholderPanel.open_panel(preview, "empire_overview")
	await _frames(5)
	await _shot("10_placeholder_empire")
	preview.queue_free()
	await _frames(3)
	print("=== UI SHOTS DONE ===")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## 等世界加载完成（地图 + 玩家实体就绪），最多 10s 超时
func _wait_world() -> void:
	var t := 0.0
	while t < 10.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var gr := get_tree().current_scene
		if gr != null and gr.has_method("get_current_map") and gr.has_method("get_player_entity"):
			if gr.get_current_map() != null and gr.get_player_entity() != null:
				await _frames(10)
				return
	print("[UIShots] WARN: 等世界超时（10s）")


func _shot(shot_name: String) -> void:
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[UIShots] %s.png" % shot_name)