extends Node2D
class_name MapRenderer
## 战略图渲染器（L1 单层，Tab 键）—— 与 L2 同款分层矢量绘制
##
## 数据来自 l1_world.json（含 context_size/neighbors/lakes，坐标 = context 局部）。
## 全部矢量绘制（地块少），任意缩放清晰，不依赖底图纹理。
## 分层（context 坐标系，含邻居老 L1 块扩展区域，与 L2MapRenderer 一致）：
##   海洋背景 -> 湖泊(浅蓝) -> 当前 L1 城市块(政权色) -> 邻居老 L1 块(灰色空心描边)
##   -> 城市描边 + 出生 L1 权威轮廓(深色) -> hover 描边(灰) -> 内容区纸边黑框
##   -> F3 地块编号
## 邻居块空心化（A3）：只描边不填充，聚焦本 L1；context 外缘画黑线"纸张边界"。
##
## 交互：hover 命中城市块（经相机换算 + 索引图查询），点击选中由控制器经 api 处理。

## 关联的 L1 世界数据
var _data: L1WorldData = null

## 当前地图模式（B4 TERRAIN/POLITICAL，MapModeManager 广播 → 控制器转发）。
## 地形底图层（B2 产 PNG）与政权叠加层（Phase F）落地前两模式渲染一致（回退现状着色），
## 本字段为届时分层绘制的接入口
var map_mode: int = MapModeManager.Mode.TERRAIN

## 相机引用（悬停检测做 screen->map 坐标换算）
var _camera: MapCamera = null

## 当前悬停的地块 ID（""=无）
var hovered_tile_id: String = ""

## 性能缓存：城市描边段 + 出生 L1 轮廓 + 邻居空心轮廓（不随 zoom/hover 变化，set_data 后首帧构建一次复用）。
## 原实现每帧重建描边段并对每段遍历湖全部边做距离计算（4668 段 × 湖边数 ≈ 百万级），
## hover 每帧触发 → 卡顿源；缓存后 hover 重绘 = 1 次 draw_multiline。
var _cached_segs: PackedVector2Array = PackedVector2Array()
## 出生 L1 权威轮廓（主大陆单环，闭合；export 已保证 l1_polygon 只含最大环）
var _cached_l1_closed: PackedVector2Array = PackedVector2Array()
## 邻居老 L1 块空心轮廓（每块一条闭合折线，A3 空心化）
var _cached_neighbor_outlines: Array[PackedVector2Array] = []
var _segs_valid: bool = false

## 静态色块层 ArrayMesh（海洋+湖泊+城市色块，set_data 后烘焙一次；描边/轮廓/hover 仍动态）。
## Geometry2D.triangulate_polygon 一次三角剖分 → 每帧 1 次 draw_mesh，免每帧 earcut（8 城 4750 点 + 湖）。
var _base_mesh: ArrayMesh = null

## 配色（与 L2MapRenderer 完全一致）
const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)
const LAKE_COLOR := Color(28.0 / 255.0, 50.0 / 255.0, 82.0 / 255.0)
## 邻居老 L1 块（A3 空心化：灰色轮廓线，不填充）
const NEIGHBOR_COLOR := Color(0.45, 0.45, 0.45)
const NEIGHBOR_BORDER_WIDTH := 2.0
## 内容区"纸张边界"黑框（context 外缘，A3）
const PAPER_BORDER_COLOR := Color(0.08, 0.08, 0.08)
const PAPER_BORDER_WIDTH := 4.0
## 城市常驻描边（内部城界；屏幕像素固定、细，不随缩放变化——避免缩放时粗细跳变）
const TILE_BORDER_COLOR := Color(0.35, 0.35, 0.35)
const TILE_BORDER_WIDTH := 2.0
## 出生 L1 轮廓 / 邻居分界（屏幕像素固定，略粗区分出生块边界）
const BORDER_COLOR := Color(0.25, 0.25, 0.25)
const BORDER_WIDTH := 2.5
## hover 描边（屏幕像素固定）
const HOVER_COLOR := Color(0.55, 0.55, 0.55)
const HOVER_WIDTH := 3.0
## 城市中心标记点（小圆点 + 细环，屏幕像素固定；画在聚落位置，指示城市中心）
const CITY_DOT_RADIUS := 3.0
const CITY_DOT_RING_WIDTH := 1.0
const CITY_DOT_COLOR := Color(0.95, 0.95, 0.9)
const CITY_DOT_RING := Color(0.12, 0.12, 0.12)
## F3 调试：城市编号
const LABEL_COLOR := Color(1.0, 0.9, 0.3, 0.95)
const LABEL_BG := Color(0.0, 0.0, 0.0, 0.75)
## F3 城市编号字号（地图单元，原生渲染）：8192 级 context 城市约 180 地图单元，
## 30 号在默认整图适配（zoom≈0.77）下约 23px 屏幕，字号随地图缩放（原生行为）
const LABEL_SIZE := 30.0
## F3 城市编号屏幕上限（像素）：仅高缩放时封顶防"雷霆大字"，默认缩放不受影响
const LABEL_SCREEN_CAP := 40.0

