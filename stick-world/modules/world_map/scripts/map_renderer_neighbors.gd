extends RefCounted
## MapRenderer 邻省完整渲染助手（需求 7）—— 邻包按需装载 + 城块界/城市 blob/政权色完整叠加。
##
## 现状兜底（既有链，本文件之外）：本包 context 内嵌的 neighbors 多边形只给「地形透出 +
## 主导政权色暗一阶」一层，邻省的城块界与城市 blob 不显示。本助手把邻省升级为完整渲染。
##
## 邻包定位：neighbors[i].label → config/strategic_map/l1_packs/l1_%03d/
## （出生省 = config/strategic_map 根目录单份数据，包不存在则静默跳过该邻省）。
## 分帧装载：open_l1（宿主 set_data）时按邻省列表建队列，每帧 1 包（读数据 + 建裁剪几何 +
## 城市层打开时入队三档建成区贴图）——不卡首开；装载完成前既有兜底层原样不动。
##
## 完整内容（叠在兜底之上，全部裁进本包窗口）：
##   政权色 = 邻包 states 真实色**逐城块**染（乘邻省暗一阶）；比侧表主导色更准确
##   城块界 = 邻包 tiles 多边形链（语义同本省灰城界）
##   城市 blob = 邻包三档贴图（low/mid/high，按邻包 settlement population_score 的烘焙档；
##     只画不重算——运行时档位补丁只针对本省）
##
## 坐标与裁剪：邻包 context 坐标 → 本包 context 坐标 = + (邻.world_origin − 本.world_origin)。
## 邻包 window 只与本包窗口部分相交，几何与贴图一律裁进
##   clip = 本包 context 矩形 ∩ 该邻省在本包 neighbors 里的窗口多边形包围盒。
## 用「窗口多边形包围盒」而不是整个 context：本包既有的邻省轮廓与兜底色块就是按窗口
## 多边形生成的，裁到它的包围盒才与既有轮廓对得上（否则颜色会越过省界灰线）。
##
## 生命周期：只装当前包 neighbors 列出的邻包；换包（set_data→reset）清旧数据/几何/贴图/队列。
## 邻包建成区贴图走宿主既有异步解码线程（map_renderer_tex_jobs 的 "neighbor_blob" 任务），
## 解码后按窗口裁成小贴图再常驻（整张 context 贴图对邻省是浪费：只要窗口内那一段）。
##
## 纪律：状态全部留宿主 map_renderer.gd（_nb_packs/_nb_queue/_nb_loaded），本文件经 _h 回引
## 读写；几何/裁剪复用 map_renderer_geo 的静态工具；不写 class_name（防全局类循环引用）。

const _GeoLib := preload("res://modules/world_map/scripts/map_renderer_geo.gd")

## 邻包根目录（label → l1_packs/l1_%03d）
const L1_PACKS_BASE := "res://config/strategic_map/l1_packs"
## 出生省数据根目录（不在 l1_packs 里；其邻省可能反过来指向它）
const BIRTH_BASE := "res://config/strategic_map"

var _h   ## 宿主 MapRenderer（Node2D）动态回引


## 复位（宿主 set_data 换包）：清旧邻包（数据/几何/贴图随引用释放）并按新包邻居重建队列
func reset() -> void:
	_h._nb_packs = []
	_h._nb_loaded = {}
	# 宿主 _nb_queue 是元素类型化数组（Array[int]）：跨脚本动态赋普通 [] 会被运行时拒绝
	# （Invalid assignment）并中止本函数，须 clear() 就地清空
	_h._nb_queue.clear()
	if _h._data == null:
		return
	for nb in _h._data.neighbors:
		var label := int((nb as Dictionary).get("label", 0))
		if label > 0:
			_h._nb_queue.append(label)


## 分帧装载（宿主 _process 每帧调用）：一帧一包，队列空即无事
func pump() -> void:
	if _h._nb_queue.is_empty() or _h._data == null:
		return
	var label: int = _h._nb_queue.pop_front()
	if _h._nb_loaded.has(label):
		return
	var pack := build_pack(label)
	if pack.is_empty():
		return
	_h._nb_packs.append(pack)
	_h._nb_loaded[label] = true
	# 兜底色块排除已完整装载的邻省（同层两份半透明填充会叠暗）
	_GeoLib.bake_neighbors_mesh(_h)
	# 三档建成区贴图无条件入队（装载与城市层开关解耦——关层装载、开层即画；
	# 贴图就绪前该邻省只画城块界 + 政权色，draw_blobs 只消费 blob_ready 的包）
	_h._tex().ensure()
	_h.queue_redraw()


