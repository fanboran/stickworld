extends Node
## L1 地图观感探针 —— 三模式（地形/政治/交通）在「城界三岔口」与「海岸线」的放大取样。
##
## 用法（需真实渲染，不能 headless）：
##   godot --path stick-world res://tests/dev/capture_l1_map_probe.tscn
## 产物（gitignored）：stick-world/temp/l1_probe/{terrain|political|traffic}_{full|junction|coast}.png
##
## 取样点由数据自身算出（不写死坐标）：三岔口 = 被 ≥3 个地块共享的顶点；
## 海岸线 = 附近 6px 内同时存在地块码与海洋码(0) 的顶点。三模式同机位复拍，便于逐张对比。

const SM_BASE := "res://config/strategic_map"
const L1_JSON := SM_BASE + "/l1_world.json"
const OUT_DIR := "res://temp/l1_probe"
## 放大档（城界/海岸线的像素级观感）
const ZOOM := 3.0
const MODES := [
	MapModeManager.Mode.TERRAIN,
	MapModeManager.Mode.POLITICAL,
	MapModeManager.Mode.TRAFFIC,
]
const MODE_NAMES := {
	MapModeManager.Mode.TERRAIN: "terrain",
	MapModeManager.Mode.POLITICAL: "political",
	MapModeManager.Mode.TRAFFIC: "traffic",
}

var _vp_size: Vector2
var _data: L1WorldData
var _renderer: MapRenderer
var _cam: MapCamera


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_data = L1WorldData.load_from(L1_JSON, SM_BASE)
	if _data == null:
		print("L1_PROBE_FAIL no data")
		get_tree().quit(1)
		return
	_renderer = MapRenderer.new()
	add_child(_renderer)
	_cam = MapCamera.new()
	_cam.drag_enabled = false
	_cam.zoom_enabled = false
	add_child(_cam)
	_cam.target = _renderer
	_renderer.set_camera(_cam)
	_renderer.set_data(_data)
	await _wait_frames(4)
	var junction := _junction_point()
	var coast := _coast_point()
	print("PROBE_POINTS junction=", junction, " coast=", coast)
	for mode in MODES:
		MapModeManager.set_mode(mode)
		_renderer.set_map_mode(mode)
		# 静态底图异步线程解码：等当前模式的贴图就位（否则拍到矢量回退态）
		var guard := 0
		while not _renderer._mode_textures.has(mode) and guard < 900:
			guard += 1
			await get_tree().process_frame
		print("MODE ", MODE_NAMES[mode], " texture_ready=", _renderer._mode_textures.has(mode),
				" frames=", guard)
		# 政治模式还要等「水面回贴」贴图烘完（线程内像素扫描）——否则拍到未收敛的岸边溢出
		if mode == MapModeManager.Mode.POLITICAL:
			var t0 := Time.get_ticks_msec()
			var wguard := 0
			while _renderer._water_tex == null and not _renderer._water_failed and wguard < 600:
				wguard += 1
				await get_tree().process_frame
			print("WATER_RESTORE ready=", _renderer._water_tex != null,
					" failed=", _renderer._water_failed,
					" 等待 ", Time.get_ticks_msec() - t0, "ms /", wguard, " 帧")
		await _wait_frames(6)
		var name: String = MODE_NAMES[mode]
		var ctx := float(maxi(_data.context_size.y, _data.size))
		_focus(Vector2(ctx, ctx) * 0.5, _vp_size.y * 0.85 / ctx)
		await _wait_frames(4)
		await _capture(name + "_full")
		if junction != Vector2.INF:
			_focus(junction, ZOOM)
			await _wait_frames(4)
			await _capture(name + "_junction")
		if coast != Vector2.INF:
			_focus(coast, ZOOM)
			await _wait_frames(4)
			await _capture(name + "_coast")
	print("L1_PROBE_DONE")
	get_tree().quit()


## 三岔口：被 ≥3 个地块共享的顶点（坐标按 0.05px 量化归并）
func _junction_point() -> Vector2:
	var buckets: Dictionary = {}
	for tile in _data.tiles:
		if tile.polygon.size() < 3:
			continue
		for p in tile.polygon:
			var key := "%d_%d" % [roundi(p.x * 20.0), roundi(p.y * 20.0)]
			if not buckets.has(key):
				buckets[key] = {"pt": p, "tiles": {}}
			buckets[key]["tiles"][tile.tile_id] = true
	var best := Vector2.INF
	var best_n := 0
	for key in buckets:
		var n: int = (buckets[key]["tiles"] as Dictionary).size()
		if n > best_n:
			best_n = n
			best = buckets[key]["pt"]
	print("JUNCTION max shares=", best_n, " tiles=", (buckets[
			"%d_%d" % [roundi(best.x * 20.0), roundi(best.y * 20.0)]]["tiles"] as Dictionary).keys(),
			" mask_code=", _mask_code(best))
	return best


func _mask_code(p: Vector2) -> int:
	var mask := _data.mask_image
	if mask == null:
		return -1
	var xi := int(p.x)
	var yi := int(p.y)
	if xi < 0 or yi < 0 or xi >= mask.get_width() or yi >= mask.get_height():
		return -1
	var px := mask.get_pixel(xi, yi)
	return (int(px.r * 255.0) << 16) | (int(px.g * 255.0) << 8) | int(px.b * 255.0)


## 海岸线：附近 6px 内既有地块码又有海洋码(0) 的地块顶点
func _coast_point() -> Vector2:
	var mask := _data.mask_image
	if mask == null:
		return Vector2.INF
	var offs := [Vector2(6, 0), Vector2(-6, 0), Vector2(0, 6), Vector2(0, -6)]
	for tile in _data.tiles:
		for p in tile.polygon:
			var has_land := false
			var has_sea := false
			for o in offs:
				var q := p + (o as Vector2)
				var xi := int(q.x)
				var yi := int(q.y)
				if xi < 0 or yi < 0 or xi >= mask.get_width() or yi >= mask.get_height():
					continue
				var px := mask.get_pixel(xi, yi)
				var code := (int(px.r * 255.0) << 16) | (int(px.g * 255.0) << 8) | int(px.b * 255.0)
				if code == 0:
					has_sea = true
				else:
					has_land = true
			if has_land and has_sea:
				return p
	return Vector2.INF


func _focus(center: Vector2, zoom: float) -> void:
	_cam.set_zoom(zoom)
	# 用回读的实际缩放算偏移（set_zoom 会被 min/max_zoom 夹——按请求值算会把内容推出屏外）
	var z: float = _cam.get_zoom()
	_cam.set_offset(_vp_size * 0.5 - center * z)
	print("FOCUS center=", center, " want_zoom=", zoom, " got_zoom=", z,
			" offset=", _cam.get_offset())


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _capture(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	img.save_png(path)
	print("SHOT ", shot_name, " -> ", path)
