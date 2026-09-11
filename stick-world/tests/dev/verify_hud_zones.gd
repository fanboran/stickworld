extends Node
## HUD zone 落位验收（批次 B 验收辅助）：
##   1. 真实游戏窗口化启动（game_root.tscn → SystemSetup 全量装配）
##   2. 1920×1080 与 1280×720 两档分辨率 HUD 截图（真渲染，zone debug 画框可见）
##   3. 临时挂两张验收卡进 top_left_stack，截图证明堆叠游标逐件下移无重叠
##   4. 断言六区落位符合 hud_zone_layout.gd 保留区合同（锚定+偏移，随分辨率自适应）
## 运行（不要 --headless，headless 是哑渲染截不出图）：
##   godot --path stick-world res://tests/dev/verify_hud_zones.tscn
## 退出码：0 全部通过，1 有失败

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const _SketchPanelScript := preload("res://modules/ui_global/scripts/sketch/sketch_panel.gd")

## 截图输出目录（worktree 下 temp/shots_b/，gitignored）
const OUT_DIR := "res://../temp/shots_b"
const BOOT_TIMEOUT_FRAMES := 900

var _fails: Array[String] = []
var _game_root: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame

	# ── 启动真实游戏，等世界就绪 ──
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	var map: Node2D = null
	for i in BOOT_TIMEOUT_FRAMES:
		map = _game_root.get_current_map()
		if map != null:
			break
		await get_tree().process_frame
	if map == null:
		_fail("世界未就绪（BOOT_TIMEOUT_FRAMES 内地图未加载）")
		return _finish()
	_ok("世界就绪（map=%s）" % map.name)

	# 等 HUD 装配稳定（demo_quest deferred、资源注入、容器首轮布局）
	var quest: Control = null
	for i in BOOT_TIMEOUT_FRAMES:
		quest = _game_root.ui_root.get_node_or_null("HudOverlay/QuestPanel")
		if quest != null and quest.size.y > 0.0:
			break
		await get_tree().process_frame
	for i in 30:
		await get_tree().process_frame
	if quest == null:
		_fail("QuestPanel 未装配")
		return _finish()

	# ── 1920×1080 截图 ──
	_push_notifications()
	await _shot("hud_zones_1920.png")
	_check_layout_1920()

	# ── 1280×720 截图（stretch canvas_items+expand：16:9 窗口下画布坐标仍为
	# 1920×1080，HUD 整体缩放渲染——PNG 真实像素 1280×720）──
	get_window().size = Vector2i(1280, 720)
	await get_tree().process_frame
	for i in 15:
		await get_tree().process_frame
	_push_notifications()
	await _shot("hud_zones_720.png")
	_check_layout_720()

	# ── 16:10（1280×800）：宽高比变化时画布重排，证明 zone 锚定随分辨率自适应 ──
	get_window().size = Vector2i(1280, 800)
	await get_tree().process_frame
	for i in 15:
		await get_tree().process_frame
	_push_notifications()
	await _shot("hud_zones_1280x800.png")
	_check_layout_1610()

	# ── 堆叠游标验证：临时挂两张验收卡（1920）──
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	for i in 15:
		await get_tree().process_frame
	var card_a := _make_card("验收卡甲")
	var card_b := _make_card("验收卡乙")
	_push_notifications()
	await _shot("hud_zones_stack.png")
	_check_stack(card_a, card_b)

	_finish()


# ─────────────────────────────── 断言 ────────────────────────────────

func _check_layout_1920() -> void:
	var vp := get_viewport().get_visible_rect().size
	var mm: Control = _game_root.ui_root.get_node_or_null("HudOverlay/Minimap")
	if mm == null:
		_fail("Minimap 未装配")
	else:
		var r := mm.get_global_rect()
		_check(absf(r.get_center().x - vp.x * 0.5) < 2.0, "Minimap 水平居中（center=%.1f）" % r.get_center().x)
		_check(r.size == Vector2(360, 120), "Minimap 体量 360x120（实际 %s）" % r.size)
		_check(r.position.y >= 7.0 and r.end.y <= 133.0, "Minimap 落在 top_center 保留区 y 8..132（%s）" % r)
	var zb: Control = _game_root.ui_root.get_node_or_null("HudOverlay/ZoomBar")
	if zb == null:
		_fail("ZoomBar 未装配")
	else:
		var r := zb.get_global_rect()
		_check(absf(r.end.x - vp.x + 8.0) < 2.0, "ZoomBar 贴右缘 8px（right=%.1f）" % r.end.x)
		_check(r.end.y <= vp.y - 96.0 + 1.0, "ZoomBar 底边让开 ModePanel（bottom=%.1f ≤ %.1f）" % [r.end.y, vp.y - 96.0])
	_check_stack_base()
	_check_feed(vp)
	var debug_layer: Node = _game_root.ui_root.get_node_or_null("HudZoneDebug")
	_check(debug_layer != null, "zone debug 画框层存在（截图可见半透明框）")