## 装一个邻包 → pack 字典（包不存在/数据为空返回 {}）：只装配渲染所需形状
## （shapes_only：跳过底图/索引图/河湖/道路，见 L1WorldData.load_from）。
func build_pack(label: int) -> Dictionary:
	var base_dir := pack_dir_for(label)
	if base_dir.is_empty():
		return {}
	var data: L1WorldData = L1WorldData.load_from(
			"%s/l1_world.json" % base_dir, base_dir, true)
	if data == null or data.tiles.is_empty():
		return {}
	var offset := Vector2(data.world_origin - _h._data.world_origin)
	var clip := clip_rect_for(label)
	var prov_polys := province_polys_for(label)
	var blob_tex: Array = []
	for i in SettlementBlob.TIER_COUNT:
		blob_tex.append(null)
	return {
		"label": label,
		"data": data,
		"offset": offset,
		"clip": clip,
		"mesh": build_fill_mesh(data, offset, clip, prov_polys),
		"borders": build_borders(data, offset, clip),
		"blob_tex": blob_tex,
		"blob_rect": Rect2(),
		"blob_ready": false,
	}


## 邻包目录（label → l1_packs/l1_%03d；该包不存在时回退出生省根目录，仍不存在返回空串）
static func pack_dir_for(label: int) -> String:
	var pack := "%s/l1_%03d" % [L1_PACKS_BASE, label]
	if FileAccess.file_exists("%s/l1_world.json" % pack) \
			or FileAccess.file_exists("%s/l1_world.bin" % pack):
		return pack
	if FileAccess.file_exists("%s/l1_world.json" % BIRTH_BASE) \
			or FileAccess.file_exists("%s/l1_world.bin" % BIRTH_BASE):
		return BIRTH_BASE
	return ""


## 该邻省的省界多边形（本包 neighbors[] 的 polygons，本包 context 局部坐标）——
## 完整层城块裁进省界（不规则共边），不再只用包围盒直边裁（省界直线化 = 裁剪痕，
## 创始人 2026-09-29 指正）
func province_polys_for(label: int) -> Array:
	var out: Array = []
	for nb in _h._data.neighbors:
		if int((nb as Dictionary).get("label", 0)) != label:
			continue
		for poly in (nb as Dictionary).get("polygons", []):
			var pts := _GeoLib.pts(poly)
			if pts.size() >= 3:
				out.append(pts)
	return out


## 该邻省的裁剪矩形 = 本包 context 矩形 ∩ 该邻省窗口多边形包围盒
func clip_rect_for(label: int) -> Rect2:
	var ctx = _h._data.context_size
	var full := Rect2(Vector2.ZERO, Vector2(float(ctx.x), float(ctx.y)))
	if full.size.x <= 0.0 or full.size.y <= 0.0:
		var side := float(_h._data.size)
		full = Rect2(Vector2.ZERO, Vector2(side, side))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var found := false
	for nb in _h._data.neighbors:
		if int((nb as Dictionary).get("label", 0)) != label:
			continue
		for poly in (nb as Dictionary).get("polygons", []):
			for p in _GeoLib.pts(poly):
				lo = lo.min(p)
				hi = hi.max(p)
				found = true
	if not found:
		return full
	return full.intersection(Rect2(lo, hi - lo))


