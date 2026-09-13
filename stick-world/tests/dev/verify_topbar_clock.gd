extends Node
## 顶栏「组织」按钮 vs 右上时钟（ClockWidget）防撞验收。
##
## 背景：顶栏那排按钮是场景里 MarginContainer 排的（右内边距 12px），而右上时钟由
## zone 引擎钉在 `top_right` 保留区（距右缘 184px）——两者重叠时，时钟作为后画的
## Control 既盖住按钮又吃鼠标事件，表现就是「按钮看得见点不到」。
##
## 本探针做三件事（都在真实游戏进程里，真渲染真输入）：
##   1. 几何：组织按钮矩形与时钟矩形**不相交**，且按钮整体在视口内；
##   2. 可点：把鼠标移到按钮中心，读 `Viewport.gui_get_hovered_control()` ——
##      命中的必须是按钮本身或其子级（引擎级判据，不是"看起来没被盖住"）；
##   3. 真点击：在该位置派发 motion + 左键按下/抬起，断言按钮的 `pressed` 真的触发。
## 另留 1920×1080 与 1280×720 两档截图（`res://../temp/shots_topbar/`，gitignored）。
##
## 运行（**不要 --headless**：headless 没有真实渲染与鼠标）：
##   godot --path stick-world res://tests/dev/verify_topbar_clock.tscn
## 退出码：0 全部通过 / 1 有失败。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const OUT_DIR := "res://../temp/shots_topbar"
const BOOT_TIMEOUT_FRAMES := 900

var _fails: Array[String] = []
var _pass_count: int = 0
var _game_root: Node = null
var _org: Button = null
var _clock: Control = null


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame

	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	var map: Node2D = null
	for i in BOOT_TIMEOUT_FRAMES:
		map = _game_root.get_current_map()
		if map != null:
			break
		await get_tree().process_frame
	if map == null:
		_fail("世界未就绪（%d 帧内地图未加载）" % BOOT_TIMEOUT_FRAMES)
		return _finish()
	_ok("世界就绪（map=%s）" % map.name)

	# 等 HUD 装配稳定（容器首轮布局完成）
	var hud: Control = null
	for i in BOOT_TIMEOUT_FRAMES:
		hud = _resolve_hud()
		_org = _resolve_org(hud)
		_clock = _resolve_clock(hud)
		if _org != null and _clock != null and _org.size.x > 0.0 and _clock.size.x > 0.0:
			break
		await get_tree().process_frame
	for i in 30:
		await get_tree().process_frame
	if _org == null or _clock == null:
		_fail("顶栏未装配（org=%s clock=%s）" % [_org, _clock])
		return _finish()

	_check_geometry()
	await _shot("topbar_clock_1920.png")
	await _check_clickable()

	# 720p 复验：zone 偏移是固定像素、按钮行是容器排的，两者都应随右缘重排
	get_window().size = Vector2i(1280, 720)
	for i in 20:
		await get_tree().process_frame
	_check_geometry()
	await _check_clickable()
	await _shot("topbar_clock_720.png")

	_finish()


# ─────────────────────────────── 断言 ────────────────────────────────

## 几何：不重叠 + 在视口内 + 按钮右缘确实让开了时钟左缘
func _check_geometry() -> void:
	var vp := get_viewport().get_visible_rect().size
	var org := _org.get_global_rect()
	var clk := _clock.get_global_rect()
	print("[INFO] 视口 %s | 组织按钮 %s | 时钟 %s" % [vp, org, clk])
	_check(not org.intersects(clk), "组织按钮与时钟不相交（org=%s clk=%s）" % [org, clk])
	_check(org.end.x <= clk.position.x + 0.5,
			"按钮右缘(%0.1f) 不越过时钟左缘(%0.1f)" % [org.end.x, clk.position.x])
	_check(org.position.x >= 0.0 and org.end.x <= vp.x,
			"按钮完整落在视口内（x %0.1f..%0.1f / 视口宽 %0.1f）" % [org.position.x, org.end.x, vp.x])
	_check(org.size.x > 8.0 and org.size.y > 8.0,
			"按钮有可点面积（%s）" % org.size)


## 可点：引擎判定"鼠标下是谁" + 真派发一次点击
func _check_clickable() -> void:
	var center: Vector2 = _org.get_global_rect().get_center()
	var win_pos := _to_window_pos(center)
	var motion := InputEventMouseMotion.new()
	motion.position = win_pos
	motion.global_position = win_pos
	Input.warp_mouse(win_pos)
	Input.parse_input_event(motion)
	for i in 3:
		await get_tree().process_frame
	var hovered: Control = get_viewport().gui_get_hovered_control()
	var hit_org: bool = hovered == _org or (_org != null and hovered != null
			and _org.is_ancestor_of(hovered))
	_check(hit_org, "鼠标在按钮中心时命中的是按钮（实际命中：%s）"
			% (hovered.name if hovered != null else "<无>"))

	# 真点击：motion → 按下 → 抬起，断言 pressed 触发
	var fired: Array[bool] = [false]
	var cb := func() -> void: fired[0] = true
	_org.pressed.connect(cb)
	_send_button(win_pos, true)
	for i in 2:
		await get_tree().process_frame
	_send_button(win_pos, false)
	for i in 3:
		await get_tree().process_frame
	_org.pressed.disconnect(cb)
	_check(fired[0], "在该位置派发左键点击能触发按钮 pressed")


## 画布坐标 → 窗口像素坐标。`stretch_mode=canvas_items` 下画布恒定 1920×1080，
## 窗口小于画布时鼠标要按窗口坐标给（引擎再把事件换算回画布），否则光标落到屏幕外
## （踩过：720p 下 hover 命中 <无>，不是防撞失效，是本探针少了一次换算）。
func _to_window_pos(canvas_pos: Vector2) -> Vector2:
	var canvas := get_viewport().get_visible_rect().size
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return canvas_pos
	return canvas_pos * (Vector2(get_window().size) / canvas)


func _send_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)


# ─────────────────────────────── 定位与截图 ────────────────────────────────

func _resolve_hud() -> Control:
	if _game_root == null or _game_root.get("ui_root") == null:
		return null
	var ui_root: Node = _game_root.ui_root
	if ui_root.has_method("get_slot"):
		var slot: Control = ui_root.get_slot("GlobalHUD")
		if slot != null:
			return slot
	return ui_root.get_node_or_null("GlobalHUD") as Control


func _resolve_org(hud: Control) -> Button:
	if hud == null:
		return null
	return hud.get_node_or_null("MarginContainer/HBoxContainer/OrgButton") as Button


func _resolve_clock(hud: Control) -> Control:
	if hud == null:
		return null
	return hud.get_node_or_null("ClockWidget") as Control


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
		_ok(label)
	else:
		_fail(label)


func _ok(label: String) -> void:
	_pass_count += 1
	print("[OK] ", label)


func _fail(label: String) -> void:
	_fails.append(label)
	print("[FAIL] ", label)


func _finish() -> void:
	print("=== 顶栏时钟防撞验收：%d 项断言，%d 失败 ===" % [_pass_count + _fails.size(), _fails.size()])
	if _fails.is_empty():
		print("=== 顶栏时钟防撞验收：全部通过 ===")
		get_tree().quit(0)
	else:
		for f in _fails:
			print("[FAIL] ", f)
		get_tree().quit(1)
