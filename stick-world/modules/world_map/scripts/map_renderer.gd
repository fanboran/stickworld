extends Node2D
class_name MapRenderer
## 战略图渲染器（L1 单层，Tab 键）—— R4 三模式语义分离（地形 / 政治 / 交通）
##
## 数据来自 l1_world.json（含 context_size/neighbors/lakes，坐标 = context 局部）。
## 三模式语义（创始人 2026-09-08 拍板，观感返工 §R4）：
##   地形   = l1_terrain.png 贴图 + 建成区三档贴图（blob 仅本模式）+ 交互层；不画道路
##   政治   = 运行时矢量政权色填充（R9 裁决：政权色随游戏进程变化，不烘焙）
##            + 地块界线描边 + 交互层；不画建成区、不画道路；底图无贴图（政权色全填充）
##   交通   = l1_travel.png 贴图（地形底图 + R6 道路 casing 双层实线已烘焙）
##            + 交互层；不画建成区、不画矢量道路
## 交互层（三模式全保留）：城市描边/中心点、hover/选中、当前城流动描边、玩家位置
## 标记、快速旅行路由高亮（琥珀虚线——虚线的正确语用位置，§7.2-4）、纸边框。
## 静态层贴图缺失时回退矢量管线（政权色填充 + 实线道路分级——R6 废虚线）。
##
## 线条语言（R8 层2 token 化 + feedback1 去抖动）：线条平滑直绘
## （draw_polyline/draw_multiline/draw_arc，antialiased），严丝合缝——共享边
## 无向去重只描一次、端点共点。线宽/色全部走 MapTokens（本文件零字面量）；
## 琥珀只出现在路由高亮（操作语义）。
##
## 建成区 blob V2（§R5，创始人拍板随人口增长动态化）：每包三档严格嵌套贴图
## （blob_low/mid/high.png，high ⊆ mid ⊆ low）逐层叠加 = 每城烘焙档形状；
## 运行时按扰动后 population_score 判档（0.35/0.65，SettlementBlob.tier_of），
## 与烘焙档不同的城经「单城小贴图」修正（升档直接叠加覆盖；降档先以
## l1_terrain.png 原样回贴擦除旧档像素再重画影响域各城）——补丁分帧生成防卡顿。
## 贴图未就绪时回退包几何矢量画法（blob_v2_geo.bin 环顶点）。
##
## 分层（context 坐标系，含邻居老 L1 块扩展区域）：
##   静态底图(贴图或矢量) -> [交通回退:道路] -> 河流 -> 湖泊 -> 路由高亮(琥珀虚线)
##   -> 建成区 blob(仅地形) -> 邻居老 L1 块(灰色空心描边) -> 城市描边 + 出生 L1 轮廓
##   -> 城市中心点 -> hover 描边 -> 当前城流动描边 -> 内容区纸边黑框 -> F3 编号 -> 玩家标记
##
## 交互：hover 命中城市块（经相机换算 + 索引图查询），点击选中由控制器经 api 处理。

## 关联的 L1 世界数据
var _data: L1WorldData = null

## 当前地图模式（MapModeManager 广播 → 控制器转发；R4 三态真分支）
var map_mode: int = MapModeManager.Mode.TERRAIN

## 相机引用（悬停检测做 screen->map 坐标换算）
var _camera: MapCamera = null

## 当前悬停的地块 ID（""=无）
var hovered_tile_id: String = ""

## 性能缓存：城市描边段 + 出生 L1 轮廓 + 邻居空心轮廓 + 河流折线（原始平滑点列；
## 不随 zoom/hover 变化，set_data 后首帧构建一次复用）。
## 原实现每帧重建描边段并对每段遍历湖全部边做距离计算（4668 段 × 湖边数 ≈ 百万级），
## hover 每帧触发 → 卡顿源；缓存后 hover 重绘 = 1 次 draw_multiline。
var _cached_segs: PackedVector2Array = PackedVector2Array()
## 出生 L1 权威轮廓（主大陆单环，闭合；export 已保证 l1_polygon 只含最大环）
var _cached_l1_closed: PackedVector2Array = PackedVector2Array()
## 邻居老 L1 块空心轮廓（每块一条闭合折线，A3 空心化）
var _cached_neighbor_outlines: Array[PackedVector2Array] = []
## 河流折线（矢量回退层消费）+ 平行宽度表
var _river_lines: Array[PackedVector2Array] = []
var _river_widths: PackedFloat32Array = PackedFloat32Array()
## 道路分级缓存（R6 实线分级，set_data 后构建一次）：土路/官道折线组。
## 运行时矢量仅交通模式贴图缺失回退时绘制——正常观感走 l1_travel.png 贴图
## （道路 casing 已烘焙，§R4：地形/政治模式不显示道路）
var _road_dirt_lines: Array[PackedVector2Array] = []
var _road_paved_lines: Array[PackedVector2Array] = []
var _segs_valid: bool = false

## 静态色块层 ArrayMesh（城市色块 / 湖泊各自一张，set_data 后烘焙一次；描边/轮廓/hover 仍动态）。
## 拆两层：河流通篇画在中间（tiles 之上、湖泊之下——河入湖被湖面覆盖，河穿城市块正常显示）。
## Geometry2D.triangulate_polygon 一次三角剖分 → 每帧 2 次 draw_mesh，免每帧 earcut（8 城 4750 点 + 湖）。
var _tiles_mesh: ArrayMesh = null
var _lakes_mesh: ArrayMesh = null

