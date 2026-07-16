extends Node2D
class_name MapRenderer
## 战略图渲染器 —— 分层级差异化渲染
##
## 详见 docs/技术/架构/战略图架构.md §四 渲染架构
##
## 渲染策略（按粒度）：
##   L3 大世界：预渲染风格化底图 + Shader 叠加边界/政治色（P0 用 _draw 简版）
##   L2 地区：预渲染底图 + 地标图标 + 聚落规模指示
##   L1 地块：地形底图 + 动态聚落建筑群（SettlementRenderer）+ 道路 + 资源
##
## P0 简版：用 GDScript _draw 实现，不上 Shader（P1 再上）
## P1 完整版：Shader 驱动（region_overlay.shader + border_outline.shader）

## 关联的数据容器
@export var data: StrategicMapData

## 关联的聚落建筑群渲染器（L1 用）
@export var settlement_renderer: SettlementRenderer

## 颜色缓存（按地图模式预计算）
## {mode_int: {id_string: Color}}
var _color_cache: Dictionary = {}

## 当前地图模式
var current_mode: int = 0  # 0=POLITICAL, 1=TERRAIN, 2=RESOURCE, 3=STICKMAN, 4=BATTLEFRONT

## 当前悬停的 ID（""表示无）
var hovered_id: String = ""

## 当前选中的 ID（""表示无）
var selected_id: String = ""

## 叠加层不透明度
@export var overlay_alpha: float = 0.5

## 选中高亮颜色
@export var selection_color: Color = Color(1.0, 0.85, 0.2, 0.4)

## 悬停高亮颜色
@export var hover_color: Color = Color(1.0, 1.0, 1.0, 0.25)

## 边框颜色
@export var border_color: Color = Color(0.0, 0.0, 0.0, 0.3)

## 调试模式：绘制 ID 标签
@export var debug_show_labels: bool = false

## 战线标记列表（运行时动态）
## {battle_id: {"region_id": String, "tile_id": String, "position": Vector2}}
var _battlefront_markers: Dictionary = {}


func _ready() -> void:
	_rebuild_color_cache(0)
	_rebuild_color_cache(1)
	_rebuild_color_cache(2)


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	# 悬停检测
	var mouse_pos: Vector2 = get_global_mouse_position()
	var in_viewport: bool = (get_viewport() != null and
		get_viewport().get_visible_rect().has_point(mouse_pos))
	if in_viewport and data != null:
		var query: Dictionary = data.query_id_at_screen(mouse_pos)
		var new_hovered: String = _get_query_id(query)
		if new_hovered != hovered_id:
			hovered_id = new_hovered
	queue_redraw()


func _draw() -> void:
	if data == null:
		return
	match data.current_granularity:
		StrategicMapData.Granularity.L3_CONTINENT:
			_draw_l3()
		StrategicMapData.Granularity.L2_REGION:
			_draw_l2()
		StrategicMapData.Granularity.L1_TILE:
			_draw_l1()
	_draw_battlefront_markers()
	if debug_show_labels:
		_draw_debug_labels()


# ===== L3 大世界渲染（P0 简版：底图 + _draw 叠加） =====

func _draw_l3() -> void:
	# TODO: SM-1 实现
	# 1. 绘制 continent.style_base_texture（风格化底图，含草坪/火山/山脉/河流）
	# 2. 按当前地图模式叠加边界色（_draw_mode_overlay_l3）
	# 3. 绘制地区边界描边
	# 4. 绘制政权边界（粗线）
	# 5. 绘制悬停/选中高亮
	if data.continent == null:
		return
	if data.continent.style_base_texture != null:
		var tex_size: Vector2 = data.continent.style_base_texture.get_size()
		draw_texture(data.continent.style_base_texture, -tex_size / 2.0)
	# P1: Shader 叠加边界/政治色（P0 简版跳过，只显示底图）
	_draw_highlight_if_any()


# ===== L2 地区渲染（P0 简版：底图 + 地标图标） =====

