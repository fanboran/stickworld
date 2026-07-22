extends SceneTree
## 渲染 smithy_preview.tscn 为 PNG
## 用法：
##   godot --headless --rendering-driver opengl3 --path project/ \
##     --script res://modules/building_gen/tools/render_preview.gd
## 输出：modules/building_gen/reference/smithy_preview_render.png

const SCENE_PATH := "res://modules/building_gen/scenes/smithy_preview.tscn"
const OUT_PATH := "res://modules/building_gen/reference/smithy_preview_render.png"
const PM_PATH := "res://modules/building_gen/scripts/materials/procedural_materials.gd"
const WAIT_FRAMES := 15
# 恢复基线：不扩展贴图边缘，背景/屋顶均严格按原尺寸渲染
const THATCH_EDGE_MARGIN := 0.0
const THATCH_RES_SCALE := 2.0

var _sv: SubViewport
var _frame_count := 0
var PM = null
var _log: FileAccess

func _log_line(msg: String) -> void:
	if _log == null:
		_log = FileAccess.open("res://modules/building_gen/reference/render_debug.log", FileAccess.WRITE)
	var line := "[%s] %s" % [Time.get_time_string_from_system(), msg]
	print(line)
	if _log:
		_log.store_line(line)
		_log.flush()

func _initialize() -> void:
	_log_line("_initialize start")
	var scene: PackedScene = load(SCENE_PATH)
	if scene == null:
		_log_line("[ERROR] 无法加载场景: %s" % SCENE_PATH)
		quit()
		return
	_log_line("scene loaded")
	var node: Node = scene.instantiate()
	_log_line("scene instantiated: %s" % node.name)

	PM = load(PM_PATH)
	if PM == null:
		_log_line("[ERROR] 无法加载 ProceduralMaterials: %s" % PM_PATH)
		quit()
		return
	_log_line("[STEP0] ProceduralMaterials 已加载")

	# 动态替换所有茅草材质贴图（屋顶 + 后景墙）
	_log_line("replacing thatch textures...")
	_replace_thatch_textures(node)

	# 创建 SubViewport
	_log_line("creating SubViewport...")
	_sv = SubViewport.new()
	_sv.transparent_bg = true
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(_sv)

	# 实例化场景到 SubViewport
	_sv.add_child(node)
	_log_line("[STEP1] 场景已加载, children=%d" % node.get_child_count())

	# 计算包围盒（缩放前）
	var rect := _compute_rect(node)
	if rect.size.x <= 0 or rect.size.y <= 0:
		rect = Rect2(Vector2(-400, -500), Vector2(800, 600))

	# 放大场景，让 1024 贴图在屋顶上有足够显示尺寸，LINEAR 才不会糊成纯色
	const RENDER_SCALE := 2.5
	node.scale = Vector2(RENDER_SCALE, RENDER_SCALE)
	# 给足够大的 viewport 防止缩放后被裁剪；最后会用 get_used_rect() 裁剪
	_sv.size = Vector2i(1600, 1200)
	node.position = -rect.position * RENDER_SCALE + Vector2(100, 100)
	_log_line("[STEP2] rect=%s, sv.size=%s, scale=%.1f" % [rect, _sv.size, RENDER_SCALE])


