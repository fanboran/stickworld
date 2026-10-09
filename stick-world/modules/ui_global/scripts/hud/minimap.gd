class_name Minimap
extends Control
## 小地图 —— 屏幕正上方中央的本地块缩略图。
##
## 详见 docs/技术/架构/场景与战斗/UI.md §10.4。
##
## 显示内容（绘制核见 minimap_painter.gd，与放大版窗口共用同一投影）：
##   - 地表：按地图侧供给的材质色带铺实际颜色（主街石板 / 城外草地，不再是全幅纯绿）
##   - 建筑：按世界实际材质色缩略（不再分类硬编码黄点）
##   - 实体点：玩家（绿点+呼吸光环）/ 同阵营（蓝）/ 敌方（红）/ 中立 NPC·村民（淡土石）
##     ——位置按实体实际纵深落点（地面带内映射，不再一律钉在天地分界线上）
##   - 视野框（红框）
##
## 体量：高固定 120，宽按**等比例尺**随地图宽自适应（见 _desired_width），
## 上限受顶栏两侧按钮群之间的空档（减去 L1 缩略窗占位）钳制，
## 位置归 zone（top_center 全跨度内居中，见 hud_zone_layout.gd）。
##
## 交互：
##   - 左键点击/拖动：相机跳转到点击位置（RTS 式，暂停自动跟随）
##   - 双击 / 点右上角展开把手：发 expand_requested 展开成放大版（装配层开窗）
##     单击保留 RTS 跳转（已验收语义），故展开不复用单击
##
## 由 GameRoot 在装配时创建并 add_child 到 UIRoot，随后调用 setup(game_root)。

# ─────────────────────────────── 常量 ────────────────────────────────
## 小地图高度（屏幕像素；地面带比例由地图 ground_ratio 决定）
const MAP_HEIGHT: float = 120.0
## 宽度可读下限（px）：比这更窄就退回固定宽度，宁可比例失真也不越走越小
const BASE_WIDTH: float = 360.0
## 实体点/视野框更新频率（Hz，节流避免每帧重算）
const UPDATE_HZ: float = 15.0
## 右上角展开把手尺寸与内缩（px）
const GLYPH_BOX: float = 16.0
const GLYPH_INSET: float = 3.0

## 请求展开放大版（装配层接线开 MinimapWindow）
signal expand_requested

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _camera_rig: Node = null

# ─────────────────────────────── 状态 ────────────────────────────────
## 地图投影参数 [left, right, ground_y, ground_ratio]（set_map_info 注入）
var _map_info: Array = [0.0, 8192.0, 720.0, 0.334]
var _has_map_info: bool = false
## 当前宽度（随地图/画布自适应；高度恒 MAP_HEIGHT）
var _width: float = BASE_WIDTH
var _update_accum: float = 0.0
var _dragging: bool = false
var _hover: bool = false


# ─────────────────────────────── 装配 ────────────────────────────────

func _ready() -> void:
	# 体量声明：定位归 zone（SystemSetup 经 UIRoot.place_in_zone 钉进 top_center，
	# 见 hud_zone_layout.gd），本部件不自算屏幕坐标
	custom_minimum_size = Vector2(_width, MAP_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_refresh_size):
		vp.size_changed.connect(_refresh_size)


## 由 GameRoot 调用，注入引用。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_camera_rig = game_root.camera_rig if game_root.has_method("get") else null
	if _camera_rig == null and game_root.get("camera_rig") != null:
		_camera_rig = game_root.camera_rig


## 设置地图信息（地图加载时由 GameRoot 调用，详见 §10.4.6）
func set_map_info(p_map_left: float, p_map_right: float, p_ground_y: float, p_ground_ratio: float) -> void:
	_map_info = [p_map_left, p_map_right, p_ground_y, p_ground_ratio]
	_has_map_info = true
	_refresh_size()
	queue_redraw()


# ─────────────────────────────── 体量自适应 ────────────────────────────────

## 当前小地图宽度（px）——外部（L1 缩略窗定位 / 测试）读体量的唯一出口
func get_map_width_px() -> float:
	return _width


## 地图投影参数 [left, right, ground_y, ground_ratio]（放大版窗口据此复用同一投影）
func get_map_info() -> Array:
	return _map_info


## 小地图高度（px）——烘焙底图尺寸按它算（外部读体量的出口）
func get_map_height_px() -> float:
	return MAP_HEIGHT


## 期望宽度：**等比例尺**——画面构图决定地面带像素高（`高 × ground_ratio`），
## 该像素高代表地图的地面世界深度，由此定出"世界 px / 小地图 px"；横向同比例尺
## 取宽。于是：地图越宽小地图越宽（"保持比例尺"），且**横纵同比例尺、房屋/地块
## 形状不变形**（否则实际"宽 > 深"的房子会画成"高 > 宽"）。
func _desired_width() -> float:
	var map_w: float = maxf(float(_map_info[1]) - float(_map_info[0]), 1.0)
	var band_px: float = maxf(MAP_HEIGHT * float(_map_info[3]), 1.0)
	var scale: float = maxf(_ground_depth() / band_px, 0.001)
	return map_w / scale


## 地面带世界深度（ground_y..ground_bottom）。地图未就绪（占位期）按屏高构图反推，
## 避免装配途中的宽度跳变。
func _ground_depth() -> float:
	var map := _get_current_map()
	if map != null and map.has_method("get_ground_bottom"):
		return maxf(float(map.get_ground_bottom()) - float(_map_info[2]), 1.0)
	return 1080.0 * float(_map_info[3])


