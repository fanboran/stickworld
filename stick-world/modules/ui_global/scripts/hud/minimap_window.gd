class_name MinimapWindow
extends StickWindow
## 本地地图·放大版 —— 顶部小地图展开后的浮窗（FLOATING，非模态）。
##
## 打开路径：顶部小地图右上角展开把手 / 双击小地图（Minimap.expand_requested
## 经装配层接线到此窗）。语义 = "把小地图放大看清楚"：
##   - 同一投影（MinimapPainter 单出口），位置与顶部小地图逐像素对应；
##   - 尺寸够大，故默认走**建筑类型着色 + 图例**（居住/生产/商业/市政/军事
##     一眼可读），由开关切回"实际颜色"（与小地图同色）；
##   - 地表两种模式都按实际材质色铺（类型着色的作用对象是建筑——地面跟着换色
##     会让人以为地表变了）。
##
## 交互：窗口内点击地图 → 相机跳转到该处（与小地图同 RTS 语义）；ESC / ✕ 关闭
##（StickWindow 基类行为，不触发暂停菜单）。
##
## 由 SystemSetup 装配到 UIRoot.ModalOverlay（与 OrgPanel/FormationPanel 同挂法），
## 创建后常驻隐藏，开合走 open()/close()。

# ─────────────────────────────── 常量 ────────────────────────────────
## 放大倍数（相对顶部小地图的地图区宽度；等比例尺下即"看得大这么多倍"）
const ZOOM := 1.5
## 地图区宽度钳制范围（px）：太窄看不清、太宽出安全区
const MAP_MIN_W := 640.0
const MAP_MAX_W := 1600.0
## 右侧图例列宽（色块 + 文案竖排）
const LEGEND_W: float = 84.0
## 重绘频率（Hz，与 Minimap 同节拍——实体点/光环需要动）
const UPDATE_HZ: float = 15.0
## 窗口非地图区的固定高度（标题栏 30 + 工具行+间距 44）
const CHROME_H := 74.0
const CHROME_W := 24.0

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
## 顶部小地图（地图投影参数的唯一来源，避免两处各自读 map 字段）
var _minimap: Control = null
## true = 类型着色（默认，放大版的意义所在）；false = 实际颜色（与小地图同色）
var _type_mode: bool = true
var _canvas: MinimapCanvas = null
var _mode_btn: Button = null
var _accum: float = 0.0
## 地图区宽 / 画布总高（等比例尺推出，见 refresh_geometry）
var _map_px_w: float = 900.0
var _total_h: float = 300.0


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 SystemSetup 调用，注入引用并构建 UI。
func setup(game_root: Node, minimap: Control) -> void:
	_game_root = game_root
	_minimap = minimap
	window_title = "本地地图"
	behavior = StickWindow.Behavior.FLOATING
	window_size = Vector2(_map_px_w + LEGEND_W + CHROME_W, _total_h + CHROME_H)
	_build_window()
	refresh_geometry()


func _build_content() -> void:
	var bar := StickKit.row(_body)
	_mode_btn = StickKit.sketch_button(bar, _mode_text(), _on_mode_pressed)
	StickKit.label(bar, "单击地图跳转视角 · 顶部小地图双击再次展开", StickKit.LabelKind.HINT)
	_canvas = MinimapCanvas.new()
	_canvas.name = "MapCanvas"
	_canvas.window = self
	_canvas.custom_minimum_size = Vector2(_map_px_w + LEGEND_W, _total_h)
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_canvas)


## 按顶部小地图体量重算地图区几何：**同一张图放大 ZOOM 倍**——
## 地图区 = 小地图矩形 × ZOOM（同比），故两处比例尺一致、底图与点位都不会被拉伸
## （照片底图、俯视平面图两条路径都靠这条成立）。
func refresh_geometry() -> void:
	_map_px_w = clampf(_minimap_map_px() * ZOOM, MAP_MIN_W, MAP_MAX_W)
	_total_h = _map_px_w * Minimap.MAP_HEIGHT / maxf(_minimap_map_px(), 1.0)
	window_size = Vector2(_map_px_w + LEGEND_W + CHROME_W, _total_h + CHROME_H)
	if _canvas != null:
		_canvas.custom_minimum_size = Vector2(_map_px_w + LEGEND_W, _total_h)