## ===== 建成区 blob V2 状态（§R5；仅 TERRAIN 模式消费）=====
## 包几何（blob_v2_geo.bin：每城三档环顶点 + 烘焙档；SettlementBlob.load_pack_geometry）
var _geo: Dictionary = {}
## 每城生效显示档（sid → 0/1/2）。初值 = 烘焙档（贴图画的就是它）；
## 档位判定/reconcile 后 = 运行时扰动分数判档
var _city_tier: Dictionary = {}
## 三档贴图（index = 档；叠加序 low→mid→high，嵌套无 z 冲突）
var _blob_tex: Array[Texture2D] = []
## 三档贴图全部就绪（叠加层 + 单城补丁生效开关）
var _blob_ready: bool = false
## 单城补丁（档位修正）：sid → {"tex": ImageTexture, "rect": Rect2}。
## overlay = 生效档形状小贴图（补丁栅格化）；erase = l1_terrain.png 原样回贴
## （降档擦旧档像素，随后重画影响域各城）
var _city_overlays: Dictionary = {}
var _city_erases: Dictionary = {}
## 待生成补丁的城队列（分帧消费防卡顿；settlement_updated 插队优先）
var _overlay_queue: Array[String] = []
## 每帧补丁生成预算（栅格化单城 ~几十 ms，一帧两城把补齐窗口压在 ~0.5s 内）
const OVERLAY_BUDGET_PER_FRAME := 2

## 模式静态底图（R9 静态层烘焙化 + R4 三模式）：TERRAIN = 本包 l1_terrain.png
## （B2 同管线，地形/群系/河湖/海洋）；TRAFFIC = l1_travel.png（地形底图 + R6 道路
## casing 双层实线烘焙）。POLITICAL 无贴图（R9 裁决：政权色随游戏进程变化，运行时矢量）。
## 贴图坐标 ↔ context 坐标 1:1（与 l1_base.png 同系无 offset）。异步后台线程解码
## （l3_map_renderer 三线程同款样板：FileAccess 直读不需 .import；Thread 未 join 直接
## 销毁在 Windows 会段错误——_exit_tree / set_data 换包前统一 wait_to_finish）。
## 解码完成前回退现状矢量管线。
const MODE_TEXTURES := {
	MapModeManager.Mode.TERRAIN: "l1_terrain.png",
	MapModeManager.Mode.TRAFFIC: "l1_travel.png",
}
## 按模式缓存的本包底图（set_data 换包清空；POLITICAL 恒缺席）
var _mode_textures: Dictionary = {}
## TERRAIN 底图 Image（降档擦除贴图的取样源；随贴图线程解码后保留）
var _terrain_img: Image = null
## 贴图加载线程（单线程串行消费 _load_queue；R9 样板：目标归档 + join 防段错误）
var _tex_thread: Thread = null
var _tex_result: Image = null
## 在途任务（{"kind": "mode"/"blob", "slot": int, "path": String}；完成时按它归档）
var _tex_slot: Dictionary = {}
## 待加载队列（模式切换/set_data 时按需补充）
var _load_queue: Array[Dictionary] = []

## ===== 线条/色彩 token（R8 层2）：真相源在 MapTokens，本文件零色值/线宽字面量 =====
## 语义色槽：内容线 = 群系色派生（生成端同源）；交互线（hover）= BORDER_STRONG；
## 操作线（路由高亮）= ACCENT（琥珀唯一合法位置）；玩家位置 = 玩家国色（运行时取）。
## 下列 const 为绘制代码的本地别名（含 strategic_map_controller 图例引用的公共入口）。

## 配色（与 L2MapRenderer 一致；水体色与 B2 底图 terrain_params.json colors 同源，改色两端同步）
const OCEAN_COLOR := MapTokens.L1_OCEAN
const LAKE_COLOR := MapTokens.L1_LAKE
## 河流（B3）：宽度 = 生成端 EDT 实测河宽（地图单位），下限保证缩到整图适配时细河仍可见
const RIVER_COLOR := MapTokens.L1_RIVER
const RIVER_MIN_WIDTH := MapTokens.L1_RIVER_MIN_WIDTH

## 道路（R6 实线分级；色与生成端 casing 面色 l1_terrain_params.json travel.face_color 同源）
const ROAD_COLOR_DIRT := MapTokens.L1_ROAD_DIRT
const ROAD_COLOR_PAVED := MapTokens.L1_ROAD_PAVED
const ROAD_WIDTH_DIRT := MapTokens.L1_ROAD_WIDTH_DIRT
const ROAD_WIDTH_PAVED := MapTokens.L1_ROAD_WIDTH_PAVED
## 图例条目（控制器 _fill_legend 按模式取用；R6 废虚线——文字定「土路/官道」）
const ROAD_LEGEND: Array[Dictionary] = [
	{"color": MapTokens.L1_ROAD_DIRT, "text": "土路"},
	{"color": MapTokens.L1_ROAD_PAVED, "text": "官道"},
]

## 群系图例色（B2 地形底图色板的 L1 图例入口；与生成端 biome_generate.py 同源）
const BIOME_LEGEND: Array[Dictionary] = MapTokens.BIOME_LEGEND

## 邻居老 L1 块（A3 空心化：灰色轮廓线，不填充）
const NEIGHBOR_COLOR := MapTokens.L1_NEIGHBOR_COLOR
const NEIGHBOR_BORDER_WIDTH := MapTokens.L1_NEIGHBOR_BORDER_WIDTH
## 内容区"纸张边界"黑框（context 外缘，A3）
const PAPER_BORDER_COLOR := MapTokens.L1_PAPER_BORDER_COLOR
const PAPER_BORDER_WIDTH := MapTokens.L1_PAPER_BORDER_WIDTH
## 城市常驻描边（内部城界；屏幕像素固定、细，不随缩放变化——避免缩放时粗细跳变）
const TILE_BORDER_COLOR := MapTokens.L1_TILE_BORDER_COLOR
const TILE_BORDER_WIDTH := MapTokens.L1_TILE_BORDER_WIDTH
## 出生 L1 轮廓 / 邻居分界（屏幕像素固定，略粗区分出生块边界）
const BORDER_COLOR := MapTokens.L1_BORDER_COLOR
const BORDER_WIDTH := MapTokens.L1_BORDER_WIDTH
## hover 描边（交互线槽 = StickTokens.BORDER_STRONG，R8 层2 语义归位；屏幕像素固定）
const HOVER_COLOR := MapTokens.L1_HOVER_COLOR
const HOVER_WIDTH := MapTokens.L1_HOVER_WIDTH
## 城市中心标记点（小圆点 + 细环，屏幕像素固定；画在聚落位置，指示城市中心）
const CITY_DOT_RADIUS := MapTokens.L1_CITY_DOT_RADIUS
const CITY_DOT_RING_WIDTH := MapTokens.L1_CITY_DOT_RING_WIDTH
const CITY_DOT_COLOR := MapTokens.L1_CITY_DOT_COLOR
const CITY_DOT_RING := MapTokens.L1_CITY_DOT_RING
## 城市建成区（C2/§R5）：烘焙贴图填充底色近似值（生成端同源，改色两端同步）。
## T4+ 白描边 / T5 金描边（内容色板琥珀棕——R8 层2 语义归位；矢量回退层用）
const BLOB_FILL := MapTokens.L1_BLOB_FILL
const BLOB_EDGE := MapTokens.L1_BLOB_EDGE
const BLOB_EDGE_T4 := MapTokens.L1_BLOB_EDGE_T4
const BLOB_EDGE_T5 := MapTokens.L1_BLOB_EDGE_T5
const BLOB_EDGE_WIDTH := MapTokens.L1_BLOB_EDGE_WIDTH
## F3 调试：城市编号（调试域专色，非地图语义色）
const LABEL_COLOR := MapTokens.DEBUG_INK
const LABEL_BG := MapTokens.DEBUG_BG
## F3 城市编号字号（地图单元，原生渲染）
const LABEL_SIZE := MapTokens.L1_LABEL_SIZE
const LABEL_SCREEN_CAP := MapTokens.L1_LABEL_SCREEN_CAP

