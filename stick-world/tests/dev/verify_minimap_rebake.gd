extends Node
## 小地图·照片底图运行期重烘验收（低占用实时管线）。
##
## 验什么：底图不再是"进图烘一次冻结"——昼夜换档经 hd2d 脏信号 → 防抖重烘，
## 小地图 15Hz 快照自动换图；重烘全程零可见副作用（渲染层剔除，不动 visible）；
## 烘焙确定性（火柴人移动不改变底图 = 排除生效，含其不投影）。
##
## 运行（不要 --headless，headless 是哑渲染截不出图）：
##   godot --path stick-world res://tests/dev/verify_minimap_rebake.tscn
## 截图输出：res://../temp/shots_b/minimap_rebake_*.png（gitignored）
## 退出码：0 全通过，1 有失败

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene := preload("res://modules/units/scenes/stickman_entity.tscn")
const OUT_DIR := "res://../temp/shots_b"
## 重烘链超时：防抖 0.5s + 烘焙数帧 + 小地图 15Hz 快照间隔，3s 裕量足够
const REBAKE_TIMEOUT_S := 3.0

var _fails: Array[String] = []
var _pass_count: int = 0
var _game_root: Node = null
## 全程盯排除根的 visible（剔除路线下任何一帧被置 false 即失败）
var _watch_roots: Array = []
var _watch_failed := false


func _ready() -> void:
	_run()


func _process(_delta: float) -> void:
	if _watch_failed:
		return
	for r in _watch_roots:
		if r != null and is_instance_valid(r) and not (r as Node3D).visible:
			_watch_failed = true
			_fail("排除根 visible 被烘焙改动（%s）——剔除路线不应触碰可见性" % r.name)
			return


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	var map: Node2D = null
	for i in 1800:
		if _game_root.get("_boot_world_phase") == false and _game_root.get_current_map() != null:
			map = _game_root.get_current_map()
			break
		await get_tree().process_frame
	if map == null:
		_fail("世界未就绪（地图未加载）")
		return _finish()
	_ok("世界就绪（map=%s）" % map.name)
	for i in 30:
		await get_tree().process_frame

	var hd: Node = map.get("_hd")
	if hd == null:
		_fail("地图无 _hd（非 HD-2D 图？本工位须在城镇图跑）")
		return _finish()
	for root_name in ["_char_host", "_prop_root", "_cloud_root"]:
		var r: Node = hd.get(root_name)
		if r is Node3D:
			_watch_roots.append(r)
	_check(_watch_roots.size() == 3, "排除根盯防就位（%d/3）" % _watch_roots.size())

	# ── 1. 装配期首烘已就位 ──
	var base: Dictionary = map.get_minimap_base()
	_check(not base.is_empty() and base.get("texture") != null,
			"装配期首烘底图就位（texture 尺寸 %s）"
			% str((base.get("texture") as ImageTexture).get_size() if base.get("texture") != null else Vector2i.ZERO))
	if base.is_empty():
		return _finish()

	# ── 2. 烘焙确定性 + 火柴人排除：摆 3 个火柴人在临街前排，烘 A →
	#       全体横移 240px → 烘 B；底图应逐像素几乎一致（排除层生效且不投影）──
	var gy: float = map.ground_y
	var band: float = map.get_ground_bottom() - gy
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	var stickmen: Array[Node2D] = []
	for i in 3:
		var e: Node2D = map.spawn_entity(_StickmanScene,
				Vector2(mid_x - 200.0 + float(i) * 200.0, gy + band * 0.6))
		if e != null:
			stickmen.append(e)
	_check(stickmen.size() == 3, "3 个火柴人上街（billboard 渲染源）")
	for i in 20:
		await get_tree().process_frame
	var size := _bake_size(map)
	var t0 := Time.get_ticks_msec()
	var bake_a: Dictionary = await map.bake_minimap_base(size.x, size.y)
	var ms_a: int = Time.get_ticks_msec() - t0
	for e in stickmen:
		e.global_position.x += 240.0
		if e.has_method("set_last_valid_position"):
			e.set_last_valid_position(e.global_position)
	for i in 6:
		await get_tree().process_frame
	var t1 := Time.get_ticks_msec()
	var bake_b: Dictionary = await map.bake_minimap_base(size.x, size.y)
	var ms_b: int = Time.get_ticks_msec() - t1
	_check(not bake_a.is_empty() and not bake_b.is_empty(), "两次直烘均成功（%dms / %dms）" % [ms_a, ms_b])
	print("[INFO] 单次烘焙耗时：%dms / %dms（空闲期烘焙视口 DISABLED，零常驻成本）" % [ms_a, ms_b])
	if not bake_a.is_empty() and not bake_b.is_empty():
		var diff := _image_diff((bake_a["texture"] as ImageTexture).get_image(),
				(bake_b["texture"] as ImageTexture).get_image())
		_check(diff.ratio_bad <= 0.005,
				"火柴人横移 240px 底图逐像素几乎不变（差异像素 %.3f%% ≤ 0.5%%）"
				% [diff.ratio_bad * 100.0])
		_check(diff.mean <= 1.0,
				"底图确定性（平均像素差 %.3f/255 ≤ 1.0）" % diff.mean)

	# ── 3. 昼夜脏链：环境系统时钟拨夜 → game_time → 地图换档 → hd2d 脏信号
	#       → 防抖重烘 → 底图换新（全真链路，不短路任何环节）──
	var env: Node = _game_root.get("environment_system")
	if env == null:
		_fail("environment_system 不可达（真实链路入口缺失）")
		return _finish()
	var day_tex: ImageTexture = (map.get_minimap_base()["texture"] as ImageTexture)
	var day_img: Image = day_tex.get_image()
	_save_png(day_img, "minimap_rebake_base_day.png")
	env.set("time_of_day", 22.0)
	var night_tex: ImageTexture = await _await_rebake(map, day_tex)
	if night_tex == null:
		_fail("拨夜后 %.0fs 内底图未重烘（脏链断：hd2d 信号 → 防抖 → 重烘）" % REBAKE_TIMEOUT_S)
		return _finish()
	_ok("拨夜 → 防抖重烘生效（texture 已换新）")
	var night_img: Image = night_tex.get_image()
	_save_png(night_img, "minimap_rebake_base_night.png")
	var luma_day := _mean_luma(day_img)
	var luma_night := _mean_luma(night_img)
	_check(luma_night < luma_day - 3.0,
			"夜底图整体更暗（昼 %.1f → 夜 %.1f，窗光局部亮但环境光低一档）"
			% [luma_day, luma_night])
	await _shot_minimap_crop("minimap_rebake_night")

	# ── 4. 拨回昼：再换一版（链路双向，非一次性）──
	env.set("time_of_day", 12.0)
	var day2_tex: ImageTexture = await _await_rebake(map, night_tex)
	if day2_tex == null:
		_fail("拨昼后 %.0fs 内底图未重烘" % REBAKE_TIMEOUT_S)
		return _finish()
	_ok("拨昼 → 再次重烘（链路双向）")
	_check(_mean_luma(day2_tex.get_image()) > luma_night + 3.0,
			"回昼底图变亮（夜 %.1f → 昼 %.1f）" % [luma_night, _mean_luma(day2_tex.get_image())])
	await _shot_minimap_crop("minimap_rebake_day")

	_finish()