# 玩家图钉（F2/C1，总体设计 §5.6：琥珀色图钉，唯一允许的图标类美术——此处程序化绘制）
const PIN_COLOR := Color(1.0, 0.72, 0.11)
const PIN_OUTLINE := Color(0.25, 0.15, 0.02)
const PIN_HEAD_RADIUS := 11.0
const PIN_TAIL_LEN := 20.0
const PIN_LABEL := "你在这里"
const PIN_LABEL_SIZE := 22.0

## 玩家图钉（L1 地图坐标；默认 = 出生聚落，api.set_player_map 动态更新）
var _pin_pos := Vector2.ZERO
var _pin_visible := false

var _debug_was_visible: bool = false

## 当前所在城市地块蓝光流动描边（"你在这里"，细粒度层级）：
## 含玩家当前聚落的地块（出生 = spawn 聚落所在块）。Phase C 玩家跨城移动后经
## set_current_tile 动态更新（现阶段恒出生块）。双色不透明，与 M 大世界同视觉语言
var _current_tile_id: String = ""
const GLOW_A := Color(0.35, 0.85, 1.0)
const GLOW_B := Color(0.15, 0.45, 0.95)
## 描边宽（屏幕像素固定，与其他描边一致策略）
const GLOW_WIDTH := 4.0
## 当前地块轮廓分段缓存（几何不变，重采样一次复用）
var _glow_outline: PackedVector2Array = PackedVector2Array()
## 流动动画相位（秒）
var _glow_time := 0.0


func set_data(data: L1WorldData) -> void:
	_data = data
	_segs_valid = false
	_base_mesh = null
	_current_tile_id = ""
	# 当前所在地块默认 = 出生聚落所在块（玩家跨城移动后由 set_current_tile 切换）
	if _data != null and not _data.spawn_settlement_id.is_empty():
		for tile in _data.tiles:
			if tile.settlement != null \
					and tile.settlement.settlement_id == _data.spawn_settlement_id:
				_current_tile_id = tile.tile_id
				# 图钉默认锚出生聚落（F2/C1；api.set_player_map 动态更新）
				_pin_pos = tile.settlement.position
				_pin_visible = true
				break
	_build_glow_outline()
	queue_redraw()


## 设置玩家当前所在地块（Phase C 动态跟踪入口；未知 id 忽略）
func set_current_tile(tile_id: String) -> void:
	if tile_id == _current_tile_id:
		return
	for tile in _data.tiles:
		if tile.tile_id == tile_id:
			_current_tile_id = tile_id
			_build_glow_outline()
			queue_redraw()
			return


## 构建当前地块流动描边分段缓存
func _build_glow_outline() -> void:
	_glow_outline = PackedVector2Array()
	if _data == null or _current_tile_id.is_empty():
		return
	for tile in _data.tiles:
		if tile.tile_id == _current_tile_id and tile.polygon.size() >= 3:
			_glow_outline = FlowOutline.resample_closed(tile.polygon)
			return


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## 地图模式切换（控制器在 open() 时也推一次当前模式——跨视图全局状态）
func set_map_mode(mode: int) -> void:
	if mode == map_mode:
		return
	map_mode = mode
	queue_redraw()


