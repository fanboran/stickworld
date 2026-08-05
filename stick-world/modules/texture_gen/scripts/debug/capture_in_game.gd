extends Node
## 标准运行模式下的自动截图工具
##
## 用法：把本脚本挂到调试场景的任意节点上，用命令行正常运行项目：
##   godot --path <project> --position 10000,10000
## 运行后会等待若干帧确保 Shader 已编译并渲染完成，保存 viewport 截图并退出。
##
## 设计要点：
## - `crop_node_paths`：可指定多个节点（Sprite2D / Polygon2D），按它们的 union AABB + padding
##   裁剪截图。这样 smithy_thatch_capture 这类"屋顶特写"会输出贴近屋顶的紧凑图，
##   而不是带四周灰边的整张 viewport。
## - `preview_guides_node_path`：可选，指向一个带 `show_guides` 属性的节点（Node2D），
##   capture 时设为 false，隐藏 _draw() 辅助线。

## 截图保存路径（res:// 路径）
@export var output_path: String = "res://modules/building_gen/materials/thatch/reference/thatch_debug_capture.png"

## 要精确截图的节点路径列表（多节点 union AABB）。留空则截取整个 viewport。
## 支持 Sprite2D 和 Polygon2D；最终裁剪矩形 = 所有节点的 union AABB + padding。
@export var crop_node_paths: Array[NodePath] = []

## 截图周围的 padding（屏幕像素）。给特写留出少量边距。
@export var crop_padding: int = 16

## 启动后等待的帧数，给 Shader 编译和窗口初始化留足时间
@export var settle_frames: int = 5

## 可选：指向带 `show_guides` 属性的节点。capture 时设为 false 隐藏 _draw() 辅助线。
## 例如 smithy_preview.gd 的 SmithyPreview 根节点。
@export var preview_guides_node_path: NodePath = NodePath("")

## 可选：另外的带 show_guides 的节点列表（如 ThatchApplier），capture 时也设为 false。
@export var extra_guides_node_paths: Array[NodePath] = []

## 可选：要隐藏的节点路径列表（capture 时整组节点 `.visible = false`）。
## 用来屏蔽 smithy_preview 中的柱子、墙、横梁等无关节点，让截图只包含目标区域。
@export var hide_node_paths: Array = []

## 可选：把裁剪区域的背景填成透明（alpha=0）。需要 display/window.per_pixel_transparency=true。
## 让截图里没有屋顶的位置完全透明——直接贴近参考图的"屋顶特写 + 透明背景"风格。
@export var transparent_background: bool = false

## 超采样倍率（2 = 2x 分辨率渲染后降采样，边缘更平滑）
@export var super_sample: int = 2


var _frame: int = 0
var _phase: int = 0  # 0=等待shader编译, 1=隐藏辅助线, 2=隐藏节点, 3=超采样准备, 4=超采样等待, 5=截图
var _ss: int = 1       # 超采样倍率

func _ready() -> void:
	# 设置 viewport 透明背景，让 Sprite2D 的透明区域直接显示为透明
	var vp := get_viewport()
	if vp != null:
		vp.transparent_bg = true
		print("[capture_in_game] viewport transparent_bg = true")

	# 兜底：如果 tscn 没把 Array export 加载进来（Godot 4 tscn 加载 Array 已知问题），
	# 手动设置 hide_node_paths 兜底
	if hide_node_paths.is_empty():
		hide_node_paths = [
			NodePath("../SmithyPreview/L1_BackWall"),
			NodePath("../SmithyPreview/L4_FrontWall"),
			NodePath("../SmithyPreview/L5_Roof/SlantedBeam"),
			NodePath("../SmithyPreview/L5_Roof/VerticalStrut"),
			NodePath("../SmithyPreview/L5_Roof/Beam"),
			NodePath("../SmithyPreview/L5_Roof/SlantedStrut"),
		]
	print("[capture_in_game] _ready: hide_node_paths.size=", hide_node_paths.size(), " crop_node_paths.size=", crop_node_paths.size())
	_frame = 0
	_phase = 0