## 顶部小地图的地图区宽度（px；放大倍数以它为基准）
func _minimap_map_px() -> float:
	if _minimap != null and _minimap.has_method("get_map_width_px"):
		return float(_minimap.get_map_width_px())
	return 420.0


## 地图区尺寸（MinimapCanvas 取用：宽 × 画布总高，地面带 = 总高 × ground_ratio）
func map_px_w() -> float:
	return _map_px_w


func total_h() -> float:
	return _total_h


func _process(delta: float) -> void:
	if not visible or _canvas == null:
		return
	_accum += delta
	if _accum >= 1.0 / UPDATE_HZ:
		_accum = 0.0
		_canvas.queue_redraw()


func open() -> void:
	super()
	# 每次打开复位到默认类型着色（放大版的意义），并按当前地图态重算几何
	_type_mode = true
	if _mode_btn != null:
		_mode_btn.text = _mode_text()
	refresh_geometry()
	# 体量变了要重新居中（基类只在构建时定位一次；FLOATING 即屏中居中 + 夹安全区）
	_position_panel()
	if _mode_btn != null:
		_mode_btn.visible = not has_photo_base()
	_accum = 0.0
	if _canvas != null:
		_canvas.queue_redraw()


# ─────────────────────────────── 绘制区取数（MinimapCanvas 调用）────────────────────────────────

## 绘制区节点（验收断言/外部查询用）
func canvas() -> Control:
	return _canvas


## 是否已有照片底图。有则类型着色无处可用（照片本身就是实际颜色、前排不再画色块）
## ——开关与图例据此隐藏，避免"按了没反应"的假按钮。
func has_photo_base() -> bool:
	var snap: Dictionary = MinimapPainter.build_snapshot(current_map(), map_info())
	var base: Dictionary = snap.get("base", {})
	return not base.is_empty() and base.get("texture") != null


func is_type_mode() -> bool:
	return _type_mode


func color_mode() -> String:
	return MinimapPainter.MODE_TYPE if _type_mode else MinimapPainter.MODE_ACTUAL


func current_map() -> Node2D:
	if _game_root == null or not _game_root.has_method("get_current_map"):
		return null
	return _game_root.get_current_map()


## 地图投影参数：取自顶部小地图（单一来源）
func map_info() -> Array:
	if _minimap != null and _minimap.has_method("get_map_info"):
		return _minimap.get_map_info()
	return [0.0, 8192.0, 720.0, 0.334]


func viewport_world() -> Rect2:
	if _game_root == null or _game_root.camera_rig == null:
		return Rect2()
	var rig: Node = _game_root.camera_rig
	if not rig.has_method("get_viewport_rect_world"):
		return Rect2()
	return rig.get_viewport_rect_world()


func jump_camera_at(local_x: float, map_rect: Rect2) -> void:
	if _game_root == null or _game_root.camera_rig == null:
		return
	var rig: Node = _game_root.camera_rig
	if not rig.has_method("jump_to_x"):
		return
	var snap: Dictionary = MinimapPainter.build_snapshot(current_map(), map_info())
	rig.jump_to_x(MinimapPainter.x_to_world(local_x, map_rect, snap))


# ─────────────────────────────── 内部 ────────────────────────────────

func _on_mode_pressed() -> void:
	_type_mode = not _type_mode
	if _mode_btn != null:
		_mode_btn.text = _mode_text()
	if _canvas != null:
		_canvas.queue_redraw()


func _mode_text() -> String:
	return "类型着色：%s" % ("开" if _type_mode else "关")
