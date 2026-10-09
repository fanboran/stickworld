extends Node
## 小地图·战场观感与阵营点验收（小地图优化与细化：战场可用 + 双方兵力一眼可读）。
##
## 为什么单独一个工位：自动化集成测试只能断言"装配/跳转没坏"，而本项要验的
## 是**看到什么**——战场图下小地图是否按宽地图自适应变宽、双方阵营点是否红蓝
## 可分、点位是否落在实体真实纵深上。故本场景真启动 GameRoot → 切战场图 →
## 自刷两阵营单位 → 出图 + 断言点色构成。
##
## 运行（不要 --headless，headless 是无哑渲染截不出图）：
##   godot --path stick-world res://tests/dev/verify_minimap_battle.tscn
## 截图输出：res://../temp/shots_b/minimap_battle.png（gitignored）
## 退出码：0 全通过，1 有失败

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene := preload("res://modules/units/scenes/stickman_entity.tscn")
## 战场图（256 格 × 24px ≈ 6144px 宽；比例尺 = 参考地图宽 8192 填满顶栏空档，
## 故战场比城镇 7080 略窄，超过 8192 的地图才会被空档钳住）
const TARGET_MAP := "battlefield"
const OUT_DIR := "res://../temp/shots_b"
## 双方各单位数（够看出两片色团即可，不进战斗）
const PER_SIDE := 6

var _fails: Array[String] = []
var _pass_count: int = 0
var _game_root: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	# 等世界就绪（boot 阶段异步推进，死等帧数会撞在地图注册前）
	var map: Node2D = null
	for i in 1800:
		if _game_root.get("_boot_world_phase") == false and _game_root.get_current_map() != null:
			break
		await get_tree().process_frame
	var loader: Node = _game_root.get("scene_loader")
	if loader == null or not loader.has_method("load_map"):
		_fail("scene_loader 不可用")
		return _finish()
	loader.load_map(TARGET_MAP)
	for i in 600:
		await get_tree().process_frame
		var m: Node2D = _game_root.get_current_map()
		if m != null and TARGET_MAP in str(m.scene_file_path):
			map = m
			break
	if map == null:
		_fail("战场图未加载")
		return _finish()
	_ok("战场图就绪：%s（左 %.0f / 右 %.0f，宽 %.0f）"
			% [map.name, map.map_left, map.map_right, map.map_right - map.map_left])

	# 清掉地图自带单位，只留本工位自刷的两阵营（画面纯净、点色构成可断言）
	for e in map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame

	# 自刷两阵营：蓝方靠左、红方靠右，纵深错开（顺带验证"点位反映前后站位"）
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	var gy: float = map.ground_y
	var gb: float = map.ground_bottom
	var band: float = gb - gy
	for i in PER_SIDE:
		_spawn(map, 1, Vector2(mid_x - 1400.0 + float(i) * 60.0,
				gy + band * (0.30 + 0.05 * float(i))))
		_spawn(map, 2, Vector2(mid_x + 1200.0 + float(i) * 60.0,
				gy + band * (0.70 - 0.05 * float(i))))
	for i in 20:
		await get_tree().process_frame

	var mm: Control = _game_root.ui_root.get_node_or_null("HudOverlay/Minimap")
	if mm == null:
		_fail("Minimap 未装配")
		return _finish()
	var vp_x: float = get_viewport().get_visible_rect().size.x
	var width: float = mm.get_map_width_px()
	var cap: float = HudZoneLayout.top_center_map_max_width(vp_x)
	var map_w: float = map.map_right - map.map_left
	# 等比例尺合同：地面带像素高（120×ground_ratio）代表世界地面深 → 世界/小地图比例尺，
	# 横向同比例尺取宽（战场 6144 与城镇 7080 因此各得各的宽度，且都不变形）
	var map_info: Array = mm.get_map_info()
	var scale: float = (map.get_ground_bottom() - float(map_info[2])) / (120.0 * float(map_info[3]))
	var expect: float = clampf(map_w / scale, Minimap.BASE_WIDTH, cap)
	_check(absf(width - expect) < 1.0,
			"小地图宽度 = 地图宽 ÷ 等比例尺 %.2f（%.1f，期望 %.1f）" % [scale, width, expect])
	_check(width > Minimap.BASE_WIDTH,
			"战场图下小地图宽于可读下限（%.1f > %.0f）" % [width, Minimap.BASE_WIDTH])
	_check(width <= cap + 1.0, "小地图宽度不超可用上限 %.1f（实际 %.1f）" % [cap, width])
	var r := mm.get_global_rect()
	var zone_cx: float = HudZoneLayout.zone_rect(&"top_center",
			get_viewport().get_visible_rect().size).get_center().x
	_check(absf(r.get_center().x - zone_cx) < 2.0,
			"变宽后在 top_center 区内居中（center=%.1f / 区中 %.1f）" % [r.get_center().x, zone_cx])
	_check(r.position.x >= HudZoneLayout.TOP_CENTER_FREE_LEFT_PX - 0.5
			and r.end.x <= HudZoneLayout.TOP_CENTER_FREE_RIGHT_PX + 0.5,
			"变宽后不压顶栏按钮群（%.1f..%.1f 在 %.0f..%.0f 内）"
			% [r.position.x, r.end.x,
			HudZoneLayout.TOP_CENTER_FREE_LEFT_PX, HudZoneLayout.TOP_CENTER_FREE_RIGHT_PX])

	# 阵营点构成：走**真实渲染路径**取阵营口径（无附身单位 = 观战，my_faction 为空，
	# 此时必须靠固定阵营色表分敌我——曾经两边都判"非我方"而全画成红）
	var points: Array = MinimapPainter.collect_points(map)
	var my_faction: Variant = MinimapPainter.player_faction_of(points)
	_check(my_faction == null, "本工位无附身单位（观战口径，阵营色走固定表）")
	var ally_color: Color = MinimapPainter.point_color(1, my_faction)
	var enemy_color: Color = MinimapPainter.point_color(2, my_faction)
	var ally := 0
	var enemy := 0
	for p: Dictionary in points:
		var c: Color = MinimapPainter.point_color(int(p["faction"]), my_faction)
		if c.is_equal_approx(ally_color):
			ally += 1
		elif c.is_equal_approx(enemy_color):
			enemy += 1
	_check(points.size() >= PER_SIDE * 2, "战场单位点全部上屏（%d 个）" % points.size())
	_check(ally >= PER_SIDE, "本方单位点 %d 个（≥%d）" % [ally, PER_SIDE])
	_check(enemy >= PER_SIDE, "敌方单位点 %d 个（≥%d）" % [enemy, PER_SIDE])
	_check(not ally_color.is_equal_approx(enemy_color),
			"敌我点色可分（蓝 %.2f,%.2f,%.2f / 红 %.2f,%.2f,%.2f）"
			% [ally_color.r, ally_color.g, ally_color.b,
			enemy_color.r, enemy_color.g, enemy_color.b])
	# 纵深落点：左方点集中在浅纵深（y 小 = 画得靠上）、右方点集中在深纵深
	var left_y: float = 0.0
	var right_y: float = 0.0
	for p: Dictionary in points:
		var py: float = MinimapPainter.world_to_y(float(p["y"]), r, MinimapPainter.build_snapshot(map, mm.get_map_info()))
		if int(p["faction"]) == 1:
			left_y += py
		else:
			right_y += py
	_check(left_y / maxf(float(ally), 1.0) < right_y / maxf(float(enemy), 1.0),
			"点位反映实际纵深（本方平均 y %.1f < 敌方 %.1f，靠后=靠上）"
			% [left_y / maxf(float(ally), 1.0), right_y / maxf(float(enemy), 1.0)])

	await _shot_minimap_crop("minimap_battle")
	_finish()