func _process(_delta: float) -> void:
	_frame += 1

	# Phase 0: 等待 shader 编译
	if _phase == 0:
		if _frame < settle_frames:
			return
		_phase = 1
		_frame = 0
		# 关闭预览辅助线
		if not preview_guides_node_path.is_empty():
			var guides_node := get_node_or_null(preview_guides_node_path)
			if guides_node != null and "show_guides" in guides_node:
				guides_node.set("show_guides", false)
		for extra_np in extra_guides_node_paths:
			var extra_node := get_node_or_null(extra_np)
			if extra_node != null and "show_guides" in extra_node:
				extra_node.set("show_guides", false)
		print("[capture_in_game] Phase 0 -> 1")
		return

	# Phase 1: 等待辅助线隐藏生效
	if _phase == 1:
		if _frame < 2:
			return
		_phase = 2
		_frame = 0
		# 隐藏无关节点
		for np in hide_node_paths:
			var n := get_node_or_null(np)
			if n != null:
				n.visible = false
				print("[capture_in_game] hidden: %s" % np)
		print("[capture_in_game] Phase 1 -> 2")
		return

	# Phase 2: 等待隐藏生效
	if _phase == 2:
		if _frame < 2:
			return
		_phase = 3
		_frame = 0
		print("[capture_in_game] Phase 2 -> 3 (super sample)")
		_apply_super_sample()
		return

	# Phase 3: 等待超采样窗口更新生效
	if _phase == 3:
		if _frame < 3:
			return
		_phase = 4
		print("[capture_in_game] Phase 3 -> 4 (capturing)")
		_capture_and_save()
		set_process(false)

func _capture_and_save() -> void:
	var vp := get_viewport()
	if vp == null:
		push_error("[capture_in_game] viewport 为 null")
		get_tree().quit(1)
		return

	var tex := vp.get_texture()
	if tex == null:
		push_error("[capture_in_game] viewport texture 为 null")
		get_tree().quit(1)
		return

	var img := tex.get_image()
	if img == null:
		push_error("[capture_in_game] 截图失败：img 为 null")
		get_tree().quit(1)
		return

	if not crop_node_paths.is_empty():
		img = _crop_to_nodes(img, vp)
		if img == null:
			push_error("[capture_in_game] 按节点裁剪失败")
			get_tree().quit(1)
			return

	if transparent_background:
		img = _apply_transparent_background(img)

	# 降采样回目标尺寸
	if _ss > 1:
		img.resize(int(img.get_width() / float(_ss)), int(img.get_height() / float(_ss)), Image.INTERPOLATE_LANCZOS)

	var err := img.save_png(output_path)
	if err != OK:
		push_error("[capture_in_game] 保存截图失败: %d" % err)
		get_tree().quit(1)
		return

	print("[capture_in_game] 已保存: %s (%dx%d)" % [output_path, img.get_width(), img.get_height()])
	get_tree().quit(0)


## 超采样：放大窗口并更新茅草 shader 的 resolution 参数
func _apply_super_sample() -> void:
	_ss = maxi(1, super_sample)
	if _ss <= 1:
		return

	var window := get_window()
	if window == null:
		return
	var old_size := window.size
	window.size = Vector2i(old_size.x * _ss, old_size.y * _ss)
	print("[capture_in_game] super_sample: window %dx%d -> %dx%d" % [old_size.x, old_size.y, window.size.x, window.size.y])

	# 缩放 camera zoom → Polygon2D 在屏幕上 2x 大
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_2d()
		if cam != null:
			cam.zoom = cam.zoom * float(_ss)
			print("[capture_in_game] super_sample: camera zoom -> %s" % cam.zoom)

	# 更新所有茅草 Polygon2D 的 shader resolution uniform
	for np in crop_node_paths:
		var poly := get_node_or_null(np) as Polygon2D
		if poly == null or poly.material == null:
			continue
		var mat := poly.material as ShaderMaterial
		if mat == null:
			continue
		var old_res := mat.get_shader_parameter("resolution") as Vector2
		if old_res != Vector2.ZERO:
			mat.set_shader_parameter("resolution", old_res * float(_ss))
			print("[capture_in_game] super_sample: %s resolution %s -> %s" % [poly.name, old_res, old_res * float(_ss)])


