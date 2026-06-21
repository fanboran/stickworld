extends Node2D
class_name MapRenderer
## 世界地图核心渲染器 —— P社 Clausewitz 引擎风格的像素-省份映射系统
##
## 核心原理：
##   region_mask_texture 是一张索引颜色图，每个像素的 RGB 值通过 ID<->RGB 编码
##   唯一地对应一个 region_id。这与 P社的 provinces.bmp 机制完全一致。
##
##   渲染管线：
##     1. 绘制底图（base_map_texture）
##     2. 对每个像素读取 region_mask 获取 region_id
##     3. 根据当前地图模式，查找该 region_id 对应的颜色
##     4. 将该颜色以半透明叠加绘制到底图上
##   鼠标点击检测也是同样的原理 —— 采样点击位置的像素即可获知点击了哪个地块。

## 区域索引纹理（每个像素的RGB对应一个region_id）
@export var region_mask_texture: Texture2D

## 基础底图纹理（美术图层，提供地形视觉）
@export var base_map_texture: Texture2D

## 世界地图全局数据
@export var world_data: WorldMapData

## 颜色缓存（按地图模式预计算，避免每帧重算）
var _color_cache: Dictionary = {}  # {mode_int: {region_id_int: Color}}

## 当前地图模式
var current_mode: int = 0  # 0=POLITICAL, 1=TERRAIN, 2=RESOURCE

## 当前悬停的地块ID（-1表示无）
var hovered_region_id: int = -1

## 当前选中的地块ID（-1表示无）
var selected_region_id: int = -1

## 高亮叠加不透明度
@export var overlay_alpha: float = 0.5

## 选中高亮颜色
@export var selection_color: Color = Color(1.0, 0.85, 0.2, 0.4)

## 悬停高亮颜色
@export var hover_color: Color = Color(1.0, 1.0, 1.0, 0.25)

## 边框颜色
@export var border_color: Color = Color(0.0, 0.0, 0.0, 0.3)

## 调试模式：绘制 region_id 标签
@export var debug_show_labels: bool = false

## ID编码时各通道的位偏移
const ID_R_SHIFT: int = 16
const ID_G_SHIFT: int = 8
const ID_B_SHIFT: int = 0
const ID_MASK: int = 0xFF


# ===== ID <-> 颜色编码（与P社 provinces.bmp 的RGB编码逻辑等价）=====

## 将 region_id 编码为 RGB Color
static func id_to_color(rid: int) -> Color:
	return Color(
		float((rid >> ID_R_SHIFT) & ID_MASK) / 255.0,
		float((rid >> ID_G_SHIFT) & ID_MASK) / 255.0,
		float((rid >> ID_B_SHIFT) & ID_MASK) / 255.0,
		1.0
	)

## 将 RGB Color 解码为 region_id
static func color_to_id(c: Color) -> int:
	var r: int = int(c.r * 255.0) & ID_MASK
	var g: int = int(c.g * 255.0) & ID_MASK
	var b: int = int(c.b * 255.0) & ID_MASK
	return (r << ID_R_SHIFT) | (g << ID_G_SHIFT) | (b << ID_B_SHIFT)


func _ready():
	_rebuild_color_cache(0)
	_rebuild_color_cache(1)
	_rebuild_color_cache(2)

## 重建指定地图模式的颜色缓存
func _rebuild_color_cache(mode: int) -> void:
	if world_data == null:
		return
	var cache: Dictionary = {}
	for rid in world_data.regions.keys():
		cache[rid] = world_data.get_region_color(rid, mode)
	_color_cache[mode] = cache


# ===== 地块查询 =====

## 根据地图空间坐标获取 region_id
## 地图中心为原点 (0,0)，X 向右，Y 向下
func get_region_id_at_map_position(map_pos: Vector2) -> int:
	if region_mask_texture == null:
		return -1
	var mask_img: Image = region_mask_texture.get_image()
	if mask_img.is_empty():
		return -1

	var tex_size: Vector2i = region_mask_texture.get_size()
	var half_size: Vector2 = Vector2(tex_size) / 2.0

	# 地图坐标 → 纹理像素坐标
	var tex_x: int = int(map_pos.x + half_size.x)
	var tex_y: int = int(map_pos.y + half_size.y)

	if tex_x < 0 or tex_x >= tex_size.x or tex_y < 0 or tex_y >= tex_size.y:
		return -1

	var pixel_color: Color = mask_img.get_pixel(tex_x, tex_y)
	return color_to_id(pixel_color)

## 根据屏幕坐标获取 region_id
func get_region_id_at_screen_position(screen_pos: Vector2) -> int:
	var map_pos: Vector2 = to_local(screen_pos)
	return get_region_id_at_map_position(map_pos)


# ===== 渲染入口 =====

func _process(_delta: float):
	# 悬停检测
	var mouse_pos: Vector2 = get_global_mouse_position()
	if is_visible_in_tree():
		var in_viewport: bool = (get_viewport() != null and
			get_viewport().get_visible_rect().has_point(mouse_pos))
		if in_viewport:
			hovered_region_id = get_region_id_at_screen_position(mouse_pos)
	queue_redraw()

