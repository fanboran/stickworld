extends Node
## 疆域染色验收捕图器 —— 政治模式下「占据多少就染色多少」的占领前后对比。
##
## 用法（需真实渲染，不能 headless）：
##   godot --path stick-world res://tests/dev/capture_territory_dyeing.tscn
## 产物（gitignored，给创始人直接点开看）：
##   stick-world/temp/territory_dyeing/before_zoom.png   占领前（该地块=所属政权色）
##   stick-world/temp/territory_dyeing/after_zoom.png    占领后（同一地块=玩家疆域色）
##   stick-world/temp/territory_dyeing/after_full.png    全图适配视角（三座据点全占）
##
## 只走真实链路：归属真值写 WorldState.territories → expansion api 的
## get_owned_tile_keys() 出已占地块表 → 渲染器 set_owned_tiles 逐格覆盖。

const SM_BASE := "res://config/strategic_map"
const L1_JSON := SM_BASE + "/l1_world.json"
const OUT_DIR := "res://temp/territory_dyeing"
## 放大档（该据点地块占屏比例够大，一眼能看出逐格染色而非整片变色）
const ZOOM := 2.5

const RegistryScript := preload("res://modules/expansion/scripts/territory_registry.gd")
const ApiScript := preload("res://modules/expansion/api.gd")

var _vp_size: Vector2
var _data: L1WorldData
var _renderer: MapRenderer
var _cam: MapCamera
var _api: Node


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_data = L1WorldData.load_from(L1_JSON, SM_BASE)
	if _data == null:
		print("DYEING_CAPTURE_FAIL no data")
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
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	_renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	_api = Node.new()
	_api.set_script(ApiScript)
	add_child(_api)
	await _wait_frames(10)

	# 据点地块（配置的 tile_key 在本包数据里定位；取第一座做放大对比）
	var tiles := _territory_tiles()
	if tiles.is_empty():
		print("DYEING_CAPTURE_FAIL 本包数据里找不到据点地块")
		get_tree().quit(1)
		return
	var probe_tile: L1TileDef = tiles[0]
	var center := _polygon_center(probe_tile.polygon)
	_focus(center, ZOOM)
	await _wait_frames(8)
	await _capture("before_zoom")

	# 占领（真值 → 已占地块表 → 渲染器），同一机位复拍
	var ids := _territory_ids()
	for id in ids:
		WorldState.territories[id] = {
			"state": RegistryScript.State.CAPTURED, "garrison_losses": 0,
			"control_progress": 100.0, "owner": RegistryScript.PLAYER_OWNER_ID,
			"faction": RegistryScript.PLAYER_FACTION_ID,
		}
	var owned: Array = _api.get_owned_tile_keys()
	print("OWNED_TILES ", owned)
	_renderer.set_owned_tiles(owned)
	_renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	await _wait_frames(8)
	await _capture("after_zoom")

	# 全图适配：三座据点地格的染色位置关系
	var ctx := float(maxi(_data.context_size.y, _data.size))
	var fit: float = _vp_size.y * 0.85 / ctx
	_focus(Vector2(ctx, ctx) * 0.5, fit)
	await _wait_frames(8)
	await _capture("after_full")

	# 复原（probe 进程内自洽；真值不落盘）
	for id in ids:
		WorldState.territories.erase(id)
	print("DYEING_CAPTURE_DONE")
	get_tree().quit()


## 据点地块：配置里每个 territory 的 tile_key 在数据中对应的 L1TileDef
func _territory_tiles() -> Array:
	var keys := {}
	for row in _all_rows():
		keys[String(row.get("tile_key", ""))] = true
	var out: Array = []
	for tile in _data.tiles:
		if keys.has(tile.tile_id):
			out.append(tile)
	return out


func _territory_ids() -> Array:
	var out: Array = []
	for row in _all_rows():
		out.append(String(row.get("id", "")))
	return out


func _all_rows() -> Array:
	var reg = RegistryScript.new()
	if not reg.load_config():
		return []
	return reg.get_all()


func _polygon_center(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	var acc := Vector2.ZERO
	for p in poly:
		acc += p
	return acc / float(poly.size())


## 机位硬定：地图点 center 摆到屏幕中心（同 r8_feedback_capture 口径）
func _focus(center: Vector2, zoom: float) -> void:
	_cam.set_zoom(zoom)
	_cam.set_offset(_vp_size * 0.5 - center * zoom)


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _capture(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	img.save_png(path)
	print("SHOT ", shot_name, " ", img.get_size(), " -> ", path)