# 多节点 union AABB 裁剪：计算所有 crop_node 在屏幕空间的世界 AABB，
# 应用 Camera2D 变换后取并集，再加 padding。
func _crop_to_nodes(img: Image, vp: Viewport) -> Image:
	var viewport_size := vp.get_visible_rect().size
	var cam := vp.get_camera_2d()

	var union: Rect2 = Rect2()
	var first := true

	for np in crop_node_paths:
		var node := get_node_or_null(np)
		if node == null:
			push_error("[capture_in_game] 找不到目标节点: %s" % np)
			continue

		var world_pos: Vector2
		var world_size: Vector2

		if node is Sprite2D:
			var sprite := node as Sprite2D
			world_pos = sprite.global_position
			world_size = sprite.texture.get_size() * sprite.scale
		elif node is Polygon2D:
			var poly := node as Polygon2D
			# Polygon2D 的多边形顶点是 local，需要叠加 node 的 global_transform
			var pts := poly.polygon
			if pts.size() < 3:
				continue
			var xform := poly.global_transform
			var bmin := xform * pts[0]
			var bmax := bmin
			for p in pts:
				var wp := xform * p
				bmin = bmin.min(wp)
				bmax = bmax.max(wp)
			world_pos = (bmin + bmax) * 0.5
			world_size = bmax - bmin
		else:
			push_error("[capture_in_game] 不支持的节点类型: %s" % node.get_class())
			continue

		# 世界坐标 -> 屏幕坐标
		var top_left: Vector2
		var size: Vector2
		if cam != null:
			top_left = (world_pos - world_size * 0.5 - cam.global_position) * cam.zoom + viewport_size * 0.5
			size = world_size * cam.zoom
		else:
			top_left = world_pos - world_size * 0.5
			size = world_size

		var rect := Rect2(top_left, size)
		if first:
			union = rect
			first = false
		else:
			union = union.merge(rect)

	if first:
		# 没有有效节点
		return null

	# 加 padding
	union = union.grow(crop_padding)

	# 转 Rect2i
	var ri := Rect2i(int(union.position.x), int(union.position.y), int(union.size.x), int(union.size.y))

	# 边界保护
	if ri.position.x < 0:
		ri.position.x = 0
	if ri.position.y < 0:
		ri.position.y = 0
	if ri.end.x > img.get_width():
		ri.size.x = img.get_width() - ri.position.x
	if ri.end.y > img.get_height():
		ri.size.y = img.get_height() - ri.position.y

	if ri.size.x <= 0 or ri.size.y <= 0:
		push_error("[capture_in_game] 计算出的截图区域无效: %s" % ri)
		return null

	print("[capture_in_game] 裁剪区域: pos=(%d, %d) size=(%d, %d)" % [ri.position.x, ri.position.y, ri.size.x, ri.size.y])
	return img.get_region(ri)


