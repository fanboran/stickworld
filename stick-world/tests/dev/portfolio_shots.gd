extends Node
## 作品集/README 实机截图驱动（dev 层）——真渲染跑游戏，按剧本截全套实机画面。
## 产物喂 README「游戏实机画面」（docs/演示/，入库时改中文名）。
## 用法（必须带显示，不能 --headless）：
##   godot --path stick-world --resolution 1920x1080 res://tests/dev/portfolio_shots.tscn
## 产物写到 user://shots/portfolio_*.png；结束后自动 quit。

const SHOT_DIR := "user://shots"
const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"
const LOADING_SCENE := "res://modules/ui_global/scenes/menus/loading_screen.tscn"
## 小地图区裁剪外扩边距（px）
const CROP_PAD := 12.0


func run() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	await _frames(5)
	# ── 主菜单 / 读取存档面板 ──
	var menu: Control = (load(MAIN_MENU_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	await _frames(10)
	await _shot("portfolio_menu")
	if menu.has_method("_open_load_panel"):
		menu._open_load_panel()
		await _frames(8)
		await _shot("portfolio_load_panel")
		menu._load_panel.close()
		await _frames(2)
	menu.queue_free()
	await _frames(3)
	# ── 载入屏（双进度条）：早/中各一张，选进度可读的用 ──
	SaveManager.boot_load_slot = 0
	get_tree().change_scene_to_file(LOADING_SCENE)
	await _frames(40)
	await _shot("portfolio_loading_early")
	await _seconds(7.0)
	await _shot("portfolio_loading_mid")
	# ── 等世界就绪（HD-2D 主街）──
	await _wait_world()
	await _seconds(4.0)
	var gr := get_tree().current_scene
	# ── 白天主街（README 第二位图机位，村民走动几秒后入镜）──
	await _shot("portfolio_street_day")
	# 拉远到 0.75 倍（视宽 ~80 格，贴近原型宽景取景）再拍一张
	var rig: Camera2D = gr.get("camera_rig") if gr.get("camera_rig") != null else null
	if rig != null and rig.has_method("set_user_zoom"):
		rig.call("set_user_zoom", 0.75)
		await _seconds(0.6)
		await _shot("portfolio_street_wide")
	# ── 游戏内设置面板 ──
	if gr.has_method("toggle_settings_menu"):
		gr.toggle_settings_menu()
		await _frames(8)
		await _shot("portfolio_settings")
		gr.toggle_settings_menu()
		await _frames(3)
	# ── 暂停菜单（ESC 语义）──
	if gr.has_method("_handle_escape"):
		gr._handle_escape()
		await _frames(8)
		await _shot("portfolio_pause")
		gr._handle_escape()
		await _frames(3)
	# ── 建造菜单（白天主街）──
	var bm: Control = gr.get_build_menu() if gr.has_method("get_build_menu") else null
	if bm != null:
		bm.call("_on_toggle_pressed")
		await _frames(8)
		await _shot("portfolio_build")
		bm.call("_on_toggle_pressed")
		await _frames(3)
	# ── 深夜 + 编制管理（编队与夜空）──
	var env: Node = gr.get_node_or_null("EnvironmentSystem")
	if env != null and env.has_method("set_time_of_day"):
		env.set_time_of_day(23.0)
		env.set_seconds_per_day(1000000.0)  # 冻结时间流速，等星野 lerp 到满强度
		await _seconds(2.5)
	if gr.has_method("toggle_org_panel"):
		gr.toggle_org_panel()
		await _frames(8)
		# 从预设创建军事编制，把组织树填上再截（默认选中「军事编制」）
		var org: Control = gr.get_org_panel() if gr.has_method("get_org_panel") else null
		if org != null and org.has_method("_on_preset_create_pressed"):
			org.call("_on_preset_create_pressed")
			await _frames(10)
		await _shot("portfolio_formation_night")
		gr.toggle_org_panel()
		await _frames(3)
	# ── 小地图区裁剪（顶部中央堆叠 Minimap + L1Thumbnail + ZoomBar）──
	await _shot_minimap_crop(gr, "portfolio_minimap")
	print("=== PORTFOLIO SHOTS DONE ===")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout


## 等世界加载完成（地图 + 玩家实体就绪），最多 60s 超时（分帧装配实测 ~22s）
func _wait_world() -> void:
	var t := 0.0
	while t < 60.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var gr := get_tree().current_scene
		if gr != null and gr.has_method("get_current_map") and gr.has_method("get_player_entity"):
			if gr.get_current_map() != null and gr.get_player_entity() != null:
				await _frames(10)
				return
	print("[PortfolioShots] WARN: 等世界超时（60s）")


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[PortfolioShots] %s.png %s" % [shot_name, img.get_size()])


## 联合矩形裁剪：Minimap + L1Thumbnail + ZoomBar 外扩 CROP_PAD
func _shot_minimap_crop(gr: Node, shot_name: String) -> void:
	var ui_root: Node = gr.get("ui_root") if gr.get("ui_root") != null else null
	if ui_root == null:
		print("[PortfolioShots] SKIP 裁剪：无 ui_root")
		return
	var union := Rect2()
	var found := false
	for node_name in ["Minimap", "L1Thumbnail", "ZoomBar"]:
		var c: Control = ui_root.get_node_or_null(NodePath("HudOverlay/" + node_name))
		if c == null:
			continue
		var r := c.get_global_rect()
		union = r if not found else union.merge(r)
		found = true
	if not found:
		print("[PortfolioShots] SKIP 裁剪：未找到小地图区节点")
		return
	union = union.grow(CROP_PAD)
	await RenderingServer.frame_post_draw
	var full := get_viewport().get_texture().get_image()
	var clip := Rect2i(
		Vector2i(maxi(int(union.position.x), 0), maxi(int(union.position.y), 0)),
		Vector2i(mini(int(union.size.x), full.get_width() - int(union.position.x)),
			mini(int(union.size.y), full.get_height() - int(union.position.y))))
	var img := full.get_region(clip)
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[PortfolioShots] %s.png %s（裁剪 %s）" % [shot_name, img.get_size(), clip])