## 玩家位置标记（R2，GPS 范式，§7.3-6 规范表）：中心 4px 玩家国色点（白描边）+
## 12px 静态细环 + 1.5s 周期向外扩散淡出脉冲环。色取所在地块政权色（内容语义）。
## 全部尺寸屏幕像素固定（÷zoom 换算）
const PLAYER_DOT_RADIUS := MapTokens.L1_PLAYER_DOT_RADIUS
const PLAYER_DOT_OUTLINE_W := MapTokens.L1_PLAYER_DOT_OUTLINE_W
const PLAYER_RING_RADIUS := MapTokens.L1_PLAYER_RING_RADIUS
const PLAYER_RING_WIDTH := MapTokens.L1_PLAYER_RING_WIDTH
const PLAYER_PULSE_FROM := MapTokens.L1_PLAYER_PULSE_FROM
const PLAYER_PULSE_TO := MapTokens.L1_PLAYER_PULSE_TO
const PLAYER_PULSE_PERIOD := MapTokens.L1_PLAYER_PULSE_PERIOD
const PLAYER_PULSE_ALPHA := MapTokens.L1_PLAYER_PULSE_ALPHA

## 快速旅行路由高亮（P6/E3「途经路径高亮」）：途经道路亮琥珀虚线加粗 + 途经聚落
## 节点白描边空心圆，画在水系之上。虚线 = UI 操作语义的正确位置（§7.2-4）；
## 琥珀 = 操作线槽 StickTokens.ACCENT（R8 层2：地图上琥珀的唯一合法位置）
const ROUTE_HIGHLIGHT_COLOR := MapTokens.L1_ROUTE_COLOR
const ROUTE_HIGHLIGHT_WIDTH := MapTokens.L1_ROUTE_WIDTH_RATIO
const ROUTE_DASH := MapTokens.L1_ROUTE_DASH_RATIO
const ROUTE_GAP := MapTokens.L1_ROUTE_GAP_RATIO
const ROUTE_NODE_RADIUS := MapTokens.L1_ROUTE_NODE_RADIUS
## 路由高亮数据（api.get_travel_status 的 roads/path → context 折线 + 节点位置）
var _route_road_pts: Array[PackedVector2Array] = []
var _route_nodes: PackedVector2Array = PackedVector2Array()

## 玩家位置（L1 地图坐标；默认 = 出生聚落，api.set_player_map 动态更新）
var _player_pos := Vector2.ZERO
var _player_visible := false
## 玩家所在地块政权色（标记中心点/脉冲环用；内容语义）
var _player_state_color := Color.WHITE

var _debug_was_visible: bool = false

## 当前所在城市的流动描边（"你在这里"，细粒度层级）：
## 几何 = 该城建成区 blob 轮廓（R2——与城市本体图形共用同一几何，描边与建成区
## 轮廓逐像素重合；原整地块多边形描边与城市轮廓不重合，已废）。
## 含玩家当前聚落的地块（出生 = spawn 聚落所在块），跨城移动后经 set_current_tile 更新。
## 双色不透明，与 M 大世界同视觉语言；FlowOutline 流动语义保留（色带沿轮廓移动）
var _current_tile_id: String = ""
const GLOW_A := MapTokens.L1_GLOW_A
const GLOW_B := MapTokens.L1_GLOW_B
## 描边宽（屏幕像素固定，与其他描边一致策略）
const GLOW_WIDTH := MapTokens.L1_GLOW_WIDTH
## 当前城 blob 轮廓分段缓存（几何不变，重采样一次复用）
var _glow_outline: PackedVector2Array = PackedVector2Array()
## 流动动画相位（秒）
var _glow_time := 0.0
## 玩家位置脉冲环相位（秒，PLAYER_PULSE_PERIOD 周期循环）
var _pulse_time := 0.0