# ─────────────────────────────── 辅助 ────────────────────────────────

func _spawn(map: Node2D, faction: int, pos: Vector2) -> void:
	var e: Node2D = map.spawn_entity(_StickmanScene, pos)
	if e == null:
		return
	if e.has_method("set_faction"):
		e.set_faction(faction)
	if e.has_method("set_last_valid_position"):
		e.set_last_valid_position(pos)


## 裁小地图区域出图（含 L1 缩略窗与缩放条——顶部小地图区整块的验收视角）
func _shot_minimap_crop(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var union := Rect2()
	for path in ["HudOverlay/Minimap", "HudOverlay/L1Thumbnail", "HudOverlay/ZoomBar"]:
		var c: Control = _game_root.ui_root.get_node_or_null(path)
		if c == null or not c.visible:
			continue
		var cr := c.get_global_rect()
		union = cr if union.size == Vector2.ZERO else union.merge(cr)
	if union.size == Vector2.ZERO:
		union = Rect2(0, 0, 900, 200)
	var pad := 12.0
	var rect := Rect2(union.position - Vector2(pad, pad), union.size + Vector2(pad * 2.0, pad * 2.0))
	var clipped := rect.intersection(Rect2(Vector2.ZERO, Vector2(img.get_size())))
	var crop := img.get_region(Rect2i(clipped.position, clipped.size))
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + tag + ".png"
	var err := crop.save_png(path)
	if err != OK:
		_fail("截图保存失败 %s（err=%d）" % [path, err])
	else:
		print("[SHOT] ", path, " ", crop.get_size())


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
	print("=== 战场小地图验收：%d 项断言，%d 失败 ===" % [_pass_count + _fails.size(), _fails.size()])
	get_tree().quit(1 if not _fails.is_empty() else 0)