# 把所有 crop_node 的 polygon mask 合到 alpha mask，再用 mask 把非 polygon 区域 alpha 设为 0。
# 保留 polygon 内部像素（已经带茅草颜色），背景变透明。
func _apply_transparent_background(img: Image) -> Image:
	# 必须先转到 RGBA8，否则 set_pixel 设的 alpha=0 会被 save_png 丢弃
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()

	# 1) 算 crop offset = union AABB 的左上角（来自 _crop_to_nodes 的同样算法）
	var vp := get_viewport()
	var viewport_size := vp.get_visible_rect().size
	var cam := vp.get_camera_2d()
	var union: Rect2 = Rect2()
	var first := true
	for np in crop_node_paths:
		var node := get_node_or_null(np)
		if node == null:
			continue
		var world_pos: Vector2
		var world_size: Vector2
		if node is Sprite2D:
			var sprite := node as Sprite2D
			world_pos = sprite.global_position
			world_size = sprite.texture.get_size() * sprite.scale
		elif node is Polygon2D:
			var poly := node as Polygon2D
			var pts := poly.polygon
			var xform := poly.global_transform
			var bmin := xform * pts[0]
			var bmax := bmin
			for p in pts:
				var wp := xform * p
				bmin = bmin.min(wp)
				bmax = bmax.max(wp)
			world_pos = (bmin + bmax) * 0.5
			world_size = bmax - bmin
		else:
			continue
		var tl: Vector2
		var sz: Vector2
		if cam != null:
			tl = (world_pos - world_size * 0.5 - cam.global_position) * cam.zoom + viewport_size * 0.5
			sz = world_size * cam.zoom
		else:
			tl = world_pos - world_size * 0.5
			sz = world_size
		var r := Rect2(tl, sz)
		if first:
			union = r
			first = false
		else:
			union = union.merge(r)
	union = union.grow(crop_padding)
	var crop_off := Vector2(union.position)

	# 2) 画 mask：polygon 内部 alpha=1，外部 alpha=0
	var mask := Image.create(w, h, false, Image.FORMAT_RGBA8)
	mask.fill(Color(0, 0, 0, 0))
	for np in crop_node_paths:
		var node := get_node_or_null(np)
		if node == null:
			continue
		if node is Polygon2D:
			var poly: Polygon2D = node
			var xform := poly.global_transform
			var pts := poly.polygon
			var screen_pts := PackedVector2Array()
			screen_pts.resize(pts.size())
			for i in range(pts.size()):
				var world_p: Vector2 = xform * pts[i]
				var sp: Vector2
				if cam != null:
					sp = (world_p - cam.global_position) * cam.zoom + viewport_size * 0.5
				else:
					sp = world_p
				screen_pts[i] = sp - crop_off
			# Image 没有 fill_polygon：用 scanline 填充（凸多边形 OK；凹多边形需要 earcut 切分）
			_fill_polygon_scanline(mask, screen_pts)
		elif node is Sprite2D:
			var sprite: Sprite2D = node
			var world_pos: Vector2 = sprite.global_position
			var world_size: Vector2 = sprite.texture.get_size() * sprite.scale
			var top_left: Vector2
			if cam != null:
				top_left = (world_pos - world_size * 0.5 - cam.global_position) * cam.zoom + viewport_size * 0.5
			else:
				top_left = world_pos - world_size * 0.5
			top_left -= crop_off
			var rect := Rect2i(int(top_left.x), int(top_left.y),
				int(world_size.x * (cam.zoom.x if cam else 1.0)),
				int(world_size.y * (cam.zoom.y if cam else 1.0)))
			mask.fill_rect(rect, Color(1, 1, 1, 1))

	# 3) 用 mask 把 img 非 polygon 区域 alpha 设为 0
	for y in range(h):
		for x in range(w):
			if mask.get_pixel(x, y).a < 0.5:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	return img


# Scanline 凸多边形填充：把 polygon 内的像素在 mask 上设 alpha=1。
# 简单实现：枚举 polygon 内的点测试，更稳的做法是 scanline。
# 对当前需求（屋顶 polygon 凹多边形也可），采用"逐行扫描 + 边相交"算法。
func _fill_polygon_scanline(mask: Image, pts: PackedVector2Array) -> void:
	var w := mask.get_width()
	var h := mask.get_height()
	if pts.size() < 3:
		return
	# 计算 y 范围
	var y_min_f := pts[0].y
	var y_max_f := pts[0].y
	for p in pts:
		y_min_f = minf(y_min_f, p.y)
		y_max_f = maxf(y_max_f, p.y)
	var y_min := maxi(0, int(floor(y_min_f)))
	var y_max := mini(h - 1, int(ceil(y_max_f)))
	for y in range(y_min, y_max + 1):
		# 收集该行的边交点
		var xs: Array[float] = []
		var n := pts.size()
		for i in range(n):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[(i + 1) % n]
			# 边跨过 y（包含 y == ay 情况）
			if (a.y <= y and b.y > y) or (b.y <= y and a.y > y):
				var t: float = (y - a.y) / (b.y - a.y)
				xs.append(lerpf(a.x, b.x, t))
		xs.sort()
		# 成对填充
		for k in range(0, xs.size() - 1, 2):
			var x_start := maxi(0, int(ceil(xs[k])))
			var x_end := mini(w - 1, int(floor(xs[k + 1])))
			for x in range(x_start, x_end + 1):
				mask.set_pixel(x, y, Color(1, 1, 1, 1))
