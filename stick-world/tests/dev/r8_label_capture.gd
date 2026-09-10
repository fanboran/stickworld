extends Node
## feedback2 观感修复验收截图（用完即删）：L3 政治三机位 + 出生地区 L2 下钻。
##   L3 全景（国名+都城星标，验证 B 海洋底/E 城邦族色/A 国界/C 统一界线）/
##   L3 出生地区特写（五问题主视角）/ L3 深放大 / L2 region_013 政治模式（验证 D 陆地洞）
## 用法：godot --path . res://tests/dev/r8_label_capture.tscn（需真实渲染，不能 headless）
## 产物：仓库根 tools/worldgen/output/feedback2_*.png

const OUT_DIR := "../tools/worldgen/output"
const SM_BASE := "res://config/strategic_map"
const WAIT_FRAMES := 600  # 异步解码等待上限（帧）
## 出生地区 label（l3_map_renderer.player_region_label 同源）
const BIRTH_REGION_LABEL := 13

var _vp_size: Vector2


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://" + OUT_DIR))
	# 游戏同构 CanvasLayer（strategic_map_l3.tscn 同款：OceanBackground 首子节点）+
	# 后挂渲染器；海洋底是否盖住 z=-1 的政治层由此实证
	var layer := CanvasLayer.new()
	layer.layer = 101
	add_child(layer)
	_add_ocean_background_to(layer)
	await _shot_l2(layer)
	await _shot_l3(layer)
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	print("R8_LABEL_CAPTURE_DONE")
	get_tree().quit()


## 全屏海洋底（feedback2 B）：游戏内 = strategic_map_l3.tscn 的 OceanBackground
## （l3_map_controller open() 挂载），截图树此前缺件 → 截图四周露编辑器灰底。
## 色与 political shader empty_color 同源（MapTokens.L3_OCEAN = 30/55/95）。
func _add_ocean_background_to(layer: CanvasLayer) -> void:
	var ocean := ColorRect.new()
	ocean.name = "OceanBackground"
	ocean.color = MapTokens.L3_OCEAN
	ocean.set_anchors_preset(Control.PRESET_FULL_RECT)
	ocean.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# z=-2 与 strategic_map_l3.tscn 同步（feedback2 B 实证：政治 ID mask 层是
	# 渲染器子节点 z=-1，海洋底 z=0 会把它整个盖住——游戏内同病，场景已修）
	ocean.z_index = -2
	layer.add_child(ocean)


func _make_camera(renderer: Node2D, zoom: float, center: Vector2) -> MapCamera:
	var cam := MapCamera.new()
	cam.drag_enabled = false
	cam.zoom_enabled = false
	add_child(cam)
	cam.target = renderer
	renderer.set_camera(cam)
	cam.set_zoom(zoom)
	# screen = offset + map × zoom → 地图点 center 摆到屏幕中心
	cam.set_offset(_vp_size * 0.5 - center * zoom)
	return cam


