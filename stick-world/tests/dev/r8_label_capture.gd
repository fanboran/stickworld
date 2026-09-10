extends Node
## R8 层3 标注体系验收截图（用完即删）：三级视图标注效果离屏渲染。
##   L3 政治全景（国名+都城星标）/ L3 深放大（国名退场阈值）/ L2 地区（地区名+重镇）/
##   L1 地块（城市名+首都星标）
## 用法：godot --path . res://tests/dev/r8_label_capture.tscn（需真实渲染，不能 headless）
## 产物：仓库根 tools/worldgen/output/r8_label_*.png

const OUT_DIR := "../tools/worldgen/output"
const SM_BASE := "res://config/strategic_map"
const WAIT_FRAMES := 600  # 异步解码等待上限（帧）

var _vp_size: Vector2


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://" + OUT_DIR))
	await _shot_l1()
	await _shot_l2()
	await _shot_l3()
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	print("R8_LABEL_CAPTURE_DONE")
	get_tree().quit()


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


## ── L1：l1_002 地形模式，城市名 + 首都星标（全模式语义）──
func _shot_l1() -> void:
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	var data := L1WorldData.load_from(
		SM_BASE + "/l1_packs/l1_002/l1_world.json", SM_BASE + "/l1_packs/l1_002")
	var renderer := MapRenderer.new()
	add_child(renderer)
	var cam := _make_camera(renderer, 1.0, Vector2.ZERO)  # 占位，下面按 context 重算
	renderer.set_data(data)
	renderer.set_map_mode(MapModeManager.Mode.TERRAIN)
	var ctx := float(maxi(data.context_size.y, data.size))
	var fit := _vp_size.y * 0.85 / ctx
	cam.set_zoom(fit)
	cam.set_offset(_vp_size * 0.5 - Vector2(ctx, ctx) * fit * 0.5)
	await _wait_until(func(): return renderer._mode_textures.size() > 0 and renderer._blob_ready)
	for i in 8:
		await get_tree().process_frame
	_diag("L1", renderer)
	await _capture("r8_label_l1_city")
	await _teardown([renderer, cam])


## ── L2：region_001 政治模式默认视角，地区名 + 都城星标/名 + 重镇名 ──
func _shot_l2() -> void:
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	var data := L2WorldData.load_from(
		SM_BASE + "/l2_packs/region_001/l2_world.json", SM_BASE + "/l2_packs/region_001")
	var renderer := L2MapRenderer.new()
	add_child(renderer)
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
	await _capture("r8_label_l2_region")
	await _teardown([renderer, cam])


## ── L3：政治模式两连拍（共用一次 8192 数据装载/解码）──
##   全景适配：国名 + 都城星标；深放大（r>6）：国名退场，只余星标
func _shot_l3() -> void:
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	var data := L3WorldData.load_from(SM_BASE + "/l3_world.json", SM_BASE)
	var renderer := L3MapRenderer.new()
	add_child(renderer)
	var cam := _make_camera(renderer, 1.0, Vector2.ZERO)
	renderer.set_data(data)
	renderer.set_map_mode(MapModeManager.Mode.POLITICAL)
	# 等政权 ID mask 后台解码完成（67MB PNG，数秒）
	await _wait_until(func(): return renderer._political_layer != null)
	# 取一个都城星标落点做深放大的画面中心（星标在深放大下仍恒显）
	var stars: Array = renderer._label_layer._stars
	var center: Vector2 = stars[0]["pos"] if not stars.is_empty() else Vector2.ONE * 4096.0
	# 1) 整图适配（控制器 open() 口径：视口高 − 上下海洋边距）
	var fit := (_vp_size.y - 128.0) / float(data.size)
	cam.set_zoom(fit)
	cam.set_offset(_vp_size * 0.5 - Vector2(data.size, data.size) * fit * 0.5)
	for i in 8:
		await get_tree().process_frame
	_diag("L3fit", renderer)
	await _capture("r8_label_l3_country")
	# 2) 深放大 zoom 1.2（适配 zoom ~0.116 → r ≈ 10 > 6，国名阈值退场）
	cam.set_zoom(1.2)
	cam.set_offset(_vp_size * 0.5 - center * 1.2)
	for i in 8:
		await get_tree().process_frame
	_diag("L3zoom", renderer)
	await _capture("r8_label_l3_zoomed")
	await _teardown([renderer, cam])