func _draw():
	_draw_base_map()
	_draw_mode_overlay()
	_draw_borders()
	if hovered_region_id != -1:
		_draw_highlight(hovered_region_id, hover_color)
	if selected_region_id != -1:
		_draw_highlight(selected_region_id, selection_color)
	if debug_show_labels:
		_draw_debug_labels()

## 绘制底图
func _draw_base_map():
	if base_map_texture == null:
		return
	var tex_size: Vector2 = base_map_texture.get_size()
	draw_texture(base_map_texture, -tex_size / 2.0)

## 绘制当前模式的叠加层
## 基于P社思路：逐像素读取索引图 → 查表获取显示颜色 → 叠加绘制
func _draw_mode_overlay():
	if region_mask_texture == null or world_data == null:
		return

	var mask_img: Image = region_mask_texture.get_image()
	if mask_img.is_empty():
		return

	var cache: Dictionary = _color_cache.get(current_mode, {})
	var tex_size: Vector2i = region_mask_texture.get_size()
	var half_size: Vector2 = Vector2(tex_size) / 2.0

	# 逐像素处理 —— 对于小地图（1024x512）完全可行
	# 对于大地图可以降采样或使用Shader来做
	for y in range(0, tex_size.y, 2):
		for x in range(0, tex_size.x, 2):
			var pixel: Color = mask_img.get_pixel(x, y)
			var rid: int = color_to_id(pixel)
			var display_color: Color = cache.get(rid, Color(0.5, 0.5, 0.5, overlay_alpha))
			if display_color.a < 0.01:
				continue
			display_color.a *= overlay_alpha
			draw_rect(Rect2(
				float(x) - half_size.x,
				float(y) - half_size.y,
				2.0, 2.0
			), display_color)

## 绘制地块边界
func _draw_borders():
	if region_mask_texture == null:
		return
	var mask_img: Image = region_mask_texture.get_image()
	if mask_img.is_empty():
		return

	var tex_size: Vector2i = region_mask_texture.get_size()
	var half_size: Vector2 = Vector2(tex_size) / 2.0

	# 检测像素邻接的边界边缘（邻接像素属于不同region_id即为边界）
	var border_step: int = 4
	for y in range(0, tex_size.y, border_step):
		for x in range(0, tex_size.x, border_step):
			var current: int = color_to_id(mask_img.get_pixel(x, y))

			# 检查右侧邻居
			if x + border_step < tex_size.x:
				var right: int = color_to_id(mask_img.get_pixel(x + border_step, y))
				if current != right:
					draw_line(
						Vector2(float(x + border_step) - half_size.x, float(y) - half_size.y),
						Vector2(float(x + border_step) - half_size.x, float(y + border_step) - half_size.y),
						border_color, 1.0
					)

			# 检查下方邻居
			if y + border_step < tex_size.y:
				var down: int = color_to_id(mask_img.get_pixel(x, y + border_step))
				if current != down:
					draw_line(
						Vector2(float(x) - half_size.x, float(y + border_step) - half_size.y),
						Vector2(float(x + border_step) - half_size.x, float(y + border_step) - half_size.y),
						border_color, 1.0
					)

## 绘制地块高亮
func _draw_highlight(rid: int, h_color: Color):
	if region_mask_texture == null:
		return
	var mask_img: Image = region_mask_texture.get_image()
	if mask_img.is_empty():
		return

	var tex_size: Vector2i = region_mask_texture.get_size()
	var half_size: Vector2 = Vector2(tex_size) / 2.0

	for y in range(0, tex_size.y, 2):
		for x in range(0, tex_size.x, 2):
			var pixel: Color = mask_img.get_pixel(x, y)
			if color_to_id(pixel) == rid:
				draw_rect(Rect2(
					float(x) - half_size.x,
					float(y) - half_size.y,
					2.0, 2.0
				), h_color)

## 调试：绘制所有地块ID标签
func _draw_debug_labels():
	if world_data == null:
		return
	for rid in world_data.regions:
		var region: RegionDefinition = world_data.regions[rid]
		if region.center_position != Vector2.ZERO:
			draw_string(
				ThemeDB.fallback_font,
				region.center_position,
				"%d:%s" % [rid, region.name],
				HORIZONTAL_ALIGNMENT_CENTER,
				-1,
				10
			)


# ===== 公共方法 =====

## 设置地图模式并重建缓存
func set_map_mode(mode: int):
	current_mode = mode
	if not _color_cache.has(mode):
		_rebuild_color_cache(mode)

## 刷新颜色缓存（归属变化时调用）
func refresh_cache():
	_rebuild_color_cache(0)
	_rebuild_color_cache(1)
	_rebuild_color_cache(2)

## 选中地块
func select_region(rid: int):
	selected_region_id = rid

## 取消选中
func deselect_region():
	selected_region_id = -1

## 获取当前悬停地块
func get_hovered_region() -> int:
	return hovered_region_id

## 获取当前选中地块
func get_selected_region() -> int:
	return selected_region_id