func _process(_delta: float) -> bool:
	_frame_count += 1
	if _frame_count < WAIT_FRAMES:
		return false

	# 等待渲染完成后截图（多帧重试：headless 下 SubViewport texture 可能有延迟）
	_log_line("[STEP3] 截图 (frame %d)..." % _frame_count)
	var img: Image = null
	for retry in range(10):
		var tex := _sv.get_texture()
		if tex != null:
			img = tex.get_image()
			if img != null and not img.is_empty():
				break
		_log_line("[STEP3] retry %d: get_image() 尚未就绪" % retry)
		await process_frame
		_frame_count += 1
	if img == null or img.is_empty():
		_log_line("[ERROR] get_image() 多次重试后仍返回 null/empty")
		quit()
		return true
	_log_line("[STEP4] 图像: %dx%d" % [img.get_width(), img.get_height()])

	var used := img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		img.save_png(OUT_PATH)
		_log_line("[OK] 渲染完成（兜底）: %s  (%dx%d)" % [ProjectSettings.globalize_path(OUT_PATH), img.get_width(), img.get_height()])
	else:
		var crop := img.get_region(used)
		var final_img := Image.create(crop.get_width() + 8, crop.get_height() + 8, false, Image.FORMAT_RGBA8)
		final_img.fill(Color(0, 0, 0, 0))
		final_img.blit_rect(crop, Rect2i(0, 0, crop.get_width(), crop.get_height()), Vector2i(4, 4))
		final_img.save_png(OUT_PATH)
		_log_line("[OK] 渲染完成: %s  (%dx%d)" % [ProjectSettings.globalize_path(OUT_PATH), final_img.get_width(), final_img.get_height()])

	quit()
	return true


func _compute_rect(node: Node) -> Rect2:
	var r := Rect2()
	for child in _collect_sprites_and_polys(node):
		if child is Sprite2D:
			var tex = child.texture
			if tex == null: continue
			var ts: Vector2 = tex.get_size() * child.scale
			var offset = ts * 0.5 if child.centered else Vector2.ZERO
			var pos: Vector2 = child.position - offset
			r = r.expand(pos)
			r = r.expand(pos + ts)
		elif child is Polygon2D:
			for pt in child.polygon:
				r = r.expand(child.position + pt * child.scale)
	return r


func _collect_sprites_and_polys(node: Node) -> Array:
	var result := []
	_collect_recursive(node, result)
	return result

func _collect_recursive(node: Node, arr: Array) -> void:
	if node is Sprite2D or node is Polygon2D:
		arr.append(node)
	for child in node.get_children():
		_collect_recursive(child, arr)


# 递归遍历场景节点，为所有茅草材质 Polygon2D / Sprite2D 重新生成专属贴图。
# 屋顶 Polygon2D 按包围盒尺寸生成范围贴图；后景墙 Sprite2D 按原纹理尺寸生成深色版。
func _replace_thatch_textures(node: Node) -> void:
	var counter := [0, 0]  # [Polygon2D, Sprite2D]
	_replace_recursive(node, counter)
	_log_line("[STEP1.5] 茅草贴图已替换: %d 个 Polygon2D, %d 个 Sprite2D" % [counter[0], counter[1]])


func _replace_recursive(node: Node, counter: Array) -> void:
	_log_line("[debug] visit: %s (%s)" % [node.name, node.get_class()])
	if node is Polygon2D:
		var pname: String = node.get_name()
		var parent := node.get_parent()
		var parent_is_roof_group := parent != null and parent.get_name() == "L5_Roof"
		if pname.find("Roof") >= 0 or parent_is_roof_group:
			var poly: PackedVector2Array = node.polygon
			var bounds := _poly_bounds(poly)
			var tex_w := ceili(bounds.size.x)
			var tex_h := ceili(bounds.size.y)
			if tex_w < 16: tex_w = 16
			if tex_h < 16: tex_h = 16
			_log_line("[debug] polygon=%s" % [poly])
			_log_line("[debug] generating texture for %s (%dx%d)" % [pname, tex_w, tex_h])
			var mirror := pname.find("Left") < 0
			var tex = PM.make_thatch_for_polygon(tex_w, tex_h, hash(pname), 1.0, 0.22, 2.0, mirror, THATCH_EDGE_MARGIN)
			node.texture = tex
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			var min_x := bounds.position.x
			var max_x := bounds.position.x + bounds.size.x
			var min_y := bounds.position.y
			var max_y := bounds.position.y + bounds.size.y
			var uvs: PackedVector2Array = []
			for pt in poly:
				var u := (pt.x - min_x) / (max_x - min_x) * tw
				var v := (pt.y - min_y) / (max_y - min_y) * th
				uvs.append(Vector2(u, v))
			node.uv = uvs
			node.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
			node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			# 应用茅草边缘 Shader，在渲染管线里结合 alpha 蒙版与草丝生成
			node.material = PM.create_thatch_material(tex)
			counter[0] += 1
			_log_line("  └ 屋顶: %s (%dx%d)" % [pname, tex_w, tex_h])
	elif node is Sprite2D:
		var sname: String = node.get_name()
		if sname.find("BackWall") >= 0:
			var tex_size := Vector2(64, 64)
			if node.has_meta("thatch_size"):
				tex_size = Vector2(node.get_meta("thatch_size"))
			elif node.texture != null:
				tex_size = node.texture.get_size()
			elif node.region_enabled and node.region_rect.size.x > 0:
				tex_size = node.region_rect.size
			var tex_w := ceili(tex_size.x)
			var tex_h := ceili(tex_size.y)
			if tex_w < 16: tex_w = 16
			if tex_h < 16: tex_h = 16
			var tex = PM.make_thatch_for_polygon(tex_w, tex_h, hash(sname), 0.95, 0.10, 1.0, false, THATCH_EDGE_MARGIN)
			node.texture = tex
			# 后景墙同样使用茅草 Shader 保持风格一致（内部边界默认整张纹理）
			node.material = PM.create_thatch_material(tex)
			counter[1] += 1
			_log_line("  └ 后景墙: %s (%dx%d)" % [sname, tex_w, tex_h])
	for child in node.get_children():
		_replace_recursive(child, counter)


