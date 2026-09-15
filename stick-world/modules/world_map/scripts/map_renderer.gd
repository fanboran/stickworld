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
##
## 子域拆分（同目录助手，本文件保留全部状态/常量/公共 API/层序编排）：
##   map_renderer_geo.gd        静态几何库（点列工具/邻湖判定/静态几何缓存构建/底色 mesh 烘焙）
##   map_renderer_blob_layer.gd 建成区 blob V2（包几何装载/档位对账/单城补丁/两套档位绘制件）
##   map_renderer_tex_jobs.gd   贴图异步加载机制（queue/pump/解码线程体/join/poll）
##   map_renderer_layers.gd     交互叠加绘制件（路由高亮/邻居轮廓/城市点/F3 编号/玩家标记）
const _Geo := preload("res://modules/world_map/scripts/map_renderer_geo.gd")
const _BlobLayer := preload("res://modules/world_map/scripts/map_renderer_blob_layer.gd")
const _TexJobs := preload("res://modules/world_map/scripts/map_renderer_tex_jobs.gd")
const _Layers := preload("res://modules/world_map/scripts/map_renderer_layers.gd")

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

## 静态色块层 ArrayMesh（城市色块 / 湖泊 / 邻居灰底各自一张，set_data 后烘焙一次；
## 描边/轮廓/hover 仍动态）。
## 拆两层：河流通篇画在中间（tiles 之上、湖泊之下——河入湖被湖面覆盖，河穿城市块正常显示）。
## Geometry2D.triangulate_polygon 一次三角剖分 → 每帧 2 次 draw_mesh，免每帧 earcut（8 城 4750 点 + 湖）。
var _tiles_mesh: ArrayMesh = null
var _lakes_mesh: ArrayMesh = null
## 邻居老 L1 块灰底（第四批反馈：政治模式下邻居不再空心，整块填灰——与 L2 的
## NEIGHBOR 同语义；仅 POLITICAL 消费，地形/交通模式保持底图原样）
var _neighbors_mesh: ArrayMesh = null

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

## ===== 子域助手实例（懒建：首建后仅返回引用，每帧路径零新增分配）=====
var _blob_layer: RefCounted = null
var _tex_jobs: RefCounted = null


## 建成区 blob V2 助手访问器（_h 回引本宿主）
func _blob() -> RefCounted:
	if _blob_layer == null:
		_blob_layer = _BlobLayer.new()
		_blob_layer._h = self
	return _blob_layer


## 贴图异步加载助手访问器（_h 回引本宿主）
func _tex() -> RefCounted:
	if _tex_jobs == null:
		_tex_jobs = _TexJobs.new()
		_tex_jobs._h = self
	return _tex_jobs


func set_data(data: L1WorldData) -> void:
	_data = data
	_segs_valid = false
	_tiles_mesh = null
	_lakes_mesh = null
	_neighbors_mesh = null
	_route_road_pts.clear()
	_route_nodes = PackedVector2Array()
	# 换包：旧贴图/旧线程/旧 blob 状态作废（join 防未完成 Thread 销毁段错误）
	_tex().join()
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
		var pack := _BlobLayer.load_pack(_data)
		_geo = pack["geo"]
		_city_tier = pack["tiers"]
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
	_tex().ensure()
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
		# 挂渲染器父级（Content，无相机变换）：屏幕像素口径（同 L3/L2 注）
		var host := get_parent()
		if host != null:
			host.add_child(_label_layer)
		else:
			add_child(_label_layer)
		_label_layer.set_host(self)
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


## 单城档位刷新（EventBus.settlement_updated → api 调用；SettlementRef.population_score
## 已由 api 更新，这里重判档位并把该城排进补丁队列优先生成。不在当前数据中的 id 忽略）
func invalidate_blob(settlement_id: String) -> void:
	_blob().invalidate(settlement_id)


## 构建当前城流动描边缓存（R2）：几何 = 当前城 mid 档建成区轮廓（包几何最大外环，
## 与建成区图形重合的 R2 语义；旧径向 blob 轮廓已随 §R5 退役）。
## 固定 mid 档——分数变化不再引起描边几何跳变。（轮廓提取见 blob 助手 static 纯函数）
func _build_glow_outline() -> void:
	_glow_outline = PackedVector2Array()
	if _data == null or _current_tile_id.is_empty():
		return
	_glow_outline = _BlobLayer.current_city_outline(_geo, _data, _current_tile_id)


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## 地图模式切换（控制器在 open() 时也推一次当前模式——跨视图全局状态）
func set_map_mode(mode: int) -> void:
	if mode == map_mode:
		return
	map_mode = mode
	# 切到需静态底图的模式（TERRAIN/TRAFFIC）时按需触发加载（首帧/其他模式期间未加载过）
	_tex().ensure()
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