## 可用宽度上限（空档宽 − L1 缩略窗占位；HudZoneLayout 是布局真相源）
func _max_width() -> float:
	var vp := get_viewport()
	var vp_x: float = vp.get_visible_rect().size.x if vp != null else 1920.0
	return HudZoneLayout.top_center_map_max_width(vp_x)


## 重算并应用宽度（地图变化 / 画布尺寸变化时调用）。
## 下限 360：空档太窄（或画布异形）时退回固定宽度，接受与按钮群接近/重叠，
## 不把地图缩到看不清（口径见待办"窄跨度/超宽地图时钳回 360"）。
func _refresh_size() -> void:
	var cap: float = _max_width()
	var w: float = clampf(_desired_width(), BASE_WIDTH, cap)
	w = maxf(w, BASE_WIDTH)
	if is_equal_approx(w, _width):
		return
	_width = w
	custom_minimum_size = Vector2(_width, MAP_HEIGHT)
	queue_redraw()


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _process(delta: float) -> void:
	# 节流重绘（15Hz 足够，实体点/视野框不需要每帧）
	_update_accum += delta
	if _update_accum >= 1.0 / UPDATE_HZ:
		_update_accum = 0.0
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var was_hover: bool = _hover
		_hover = _expand_glyph_rect().has_point(event.position)
		if _hover != was_hover:
			queue_redraw()
		if _dragging and _has_map_info:
			_jump_to_mouse(event.position)
		return
	if not _has_map_info:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# 展开把手 / 双击 = 展开（单击保留 RTS 相机跳转语义）
			if _expand_glyph_rect().has_point(event.position) or event.double_click:
				expand_requested.emit()
				accept_event()
				return
			_dragging = true
			_jump_to_mouse(event.position)
		else:
			_dragging = false


## 鼠标移出收起把手高亮
func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover:
		_hover = false
		queue_redraw()


# ─────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, Vector2(_width, MAP_HEIGHT))
	if not _has_map_info:
		_draw_placeholder(rect)
		return
	var map: Node2D = _get_current_map()
	var snap: Dictionary = MinimapPainter.build_snapshot(map, _map_info)
	var points: Array = MinimapPainter.collect_points(map)
	MinimapPainter.draw(self, rect, snap, points, {"viewport_world": _viewport_world()})
	_draw_expand_glyph(rect)


func _draw_placeholder(rect: Rect2) -> void:
	draw_rect(rect, StickTokens.WINDOW_BG, true)
	draw_rect(rect, StickTokens.BORDER_STRONG, false, MinimapPainter.BORDER_W)
	_draw_expand_glyph(rect)


## 右上角展开把手：常态淡显（可发现）、悬停高亮。图标 = 底板 + 右上外指箭头，
## 点击热区见 _expand_glyph_rect。
func _draw_expand_glyph(rect: Rect2) -> void:
	var g := _expand_glyph_rect()
	var a: float = 0.95 if _hover else 0.5
	var col := Color(1.0, 1.0, 1.0, a)
	var box := Rect2(g.position + Vector2(3.0, 3.0), Vector2(GLYPH_BOX - 6.0, GLYPH_BOX - 6.0))
	draw_rect(box, Color(0.05, 0.04, 0.03, a * 0.55), true)
	draw_rect(box, col, false, 1.0)
	var p: Vector2 = box.position + box.size - Vector2(1.0, 1.0)
	draw_line(p, p - Vector2(4.0, 4.0), col, 1.0)
	draw_line(p, p - Vector2(4.0, 0.0), col, 1.0)
	draw_line(p, p - Vector2(0.0, 4.0), col, 1.0)


func _expand_glyph_rect() -> Rect2:
	return Rect2(Vector2(_width - GLYPH_BOX - GLYPH_INSET, GLYPH_INSET),
			Vector2(GLYPH_BOX, GLYPH_BOX))


## 相机可视世界范围（供绘制核画视野框；相机不可用时返回空 Rect2 = 不画）
func _viewport_world() -> Rect2:
	if _camera_rig == null or not _camera_rig.has_method("get_viewport_rect_world"):
		return Rect2()
	return _camera_rig.get_viewport_rect_world()


# ─────────────────────────────── 坐标映射 ────────────────────────────────

## 小地图 X → 世界坐标 X（公开：点击跳转与外部查询共用同一投影）
func minimap_to_world_x(minimap_x: float) -> float:
	var rect := Rect2(Vector2.ZERO, Vector2(_width, MAP_HEIGHT))
	return MinimapPainter.x_to_world(minimap_x, rect,
			MinimapPainter.build_snapshot(_get_current_map(), _map_info))


# ─────────────────────────────── 交互 ────────────────────────────────

## 点击/拖动小地图 → 相机跳转（RTS 式，暂停自动跟随，详见 §10.4.5）
func _jump_to_mouse(local_pos: Vector2) -> void:
	if _camera_rig == null or not _camera_rig.has_method("jump_to_x"):
		return
	_camera_rig.jump_to_x(minimap_to_world_x(local_pos.x))


# ─────────────────────────────── 内部辅助 ────────────────────────────────

func _get_current_map() -> Node2D:
	if _game_root == null:
		return null
	if _game_root.has_method("get_current_map"):
		return _game_root.get_current_map()
	return null