func set_data(data: L1WorldData) -> void:
	_data = data
	_segs_valid = false
	_tiles_mesh = null
	_lakes_mesh = null
	_route_road_pts.clear()
	_route_nodes = PackedVector2Array()
	# 换包：旧贴图/旧线程/旧 blob 状态作废（join 防未完成 Thread 销毁段错误）
	_join_texture_thread()
	_mode_textures = {}
	_terrain_img = null
	_blob_tex.clear()
	for i in SettlementBlob.TIER_COUNT:
		_blob_tex.append(null)
	_blob_ready = false
	_city_overlays = {}
	_city_erases = {}
	_overlay_queue.clear()
	_current_tile_id = ""
	# 包几何（三档环顶点 + 烘焙档）同步装载——单包几十 KB 解压 + parse，毫秒级；
	# 生效档初值 = 烘焙档（贴图画的就是它，reconcile 后修正为运行时判档）
	_city_tier = {}
	if _data != null:
		_geo = SettlementBlob.load_pack_geometry(_data.base_dir)
		for tile in _data.tiles:
			if tile.settlement == null:
				continue
			_city_tier[tile.settlement.settlement_id] = \
				SettlementBlob.bake_tier_of(_geo, tile.settlement.settlement_id)
	# 当前所在地块默认 = 出生聚落所在块（玩家跨城移动后由 set_current_tile 切换）
	if _data != null and not _data.spawn_settlement_id.is_empty():
		for tile in _data.tiles:
			if tile.settlement != null \
					and tile.settlement.settlement_id == _data.spawn_settlement_id:
				_current_tile_id = tile.tile_id
				# 玩家位置标记默认锚出生聚落（api.set_player_map 动态更新）；
				# 色取所在地块政权色（内容语义，R2 裁决：非琥珀）
				_player_pos = tile.settlement.position
				_player_visible = true
				_player_state_color = _data.get_state_color(tile.owner_state_id)
				break
	_build_glow_outline()
	# 当前模式需要静态底图（TERRAIN/TRAFFIC）时按需触发异步加载（POLITICAL 无贴图）
	_ensure_static_textures()
	_ensure_label_layer()
	queue_redraw()


## 地图标注层（R8 层3）：城市名（包内 settlement name）+ 都城星标
## （capital_settlement_id，§7.3-1 首都星形惯例）。聚落语义全模式显示
var _label_layer: MapLabelLayer = null


## 标注层挂载（R8 层3）：懒建子节点 + 喂 L1 聚落数据（换包重复调用即重建）
func _ensure_label_layer() -> void:
	if _label_layer == null:
		_label_layer = MapLabelLayer.new()
		_label_layer.set_camera(_camera)
		add_child(_label_layer)
	_label_layer.setup_l1(_data)


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


## 档位对账（三档贴图就绪后一次）：运行时扰动分 vs 烘焙档不同的城 → 补丁队列
## （分帧生成，生成前保持烘焙档画面——±15% jitter 边界城的短暂小偏差，可接受）
func _reconcile_tiers() -> void:
	if not _blob_ready or _data == null:
		return
	for tile in _data.tiles:
		if tile.settlement == null:
			continue
		var sid := tile.settlement.settlement_id
		var t := SettlementBlob.tier_of(tile.settlement.population_score)
		if t != int(_city_tier.get(sid, -1)):
			_city_tier[sid] = t
			if not _overlay_queue.has(sid):
				_overlay_queue.append(sid)
	queue_redraw()


## 单城档位刷新（EventBus.settlement_updated → api 调用；SettlementRef.population_score
## 已由 api 更新，这里重判档位并把该城排进补丁队列优先生成。不在当前数据中的 id 忽略）
func invalidate_blob(settlement_id: String) -> void:
	if _data == null:
		return
	var sref := _data.get_settlement(settlement_id)
	if sref == null:
		return
	var new_tier := SettlementBlob.tier_of(sref.population_score)
	if new_tier != int(_city_tier.get(settlement_id, new_tier)):
		_city_tier[settlement_id] = new_tier
		_overlay_queue.erase(settlement_id)     # 去重：同一城只保留一个待补丁条目
		_overlay_queue.insert(0, settlement_id)
		_process_overlay_queue()
	queue_redraw()


## 构建当前城流动描边缓存（R2）：几何 = 当前城 mid 档建成区轮廓（包几何最大外环，
## 与建成区图形重合的 R2 语义；旧径向 blob 轮廓已随 §R5 退役）。
## 固定 mid 档——分数变化不再引起描边几何跳变。
func _build_glow_outline() -> void:
	_glow_outline = PackedVector2Array()
	if _data == null or _current_tile_id.is_empty():
		return
	for tile in _data.tiles:
		if tile.tile_id == _current_tile_id:
			if tile.settlement != null:
				var ring := SettlementBlob.glow_outline(_geo, tile.settlement.settlement_id)
				if ring.size() >= 3:
					var pts := PackedVector2Array()
					pts.resize(ring.size())
					for i in ring.size():
						pts[i] = ring[i] + tile.settlement.position
					_glow_outline = FlowOutline.resample_closed(pts)
			return


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## 地图模式切换（控制器在 open() 时也推一次当前模式——跨视图全局状态）
func set_map_mode(mode: int) -> void:
	if mode == map_mode:
		return
	map_mode = mode
	# 切到需静态底图的模式（TERRAIN/TRAFFIC）时按需触发加载（首帧/其他模式期间未加载过）
	_ensure_static_textures()
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


## ===== 静态贴图异步加载（R9/R4 底图 + §R5 建成区三档；l3_map_renderer 三线程同款样板）=====
## 后台线程 FileAccess 直读 + PNG 解码（纯 CPU、线程安全，主线程零阻塞）；
## 单线程串行消费 _load_queue（任务含 kind/slot，完成时按它归档）。
## 完成前当前模式回退矢量管线，解码完成后 queue_redraw 自动切上。
func _ensure_static_textures() -> void:
	if _data == null:
		return
	_queue_static_textures()
	_pump_load_queue()


## 按当前模式把「需要而未装载/未排队/未在途」的贴图任务入队
func _queue_static_textures() -> void:
	if MODE_TEXTURES.has(map_mode) and not _mode_textures.has(map_mode):
		_load_queue.append({
			"kind": "mode", "slot": map_mode,
			"path": "%s/%s" % [_data.base_dir, MODE_TEXTURES[map_mode]],
		})
	# 建成区三档只在 TERRAIN 模式消费（POLITICAL/TRAFFIC 不显示建成区，§R4）
	if map_mode == MapModeManager.Mode.TERRAIN and not _blob_ready:
		for ti in SettlementBlob.TIER_COUNT:
			if _blob_tex[ti] == null:
				_load_queue.append({
					"kind": "blob", "slot": ti,
					"path": "%s/%s" % [_data.base_dir, SettlementBlob.TIER_FILES[ti]],
				})