# ─────────────────────────────── 辅助 ────────────────────────────────

## 首烘尺寸口径（与 game_root_map_flow.MINIMAP_BAKE_SCALE 相同：显示矩形 ×2）
func _bake_size(map: Node2D) -> Vector2i:
	var mm: Control = _game_root.ui_root.get_node_or_null("HudOverlay/Minimap")
	if mm != null and mm.has_method("get_map_width_px") and mm.has_method("get_map_height_px"):
		return Vector2i(int(round(float(mm.get_map_width_px()) * 2.0)),
				int(round(float(mm.get_map_height_px()) * 2.0)))
	return Vector2i(int(map.map_right - map.map_left) / 9, 240)


## 等底图换新（texture 对象变化即重烘完成；超时返回 null）
func _await_rebake(map: Node2D, old: ImageTexture) -> ImageTexture:
	for i in int(REBAKE_TIMEOUT_S * 60.0):
		await get_tree().process_frame
		var t: ImageTexture = map.get_minimap_base().get("texture")
		if t != null and t != old:
			return t
	return null


## 两图逐像素对比：ratio_bad = 差异超容差像素占比；mean = 全图平均绝对差
func _image_diff(a: Image, b: Image) -> Dictionary:
	if a == null or b == null or a.get_size() != b.get_size():
		return {"ratio_bad": 1.0, "mean": 255.0}
	var bad := 0
	var total: int = a.get_width() * a.get_height()
	var acc := 0.0
	var tol := 8
	for y in a.get_height():
		for x in a.get_width():
			var ca: Color = a.get_pixel(x, y)
			var cb: Color = b.get_pixel(x, y)
			var d: float = absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			acc += d / 3.0
			if d / 3.0 * 255.0 > float(tol):
				bad += 1
	return {"ratio_bad": float(bad) / float(maxi(total, 1)), "mean": acc / float(maxi(total, 1)) * 255.0}


func _mean_luma(img: Image) -> float:
	if img == null:
		return 0.0
	var acc := 0.0
	var n: int = img.get_width() * img.get_height()
	for y in img.get_height():
		for x in img.get_width():
			acc += img.get_pixel(x, y).get_luminance()
	return acc / float(maxi(n, 1)) * 255.0


func _save_png(img: Image, file_name: String) -> void:
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + file_name
	if img.save_png(path) != OK:
		_fail("底图保存失败 %s" % path)
	else:
		print("[SHOT] ", path, " ", img.get_size())


## 裁小地图区域出图（顶部小地图区整块的验收视角）
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
	_save_png(crop, tag + ".png")


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
	# 收尾拨回正午（不污染后续工位的世界时间）
	var env: Node = _game_root.get("environment_system") if _game_root != null else null
	if env != null:
		env.set("time_of_day", 12.0)
	print("=== 小地图重烘验收：%d 项断言，%d 失败 ===" % [_pass_count + _fails.size(), _fails.size()])
	if _fails.is_empty():
		print("=== 小地图重烘验收：全部通过 ===")
		get_tree().quit(0)
	else:
		for f in _fails:
			print("[FAIL] ", f)
		get_tree().quit(1)