func _capture(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "res://%s/%s.png" % [OUT_DIR, shot_name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("SHOT ", shot_name, " ", img.get_size())


## 轮询条件满足或超时（条件 callable 返回 true 即通过）
func _wait_until(cond: Callable) -> void:
	for i in WAIT_FRAMES:
		if cond.call():
			return
		await get_tree().process_frame


func _teardown(nodes: Array) -> void:
	for n in nodes:
		n.queue_free()
	await get_tree().process_frame


func _diag(tag: String, renderer: Node2D) -> void:
	var ll: MapLabelLayer = renderer.get("_label_layer")
	if ll == null:
		print("DIAG ", tag, " layer=NULL")
		return
	print("DIAG ", tag, " items=", ll._items.size(), " stars=", ll._stars.size(),
			" font=", ll._font_reg != null, " bold=", ll._font_bold != null,
			" vis=", ll.visible, " in_tree=", ll.is_inside_tree(),
			" mode=", MapModeManager.current_mode,
			" cam_z=", ll._camera.get_zoom() if ll._camera != null else -1.0)


## ── L2：region_013（出生地区）政治模式默认视角，验证 D 陆地洞全消 ──
func _shot_l2(layer: CanvasLayer) -> void:
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	var data := L2WorldData.load_from(
		SM_BASE + "/l2_packs/region_013/l2_world.json", SM_BASE + "/l2_packs/region_013")
	var renderer := L2MapRenderer.new()
	layer.add_child(renderer)
	var cam := _make_camera(renderer, 1.0, Vector2.ZERO)
	renderer.set_data(data)
	renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	var ctx := float(maxi(data.context_size.x, data.context_size.y))
	var fit := _vp_size.y * 0.72 / ctx
	cam.set_zoom(fit * 1.75)  # 控制器默认视角（重镇名阈值 r≥1.2 之上）
	cam.set_offset(_vp_size * 0.5 - Vector2(ctx, ctx) * fit * 1.75 * 0.5)
	for i in 8:
		await get_tree().process_frame
	_diag("L2", renderer)
	await _capture("feedback2_l2_birth")
	await _teardown([renderer, cam])


## ── L3：政治模式三连拍（共用一次 8192 数据装载/解码）──
##   全景适配（B 海洋底/E 城邦族色）/ 出生地区特写（A 国界/C 统一界线）/
##   深放大（r>6：国名退场，只余星标）
func _shot_l3(layer: CanvasLayer) -> void:
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	var data := L3WorldData.load_from(SM_BASE + "/l3_world.json", SM_BASE)
	var renderer := L3MapRenderer.new()
	layer.add_child(renderer)
	var cam := _make_camera(renderer, 1.0, Vector2.ZERO)
	renderer.set_data(data)
	renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	# 等政权 ID mask 后台解码完成（67MB PNG，数秒）
	await _wait_until(func(): return renderer._political_layer != null)
	# 取一个都城星标落点做深放大的画面中心（星标在深放大下仍恒显）
	var stars: Array = renderer._label_layer._stars
	var center: Vector2 = stars[0]["pos"] if not stars.is_empty() else Vector2.ONE * 4096.0
	# 出生地区质心（centroid 2048 级 [x,y] → 渲染坐标 ×size 比，_draw_l2_labels 同口径）
	var birth_center := Vector2.ONE * float(data.size) * 0.5
	for r in data.regions:
		if int(r.get("label", 0)) != BIRTH_REGION_LABEL:
			continue
		var c: Array = r.get("centroid", [0, 0])
		birth_center = Vector2(float(c[0]), float(c[1])) * float(data.size) / 2048.0
	# 1) 整图适配（控制器 open() 口径：视口高 − 上下海洋边距）
	var fit := (_vp_size.y - 128.0) / float(data.size)
	cam.set_zoom(fit)
	cam.set_offset(_vp_size * 0.5 - Vector2(data.size, data.size) * fit * 0.5)
	for i in 8:
		await get_tree().process_frame
	_diag("L3fit", renderer)
	await _capture("feedback2_l3_country")
	# 2) 出生地区特写 zoom 0.55（r≈4.7 ≤ 6 国名在显；地区占满画面）
	cam.set_zoom(0.55)
	cam.set_offset(_vp_size * 0.5 - birth_center * 0.55)
	for i in 8:
		await get_tree().process_frame
	_diag("L3birth", renderer)
	await _capture("feedback2_l3_birth")
	# 3) 深放大 zoom 1.2（适配 zoom ~0.116 → r ≈ 10 > 6，国名阈值退场）
	cam.set_zoom(1.2)
	cam.set_offset(_vp_size * 0.5 - center * 1.2)
	for i in 8:
		await get_tree().process_frame
	_diag("L3zoom", renderer)
	await _capture("feedback2_l3_zoomed")
	await _teardown([renderer, cam])