## 接口保留（api.select 调用）；选中高亮交给 hover/控制器
func select(_id: String) -> void:
	queue_redraw()


func deselect() -> void:
	queue_redraw()


func get_selected() -> String:
	return ""


## 查询地块质心（相机聚焦用；未知 id 返回 null）
func get_tile_centroid(id: String) -> Variant:
	if _data == null:
		return null
	for t in _data.tiles:
		if t.tile_id == id:
			return t.get_centroid()
	return null


func refresh() -> void:
	queue_redraw()


func _process(delta: float) -> void:
	if not is_visible_in_tree() or _data == null:
		return
	# 当前地块流动光动画：相位推进 + 每帧重绘（静态层均缓存，成本低）
	if not _glow_outline.is_empty():
		_glow_time += delta
		queue_redraw()
	# 屏幕坐标 -> 地图坐标（一次换算，与 api.query_at_screen 同路径；
	# 不能用 get_global_mouse_position——它已按节点 transform 逆变换过，再换算会双重扭曲）
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	if _camera != null and _camera.has_method("screen_to_map"):
		mouse_pos = _camera.screen_to_map(mouse_pos)
	var query: Dictionary = _data.query_at_map_pos(mouse_pos)
	var tile: L1TileDef = query.get("tile", null)
	var new_tile_id: String = tile.tile_id if tile != null else ""
	if new_tile_id != hovered_tile_id:
		hovered_tile_id = new_tile_id
		queue_redraw()
	# F3 调试模式变化时刷新（城市编号显隐）
	var debug_now: bool = DebugApi != null and DebugApi.is_visible()
	if debug_now != _debug_was_visible:
		_debug_was_visible = debug_now
		queue_redraw()


