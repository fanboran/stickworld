extends Node2D
class_name L3MapRenderer
## L3 大世界渲染器 —— 静态几何缓存（ArrayMesh）+ hover 老 L1 高亮 + 双显示模式
##
## 地图模式（B4，MapModeManager 全局）：TERRAIN 地形底图 / POLITICAL 政权 ID mask
## + LUT 查表上色（R7/R9，改 LUT 即全图换色零重烘），
## 其余显示模式为政治着色层就绪前的回退层。
## 显示模式（模式按钮切换，见 l3_zoom_indicator）：
##   MODE_L1   : 底 = 69 块老 L1 地块（鲜艳配色）
##   MODE_CITY : 底 = 1038 块城市（像 city_preview 花花绿绿）
## hover 恒命中老 L1 索引图（label 直编）；点击下钻仍按 L2（L3MapController 用 L2 索引图）。
## 线条语言（R8 层2 token 化 + feedback1 去抖动 + feedback2 统一几何源 +
## 第三批 C19 界线重设计）：政治模式界线三级——国界（浅色 casing + 深墨主线）+
## 地区界（墨色长虚线）+ 自由城邦界（灰短虚线），**都从 l3_city 城块共享边邻接提取**
## （同一几何源，同一条物理边界只有一条线；旧 region polygon 虚线双源错位退役）；
## 线条平滑直绘（antialiased），共享边端点共点严丝合缝；线宽/色全部走 MapTokens。
## 性能：两级 mesh 加载时一次性烘焙，每帧按模式 draw_mesh。

enum DisplayMode { MODE_L1, MODE_CITY }

var _data: L3WorldData = null
var _camera: MapCamera = null

## 当前地图模式（B4 TERRAIN/POLITICAL，MapModeManager 广播 → 控制器转发）。
## 地形底图层（B2 产 l3_terrain.png）与政权叠加层（Phase F）落地前两模式渲染一致
## （回退现状着色），本字段为届时分层绘制的接入口
var map_mode: int = MapModeManager.Mode.TERRAIN

## 当前显示模式
var display_mode: int = DisplayMode.MODE_L1

## hover 命中的老 L1（Dictionary，未命中为空）
var hovered_l1: Dictionary = {}

## ===== 线条/色彩 token（R8 层2）：真相源在 MapTokens，本文件零色值/线宽字面量 =====
## 非政治模式沿用现状线宽语义（原值迁移）；政治模式界线走三级规范（国/地区）。

## hover 高亮色（交互线槽 = StickTokens.BORDER_STRONG；原黄色系琥珀残留已归位）
const HOVER_COLOR := MapTokens.L3_HOVER_COLOR
## 描边=地图单位绝对粗细（不随缩放；放大超屏幕像素上限时 clamp）
const HOVER_MAP_WIDTH := MapTokens.L3_HOVER_WIDTH
const HOVER_SCREEN_CAP := MapTokens.L3_HOVER_SCREEN_CAP
const L2_BORDER_MAP_WIDTH := MapTokens.L3_REGION_BORDER_WIDTH
const L2_BORDER_SCREEN_CAP := MapTokens.L3_REGION_BORDER_SCREEN_CAP

## 海洋背景色（B2 同源）
const OCEAN_COLOR := MapTokens.L3_OCEAN
## L2 地区常驻描边（非政治模式；政治模式下即"地区界"走界线三级样式）
const L2_BORDER_COLOR := MapTokens.L3_REGION_BORDER_COLOR
## L2 地区编号（F3 调试模式；调试域专色）
const L2_LABEL_COLOR := MapTokens.DEBUG_INK
const L2_LABEL_BG := MapTokens.DEBUG_BG
const L2_LABEL_SIZE := MapTokens.L3_LABEL_SIZE

