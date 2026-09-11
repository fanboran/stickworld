extends Node
## 观感返工第三批验收截图（用完即删）—— 直接驱动**真实场景树**
## （strategic_map.tscn / strategic_map_l3.tscn / strategic_map_l2.tscn），
## 因此同时实证两件事：
##   1) C21「视口满屏」在游戏内配置下是否成立（打印 OceanBackground 的尺寸 vs 视口）；
##   2) 界线（C19）/ 都城标记（C20）/ 政权配色（C23）/ 标注文字（C24）的实际观感。
## 截图按**地图内容矩形裁剪**（C22）——不再输出带画布空边的整屏图。
##
## 用法：godot --path . res://tests/dev/r8_label_capture.tscn（需真实渲染，不能 headless）
## 产物：仓库根 tools/worldgen/output/feedback3_*.png

const OUT_DIR := "../tools/worldgen/output"
const SM := "res://config/strategic_map"
const WAIT_FRAMES := 600  # 异步解码等待上限（帧）
## 出生地区 label（l3_map_renderer.player_region_label 同源）
const BIRTH_REGION_LABEL := 13
## 裁剪外边距（屏幕像素）：给内容留一圈呼吸位
const CROP_PAD := 18.0

var _vp_size: Vector2


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://" + OUT_DIR))
	await _shot_l1()
	await _shot_l3()
	await _shot_l2()
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	print("R8_LABEL_CAPTURE_DONE")
	get_tree().quit()


## ── L1（Tab）：出生地块政治模式 + 地形模式，验证 C19/C23/C24 与全屏海洋底 ──
func _shot_l1() -> void:
	var scene: Node = preload("res://modules/world_map/scenes/strategic_map.tscn").instantiate()
	add_child(scene)
	var content: Node = scene.get_node("Content")
	var api: Node = content.get_node("Api")
	api.call("initialize", SM + "/l1_world.json", SM)
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	content.call("open")
	await _settle(10)
	_diag_ocean("L1", scene)
	var cam: MapCamera = content.get("map_camera")
	var data: L1WorldData = api.call("get_data")
	var rect := Rect2(Vector2.ZERO, Vector2(data.context_size))
	await _capture("feedback3_l1_political", cam, rect)
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	await _settle(14)
	_diag("L1", content.get("map_renderer"))
	await _capture("feedback3_l1_terrain", cam, rect)
	await _teardown([scene])


## ── L3（M）：政治模式全景 / 出生地区特写 / 深放大，验证界线三级与都城标记 ──
func _shot_l3() -> void:
	var scene: Node = preload("res://modules/world_map/scenes/strategic_map_l3.tscn").instantiate()
	add_child(scene)
	var content: Node = scene.get_node("Content")
	var renderer: L3MapRenderer = content.get("map_renderer")
	var cam: MapCamera = content.get("map_camera")
	renderer.set_data(L3WorldData.load_from(SM + "/l3_world.json", SM))
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	content.call("open")
	# 等政权着色层就绪（S3 矢量 fill 优先，mask 异步回退）
	await _wait_until(func(): return renderer._political_layer != null 		or not renderer._political_fill_meshes.is_empty())
	await _settle(10)
	print("DIAG L3 fill_meshes=", renderer._political_fill_meshes.size(),
		" mask_layer=", renderer._political_layer)


	_diag_ocean("L3", scene)
	_diag("L3fit", renderer)
	var rect := _l3_land_rect(renderer)
	print("L3 land_rect=", rect)
	await _capture("feedback3_l3_political_fit", cam, rect)
	# 出生地区特写（zoom 0.55，r≈4.7 ≤ 6 → 国名在显）
	var birth_center := _birth_region_center(renderer.get_data())
	cam.set_zoom(0.55)
	cam.set_offset(_vp_size * 0.5 - birth_center * 0.55)
	await _settle(8)
	await _capture("feedback3_l3_political_birth", cam, _view_rect(cam))
	# 深放大（r 远超国名阈值 → 国名退场，只余都城标记 + 界线细节）
	var stars: Array = renderer._label_layer._stars
	var center: Vector2 = stars[0]["pos"] if not stars.is_empty() else Vector2.ONE * 4096.0
	cam.set_zoom(1.2)
	cam.set_offset(_vp_size * 0.5 - center * 1.2)
	await _settle(8)
	await _capture("feedback3_l3_political_zoom", cam, _view_rect(cam))
	await _teardown([scene])


## ── L2（下钻）：region_013 政治模式默认视角 ──
func _shot_l2() -> void:
	var scene: Node = preload("res://modules/world_map/scenes/strategic_map_l2.tscn").instantiate()
	add_child(scene)
	var content: Node = scene.get_node("Content")
	content.call("open", "region_%03d" % BIRTH_REGION_LABEL)
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	await _settle(12)
	_diag_ocean("L2", scene)
	var cam: MapCamera = content.get("map_camera")
	var data: L2WorldData = content.get("data")
	var ctx := Vector2(float(data.context_size.x), float(data.context_size.y))
	await _capture("feedback3_l2_political", cam, Rect2(Vector2.ZERO, ctx))
	await _teardown([scene])