func _draw() -> void:
	if _data == null:
		return
	var ctx := _data.context_size
	var ctx_size := Vector2(float(ctx.x), float(ctx.y))
	if ctx_size.x <= 0.0:
		ctx_size = Vector2(float(_data.size), float(_data.size))
	var zz: float = 1.0
	if _camera != null and _camera.has_method("get_zoom"):
		zz = _camera.get_zoom()
	# 1. 静态色块层（海洋+湖泊+城市色块 → 单张 ArrayMesh，描边/轮廓/hover 仍动态画）
	if _base_mesh == null:
		_bake_base_mesh()
	if _base_mesh != null:
		draw_mesh(_base_mesh, null)
	else:
		# 回退：数据异常时逐层绘制（邻居空心：只描边，见第 4.5 层）
		draw_rect(Rect2(Vector2.ZERO, ctx_size), OCEAN_COLOR)
		for lake in _data.lakes:
			if (lake as Array).size() >= 3:
				draw_colored_polygon(_pts(lake), LAKE_COLOR)
		for tile in _data.tiles:
			if tile.polygon.size() < 3:
				continue
			draw_colored_polygon(tile.polygon, _data.get_state_color(tile.owner_state_id))
	# 静态几何缓存（城市描边段/出生轮廓/邻居空心轮廓，首帧构建一次复用）
	if not _segs_valid:
		_build_cached_geometry()
	# 4.5 邻居老 L1 块空心描边（A3：只描边不填充；屏幕像素固定）
	var nbw: float = NEIGHBOR_BORDER_WIDTH
	if zz > 0.0001:
		nbw = NEIGHBOR_BORDER_WIDTH / zz
	for outline in _cached_neighbor_outlines:
		draw_polyline(outline, NEIGHBOR_COLOR, nbw, true)
	# 5. 城市描边：屏幕像素固定（不随缩放，避免粗细跳变）；跳过"地块-湖泊"边（湖泊一圈不描边）。
	#    描边段不随 zoom/hover 变化 → 缓存复用（原每帧重建 = 4668 段 × 湖边数 距离计算，hover 卡顿源）
	var tw: float = TILE_BORDER_WIDTH
	if zz > 0.0001:
		tw = TILE_BORDER_WIDTH / zz
	if _cached_segs.size() >= 2:
		draw_multiline(_cached_segs, TILE_BORDER_COLOR, tw, true)
	# 6. 出生 L1 权威轮廓（屏幕像素固定，略粗区分出生块；邻居分界同理）
	var bw: float = BORDER_WIDTH
	if zz > 0.0001:
		bw = BORDER_WIDTH / zz
	if _cached_l1_closed.size() >= 3:
		draw_polyline(_cached_l1_closed, BORDER_COLOR, bw, true)
	# 6.5 城市中心标记点（小圆点 + 细环，屏幕像素固定——半径和环宽都随缩放换算成地图单位，
	# 放大环不遮白点、缩小环不消失；粗细保持屏幕一致）
	var dot_r: float = CITY_DOT_RADIUS
	var ring_w: float = CITY_DOT_RING_WIDTH
	if zz > 0.0001:
		dot_r = CITY_DOT_RADIUS / zz
		ring_w = CITY_DOT_RING_WIDTH / zz
	for tile in _data.tiles:
		if tile.settlement == null:
			continue
		draw_circle(tile.settlement.position, dot_r, CITY_DOT_COLOR)
		draw_arc(tile.settlement.position, dot_r, 0.0, TAU, 48, CITY_DOT_RING, ring_w, true)
	# 7. hover 城市块描边（屏幕像素固定）
	if not hovered_tile_id.is_empty():
		var hw: float = HOVER_WIDTH
		if zz > 0.0001:
			hw = HOVER_WIDTH / zz
		for tile in _data.tiles:
			if tile.tile_id == hovered_tile_id and tile.polygon.size() >= 3:
				draw_polyline(_closed(tile.polygon), HOVER_COLOR, hw, true)
				break
	# 7.5 当前所在城市地块：蓝光流动描边（"你在这里"；屏幕像素固定，画在纸边框内）
	if _glow_outline.size() >= 3:
		var gwid: float = GLOW_WIDTH
		if zz > 0.0001:
			gwid = GLOW_WIDTH / zz
		FlowOutline.draw_flow(self, _glow_outline, GLOW_A, GLOW_B, _glow_time, gwid)
	# 7.8 内容区"纸张边界"黑框（context 外缘，A3；压住贴边内容 = 装裱观感，屏幕像素固定）
	var pw: float = PAPER_BORDER_WIDTH
	if zz > 0.0001:
		pw = PAPER_BORDER_WIDTH / zz
	draw_rect(Rect2(Vector2.ZERO, ctx_size), PAPER_BORDER_COLOR, false, pw)
	# 8. F3 调试：城市编号（标在聚落位置）
	if DebugApi != null and DebugApi.is_visible():
		_draw_city_labels()
	# 9. 玩家图钉（F2/C1：琥珀色图钉 + 「你在这里」标注，画在最上层）
	if _pin_visible:
		_draw_player_pin(zz)


## 闭合多边形点列（首尾相连）
func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var out := pts.duplicate()
	out.append(out[0])
	return out


## 设置玩家图钉位置（L1 地图坐标 = 所在聚落 position_px；api.set_player_map 接线）
func set_player_pin(map_pos: Vector2) -> void:
	_pin_pos = map_pos
	_pin_visible = true
	queue_redraw()


## 隐藏玩家图钉（玩家当前不在本 L1 的任何聚落时）
func clear_player_pin() -> void:
	if not _pin_visible:
		return
	_pin_visible = false
	queue_redraw()