func _draw_l2() -> void:
	# TODO: SM-2 实现
	# 1. 绘制 region.style_base_texture（该地区风格化底图）
	# 2. 按地图模式叠加地块边界色
	# 3. 绘制 Q版地标图标（从 region.landmarks）
	# 4. 绘制聚落规模指示（每地块中心聚落用不同大小图标）
	# 5. 绘制悬停/选中高亮
	var region: RegionData = data.get_current_region()
	if region == null:
		return
	if region.style_base_texture != null:
		var tex_size: Vector2 = region.style_base_texture.get_size()
		draw_texture(region.style_base_texture, -tex_size / 2.0)
	# P1: 地标图标 + 地块边界叠加
	_draw_highlight_if_any()


# ===== L1 地块渲染（重度程序化：底图 + 动态聚落建筑群） =====

func _draw_l1() -> void:
	# TODO: SM-3 实现
	# 1. 绘制 tile.style_base_texture（该地块地形纹理底图）
	# 2. 绘制河流（从 tile.rivers 矢量）
	# 3. 绘制聚落建筑群（调用 settlement_renderer，按 level + population_score 生成）
	# 4. 绘制聚落间道路（从 tile.roads 矢量）
	# 5. 绘制资源点图标（从 tile.resources）
	# 6. 绘制聚落领地边界（淡色填充）
	# 7. 绘制悬停/选中高亮
	var tile: MapTileData = data.get_current_tile()
	if tile == null:
		return
	if tile.style_base_texture != null:
		var tex_size: Vector2 = tile.style_base_texture.get_size()
		draw_texture(tile.style_base_texture, -tex_size / 2.0)
	# P1: 动态聚落建筑群 + 道路 + 资源图标
	_draw_highlight_if_any()


# ===== 高亮 =====

func _draw_highlight_if_any() -> void:
	# TODO: SM-1 实现
	# 按当前粒度的边界索引图，高亮 hovered_id 和 selected_id 对应的区域
	if not hovered_id.is_empty():
		_draw_highlight_for_id(hovered_id, hover_color)
	if not selected_id.is_empty():
		_draw_highlight_for_id(selected_id, selection_color)


func _draw_highlight_for_id(id: String, color: Color) -> void:
	# TODO: SM-1 实现
	# 查找 id 对应的多边形，填充 color
	pass


# ===== 战线标记 =====

func _draw_battlefront_markers() -> void:
	# TODO: P1 实现
	# 在战略图上叠加战线标记（剑交叉、火焰等图标）
	pass


func add_battlefront_marker(battle_id: String, region_id: String, tile_id: String) -> void:
	# TODO: P1 实现
	# 计算标记位置（region/tile 中心），加入 _battlefront_markers
	_battlefront_markers[battle_id] = {"region_id": region_id, "tile_id": tile_id}
	queue_redraw()


func remove_battlefront_marker(battle_id: String) -> void:
	_battlefront_markers.erase(battle_id)
	queue_redraw()


# ===== 调试标签 =====

func _draw_debug_labels() -> void:
	# TODO: SM-1 实现
	# 按当前粒度绘制所有 ID + 名称
	pass


# ===== 颜色缓存 =====

func _rebuild_color_cache(mode: int) -> void:
	# TODO: SM-1 实现
	# 按地图模式预计算每个 ID 的显示色
	# POLITICAL: 按 political_owner 着色
	# TERRAIN: 按 biome 着色
	# RESOURCE: 按 resource_types 着色
	_color_cache[mode] = {}


# ===== 公共方法 =====

func set_map_mode(mode: int) -> void:
	current_mode = mode
	if not _color_cache.has(mode):
		_rebuild_color_cache(mode)
	queue_redraw()


func refresh() -> void:
	# 归属/数据变化时刷新
	_rebuild_color_cache(0)
	_rebuild_color_cache(1)
	_rebuild_color_cache(2)
	queue_redraw()


func refresh_settlement(settlement_id: String) -> void:
	# L1 粒度下聚落规模变化时，重新渲染该聚落
	# TODO: SM-3/P1 实现
	# settlement_renderer.refresh(settlement_id)
	queue_redraw()


func select(id: String) -> void:
	selected_id = id
	queue_redraw()


func deselect() -> void:
	selected_id = ""
	queue_redraw()


func get_selected() -> String:
	return selected_id


func get_hovered() -> String:
	return hovered_id


# ===== 内部辅助 =====

func _get_query_id(query: Dictionary) -> String:
	var g: int = query.get("granularity", 0)
	match g:
		0: return query.get("region_id", "")
		1: return query.get("tile_id", "")
		2: return query.get("settlement_id", "")
	return ""