## 玩家当前所在 L2 地区（全局 label；出生=13 即 region_013，含老 L1 #69）。
## **整个地区**陆地带蓝光流动描边（"你在这里"，粗粒度层级）。
## Phase C 接入玩家跨区移动后改由事件动态更新（现阶段恒出生区）
var player_region_label: int = 13
## 地区描边双色（亮青蓝 ↔ 深蓝，均不透明；色调流动替代透明度闪烁——A3 定标）
const PLAYER_GLOW_A := MapTokens.L3_PLAYER_GLOW_A
const PLAYER_GLOW_B := MapTokens.L3_PLAYER_GLOW_B
const PLAYER_GLOW_MAP_WIDTH := MapTokens.L3_PLAYER_GLOW_WIDTH  # 地图单位固定宽（地区轮廓比地块大一档）
const PLAYER_GLOW_SCREEN_CAP := MapTokens.L3_PLAYER_GLOW_SCREEN_CAP # 极端放大时屏幕像素上限

## 当前所在老 L1 轮廓的等弧长分段缓存（几何不变，重采样一次复用）
var _glow_outlines: Array[PackedVector2Array] = []
## 流动动画相位（秒）
var _glow_time := 0.0

var _l1_mesh: ArrayMesh = null
var _l1_holes_mesh: ArrayMesh = null
var _debug_was_visible: bool = false

## 异步后台加载（8192 PNG 解码不阻塞主线程）：l1_index（hover 查询）+ city_preview（城市模式底图）+ terrain（地形模式底图）
var _l1_index_thread: Thread = null
var _l1_index_result: Image = null
var _city_preview_thread: Thread = null
var _city_preview_result: Image = null
var _terrain_thread: Thread = null
var _terrain_result: Image = null
var _political_thread: Thread = null
var _political_result: Image = null

## 政治模式着色层（R7/R9：政权 ID mask + PoliticalLut 查表 shader，z=-1 垫底，
## 上层 L2 界线/玩家光流/hover 由本节点 _draw 照常画）。null = mask 未解码完
## （POLITICAL 模式回退现状着色）
var _political_layer: Sprite2D = null

## 政治模式界线缓存（R8 层2 建，feedback2 A/C 重构）：全部从城块共享边邻接提取
## （单一几何源）。国界 3px 实线（亮）= 两侧均政权且不同；地区界 2px 长虚线 =
## 两侧地区不同且非国界（与国界互斥 = 同一条物理边界只有一条线）；自由城邦界
## 1px 细灰短虚线 = 恰一侧政权（国 vs 无归属 253，feedback2 A 降级样式，防御类）。
## feedback1 去抖动：平滑直绘，虚线按构建时 zoom 固化成地图单位（烙在地图上），
## 线宽绘制时实时 ÷zoom 保持屏幕恒定
var _national_border_segs := PackedVector2Array()
var _political_region_segs := PackedVector2Array()
var _free_city_border_segs := PackedVector2Array()
var _political_borders_built := false

## 地图标注层（R8 层3）：国名 + 都城星标（§7.3-6 规范表 L3=只画首都星标+国名），
## 子节点随本渲染器被相机缩放；仅 POLITICAL 模式绘制（政治语义，层内自判门控）
var _label_layer: MapLabelLayer = null


func set_data(data: L3WorldData) -> void:
	_data = data
	_build_static_meshes()
	_build_glow_outlines()
	_ensure_l1_index()
	_ensure_terrain()
	_ensure_label_layer()
	queue_redraw()


## 标注层挂载（R8 层3）：懒建子节点 + 喂 L3 国名/都城数据（换数据重复调用即重建）
func _ensure_label_layer() -> void:
	if _label_layer == null:
		_label_layer = MapLabelLayer.new()
		_label_layer.set_camera(_camera)
		add_child(_label_layer)
	_label_layer.setup_l3(_data)


## 设置玩家当前所在 L2 地区（Phase C 动态跟踪入口；变化时重建描边缓存）
func set_player_region(label: int) -> void:
	if label == player_region_label:
		return
	player_region_label = label
	_build_glow_outlines()
	queue_redraw()


## 构建所在 L2 地区的流动描边分段缓存：该地区全部陆地多边形（land_polygons，
## 顶点 [y,x] 或 Vector2，与 _draw_l2_borders 同口径换算）
func _build_glow_outlines() -> void:
	_glow_outlines = []
	if _data == null or player_region_label <= 0:
		return
	for r in _data.regions:
		if int(r.get("label", 0)) != player_region_label:
			continue
		for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
			var pts := PackedVector2Array()
			for pp in poly:
				pts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
			var resampled := FlowOutline.resample_closed(pts)
			if resampled.size() >= 3:
				_glow_outlines.append(resampled)