## 琥珀色图钉：圆头 + 尾针 + 白点 + 「你在这里」标注（总体设计 §5.6；
## 程序化绘制，属"仅 UI 标记"豁免，不引素材）
func _draw_player_pin(zz: float) -> void:
	var head_r: float = PIN_HEAD_RADIUS
	var tail_len: float = PIN_TAIL_LEN
	if zz > 0.0001:
		head_r = PIN_HEAD_RADIUS / zz
		tail_len = PIN_TAIL_LEN / zz
	var tail_tip := _pin_pos + Vector2(0.0, tail_len)
	# 尾针（三角）
	draw_colored_polygon(PackedVector2Array([
		_pin_pos + Vector2(-head_r * 0.45, 0.0),
		_pin_pos + Vector2(head_r * 0.45, 0.0),
		tail_tip,
	]), PIN_COLOR)
	# 圆头 + 深色描边 + 白点
	draw_circle(_pin_pos, head_r, PIN_COLOR)
	draw_arc(_pin_pos, head_r, 0.0, TAU, 48, PIN_OUTLINE, maxf(1.0, head_r * 0.22), true)
	draw_circle(_pin_pos, head_r * 0.38, Color.WHITE)
	# 「你在这里」标注（尾针下方，屏幕字号封顶同城市标签口径）
	var font := ThemeDB.fallback_font
	var fs: float = PIN_LABEL_SIZE
	if zz > 0.0001:
		fs = minf(PIN_LABEL_SIZE, LABEL_SCREEN_CAP / zz)
	var txt_pos := tail_tip + Vector2(0.0, fs * 0.9)
	var halo: float = maxf(1.5, fs * 0.12)
	for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		draw_string(font, txt_pos + off * halo, PIN_LABEL, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, LABEL_BG)
	draw_string(font, txt_pos, PIN_LABEL, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, PIN_COLOR)


## 邻湖判定容差（地图单元）：边中点距湖多边形 ≤ 该值视为"地块-湖泊"边界不描边。
## 8192 级 context 下沿湖边 ~0-10、最近非湖边 ~10.1，取 context 1%（798≈8）安全。
func _lake_edge_tol() -> float:
	var tol := 4.0
	if _data.context_size.x > 0:
		tol = _data.context_size.x * 0.01
	return tol


## 烘焙静态色块层：海洋(矩形)/湖泊/城市色块 → 单张 ArrayMesh（顶点色，三角形独立顶点）。
## Geometry2D.triangulate_polygon 一次性 earcut（C++，含凹多边形），仅 set_data / 首帧调用一次。
## 邻居老 L1 块不参与（A3 空心化：只描边不填充，轮廓走 _build_cached_geometry 缓存）。
func _bake_base_mesh() -> void:
	_base_mesh = null
	var ctx := _data.context_size
	if ctx.x <= 0 or ctx.y <= 0:
		return
	# 收集 (多边形, 颜色)：顺序 = 原绘制顺序（湖泊最后画，盖城市色块——
	# 湖泊弧线与城市块交界处由湖弧线决定，严丝合缝无缝隙；export 已裁剪城市块不覆盖湖）
	var pairs: Array = []  # [[PackedVector2Array, Color], ...]
	# 海洋 = 全矩形底
	for tile in _data.tiles:
		if tile.polygon.size() >= 3:
			pairs.append([tile.polygon, _data.get_state_color(tile.owner_state_id)])
	for lake in _data.lakes:
		pairs.append([_pts(lake), LAKE_COLOR])
	# 三角剖分 + 顶点色（每三角形独立顶点，避免共享顶点颜色冲突）
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	for pair in pairs:
		var pts: PackedVector2Array = pair[0]
		if pts.size() < 3:
			continue
		var tris := Geometry2D.triangulate_polygon(pts)
		if tris.is_empty():
			continue
		for i in range(0, tris.size(), 3):
			for k in range(3):
				verts.append(pts[tris[i + k]])
				cols.append(pair[1])
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_base_mesh = mesh