func _poly_bounds(poly: PackedVector2Array) -> Rect2:
	if poly.size() == 0:
		return Rect2()
	var r := Rect2(poly[0], Vector2.ZERO)
	for i in range(1, poly.size()):
		r = r.expand(poly[i])
	return r


# 将四边形各边向外扩展 margin，并沿边插入大量随机起伏点，与 smithy_preview.gd 保持一致。
func _expand_quad_irregular(tl: Vector2, tr: Vector2, br: Vector2, bl: Vector2,
		margin: float, rng_seed: int = 0) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var edges := [
		{"a": tl, "b": tr, "n": _outward_normal(tl, tr)},
		{"a": tr, "b": br, "n": _outward_normal(tr, br)},
		{"a": br, "b": bl, "n": _outward_normal(br, bl)},
		{"a": bl, "b": tl, "n": _outward_normal(bl, tl)},
	]

	var corner_normals := [
		(edges[0]["n"] + edges[3]["n"]).normalized(),
		(edges[0]["n"] + edges[1]["n"]).normalized(),
		(edges[1]["n"] + edges[2]["n"]).normalized(),
		(edges[2]["n"] + edges[3]["n"]).normalized(),
	]
	var corners := [tl, tr, br, bl]
	var expanded_corners: Array[Vector2] = []
	for i in range(4):
		var m := margin * rng.randf_range(0.70, 1.35)
		expanded_corners.append(corners[i] + corner_normals[i] * m)

	var pts := PackedVector2Array()
	for i in range(4):
		var a := expanded_corners[i]
		var b := expanded_corners[(i + 1) % 4]
		var n: Vector2 = edges[i]["n"]
		var len := a.distance_to(b)
		# 每边 2~4 个波动，优先保证屋顶形状不扭曲
		var seg_count := clampi(int(len / 28.0), 2, 4)
		for j in range(seg_count):
			var t0 := float(j) / float(seg_count)
			var t1 := float(j + 1) / float(seg_count)
			var p0 := a.lerp(b, t0)
			var p1 := a.lerp(b, t1)
			# 分段中点向外随机波动，形成参差不齐的茅草边
			var mid := (p0 + p1) * 0.5
			var m := margin * rng.randf_range(0.50, 1.40)
			var out := mid + n * m
			pts.append(p0)
			pts.append(out)

	# 追加最后一个角点以闭合
	pts.append(expanded_corners[0])
	return pts


func _outward_normal(a: Vector2, b: Vector2) -> Vector2:
	var dir := (b - a).normalized()
	return Vector2(dir.y, -dir.x)