func get_data() -> L3WorldData:
	return _data


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## 地图模式切换（控制器在 open() 时也推一次当前模式——跨视图全局状态）
func set_map_mode(mode: int) -> void:
	if mode == map_mode:
		return
	map_mode = mode
	if mode == MapModeManager.Mode.POLITICAL:
		_ensure_political()
	if _political_layer != null:
		_political_layer.visible = mode == MapModeManager.Mode.POLITICAL
	queue_redraw()


func refresh() -> void:
	queue_redraw()


## 切换显示模式（L1 <-> 城市），返回新模式
func toggle_display_mode() -> int:
	display_mode = DisplayMode.MODE_CITY if display_mode == DisplayMode.MODE_L1 else DisplayMode.MODE_L1
	queue_redraw()
	return display_mode


func set_display_mode(mode: int) -> void:
	display_mode = mode
	queue_redraw()


func get_mode_name() -> String:
	return "城市" if display_mode == DisplayMode.MODE_CITY else "L1"


## 一次性构建静态网格：老 L1 矢量 mesh（城市模式用栅格贴图，见 _draw）
func _build_static_meshes() -> void:
	_l1_mesh = null
	_l1_holes_mesh = null
	if _data == null:
		return
	var built: Array = _build_layer_mesh(_data.l1_tiles)
	if built[0] != null:
		_l1_mesh = built[0]
	if built[1] != null:
		_l1_holes_mesh = built[1]


## 顶点 2D 数组 → ArrayMesh


func _build_layer_mesh(tiles: Array) -> Array:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var hverts := PackedVector3Array()
	var hcols := PackedColorArray()
	var hindices := PackedInt32Array()
	for t in tiles:
		var col: Array = t.get("color", [])
		var fill := Color(0.6, 0.7, 0.8)
		if col.size() >= 3:
			fill = Color(col[0] / 255.0, col[1] / 255.0, col[2] / 255.0)
		for poly in t.get("polygons", []):
			if poly.size() < 3:
				continue
			var pts2 := PackedVector2Array()
			for p in poly:
				pts2.append(p if p is Vector2 else Vector2(p[1], p[0]))
			var tri := Geometry2D.triangulate_polygon(pts2)
			if tri.is_empty():
				continue
			var base := verts.size()
			for v in pts2:
				verts.append(Vector3(v.x, v.y, 0.0))
				colors.append(fill)
			for idx in tri:
				indices.append(base + idx)
		# 洞
		for hole in t.get("holes", []):
			if hole.size() < 3:
				continue
			var hpts := PackedVector2Array()
			for p in hole:
				hpts.append(p if p is Vector2 else Vector2(p[1], p[0]))
			var htri := Geometry2D.triangulate_polygon(hpts)
			if htri.is_empty():
				continue
			var hb := hverts.size()
			for v in hpts:
				hverts.append(Vector3(v.x, v.y, 0.0))
				hcols.append(OCEAN_COLOR)
			for idx in htri:
				hindices.append(hb + idx)
	var fill_mesh: ArrayMesh = null
	var holes_mesh: ArrayMesh = null
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_COLOR] = colors
		arr[Mesh.ARRAY_INDEX] = indices
		fill_mesh = ArrayMesh.new()
		fill_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if not hverts.is_empty():
		var harr := []
		harr.resize(Mesh.ARRAY_MAX)
		harr[Mesh.ARRAY_VERTEX] = hverts
		harr[Mesh.ARRAY_COLOR] = hcols
		harr[Mesh.ARRAY_INDEX] = hindices
		holes_mesh = ArrayMesh.new()
		holes_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, harr)
	return [fill_mesh, holes_mesh]