## 线程空闲时从队列取一个任务启动（缺失文件直接跳过继续取下一个）
func _pump_load_queue() -> void:
	while _tex_thread == null and not _load_queue.is_empty():
		var job: Dictionary = _load_queue.pop_front()
		if not FileAccess.file_exists(job.path):
			continue
		_tex_slot = job
		_tex_thread = Thread.new()
		_tex_thread.start(_load_texture_async.bind(job.path))


func _load_texture_async(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		_tex_result = img


## join 后台线程并丢弃未消费结果（set_data 换包 / _exit_tree 销毁前必须调用——
## 未完成的 Thread 直接销毁在 Windows 上会段错误）
func _join_texture_thread() -> void:
	_load_queue.clear()
	_tex_slot = {}
	if _tex_thread != null:
		_tex_thread.wait_to_finish()
		_tex_thread = null
	_tex_result = null


## 每帧检查后台线程：解码完成 → wait_to_finish + 主线程建 ImageTexture 按 slot 归档；
## blob 三档齐 → 档位对账；随后按当前模式补启动下一个任务
func _poll_texture_load() -> void:
	if _tex_thread != null and not _tex_thread.is_alive():
		_tex_thread.wait_to_finish()
		_tex_thread = null
		if _tex_result != null and not _tex_slot.is_empty():
			var tex := ImageTexture.create_from_image(_tex_result)
			if str(_tex_slot.get("kind")) == "mode":
				_mode_textures[_tex_slot.slot] = tex
				if int(_tex_slot.get("slot", -1)) == MapModeManager.Mode.TERRAIN:
					_terrain_img = _tex_result   # 降档擦除贴图的取样源
			elif str(_tex_slot.get("kind")) == "blob":
				var slot := int(_tex_slot.get("slot", -1))
				if slot >= 0 and slot < _blob_tex.size():
					_blob_tex[slot] = tex
					_check_blob_ready()
			_tex_result = null
			_tex_slot = {}
			queue_redraw()
		_queue_static_textures()
		_pump_load_queue()


func _check_blob_ready() -> void:
	if _blob_ready:
		return
	for tex in _blob_tex:
		if tex == null:
			return
	_blob_ready = true
	_reconcile_tiers()


## ===== 单城档位补丁（§R5 单城刷新；分帧生成防栅格化卡顿）=====

## 每帧消费补丁队列（_process 调用；settlement_updated 走同步直通不走此队列等待）
func _process_overlay_queue() -> void:
	var n := 0
	while not _overlay_queue.is_empty() and n < OVERLAY_BUDGET_PER_FRAME:
		_build_city_patch(_overlay_queue.pop_front())
		n += 1
	if n > 0:
		queue_redraw()


## 单城补丁：按「生效档 vs 烘焙档」的差异方向生成 overlay/erase。
## 升档：嵌套覆盖（新形状 ⊇ 旧形状）→ 只需该城新档小贴图；
## 降档：旧档像素超出新形状 → 先以 l1_terrain.png 原样回贴擦除旧档区域，
##       再重画影响域内各城（含被波及的邻城）的生效档形状。
func _build_city_patch(sid: String) -> void:
	if not _blob_ready or _data == null:
		return
	var sref := _data.get_settlement(sid)
	if sref == null or not _geo.has(sid):
		return
	var tier := int(_city_tier.get(sid, -1))
	if tier < 0:
		return
	var bake := SettlementBlob.bake_tier_of(_geo, sid)
	if tier > bake:
		_city_erases.erase(sid)
		var ov := _make_city_overlay(sid, tier)
		if ov.is_empty():
			_city_overlays.erase(sid)
		else:
			_city_overlays[sid] = ov
	elif tier < bake:
		var bb := _city_context_bbox(sid, bake, sref)
		if bb.size.x <= 0.0:
			return
		var ep := _make_erase_patch(bb)
		if not ep.is_empty():
			_city_erases[sid] = ep
		for other_sid in _cities_touching(bb):
			var ot := int(_city_tier.get(other_sid, SettlementBlob.bake_tier_of(_geo, other_sid)))
			var ov2 := _make_city_overlay(other_sid, ot)
			if ov2.is_empty():
				_city_overlays.erase(other_sid)
			else:
				_city_overlays[other_sid] = ov2


## 单城生效档形状 → 小贴图（相对锚点局部栅格化 + 锚点平移定位）。该档无建成区返回 {}。
func _make_city_overlay(sid: String, tier: int) -> Dictionary:
	var sref := _data.get_settlement(sid)
	if sref == null:
		return {}
	var res := SettlementBlob.rasterize_evenodd(
		SettlementBlob.city_rings(_geo, sid, tier), BLOB_FILL)
	if res.is_empty():
		return {}
	var origin: Vector2 = res["origin"]
	var img: Image = res["img"]
	return {
		"tex": ImageTexture.create_from_image(img),
		"rect": Rect2(origin + sref.position, Vector2(img.get_width(), img.get_height())),
	}


## 擦除补丁：l1_terrain.png 原样回贴（区域 = 旧档形状 bbox 外扩 2px，裁进 context）。
## 底图 Image 未就绪（贴图加载失败等）返回 {}——降档城保持烘焙画面（报告遗留项）。
func _make_erase_patch(bb: Rect2) -> Dictionary:
	if _terrain_img == null:
		return {}
	var ctx := _data.context_size
	var bounds := Rect2(Vector2.ZERO, Vector2(ctx.x, ctx.y))
	var rect := bb.grow(2.0).intersection(bounds)
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return {}
	var img := _terrain_img.get_region(Rect2i(int(rect.position.x), int(rect.position.y),
		int(rect.size.x), int(rect.size.y)))
	return {"tex": ImageTexture.create_from_image(img), "rect": rect}


## 城 tier 档形状的 context 坐标包围盒（锚点 = settlement.position）
func _city_context_bbox(sid: String, tier: int, sref: SettlementRef) -> Rect2:
	var bb := Rect2()
	var polys := SettlementBlob.city_rings(_geo, sid, tier)
	var first := true
	for poly: Variant in polys:
		var outer: PackedVector2Array = (poly as Dictionary).get("outer", PackedVector2Array())
		for p in outer:
			var pt := p + sref.position
			if first:
				bb = Rect2(pt, Vector2.ZERO)
				first = false
			else:
				bb = bb.expand(pt)
	return bb


## 包围盒触及的城 sid 集合（各城烘焙档形状 bbox 相交判定——擦除区内所有
## 可能被波及的城都要重画）
func _cities_touching(bb: Rect2) -> Array[String]:
	var out: Array[String] = []
	if bb.size.x <= 0.0:
		return out
	for tile in _data.tiles:
		if tile.settlement == null:
			continue
		var sid := tile.settlement.settlement_id
		var ot := int(_city_tier.get(sid, SettlementBlob.bake_tier_of(_geo, sid)))
		var obb := _city_context_bbox(sid, maxi(ot, SettlementBlob.bake_tier_of(_geo, sid)),
			tile.settlement)
		if obb.size.x > 0.0 and obb.intersects(bb):
			out.append(sid)
	return out


func _exit_tree() -> void:
	_join_texture_thread()


func _process(delta: float) -> void:
	_poll_texture_load()
	# 单城档位补丁分帧生成（栅格化较重，一帧限两城）
	_process_overlay_queue()
	if not is_visible_in_tree() or _data == null:
		return
	# 动画相位推进：当前城流动光 + 玩家位置脉冲环（有任一动画即逐帧重绘；
	# 静态层均缓存，成本低）。线条已回平滑直绘，无 boiling 重掷重绘需求
	var animating := false
	if not _glow_outline.is_empty():
		_glow_time += delta
		animating = true
	if _player_visible:
		_pulse_time += delta
		animating = true
	if animating:
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
	# 0. 模式静态底图（R9/R4）：TERRAIN = l1_terrain.png；TRAFFIC = l1_travel.png
	#    （地形底图 + R6 道路 casing 已烘焙）。贴图坐标 ↔ context 坐标 1:1。
	#    贴图就绪时政权色填充与矢量河湖跳过（防双画）；解码完成前回退矢量管线（下方）。
	#    POLITICAL 无贴图（R9 裁决：政权色运行时矢量填充，归属/人口变化即时反映）
	var base_tex: Texture2D = _mode_textures.get(map_mode, null)
	var terrain_base: bool = base_tex != null
	if terrain_base:
		draw_texture_rect(base_tex, Rect2(Vector2.ZERO, ctx_size), false)
	# 静态几何缓存（城市描边段/出生轮廓/邻居空心轮廓/道路分级）——描边/轮廓层全模式消费
	if not _segs_valid:
		_build_cached_geometry()
	# 1. 矢量回退层（贴图缺失/未解码完成时）；POLITICAL 恒走本层（政权色全填充）
	if not terrain_base:
		if _tiles_mesh == null:
			_bake_base_meshes()
		if _tiles_mesh != null:
			draw_mesh(_tiles_mesh, null)
		# 1.4 道路（R6 实线分级，废 F5 虚线）：仅交通模式回退时画——
		#     §R4 创始人拍板：道路只归交通模式（贴图已含），地形/政治不显示
		if map_mode == MapModeManager.Mode.TRAFFIC:
			for line in _road_dirt_lines:
				draw_polyline(line, ROAD_COLOR_DIRT, maxf(ROAD_WIDTH_DIRT, 1.0), true)
			for line in _road_paved_lines:
				draw_polyline(line, ROAD_COLOR_PAVED, maxf(ROAD_WIDTH_PAVED, 1.2), true)
		# 1.5 河流（B3）：平滑折线（缓存），画在湖泊之下
		#     （河入湖由湖面覆盖）、城市块之上
		for ri in _river_lines.size():
			draw_polyline(_river_lines[ri], RIVER_COLOR, _river_widths[ri], true)
		if _lakes_mesh != null:
			draw_mesh(_lakes_mesh, null)
	# 1.6 快速旅行路由高亮（P6）：途经道路琥珀虚线加粗 + 节点空心圆（全模式——
	#     UI 操作语义的虚线，§7.2-4；水系之上连续可见）。
	#     R8 层2：操作线 = ACCENT。feedback1 去抖动：平滑直绘（虚线切段保留）
	if not _route_road_pts.is_empty():
		var rw: float = maxf(ctx_size.x * ROUTE_HIGHLIGHT_WIDTH, 2.0)
		var dash_segs := PackedVector2Array()
		for ri in _route_road_pts.size():
			MapSketch.dash_segments(dash_segs, _route_road_pts[ri],
				ctx_size.x * ROUTE_DASH, ctx_size.x * ROUTE_GAP)
		if dash_segs.size() >= 2:
			draw_multiline(dash_segs, ROUTE_HIGHLIGHT_COLOR, rw, true)
		var nr: float = ROUTE_NODE_RADIUS
		if zz > 0.0001:
			nr = ROUTE_NODE_RADIUS / zz
		for pos in _route_nodes:
			draw_arc(pos, nr, 0.0, TAU, 48, Color.WHITE, maxf(rw * 0.35, 1.0), true)
	if _tiles_mesh == null and not terrain_base:
		# 回退：数据异常时逐层绘制（邻居空心：只描边，见第 4.5 层）
		draw_rect(Rect2(Vector2.ZERO, ctx_size), OCEAN_COLOR)
		for lake in _data.lakes:
			if (lake as Array).size() >= 3:
				draw_colored_polygon(_pts(lake), LAKE_COLOR)
		for tile in _data.tiles:
			if tile.polygon.size() < 3:
				continue
			draw_colored_polygon(tile.polygon, _data.get_state_color(tile.owner_state_id))
	# 2.5 城市建成区（C2/§R5）：仅地形模式显示（政治/交通不画，§R4 创始人拍板）。
	#     贴图就绪 = 三档嵌套贴图逐层叠加（每城显示烘焙档形状）+ 单城档位补丁
	#     （先 erase 回贴底图，再 overlay 生效档形状）；未就绪 = 包几何矢量回退。
	if map_mode == MapModeManager.Mode.TERRAIN:
		if _blob_ready:
			for tex in _blob_tex:
				if tex != null:
					draw_texture_rect(tex, Rect2(Vector2.ZERO, ctx_size), false)
			# 降档擦除（底图原样回贴）→ 单城生效档 overlay（顺序不可换：
			# 全部 erase 完成后再统一 overlay，多城 patch 相互覆盖才正确）
			for patch: Dictionary in _city_erases.values():
				draw_texture_rect(patch.tex, patch.rect, false)
			for patch: Dictionary in _city_overlays.values():
				draw_texture_rect(patch.tex, patch.rect, false)
		else:
			# 矢量回退：包几何按生效档平涂（洞不挖——过渡画面数帧）；描边沿用级别色
			var bew: float = BLOB_EDGE_WIDTH
			if zz > 0.0001:
				bew = BLOB_EDGE_WIDTH / zz
			for tile in _data.tiles:
				var sref := tile.settlement
				if sref == null:
					continue
				var tier := int(_city_tier.get(sref.settlement_id, SettlementBlob.TIER_LOW))
				var polys := SettlementBlob.city_rings(_geo, sref.settlement_id, tier)
				if polys.is_empty():
					continue
				var edge := BLOB_EDGE
				if sref.level >= 5:
					edge = BLOB_EDGE_T5
				elif sref.level >= 4:
					edge = BLOB_EDGE_T4
				for poly: Variant in polys:
					var outer: PackedVector2Array = (poly as Dictionary).get("outer",
						PackedVector2Array())
					if outer.size() < 3:
						continue
					var pts := PackedVector2Array()
					pts.resize(outer.size())
					for i in outer.size():
						pts[i] = outer[i] + sref.position
					draw_colored_polygon(pts, BLOB_FILL)
					draw_polyline(_closed(pts), edge, bew, true)
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
	# 7. hover 城市块描边（交互线槽；屏幕像素固定；feedback1 去抖动：平滑闭合直绘）
	if not hovered_tile_id.is_empty():
		var hw: float = HOVER_WIDTH
		if zz > 0.0001:
			hw = HOVER_WIDTH / zz
		for tile in _data.tiles:
			if tile.tile_id == hovered_tile_id and tile.polygon.size() >= 3:
				draw_polyline(_closed(tile.polygon), HOVER_COLOR, hw, true)
				break
	# 7.5 当前所在城市地块：蓝光流动描边（"你在这里"；屏幕像素固定，画在纸边框内）。
	#     FlowOutline 流动语义保留（色调波沿线移动）；feedback1 去抖动：
	#     撤 boiling 笔触叠加，流动色带直接走平滑轮廓点列
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
	# 9. 玩家位置标记（R2 GPS 范式：中心点 + 静态环 + 脉冲扩散环，画在最上层）
	if _player_visible:
		_draw_player_marker(zz)


## 闭合多边形点列（首尾相连）
func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var out := pts.duplicate()
	out.append(out[0])
	return out


## 设置玩家位置（L1 地图坐标 = 所在聚落 position_px；api.set_player_map 接线。
## 方法名保留 P6 时代接口；R2 起图形为位置标记而非图钉）
func set_player_pin(map_pos: Vector2) -> void:
	_player_pos = map_pos
	_player_visible = true
	# 色随所在地块政权色走（查询失败保留旧色——跨 L1 查不到时标记仍可见）
	if _data != null:
		var query: Dictionary = _data.query_at_map_pos(map_pos)
		var tile: L1TileDef = query.get("tile", null)
		if tile != null:
			_player_state_color = _data.get_state_color(tile.owner_state_id)
	queue_redraw()


## 隐藏玩家位置标记（玩家当前不在本 L1 的任何聚落时）
func clear_player_pin() -> void:
	if not _player_visible:
		return
	_player_visible = false
	queue_redraw()


## 设置快速旅行路由高亮（P6）：roads = api.get_travel_status 的 "roads"
## （途经道路条目，取其 pts），nodes = 途经聚落位置序列（"path" 对应
## SettlementRef.position）。切换数据/关闭视图时经 clear_route_highlight 清除。
func set_route_highlight(roads: Array, nodes: PackedVector2Array) -> void:
	_route_road_pts.clear()
	for rd in roads:
		var d: Dictionary = rd if rd is Dictionary else {}
		var pts: PackedVector2Array = d.get("pts", PackedVector2Array())
		if pts.size() >= 2:
			_route_road_pts.append(pts)
	_route_nodes = nodes
	queue_redraw()


## 清除快速旅行路由高亮（无高亮时幂等）
func clear_route_highlight() -> void:
	if _route_road_pts.is_empty() and _route_nodes.is_empty():
		return
	_route_road_pts.clear()
	_route_nodes = PackedVector2Array()
	queue_redraw()


## 玩家位置标记（R2，替代拟物图钉；feedback1 去抖动：环回平滑 draw_arc）：
## 中心 4px 玩家国色点（白描边）+ 12px 静态细环（白，半透明）
## + 1.5s 周期脉冲扩散环（12→36px alpha 0.5→0，玩家国色）。全部屏幕像素固定。
func _draw_player_marker(zz: float) -> void:
	var dot_r := PLAYER_DOT_RADIUS
	var dot_ow := PLAYER_DOT_OUTLINE_W
	var ring_r := PLAYER_RING_RADIUS
	var ring_w := PLAYER_RING_WIDTH
	var p_from := PLAYER_PULSE_FROM
	var p_to := PLAYER_PULSE_TO
	if zz > 0.0001:
		dot_r /= zz
		dot_ow /= zz
		ring_r /= zz
		ring_w /= zz
		p_from /= zz
		p_to /= zz
	# 静态细环（白，半透明度略降避免喧宾夺主）
	draw_arc(_player_pos, ring_r, 0.0, TAU, 64, MapTokens.L1_PLAYER_RING_COLOR, ring_w, true)
	# 脉冲扩散环：0→1 相位，半径 12→36px、alpha 0.5→0，玩家国色
	var t := fmod(_pulse_time, PLAYER_PULSE_PERIOD) / PLAYER_PULSE_PERIOD
	var pa := lerpf(PLAYER_PULSE_ALPHA, 0.0, t)
	if pa > 0.01:
		draw_arc(_player_pos, lerpf(p_from, p_to, t), 0.0, TAU, 64,
			Color(_player_state_color, pa), ring_w, true)
	# 中心点：玩家国色填充 + 白描边
	draw_circle(_player_pos, dot_r, _player_state_color)
	draw_arc(_player_pos, dot_r, 0.0, TAU, 48, Color.WHITE, dot_ow, true)


## 邻湖判定容差（地图单元）：边中点距湖多边形 ≤ 该值视为"地块-湖泊"边界不描边。
## 8192 级 context 下沿湖边 ~0-10、最近非湖边 ~10.1，取 context 1%（798≈8）安全。
func _lake_edge_tol() -> float:
	var tol := 4.0
	if _data.context_size.x > 0:
		tol = _data.context_size.x * 0.01
	return tol


## 烘焙静态色块层：城市色块与湖泊各一张 ArrayMesh（顶点色，三角形独立顶点）。
## Geometry2D.triangulate_polygon 一次性 earcut（C++，含凹多边形），仅 set_data / 首帧调用一次。
## 邻居老 L1 块不参与（A3 空心化：只描边不填充，轮廓走 _build_cached_geometry 缓存）。
## 拆两张 mesh：河流画在两层层间（tiles 上、lakes 下），见 _draw 1.5 层。
func _bake_base_meshes() -> void:
	_tiles_mesh = null
	_lakes_mesh = null
	var ctx := _data.context_size
	if ctx.x <= 0 or ctx.y <= 0:
		return
	# 收集 (多边形, 颜色)：海洋 = 全矩形底由渲染器背景承担（OCEAN 回退分支 + 相机外区域）
	var tile_pairs: Array = []   # [[PackedVector2Array, Color], ...]
	var lake_pairs: Array = []
	for tile in _data.tiles:
		if tile.polygon.size() >= 3:
			tile_pairs.append([tile.polygon, _data.get_state_color(tile.owner_state_id)])
	for lake in _data.lakes:
		lake_pairs.append([_pts(lake), LAKE_COLOR])
	_tiles_mesh = _mesh_from_pairs(tile_pairs)
	_lakes_mesh = _mesh_from_pairs(lake_pairs)


## 多边形组 → 顶点色 ArrayMesh（每三角形独立顶点，避免共享顶点颜色冲突）
func _mesh_from_pairs(pairs: Array) -> ArrayMesh:
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
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 构建不随 zoom/hover 变化的静态几何缓存：城市描边段（跳过邻湖边）+ 出生 L1 轮廓
## + 邻居空心轮廓（A3）+ 河流折线。仅 set_data / 首帧调用一次。
## feedback1 去抖动：缓存存原始平滑点列（直绘，Godot antialiased）；
## 无向边去重保留——共享边只描一次，线条严丝合缝不叠双线。
func _build_cached_geometry() -> void:
	_cached_segs = PackedVector2Array()
	_cached_l1_closed = PackedVector2Array()
	_cached_neighbor_outlines = []
	_river_lines = []
	_river_widths = PackedFloat32Array()
	# 邻居空心轮廓（闭合折线缓存）
	for ni in _data.neighbors.size():
		for poly in _data.neighbors[ni].get("polygons", []):
			var pts := _pts(poly)
			if pts.size() >= 3:
				_cached_neighbor_outlines.append(_closed(pts))
	var lake_tol := _lake_edge_tol()
	# 湖 bbox（外扩 tol）预筛：段中点不在任何湖 bbox 内 → 直接非邻湖，省精确距离计算
	var lake_boxes: Array[Rect2] = []
	for lake in _data.lakes:
		lake_boxes.append(_lake_bbox(lake, lake_tol))
	# 城界描边段：无向边去重（相邻 tile 共享边只描一次——同一物理边一份描边，
	# 端点与邻边共点，三岔交界严丝合缝）
	var seen_edges := {}
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
			var key := MapSketch.edge_key(a, b)
			if seen_edges.has(key):
				continue
			seen_edges[key] = true
			_cached_segs.append(a)
			_cached_segs.append(b)
	# L1 权威轮廓 = 主大陆单环（export 已保证 l1_polygon 只含最大环）——闭合缓存
	if _data.l1_polygon.size() >= 3:
		_cached_l1_closed = _closed(_data.l1_polygon)
	# 河流折线（矢量回退层；宽随河流数据）
	for ri in _data.rivers.size():
		var rv: Dictionary = _data.rivers[ri]
		var rpts: PackedVector2Array = rv.get("pts", PackedVector2Array())
		if rpts.size() >= 2:
			_river_lines.append(rpts)
			_river_widths.append(maxf(float(rv.get("w", 2.0)), RIVER_MIN_WIDTH))
	# 道路分级（R6 实线分级，废 F5 虚线切分）：土路细 / 官道粗；
	# 仅交通模式矢量回退时绘制（正常观感走 l1_travel.png 贴图）
	_road_dirt_lines = []
	_road_paved_lines = []
	for rd in _data.roads:
		var pts: PackedVector2Array = rd.get("pts", PackedVector2Array())
		if pts.size() < 2:
			continue
		if str(rd.get("tier", "DIRT")) == "PAVED":
			_road_paved_lines.append(pts)
		else:
			_road_dirt_lines.append(pts)
	_segs_valid = true


## 无向边去重 key：已迁 `MapSketch.edge_key`（L1 城界共享边去重 / L3 国界邻接共用）。


## 折线按 dash/gap 弧长切段：已迁 `MapSketch.dash_segments`（R8 层2 通用化——
## 路由高亮与 L2/L3 政治模式虚线界线共用同一实现）。


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


## F3 调试：给城市打编号（屏幕恒定字号，不随缩放放大成大字）。
## 字体归正（R8 层3）：StickHand 与全游戏 UI 同源，不用 fallback 字体
func _draw_city_labels() -> void:
	var font := SketchFonts.hand()
	if font == null:
		return
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
		draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			maxi(1, roundi(halo)), LABEL_BG)
		draw_string(font, pos + Vector2(2.0, -fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_COLOR)


## 从 tile_id（"city_2082"）解析城市编号
func _city_num_from_tile_id(tile_id: String) -> String:
	var prefix := "city_"
	if tile_id.begins_with(prefix):
		return tile_id.substr(prefix.length())
	return tile_id
