extends Node
## 原声带页验收（含主菜单入口）：
##   1. 主菜单「制作人员」同行有一个正方形入口（同一行、正方形、有音符图形、有提示语）
##   2. 点它进原声带页（真跑 change_scene_to_file，验证真实跳转链路）
##   3. 曲目表来自音乐清单（条数 = 清单 cue 数），点行起播、进度推进、走带键换曲
##   4. 页面 返回 → 回主菜单，且预览模式已退出（音乐系统状态干净）
## 另留三张截图（res://../temp/shots_soundtrack/，gitignored）：主菜单入口 / 原声带页 / 播放中。
##
## 运行（不要 --headless：要真实渲染截图，也要真实音频路径）：
##   godot --path stick-world res://tests/dev/verify_soundtrack_menu.tscn
## 退出码：0 全部通过 / 1 有失败。
##
## ⚠ 跳转验证的写法：change_scene_to_file 会释放 current_scene，本脚本正是
## current_scene——所以先把主菜单挂到 root 并显式设为 current_scene，本脚本
## 自己留在 root 下旁观（跨场景存活），否则协程会被连根释放、进程挂到看门狗超时。

const MainMenuScene := preload("res://modules/ui_global/scenes/menus/main_menu.tscn")
const OUT_DIR := "res://../temp/shots_soundtrack"

var _fails: Array[String] = []
var _pass_count: int = 0
var _menu: Control = null


func _ready() -> void:
	# 看门狗：任何脚本错误中断协程时也能退出（不留挂死进程拖垮 CI）
	get_tree().create_timer(150.0, true, false, true).timeout.connect(
		func() -> void:
			print("=== 原声带页验收：看门狗超时 ===")
			get_tree().quit(1))
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame

	_menu = MainMenuScene.instantiate()
	get_tree().root.add_child(_menu)
	get_tree().current_scene = _menu      # 让主菜单成为"当前场景"（跳转时它会被换掉）
	for i in 60:
		await get_tree().process_frame
		if _menu.get_node_or_null("MenuColumn") != null \
				and _menu.get_node("MenuColumn").get_child_count() > 0:
			break
	await get_tree().process_frame

	# ── 1. 主菜单入口 ──
	var sq := _find_square_button()
	_check(sq != null, "主菜单存在原声带方钮")
	if sq == null:
		return _finish()
	var credits := _find_button_with_text("制作人员")
	_check(credits != null, "主菜单存在「制作人员」入口")
	if credits != null:
		_check(sq.get_parent() == credits.get_parent(),
			"方钮与「制作人员」在同一行（同一父容器）")
		var dy: float = absf(sq.global_position.y - credits.global_position.y)
		_check(dy <= 2.0, "方钮与「制作人员」行对齐（y 差 %.1f px）" % dy)
		_check(sq.get_parent() is HBoxContainer, "同行容器是 HBoxContainer")
	_check(is_equal_approx(sq.size.x, sq.size.y), "方钮是正方形（%.0f×%.0f）"
		% [sq.size.x, sq.size.y])
	_check(is_equal_approx(sq.size.y, credits.size.y),
		"方钮与主按钮等高（%.0f vs %.0f）" % [sq.size.y, credits.size.y])
	_check(sq.get("glyph") == SketchDraw.Glyph.NOTE, "方钮图形是音符")
	_check(String(sq.tooltip_text) != "", "方钮带提示语：%s" % sq.tooltip_text)
	await _shot("01_menu_entry.png")

	# ── 2. 入口跳转（走按钮自身的 pressed 信号 = 真实点击路径）──
	sq.pressed.emit()
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null \
				and get_tree().current_scene.name == "SoundtrackPlayer":
			break
	var page := get_tree().current_scene as SoundtrackPlayer
	_check(page != null and page.name == "SoundtrackPlayer",
		"点方钮进入原声带页（current_scene=%s）"
		% (get_tree().current_scene.name if get_tree().current_scene != null else "null"))
	if page == null or page.name != "SoundtrackPlayer":
		return _finish()
	for i in 5:
		await get_tree().process_frame

	# ── 3. 曲目表与播放 ──
	var tracks: Array = MusicDirector.get_track_list()
	var rows: Array = page.get("_rows")
	_check(rows.size() == tracks.size(),
		"曲目表行数 = 清单 cue 数（%d 行 / %d 首）" % [rows.size(), tracks.size()])
	_check(rows.size() >= 7, "曲目表至少 7 首（含标题曲/昼/夜/小镇/灯下/远望/出征）")
	_check(page.get("_selected") == 0, "默认高亮第 1 首")
	await _shot("02_player_idle.png")

	# 点第 3 行起播 → 预览模式进入、曲目正确
	if rows.size() >= 3:
		(rows[2] as Button).pressed.emit()
		for i in 10:
			await get_tree().process_frame
		_check(MusicDirector.is_previewing(), "点行后进入预览播放")
		_check(MusicDirector.get_preview_track() == str(tracks[2]["id"]),
			"预览曲目 = 点的那首（%s）" % MusicDirector.get_preview_track())
		_check(MusicDirector.get_tier() == 2, "预览固定满层（tier=2）")
		var now_title: Label = page.get("_now_title")
		_check(now_title != null and now_title.text == str(tracks[2]["title"]),
			"正在播放标题同步（%s）" % (now_title.text if now_title != null else "null"))
	# 进度推进：等一会儿看位置是否增长（真在放，不是空转）
	var pos_a: float = MusicDirector.preview_position()
	await get_tree().create_timer(1.6).timeout
	var pos_b: float = MusicDirector.preview_position()
	_check(pos_b > pos_a, "播放位置在推进（%.2fs → %.2fs）" % [pos_a, pos_b])
	var dur: float = MusicDirector.preview_duration()
	_check(dur > 0.0 and pos_b <= dur + 0.5, "位置在 [0, 曲长] 内（%.1f / %.1f）" % [pos_b, dur])
	var progress: SketchHSlider = page.get("_progress")
	_check(progress != null and is_equal_approx(progress.max_value, dur),
		"进度条量程 = 曲长")
	await _shot("03_player_playing.png")

	# 走带：下一曲 / 暂停 / 循环开关
	var play_btn: Button = page.find_child("PlayButton", true, false) as Button
	play_btn.pressed.emit()
	await get_tree().process_frame
	_check(MusicDirector.is_preview_paused(), "播放键暂停")
	play_btn.pressed.emit()
	await get_tree().process_frame
	_check(not MusicDirector.is_preview_paused(), "再按继续")
	var before: String = MusicDirector.get_preview_track()
	page._play_next()
	await get_tree().process_frame
	_check(MusicDirector.get_preview_track() != before, "下一曲切了曲目")
	_check(MusicDirector.get_preview_track() == str(tracks[3]["id"]), "下一曲 = 清单第 4 首")
	page._play_prev()
	await get_tree().process_frame
	_check(MusicDirector.get_preview_track() == before, "上一曲回到原曲")
	var repeat_btn: SketchGlyphButton = page.find_child("RepeatButton", true, false) as SketchGlyphButton
	_check(repeat_btn.active, "循环开关默认打开")
	repeat_btn.pressed.emit()
	await get_tree().process_frame
	_check(not repeat_btn.active, "循环开关可关闭")

	# ── 4. 返回主菜单：预览状态必须清干净 ──
	var back: Button = page.get_node_or_null("BackButton") as Button
	_check(back != null, "原声带页有返回键")
	if back != null:
		back.pressed.emit()
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null and get_tree().current_scene.name == "MainMenu":
			break
	_check(get_tree().current_scene != null and get_tree().current_scene.name == "MainMenu",
		"返回键回到主菜单")
	_check(not MusicDirector.is_previewing(), "离开页面后预览模式已退出（情境解析复活）")
	_check(_find_square_button() != null, "回到的主菜单仍有原声带入口")

	# ── 5. 键盘链路（空格 / ←→ / ESC，走真实输入，不是直接调方法）──
	var sq2 := _find_square_button()
	sq2.pressed.emit()
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null 				and get_tree().current_scene.name == "SoundtrackPlayer":
			break
	var page2 := get_tree().current_scene as SoundtrackPlayer
	_check(page2 != null, "再次进入原声带页")
	if page2 != null:
		_send_key(KEY_SPACE)
		await get_tree().process_frame
		_check(MusicDirector.is_previewing(), "空格起播当前高亮曲")
		_send_key(KEY_SPACE)
		await get_tree().process_frame
		_check(MusicDirector.is_preview_paused(), "空格再按暂停")
		_send_key(KEY_RIGHT)
		await get_tree().process_frame
		_check(MusicDirector.get_preview_track() == str(tracks[1]["id"]),
			"→ 切下一曲（%s）" % MusicDirector.get_preview_track())
		_send_key(KEY_LEFT)
		await get_tree().process_frame
		_check(MusicDirector.get_preview_track() == str(tracks[0]["id"]), "← 回上一曲")
		_check(not MusicDirector.is_preview_paused(), "切曲后应继续出声")
		_send_key(KEY_ESCAPE)
		for i in 30:
			await get_tree().process_frame
			if get_tree().current_scene != null and get_tree().current_scene.name == "MainMenu":
				break
		_check(get_tree().current_scene != null
			and get_tree().current_scene.name == "MainMenu", "ESC 返回主菜单")

	_finish()