func _process(delta: float) -> void:
	_poll_async_loads()
	# 当前位置流动光动画：相位推进 + 每帧重绘（mesh 均为缓存一次性 draw 命令，成本低）
	if visible and not _glow_outlines.is_empty():
		_glow_time += delta
		queue_redraw()
	# feedback1 去抖动：hover/玩家区笔触已回平滑直绘，无 boiling 重掷重绘需求
	if not visible or _data == null:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	# 渲染坐标（8192 级网格）-> 索引图坐标（2048 级查询）；hover 恒老 L1 索引图
	if _data.l1_index_image != null and _data.size > 0:
		mouse_pos *= float(_data.l1_index_image.get_width()) / float(_data.size)
	var query: Dictionary = _data.query_l1_at_map_pos(mouse_pos)
	var l1: Dictionary = query.get("l1", {})
	if int(l1.get("label", -1)) != int(hovered_l1.get("label", -1)):
		hovered_l1 = l1
		queue_redraw()
	# F3 调试模式变化时刷新（L2 编号显隐）
	var debug_now: bool = DebugApi != null and DebugApi.is_visible()
	if debug_now != _debug_was_visible:
		_debug_was_visible = debug_now
		queue_redraw()


## 异步加载：老 L1 索引图（hover 查询用）——8192 PNG 后台线程解码（纯 CPU、线程安全），
## 主线程零阻塞；完成前 query_l1_at_map_pos 因 l1_index_image 为 null 自然返回空（hover 静默）
func _ensure_l1_index() -> void:
	if _data == null or _data.l1_index_image != null or _l1_index_thread != null:
		return
	_l1_index_thread = Thread.new()
	_l1_index_thread.start(_load_l1_index_async)