## 邻省政权色填充 mesh：逐城块取邻包 states 真实政权色 × 邻省暗一阶（同本省覆盖口径）
func build_fill_mesh(data: L1WorldData, offset: Vector2, clip: Rect2,
		prov_polys: Array = []) -> ArrayMesh:
	if clip.size.x <= 0.0 or clip.size.y <= 0.0:
		return null
	var pairs: Array = []
	for tile in data.tiles:
		if tile.polygon.size() < 3:
			continue
		var moved := _moved(tile.polygon, offset)
		var clipped := _GeoLib.clip_polygon_rect(moved, clip)
		if clipped.size() < 3:
			continue
		# 省界裁剪：城块只保留省界多边形内的部分（不规则共边贴齐兜底省面，
		# 越界的包围盒直边不再压到邻省兜底上）
		var pieces: Array = [clipped]
		if not prov_polys.is_empty():
			var inside: Array = []
			for piece in pieces:
				for pp2 in prov_polys:
					inside.append_array(Geometry2D.intersect_polygons(piece, pp2))
			pieces = inside
		for piece in pieces:
			if piece.size() < 3:
				continue
			var col: Color = data.get_state_color(tile.owner_state_id)
			col.s *= _h.L1_NEIGHBOR_DESAT
			pairs.append([piece, col.darkened(_h.L1_NEIGHBOR_DIM)])
	return _GeoLib.mesh_from_pairs(pairs)


## 邻省城块界：邻包每个地块多边形成闭合链 → 裁进窗口（跳过窗口外段，不沿窗口边画假线）
func build_borders(data: L1WorldData, offset: Vector2, clip: Rect2) -> Array:
	var out: Array = []
	if clip.size.x <= 0.0 or clip.size.y <= 0.0:
		return out
	for tile in data.tiles:
		if tile.polygon.size() < 3:
			continue
		var ring := PackedVector2Array(tile.polygon)
		ring.append(tile.polygon[0])
		var moved := _moved(ring, offset)
		out.append_array(_GeoLib.clip_polyline_rect(moved, clip))
	return out


## 点列平移（邻包坐标 → 本包 context 坐标）
static func _moved(pts: PackedVector2Array, offset: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = pts[i] + offset
	return out


## 邻省建成区贴图的绘制矩形（本包 context 坐标；= 邻包 context 贴图矩形 ∩ 裁剪矩形）。
## 贴图按此矩形在解码后裁剪常驻（tex_jobs 的 crop），绘制即 draw_texture_rect(tex, rect)。
func blob_draw_rect(pack: Dictionary) -> Rect2:
	var data: L1WorldData = pack.get("data", null)
	if data == null:
		return Rect2()
	var ctx = data.context_size
	var side := Vector2(float(ctx.x), float(ctx.y))
	if side.x <= 0.0 or side.y <= 0.0:
		side = Vector2(float(data.size), float(data.size))
	var dst := Rect2(pack.get("offset", Vector2.ZERO), side)
	return dst.intersection(pack.get("clip", Rect2()))


## ===== 绘制件（宿主 _draw 调用，只读宿主状态）=====

## 政权色填充（政治层）：逐邻包一张 mesh，与本省同一覆盖不透明度
func draw_fill(canvas: CanvasItem) -> void:
	for pack in _h._nb_packs:
		var m: ArrayMesh = pack.get("mesh", null)
		if m != null:
			canvas.draw_mesh(m, null, Transform2D(),
					Color(1.0, 1.0, 1.0, _h.L1_NEIGHBOR_FILL_ALPHA))


## 城块界（城市层）：邻省灰城界链，线宽与本省同口径（屏幕像素固定）
func draw_borders(canvas: CanvasItem, zz: float) -> void:
	var w: float = _h.TILE_BORDER_WIDTH
	if zz > 0.0001:
		w = _h.TILE_BORDER_WIDTH / zz
	for pack in _h._nb_packs:
		for chain: Variant in pack.get("borders", []):
			var line := chain as PackedVector2Array
			if line.size() >= 2:
				canvas.draw_polyline(line, _h.TILE_BORDER_COLOR, w, true)


## 建成区 blob（城市层）：邻省三档贴图逐层叠加（贴图已按窗口裁过，直接落在绘制矩形）
func draw_blobs(canvas: CanvasItem) -> void:
	for pack in _h._nb_packs:
		if not bool(pack.get("blob_ready", false)):
			continue
		var rect: Rect2 = pack.get("blob_rect", Rect2())
		if rect.size.x <= 1.0 or rect.size.y <= 1.0:
			continue
		for tex: Variant in pack.get("blob_tex", []):
			if tex != null:
				canvas.draw_texture_rect(tex as Texture2D, rect, false)
