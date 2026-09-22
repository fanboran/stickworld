extends Node
## L1 地图观感探针 —— 图层开关（裸底图/政治/城市/交通）在「城界三岔口」与「海岸线」的放大取样。
##
## 用法（需真实渲染，不能 headless）：
##   godot --path stick-world res://tests/dev/capture_l1_map_probe.tscn
## 产物（gitignored）：stick-world/temp/l1_probe/{base|political|city|traffic}_{full|junction|coast}.png
##
## 底图（l1_terrain.png）恒在；每档只开一个开关层，用于判各层自身的像素级观感。
## 取样点由数据自身算出（不写死坐标）：三岔口 = 被 ≥3 个地块共享的顶点；
## 海岸线 = 附近 6px 内同时存在地块码与海洋码(0) 的顶点。各档同机位复拍，便于逐张对比。

const SM_BASE := "res://config/strategic_map"
const L1_JSON := SM_BASE + "/l1_world.json"
var OUT_DIR := "res://temp/l1_probe"
## 放大档（城界/海岸线的像素级观感）
const ZOOM := 3.0
## 取样档：每档只开列出的层（[] = 裸底图；层是独立开关，可任意叠加，这里逐层隔离取样）
const PRESETS := [
	{"name": "base", "layers": []},
	{"name": "political", "layers": [MapModeManager.Layer.POLITICAL]},
	{"name": "city", "layers": [MapModeManager.Layer.CITY]},
	{"name": "traffic", "layers": [MapModeManager.Layer.TRAFFIC]},
	{"name": "resource", "layers": [MapModeManager.Layer.RESOURCE]},
	{"name": "all", "layers": [
		MapModeManager.Layer.POLITICAL, MapModeManager.Layer.CITY,
		MapModeManager.Layer.TRAFFIC, MapModeManager.Layer.RESOURCE,
	]},
]

var _vp_size: Vector2
var _data: L1WorldData
var _renderer: MapRenderer
var _cam: MapCamera


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	# L1_PROBE_PACK=002 可选环境变量：指定取样包（默认出生根包；出生包无资源点时
	# 用它换有资源点的包拍 resource 档），产物目录按包区分
	var pack_env := OS.get_environment("L1_PROBE_PACK")
	var json_path := L1_JSON
	if not pack_env.is_empty():
		var label := pack_env.to_int()
		json_path = SM_BASE + "/l1_packs/l1_%03d/l1_world.json" % label
		OUT_DIR = OUT_DIR + "_l1_%03d" % label
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_data = L1WorldData.load_from(json_path, SM_BASE)
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
	for preset in PRESETS:
		var layers: Array = preset["layers"]
		_apply_layers(layers)
		# 静态底图异步线程解码：等底图就位（否则拍到矢量回退态）
		var guard := 0
		while _renderer._base_tex == null and guard < 900:
			guard += 1
			await get_tree().process_frame
		print("PRESET ", preset["name"], " layers=", layers, " base_ready=",
				_renderer._base_tex != null, " frames=", guard)
		await _wait_frames(6)
		var name: String = preset["name"]
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


## 应用层开关预设（未列出的层全关），并唤醒渲染器贴图加载/重绘
## （走控制器同款路径：静态开关表 + 渲染器刷新各一次）
func _apply_layers(on_layers: Array) -> void:
	for layer in [MapModeManager.Layer.POLITICAL, MapModeManager.Layer.CITY,
			MapModeManager.Layer.TRAFFIC, MapModeManager.Layer.RESOURCE]:
		var on: bool = on_layers.has(layer)
		MapModeManager.set_layer_on(layer, on)
		_renderer.set_layer_on(layer, on)


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