func _check_layout_720() -> void:
	_check(get_window().size == Vector2i(1280, 720), "窗口已切 720p（%s，PNG 像素 1280×720）" % get_window().size)
	var mm: Control = _game_root.ui_root.get_node_or_null("HudOverlay/Minimap")
	if mm != null:
		var r := mm.get_global_rect()
		_check(absf(r.get_center().x - get_viewport().get_visible_rect().size.x * 0.5) < 2.0, "720p Minimap 仍水平居中（center=%.1f）" % r.get_center().x)
	var zb: Control = _game_root.ui_root.get_node_or_null("HudOverlay/ZoomBar")
	if zb != null:
		var r := zb.get_global_rect()
		_check(absf(r.end.x - get_viewport().get_visible_rect().size.x + 8.0) < 2.0, "720p ZoomBar 仍贴右缘（right=%.1f）" % r.end.x)
	_check_stack_base()
	_check_feed(get_viewport().get_visible_rect().size)


## 16:10 画布重排：锚定边跟随（右缘/底缘偏移不变，居中区仍居中）
func _check_layout_1610() -> void:
	_check(get_window().size == Vector2i(1280, 800), "窗口已切 16:10（%s）" % get_window().size)
	var vp := get_viewport().get_visible_rect().size
	print("[INFO] 16:10 画布坐标 = %s（重排自 1920×1080）" % vp)
	var mm: Control = _game_root.ui_root.get_node_or_null("HudOverlay/Minimap")
	if mm != null:
		var r := mm.get_global_rect()
		_check(absf(r.get_center().x - vp.x * 0.5) < 2.0, "16:10 Minimap 随画布重排仍居中（center=%.1f / 画布宽 %.1f）" % [r.get_center().x, vp.x])
	var zb: Control = _game_root.ui_root.get_node_or_null("HudOverlay/ZoomBar")
	if zb != null:
		var r := zb.get_global_rect()
		_check(absf(r.end.x - vp.x + 8.0) < 2.0, "16:10 ZoomBar 贴新右缘（right=%.1f / %.1f）" % [r.end.x, vp.x])
	_check_feed(vp)


## top_left_stack 基础序：资源条 y=64 起，QuestPanel 紧随其下不重叠
func _check_stack_base() -> void:
	var hud: Control = _game_root.ui_root.get_slot("GlobalHUD")
	var host: Control = hud.get_node_or_null("ResourceBarHost")
	if host == null:
		_fail("ResourceBarHost 未装配")
		return
	var hr := host.get_global_rect()
	_check(absf(hr.position.y - 64.0) < 1.0, "资源条堆叠起点 y=64（实际 %.1f）" % hr.position.y)
	print("[INFO] 资源条实测 rect=%s（宽 %.0f）" % [hr, hr.size.x])
	var quest: Control = _game_root.ui_root.get_node_or_null("HudOverlay/QuestPanel")
	if quest != null:
		var qr := quest.get_global_rect()
		_check(absf(qr.position.y - hr.end.y - 8.0) < 2.0,
				"任务卡排在资源条下方 gap=8（task y=%.1f，资源条底=%.1f）" % [qr.position.y, hr.end.y])
		_check(not qr.intersects(hr), "任务卡与资源条无重叠")


func _check_feed(vp: Vector2) -> void:
	var feed: Control = _game_root.ui_root.get_notification_feed()
	if feed == null:
		_fail("NotificationFeed 未装配")
		return
	var r := feed.get_global_rect()
	_check(absf(r.position.x - 12.0) < 1.0, "通知流贴左 12px（left=%.1f）" % r.position.x)
	_check(absf(r.end.y - (vp.y - 96.0)) < 1.0, "通知流底边 -96（bottom=%.1f）" % r.end.y)


## 两张验收卡逐件下移、互不重叠、均在资源条+任务卡之下
func _check_stack(card_a: Control, card_b: Control) -> void:
	var ra := card_a.get_global_rect()
	var rb := card_b.get_global_rect()
	_check(absf(ra.position.y - rb.position.y) > 10.0, "验收卡逐件下移（甲 y=%.1f 乙 y=%.1f）" % [ra.position.y, rb.position.y])
	_check(not ra.intersects(rb), "验收卡甲乙无重叠（甲 %s / 乙 %s）" % [ra, rb])
	var quest: Control = _game_root.ui_root.get_node_or_null("HudOverlay/QuestPanel")
	if quest != null:
		_check(ra.position.y > quest.get_global_rect().end.y, "验收卡排在任务卡之下")


# ─────────────────────────────── 辅助 ────────────────────────────────

## 临时验收卡（模拟未来多任务线任务卡：声明体量，落位交给 zone）
func _make_card(title: String) -> Control:
	var card: Control = _SketchPanelScript.new()
	card.name = title
	card.tone = SketchPanel.Tone.DARK
	card.custom_minimum_size = Vector2(282, 56)
	var lbl := Label.new()
	lbl.text = "%s（堆叠游标验收）" % title
	card.add_child(lbl)
	_game_root.ui_root.add_to_slot("HudOverlay", card)
	_game_root.ui_root.place_in_zone(&"top_left_stack", card)
	return card


func _push_notifications() -> void:
	EventBus.ui_notification.emit("通知流", "zone 验收截图填充", "info")
	EventBus.ui_notification.emit("通知流", "底部对齐演示", "warn")


func _shot(file_name: String) -> void:
	# 通知停留期内再补一条防淡出，等渲染稳定后取真渲染帧
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


var _pass_count: int = 0


func _finish() -> void:
	print("=== HUD zone 验收：%d 项断言，%d 失败 ===" % [_pass_count + _fails.size(), _fails.size()])
	if _fails.is_empty():
		print("=== HUD zone 验收：全部通过 ===")
		get_tree().quit(0)
	else:
		for f in _fails:
			print("[FAIL] ", f)
		get_tree().quit(1)