## 构建不随 zoom/hover 变化的静态几何缓存：城市描边段（跳过邻湖边）+ 出生 L1 轮廓
## + 邻居空心轮廓（A3）。仅 set_data / 首帧调用一次。
func _build_cached_geometry() -> void:
	_cached_segs = PackedVector2Array()
	_cached_l1_closed = PackedVector2Array()
	_cached_neighbor_outlines = []
	for nb in _data.neighbors:
		for poly in nb.get("polygons", []):
			var pts := _pts(poly)
			if pts.size() >= 3:
				_cached_neighbor_outlines.append(_closed(pts))
	var lake_tol := _lake_edge_tol()
	# 湖 bbox（外扩 tol）预筛：段中点不在任何湖 bbox 内 → 直接非邻湖，省精确距离计算
	var lake_boxes: Array[Rect2] = []
	for lake in _data.lakes:
		lake_boxes.append(_lake_bbox(lake, lake_tol))
	for tile in _data.tiles:
		if tile.polygon.size() < 3:
			continue
		var pts := tile.polygon
		var n := pts.size()
		for i in range(n):
			var a := pts[i]
			var b := pts[(i + 1) % n]
			if _edge_touches_lake_fast(a, b, lake_tol, lake_boxes):
				continue
			_cached_segs.append(a)
			_cached_segs.append(b)
	# L1 权威轮廓 = 主大陆单环（export 已保证 l1_polygon 只含最大环，多环串接已在数据侧消除）
	_cached_l1_closed = _closed(_data.l1_polygon)
	_segs_valid = true


## 湖多边形包围盒（外扩 tol）——邻湖判定预筛用
func _lake_bbox(lake: Array, tol: float) -> Rect2:
	var bb := Rect2()
	var first := true
	for pt in _pts(lake):
		if first:
			bb = Rect2(pt, Vector2.ZERO)
			first = false
		else:
			bb = bb.expand(pt)
	return bb.grow(tol)


## 边中点是否贴着某湖（bbox 预筛加速版）：中点不在任何湖 bbox 内直接 false
func _edge_touches_lake_fast(a: Vector2, b: Vector2, tol: float, lake_boxes: Array[Rect2]) -> bool:
	if lake_boxes.is_empty():
		return false
	var mid := (a + b) * 0.5
	for li in range(lake_boxes.size()):
		if not lake_boxes[li].has_point(mid):
			continue
		var pts := _pts(_data.lakes[li])
		var ln := pts.size()
		for i in range(ln):
			if _dist_point_segment(mid, pts[i], pts[(i + 1) % ln]) <= tol:
				return true
	return false


## 点到线段的最短距离
func _dist_point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Array[[x,y],...] -> PackedVector2Array
func _pts(arr: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for pt in arr:
		if pt is Array and pt.size() >= 2:
			pts.append(Vector2(float(pt[0]), float(pt[1])))
	return pts


## F3 调试：给城市打编号（屏幕恒定字号，不随缩放放大成大字）
func _draw_city_labels() -> void:
	var font := ThemeDB.fallback_font
	var zz: float = 1.0
	if _camera != null and _camera.has_method("get_zoom"):
		zz = _camera.get_zoom()
	var fs: float = LABEL_SIZE
	if zz > 0.0001:
		# 原生渲染：固定地图单元字号（随地图缩放，默认整图适配即可见、大小合适）。
		# 不再 ÷ 缩放——曾让局部字号过小（如 2.6 地图单元）导致 Godot 渲染消失；
		# 仅高缩放时按屏幕像素上限封顶，防"雷霆大字"。
		fs = minf(LABEL_SIZE, LABEL_SCREEN_CAP / zz)
	var halo: float = maxf(1.5, fs * 0.12)
	for tile in _data.tiles:
		if tile.settlement == null:
			continue
		var num := _city_num_from_tile_id(tile.tile_id)
		if num.is_empty():
			continue
		var pos := tile.settlement.position
		var txt := "L1城#" + num
		for off in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
			draw_string(font, pos + off * halo, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_BG)
		draw_string(font, pos + Vector2(2.0, -fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_COLOR)


## 从 tile_id（"city_2082"）解析城市编号
func _city_num_from_tile_id(tile_id: String) -> String:
	var prefix := "city_"
	if tile_id.begins_with(prefix):
		return tile_id.substr(prefix.length())
	return tile_id