## ===== 贴图异步加载机制体在 map_renderer_tex_jobs.gd（_h 回引本宿主）=====
## 状态（_tex_thread/_tex_result/_tex_slot/_load_queue）留本文件；queue/pump/join/poll
## 经 _tex() 访问器驱动。完成前当前模式回退矢量管线，解码完成后 queue_redraw 自动切上。


func _check_blob_ready() -> void:
	if _blob_ready:
		return
	for tex in _blob_tex:
		if tex == null:
			return
	_blob_ready = true
	_blob().reconcile_tiers()


## ===== 单城档位补丁机制体在 map_renderer_blob_layer.gd（_h 回引本宿主）=====
## 状态（_geo/_city_tier/_blob_tex/_city_overlays/_city_erases/_overlay_queue）留本文件；
## 对账/补丁生成/档位绘制经 _blob() 访问器驱动（公共入口 invalidate_blob 转发同助手）。


func _exit_tree() -> void:
	_tex().join()


func _process(delta: float) -> void:
	_tex().poll()
	# 单城档位补丁分帧生成（栅格化较重，一帧限两城）
	_blob().process_overlay_queue()
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
			_Geo.bake_base_meshes(self)
		# 4.4 邻居老 L1 块灰底（仅政治模式；A3 空心化的补集——空心轮廓留在灰底之上）
		if map_mode == MapModeManager.Mode.POLITICAL and _neighbors_mesh != null:
			draw_mesh(_neighbors_mesh, null)
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
	_Layers.draw_route_highlight(self, ctx_size, zz)
	if _tiles_mesh == null and not terrain_base:
		# 回退：数据异常时逐层绘制（邻居空心：只描边，见第 4.5 层）
		draw_rect(Rect2(Vector2.ZERO, ctx_size), OCEAN_COLOR)
		for lake in _data.lakes:
			if (lake as Array).size() >= 3:
				draw_colored_polygon(_Geo.pts(lake), LAKE_COLOR)
		for tile in _data.tiles:
			if tile.polygon.size() < 3:
				continue
			draw_colored_polygon(tile.polygon, _data.get_state_color(tile.owner_state_id))
	# 2.5 城市建成区（C2/§R5）：仅地形模式显示（政治/交通不画，§R4 创始人拍板）。
	#     贴图就绪 = 三档嵌套贴图逐层叠加（每城显示烘焙档形状）+ 单城档位补丁
	#     （先 erase 回贴底图，再 overlay 生效档形状）；未就绪 = 包几何矢量回退。
	if map_mode == MapModeManager.Mode.TERRAIN:
		if _blob_ready:
			_blob().draw_tier_textures(ctx_size)
		else:
			_blob().draw_vector_fallback(zz)
	# 4.5 邻居老 L1 块空心描边（A3：只描边不填充；屏幕像素固定）
	_Layers.draw_neighbor_outlines(self, zz)
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
	_Layers.draw_city_dots(self, zz)
	# 7. hover 城市块描边（交互线槽；屏幕像素固定；feedback1 去抖动：平滑闭合直绘）
	if not hovered_tile_id.is_empty():
		var hw: float = HOVER_WIDTH
		if zz > 0.0001:
			hw = HOVER_WIDTH / zz
		for tile in _data.tiles:
			if tile.tile_id == hovered_tile_id and tile.polygon.size() >= 3:
				draw_polyline(_Geo.closed(tile.polygon), HOVER_COLOR, hw, true)
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
		_Layers.draw_city_labels(self)
	# 9. 玩家位置标记（R2 GPS 范式：中心点 + 静态环 + 脉冲扩散环，画在最上层）
	if _player_visible:
		_Layers.draw_player_marker(self, zz)


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


## 玩家位置标记绘制件在 map_renderer_layers.gd（static，第一参传宿主）；
## 邻湖判定容差/静态几何缓存构建在 map_renderer_geo.gd（build_cached_geometry，
## 写回本宿主 _cached_* / 河流 / 道路分级缓存字段；本壳名保留供 bench 直调）。
func _build_cached_geometry() -> void:
	_Geo.build_cached_geometry(self)


## 无向边去重 key：已迁 `MapSketch.edge_key`（L1 城界共享边去重 / L3 国界邻接共用）。


## 折线按 dash/gap 弧长切段：已迁 `MapSketch.dash_segments`（R8 层2 通用化——
## 路由高亮与 L2/L3 政治模式虚线界线共用同一实现）。