# ────────────────────────── 工具 ──────────────────────────

## 视口内可视的地图矩形（地图坐标）——放大特写时内容铺满视口，裁到可视域即可
func _view_rect(cam: MapCamera) -> Rect2:
	var z: float = maxf(cam.get_zoom(), 0.0001)
	return Rect2(-cam.get_offset() / z, _vp_size / z)


## L3 陆地包围盒（region land_polygons 并集 bbox，[y,x] 序）——裁掉四周空海洋带
func _l3_land_rect(renderer: L3MapRenderer) -> Rect2:
	var data: L3WorldData = renderer.get_data()
	var mn := Vector2.INF
	var mx := -Vector2.INF
	for r in data.regions:
		for poly: Variant in r.get("land_polygons", [r.get("land_polygon", [])]):
			for pp: Variant in poly:
				var v: Vector2 = pp if pp is Vector2 else Vector2(pp[1], pp[0])
				mn = mn.min(v)
				mx = mx.max(v)
	if mn == Vector2.INF:
		return Rect2(0.0, 0.0, float(data.size), float(data.size))
	return Rect2(mn, mx - mn)


## 出生地区质心（centroid 2048 级 [x,y] → 渲染坐标 ×size/2048，_draw_l2_labels 同口径）
func _birth_region_center(data: L3WorldData) -> Vector2:
	for r in data.regions:
		if int(r.get("label", 0)) != BIRTH_REGION_LABEL:
			continue
		var c: Array = r.get("centroid", [0, 0])
		return Vector2(float(c[0]), float(c[1])) * float(data.size) / 2048.0
	return Vector2.ONE * float(data.size) * 0.5


## 按地图内容矩形裁剪保存（C22）：screen = offset + map × zoom，外扩 CROP_PAD，
## 再与视口求交（内容超出屏幕时自动退化为整屏）
func _capture(shot_name: String, cam: MapCamera, map_rect: Rect2) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var z: float = maxf(cam.get_zoom(), 0.0001)
	var scr := Rect2(cam.get_offset() + map_rect.position * z, map_rect.size * z).grow(CROP_PAD)
	scr = scr.intersection(Rect2(Vector2.ZERO, _vp_size))
	if scr.size.x < 8.0 or scr.size.y < 8.0:
		scr = Rect2(Vector2.ZERO, _vp_size)
	img = img.get_region(Rect2i(roundi(scr.position.x), roundi(scr.position.y),
		roundi(scr.size.x), roundi(scr.size.y)))
	var path := "res://%s/%s.png" % [OUT_DIR, shot_name]
	img.save_png(ProjectSettings.globalize_path(path))
	print("SHOT ", shot_name, " ", img.get_size(), " crop=", scr)


## 全屏海洋底诊断（C21 硬指标：尺寸 ≥ 视口即铺满）
func _diag_ocean(tag: String, scene: Node) -> void:
	var ob: Control = scene.get_node_or_null("OceanBackground")
	var filled: bool = ob != null \
			and ob.size.x >= _vp_size.x - 0.5 and ob.size.y >= _vp_size.y - 0.5
	print("OCEAN ", tag, " node=", ob != null,
		" visible=", ob.visible if ob != null else false,
		" size=", ob.size if ob != null else Vector2.ZERO,
		" vp=", _vp_size, " filled=", filled)


func _diag(tag: String, renderer: Node2D) -> void:
	var ll: MapLabelLayer = renderer.get("_label_layer")
	if ll == null:
		print("DIAG ", tag, " layer=NULL")
		return
	print("DIAG ", tag, " items=", ll._items.size(), " stars=", ll._stars.size(),
			" font=", ll._font_reg != null, " bold=", ll._font_bold != null,
			" vis=", ll.visible, " in_tree=", ll.is_inside_tree(),
			" mode=", MapModeManager.current_mode)


## 轮询条件满足或超时（条件 callable 返回 true 即通过）
func _wait_until(cond: Callable) -> void:
	for i in WAIT_FRAMES:
		if cond.call():
			return
		await get_tree().process_frame


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _teardown(nodes: Array) -> void:
	for n in nodes:
		n.queue_free()
	await _settle(3)


func _dump_tree(n: Node, depth: int) -> void:
	if depth > 4:
		return
	var info := ""
	if n is CanvasItem:
		var ci := n as CanvasItem
		info = " z=%d vis=%s modulate=%s" % [ci.z_index, ci.visible, ci.modulate]
		if n is ColorRect:
			info += " color=%s size=%s" % [(n as ColorRect).color, (n as ColorRect).size]
		if n is MeshInstance2D:
			var mi := n as MeshInstance2D
			info += " surf=%d" % (mi.mesh.get_surface_count() if mi.mesh != null else -1)
	print("%s%s [%s]%s" % ["  ".repeat(depth), n.name, n.get_class(), info])
	for c in n.get_children():
		_dump_tree(c, depth + 1)