func _load_l1_index_async() -> void:
	var f := FileAccess.open("res://config/strategic_map/l3_l1_index_8192.png", FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		_l1_index_result = img


## 异步加载：城市模式栅格贴图——切到城市模式首次需要时后台解码（省 ~143ms 阻塞），
## 完成前城市模式短暂无底图（下一帧自动补上）
func _ensure_city_preview() -> void:
	if _data == null or _data.city_preview_texture != null or _city_preview_thread != null:
		return
	_city_preview_thread = Thread.new()
	_city_preview_thread.start(_load_city_preview_async)


func _load_city_preview_async() -> void:
	var f := FileAccess.open("res://config/strategic_map/l3_city_preview_8192.png", FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		_city_preview_result = img


## 异步加载：政治模式政权 ID mask（R7/R9：l3_political_id_8192.png，像素值 =
## 政权 lut_index；切到 POLITICAL 时按需触发， PoliticalLut 查表上色不烘焙）
func _ensure_political() -> void:
	if _data == null or _political_layer != null or _political_thread != null:
		return
	_political_thread = Thread.new()
	_political_thread.start(_load_political_async)


func _load_political_async() -> void:
	var f := FileAccess.open("res://config/strategic_map/l3_political_id_8192.png", FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		# 格式归一 RGBA8（feedback1 掉色修复）：PNG 是单通道 L8，d3d12 渲染后端
		# canvas shader 采样 L8 纹理异常（.r 恒 0 → idx 全 0 → 全图只剩海洋色）。
		# L8→RGBA8 灰度值原样复制进 RGB 通道，R 值逐位不变（保留码 254/255 不受影响）。
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		_political_result = img


## 异步加载：地形模式底图（B2 程序着色 l3_terrain.png，TERRAIN 为默认模式 → set_data 即触发）
func _ensure_terrain() -> void:
	if _data == null or _data.terrain_texture != null or _terrain_thread != null:
		return
	_terrain_thread = Thread.new()
	_terrain_thread.start(_load_terrain_async)


func _load_terrain_async() -> void:
	var f := FileAccess.open("res://config/strategic_map/l3_terrain.png", FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		_terrain_result = img


## 节点退出前 join 全部后台线程——未完成的 Thread 直接销毁在 Windows 上会段错误
func _exit_tree() -> void:
	if _l1_index_thread != null:
		_l1_index_thread.wait_to_finish()
		_l1_index_thread = null
	if _city_preview_thread != null:
		_city_preview_thread.wait_to_finish()
		_city_preview_thread = null
	if _terrain_thread != null:
		_terrain_thread.wait_to_finish()
		_terrain_thread = null
	if _political_thread != null:
		_political_thread.wait_to_finish()
		_political_thread = null


## 每帧检查后台线程：解码完成 → wait_to_finish + 取结果（ImageTexture 需主线程创建）
func _poll_async_loads() -> void:
	if _data == null:
		return
	if _l1_index_thread != null and not _l1_index_thread.is_alive():
		_l1_index_thread.wait_to_finish()
		_l1_index_thread = null
		if _l1_index_result != null:
			_data.l1_index_image = _l1_index_result
			_l1_index_result = null
	if _city_preview_thread != null and not _city_preview_thread.is_alive():
		_city_preview_thread.wait_to_finish()
		_city_preview_thread = null
		if _city_preview_result != null:
			_data.city_preview_texture = ImageTexture.create_from_image(_city_preview_result)
			_city_preview_result = null
			queue_redraw()
	if _terrain_thread != null and not _terrain_thread.is_alive():
		_terrain_thread.wait_to_finish()
		_terrain_thread = null
		if _terrain_result != null:
			_data.terrain_texture = ImageTexture.create_from_image(_terrain_result)
			_terrain_result = null
			queue_redraw()
	if _political_thread != null and not _political_thread.is_alive():
		_political_thread.wait_to_finish()
		_political_thread = null
		if _political_result != null:
			_data.political_id_image = _political_result
			_political_result = null
			_build_political_layer()
			queue_redraw()


## 构建政治模式着色层：ID mask 纹理 + 共享 PoliticalLut 的查表 shader（z=-1 垫底）。
## 颜色不进纹理——改 LUT（PoliticalLut.set_state_color）即全图即时换色，零重烘。
func _build_political_layer() -> void:
	if _political_layer != null or _data == null or _data.political_id_image == null:
		return
	var lut := PoliticalLut.shared_from_states(_data.states)
	if lut == null:
		return
	var mask_tex := ImageTexture.create_from_image(_data.political_id_image)
	var mat := ShaderMaterial.new()
	mat.shader = PoliticalLut.COLORIZE_SHADER
	mat.set_shader_parameter("id_mask", mask_tex)
	mat.set_shader_parameter("lut", lut.texture)
	_political_layer = Sprite2D.new()
	_political_layer.texture = mask_tex
	_political_layer.centered = false
	_political_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_political_layer.material = mat
	# z=-1（相对）：垫在本节点 _draw 的界线/光流/hover 之下、替代海洋底色
	_political_layer.z_index = -1
	_political_layer.visible = map_mode == MapModeManager.Mode.POLITICAL
	add_child(_political_layer)


func _draw() -> void:
	if _data == null:
		return
	# 政治模式且着色层就绪：ID mask shader 层（z=-1）已垫底铺满全图（含海洋色
	# 空区），本节点只画上层矢量；未就绪时照常画海洋底 + 回退现状着色
	var political_ready := map_mode == MapModeManager.Mode.POLITICAL 			and _political_layer != null
	if not political_ready:
		# 1. 海洋背景
		draw_rect(Rect2(Vector2.ZERO, Vector2(float(_data.size), float(_data.size))), OCEAN_COLOR)
	if map_mode == MapModeManager.Mode.TERRAIN and _data.terrain_texture != null:
		# 地形模式（B2）：程序着色底图铺满全图（2048 纹理拉伸到 8192 网格，与 city_preview 同法）；
		# 异步加载完成前回退现状填充层，解码完成后 queue_redraw 自动切上
		draw_texture_rect(_data.terrain_texture,
			Rect2(Vector2.ZERO, Vector2(float(_data.size), float(_data.size))), false)
	elif political_ready:
		pass  # 政治模式（R7/R9）：政权 ID mask + LUT 查表层已垫底，此处只画上层矢量
	elif map_mode == MapModeManager.Mode.POLITICAL:
		_ensure_political()
		if display_mode == DisplayMode.MODE_CITY:
			_ensure_city_preview()
			if _data.city_preview_texture != null:
				draw_texture_rect(_data.city_preview_texture,
					Rect2(Vector2.ZERO, Vector2(float(_data.size), float(_data.size))), false)
		else:
			if _l1_mesh != null:
				draw_mesh(_l1_mesh, null)
			if _l1_holes_mesh != null:
				draw_mesh(_l1_holes_mesh, null)
	elif display_mode == DisplayMode.MODE_CITY:
		# 城市模式：直接贴 city_preview 栅格图（花花绿绿、零剖分、快）
		_ensure_city_preview()
		if _data.city_preview_texture != null:
			draw_texture_rect(_data.city_preview_texture,
				Rect2(Vector2.ZERO, Vector2(float(_data.size), float(_data.size))), false)
		# 城市贴图像素是 2048 级，L2 边界/ hover 坐标在 8192 级 → 贴图拉伸到 8192 自带对齐
	else:
		# 2. 老 L1 模式：矢量 mesh
		if _l1_mesh != null:
			draw_mesh(_l1_mesh, null)
		if _l1_holes_mesh != null:
			draw_mesh(_l1_holes_mesh, null)
	# 3. 界线（R8 层2 分级 + feedback2 统一几何源）：政治模式 = 国界 3px 实线（亮）
	#    + 地区界 2px 长虚线 + 自由城邦界 1px 细灰短虚线（§7.3-6 规范表，城块邻接
	#    同源提取）；其他模式 = L2 地区常驻描边（现状语义）
	if political_ready:
		_draw_political_borders()
	else:
		_draw_l2_borders()
	# 3.5 玩家当前所在 L2 地区：整区蓝光流动描边（"你在这里"）。
	#     FlowOutline 流动语义保留（feedback1 去抖动：平滑轮廓直绘）
	if not _glow_outlines.is_empty():
		var gw := PLAYER_GLOW_MAP_WIDTH
		if _camera != null and _camera.has_method("get_zoom"):
			var gz: float = _camera.get_zoom()
			if gz > 0.0001:
				gw = minf(PLAYER_GLOW_MAP_WIDTH, PLAYER_GLOW_SCREEN_CAP / gz)
		for outline in _glow_outlines:
			FlowOutline.draw_flow(self, outline, PLAYER_GLOW_A, PLAYER_GLOW_B, _glow_time, gw)
	# 4. hover 老 L1 高亮（黄线轮廓）
	_draw_hover_l1()
	# 5. L2 地区编号（F3 调试模式）
	if DebugApi != null and DebugApi.is_visible():
		_draw_l2_labels()


func _draw_l2_borders() -> void:
	var bw := BORDER_WIDTH()
	for r in _data.regions:
		for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
			if poly.size() < 3:
				continue
			var bpts := PackedVector2Array()
			for pp in poly:
				bpts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
			bpts.append(bpts[0])
			draw_polyline(bpts, L2_BORDER_COLOR, bw, true)


## 政治模式界线三级绘制（第三批 C19 重设计）：**国界 = 浅色底衬 casing + 深墨主线**，
## 地区界 = 墨色长虚线，自由城邦界 = 灰色短虚线（全部屏幕像素口径恒定粗细）。
## 三类都由城块邻接提取（单一几何源，feedback2 A/C）；平滑直绘（feedback1 去抖动）。
## 绘制次序 = 语义层级倒序（低级先画、国界最后压顶）：地区界 → 自由城邦界 →
## 国界底衬 → 国界主线（底衬必须紧贴主线之下，中间不能被别的线插队）。
func _draw_political_borders() -> void:
	if not _political_borders_built:
		_build_political_borders()
	var zz := 1.0
	if _camera != null and _camera.has_method("get_zoom"):
		zz = _camera.get_zoom()
	if zz <= 0.0001:
		zz = 1.0
	if _political_region_segs.size() >= 2:
		draw_multiline(_political_region_segs, MapTokens.LINE_REGION_COLOR,
			MapTokens.LINE_REGION / zz, true)
	if _free_city_border_segs.size() >= 2:
		draw_multiline(_free_city_border_segs, MapTokens.LINE_FREE_COLOR,
			MapTokens.LINE_FREE / zz, true)
	if _national_border_segs.size() >= 2:
		# 底衬（暖白半透明）→ 主线（墨）；底衬宽 = 主线宽 + CASING_EXTRA
		draw_multiline(_national_border_segs, MapTokens.LINE_NATIONAL_CASING_COLOR,
			(MapTokens.LINE_NATIONAL + MapTokens.LINE_NATIONAL_CASING_EXTRA) / zz, true)
		draw_multiline(_national_border_segs, MapTokens.LINE_NATIONAL_COLOR,
			MapTokens.LINE_NATIONAL / zz, true)


## 构建政治模式界线缓存（首次政治绘制一次）——几何取城块多边形边，
## **「是不是界」由政权 ID mask 判定**（C19 修正）：
## 旧口径用「城块共享边无向 key 精确配对」，但 l3_city 的城块多边形是**各自独立
## 平滑**出来的——实测 34433 条边里只有 2192 条（6%）能在两侧找到同一 key，
## 于是国界只画出一小撮短线段、地区界虚线断成散落的短划（观感缺陷根源）。
## 新口径（mask 是颜色的唯一真相源：颜色在哪变，界就在哪）：
##   从每条边中点沿**外法向**探针 4px 采样 mask 像素值（= lut_index）：
##     外侧是另一政权 → 国界（实线 + 底衬）
##     恰一侧是 253 自由城邦 → 自由城邦界（细灰短虚线，防御类）
##     外侧同政权 → 查 2048 地区划分图：地区不同 → 地区界（墨色长虚线）
##     外侧 0 海洋 / 254 湖泊 → 海岸线/湖岸，本层不画
## 同一条物理界两侧各出一条近乎重合的边（两侧多边形互有 ~1-3px 平滑差）→
## 中点空间哈希**仅跨城块**去重（同城块内相邻短边绝不去重，否则界线断口）。
func _build_political_borders() -> void:
	_political_borders_built = true
	_national_border_segs = PackedVector2Array()
	_political_region_segs = PackedVector2Array()
	_free_city_border_segs = PackedVector2Array()
	if _data == null or _data.political_id_image == null:
		return
	var zz := 1.0
	if _camera != null and _camera.has_method("get_zoom"):
		zz = _camera.get_zoom()
	if zz <= 0.0001:
		zz = 1.0
	var mask: Image = _data.political_id_image
	var part: Image = _data.mask_image          # 2048 地区划分（像素 = 地区 label）
	var part_scale := 1.0
	if part != null and _data.size > 0:
		part_scale = float(part.get_width()) / float(_data.size)
	var lut_of := {}
	for sid in _data.states:
		lut_of[sid] = int((_data.states[sid] as Dictionary).get("lut_index", 0))
	# 中点空间哈希（跨城块去重）：bucket key -> 已登记城块 label
	var weld := {}
	for t in _data.city_tiles:
		var sid := str(t.get("state_id", ""))
		var self_idx := int(lut_of.get(sid, 0))
		var self_rg := int(t.get("region", 0))
		var label := int(t.get("label", 0))
		for poly in (t.get("polygons", []) as Array):
			var n: int = poly.size()
			if n < 3:
				continue
			var pts := PackedVector2Array()
			pts.resize(n)
			var cx := 0.0
			var cy := 0.0
			for i in n:
				var pp = poly[i]
				pts[i] = pp if pp is Vector2 else Vector2(pp[1], pp[0])
				cx += pts[i].x
				cy += pts[i].y
			var centroid := Vector2(cx / float(n), cy / float(n))
			for i in n:
				var a := pts[i]
				var b := pts[(i + 1) % n]
				var mid := (a + b) * 0.5
				var outward := mid - centroid
				if outward.length_squared() < 0.0001:
					continue
				var probe := mid + outward.normalized() * MapTokens.BORDER_PROBE_DIST
				if _weld_seen(weld, mid, label):
					continue
				var idx_out := _mask_code(mask, probe)
				if idx_out == self_idx:
					# 同国：看是不是地区界（2048 划分图）
					if part != null and self_rg > 0:
						var rg_out := _mask_code(part, probe * part_scale)
						if rg_out > 0 and rg_out != self_rg:
							_weld_mark(weld, mid, label)
							MapSketch.dash_segments(_political_region_segs,
								PackedVector2Array([a, b]),
								MapTokens.DASH_LONG / zz, MapTokens.DASH_LONG_GAP / zz)
					continue
				if idx_out <= 0 or idx_out == PoliticalLut.CODE_LAKE \
						or idx_out == PoliticalLut.CODE_NEIGHBOR:
					continue  # 海岸/湖岸：非政权界
				_weld_mark(weld, mid, label)
				if idx_out == PoliticalLut.CODE_FREE_CITY \
						or self_idx == PoliticalLut.CODE_FREE_CITY:
					MapSketch.dash_segments(_free_city_border_segs,
						PackedVector2Array([a, b]),
						MapTokens.DASH_SHORT / zz, MapTokens.DASH_SHORT_GAP / zz)
				else:
					_national_border_segs.append(a)
					_national_border_segs.append(b)


## mask/划分图像素值（R 通道 × 255；clamp 到图内）
func _mask_code(img: Image, p: Vector2) -> int:
	if img == null:
		return 0
	var x := clampi(roundi(p.x), 0, img.get_width() - 1)
	var y := clampi(roundi(p.y), 0, img.get_height() - 1)
	return roundi(img.get_pixel(x, y).r * 255.0)


## 中点是否已被**别的城块**登记过（同城块返回 false——同块内相邻短边不能去重）
func _weld_seen(weld: Dictionary, mid: Vector2, label: int) -> bool:
	var gx := roundi(mid.x / MapTokens.BORDER_WELD_GRID)
	var gy := roundi(mid.y / MapTokens.BORDER_WELD_GRID)
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var got: Variant = weld.get("%d,%d" % [gx + dx, gy + dy], null)
			if got != null and int(got) != label:
				return true
	return false


func _weld_mark(weld: Dictionary, mid: Vector2, label: int) -> void:
	var gx := roundi(mid.x / MapTokens.BORDER_WELD_GRID)
	var gy := roundi(mid.y / MapTokens.BORDER_WELD_GRID)
	weld["%d,%d" % [gx, gy]] = label


func BORDER_WIDTH() -> float:
	# 地图固定宽 9；放大超 16 屏像素时 clamp（极端放大防糊屏）
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			return minf(L2_BORDER_MAP_WIDTH, L2_BORDER_SCREEN_CAP / z)
	return L2_BORDER_MAP_WIDTH


func _draw_hover_l1() -> void:
	if hovered_l1.is_empty():
		return
	var hpolys: Array = hovered_l1.get("polygons", [])
	var hw := HOVER_MAP_WIDTH
	if _camera != null and _camera.has_method("get_zoom"):
		var z: float = _camera.get_zoom()
		if z > 0.0001:
			hw = minf(HOVER_MAP_WIDTH, HOVER_SCREEN_CAP / z)
	# feedback1 去抖动：hover 平滑闭合直绘
	for hp in hpolys:
		if hp.size() < 3:
			continue
		var hpts := PackedVector2Array()
		for pp in hp:
			hpts.append(pp if pp is Vector2 else Vector2(pp[1], pp[0]))
		hpts.append(hpts[0])
		draw_polyline(hpts, HOVER_COLOR, hw, true)


## F3 调试：给每个 L2 地区打编号（地区质心；centroid 2048 级 × size/mask 比例）。
## 字体归正（R8 层3）：StickHand 与全游戏 UI 同源，不用 fallback 字体
func _draw_l2_labels() -> void:
	var font := SketchFonts.hand()
	if font == null:
		return
	var scale := 1.0
	if _data.size > 0 and _data.mask_image != null:
		scale = float(_data.size) / float(_data.mask_image.get_width())
	for r in _data.regions:
		var label: int = int(r.get("label", 0))
		if label <= 0:
			continue
		var c: Array = r.get("centroid", [0, 0])
		if c.size() < 2:
			continue
		var pos := Vector2(float(c[0]), float(c[1])) * scale
		var txt := "L2#%d" % label
		draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, L2_LABEL_SIZE, 2, L2_LABEL_BG)
		draw_string(font, pos + Vector2(4.0, -L2_LABEL_SIZE * 0.3), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, L2_LABEL_SIZE, L2_LABEL_COLOR)