## 经真实输入链路发一个按键（同 test_esc_key_input 的做法）
func _send_key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	get_viewport().push_input(ev)


## 主菜单里的原声带方钮（装配时已命名 SoundtrackButton）
func _find_square_button() -> Button:
	var root := get_tree().current_scene
	return root.find_child("SoundtrackButton", true, false) as Button if root != null else null


## 当前场景里找文案为 text 的按钮（代码建的节点 owner 为空，故 owned=false）
func _find_button_with_text(text: String) -> Button:
	var root := get_tree().current_scene
	if root == null:
		return null
	for node in root.find_children("", "Button", true, false):
		if node is Button and (node as Button).text == text:
			return node
	return null


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + file_name
	var err := img.save_png(path)
	if err != OK:
		_fail("截图保存失败 %s（err=%d）" % [path, err])
	else:
		print("[SHOT] ", path, " ", img.get_size())


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass_count += 1
		print("[OK] ", label)
	else:
		_fails.append(label)
		print("[FAIL] ", label)


func _fail(label: String) -> void:
	_fails.append(label)
	print("[FAIL] ", label)


func _finish() -> void:
	print("=== 原声带页验收：%d 项断言，%d 失败 ===" % [_pass_count + _fails.size(), _fails.size()])
	if _fails.is_empty():
		print("=== 原声带页验收：全部通过 ===")
		get_tree().quit(0)
	else:
		for f in _fails:
			print("[FAIL] ", f)
		get_tree().quit(1)
