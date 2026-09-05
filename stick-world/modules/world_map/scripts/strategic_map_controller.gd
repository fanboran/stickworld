extends Node2D
class_name StrategicMapController
## 战略图主控制器（L1 单层）—— 串联组件，处理输入
##
## 结构对齐 L2（Tab L1 与 L2 一样）：底部 MapHUD（缩放条+百分比，默认缩放=100%）
## 挂在 CanvasLayer 同级 ZoomIndicator 节点，open 显示 / close 隐藏。
## 初始视角 = 整图适配（DEFAULT_ZOOM_MULT=1.0），地图居中（出生 L1 位于 context 中心），HUD 记为 100%；
## 首次打开适配后保留用户位置/缩放（与 L2/L3 一致）。
##
## 详见 docs/技术/架构/战略图架构.md §9（L1 版）
## 交互：
##   - 左键单击聚落：选中（发 settlement_clicked）
##   - 左键双击聚落：进入场景图（发 settlement_activated → api.enter_settlement）
##   - ESC：关闭战略图
##   - 中键拖拽 + 滚轮缩放（由 MapCamera 处理）

## 从 L2 下钻进入 L1 后，L1 的返回请求（ESC 触发；由接线方恢复 L2 显示）
signal back_requested

## 公共 API 引用（同一场景内）
@export var api: Node

## 组件引用
@export var map_renderer: MapRenderer
@export var map_camera: MapCamera

## 输入控制
@export var left_click_selects: bool = true
@export var double_click_enter: bool = true  ## 双击聚落进入场景图

## 双击判定：两次点击间隔（秒）
const DOUBLE_CLICK_INTERVAL: float = 0.3
var _last_click_time: float = -10.0
var _last_click_settlement: String = ""

## 默认缩放 = 整图适配（打开即见 context 全部陆地，出生 L1 居中，并以此作为 HUD 的 100%）
const DEFAULT_ZOOM_MULT := 1.0

## 底部 HUD（CanvasLayer 直接子节点，open/close 同步显隐）
var _hud: Control = null

## 粒度指示器 + 聚落 tooltip（CanvasLayer 直接子节点，open/close 同步显隐；
## 文案更新在 open()，tooltip 内容由其 _process 轮询渲染器 hover 状态）
var _indicator: GranularityIndicator = null
var _tooltip: Control = null

## 视图名牌 + 图例（CanvasLayer 直接子节点，同批显隐；内容在 open() 喂）
var _title_bar: MapTitleBar = null
var _legend: MapLegend = null

## 地图模式管理器（Content 子节点，B4：TERRAIN 默认/POLITICAL；图例/渲染器随模式切换）
var _mode_manager: MapModeManager = null

## 首次打开时设置初始视角（之后保留用户位置/缩放）
var _view_initialized: bool = false

## 是否从 L2 下钻进入（ESC 时返回 L2 而非关闭）
var _drill_from_l2: bool = false

## 玩家当前所在 L1 全局 label（默认出生；游戏内跨 L1 移动逻辑移动到其他 L1 时
## 调 set_player_l1 更新，Tab 打开跟随显示该 L1 的地图——下钻是临时查看，不改变它）
var _player_l1_label: int = 69


func _ready() -> void:
	_auto_find_components()
	# 层号统一走 LayerOrder 常量（本节点是 CanvasLayer 的 Content 子节点）
	var canvas := get_parent() as CanvasLayer
	if canvas != null:
		canvas.layer = LayerOrder.STRATEGIC_L1
	if api != null and api.has_method("setup"):
		api.setup(self, map_renderer, map_camera)
	# 渲染器悬停检测需要相机做屏幕->地图坐标换算
	if map_renderer != null and map_renderer.has_method("set_camera"):
		map_renderer.set_camera(map_camera)
	# 缩放/平移后即时重绘：描边/轮廓宽度跟随新 zoom（消除粗细滞后跳变）
	if map_camera != null and map_camera.has_method("set_map_renderer"):
		map_camera.set_map_renderer(map_renderer)
	# 地图模式（B4）：切模式 → 渲染器换层 + 图例换内容（HUD 模式条自行订阅广播）
	if _mode_manager != null and not _mode_manager.mode_changed.is_connected(_on_map_mode_changed):
		_mode_manager.mode_changed.connect(_on_map_mode_changed)
	# 底部 HUD（CanvasLayer 直接子节点）
	var layer := get_parent()
	if layer != null:
		_hud = layer.get_node_or_null("ZoomIndicator")


func _auto_find_components() -> void:
	# 组件是 StrategicMap 根节点的子节点（同场景内）
	if map_renderer == null:
		map_renderer = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is MapRenderer) as MapRenderer
	if map_camera == null:
		map_camera = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is MapCamera) as MapCamera
	if api == null:
		api = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c.name.to_lower() == "api")
	# 指示器/tooltip 挂 CanvasLayer 直下（Control 挂 Node2D 下 anchor 参照矩形为 0 会跑位），
	# 显隐由本控制器与 _hud 一同同步
	if _indicator == null:
		_indicator = MapControllerUtil.find_sibling(self, "GranularityIndicator") as GranularityIndicator
	if _tooltip == null:
		_tooltip = MapControllerUtil.find_sibling(self, "SettlementTooltip")
	if _title_bar == null:
		_title_bar = MapControllerUtil.find_sibling(self, "MapTitleBar") as MapTitleBar
	if _legend == null:
		_legend = MapControllerUtil.find_sibling(self, "MapLegend") as MapLegend
	if _mode_manager == null:
		_mode_manager = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is MapModeManager) as MapModeManager


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	# 左键：单击选中 / 双击进入
	if event is InputEventMouseButton and event.pressed:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_handle_left_click(mb.position)
	# ESC：统一走 handle_escape（下钻返回 L2 / 关闭地图）；消费事件防止
	# GameRoot 再收到后弹暂停菜单（GameRoot 也通过 handle_escape 分发，双路径互斥）
	elif event is InputEventKey and event.pressed:
		var key: InputEventKey = event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			handle_escape()
			get_viewport().set_input_as_handled()


## ESC 语义（由 GameRoot._handle_escape 统一分发，战略图打开时优先于暂停菜单）：
## 从 L2 下钻进入则返回 L2；否则关闭战略图
func handle_escape() -> bool:
	if _drill_from_l2:
		_drill_from_l2 = false
		visible = false
		if _hud != null:
			_hud.visible = false
		_set_overlay_visible(false)
		back_requested.emit()
	else:
		close()
	return true


## 指示器/名牌/图例/tooltip 显隐同步（CanvasLayer 直下子节点，不随 Content 自动隐藏）
func _set_overlay_visible(v: bool) -> void:
	if _indicator != null:
		_indicator.visible = v
	if _title_bar != null:
		_title_bar.visible = v
	if _legend != null:
		_legend.set_shown(v)
	if _tooltip != null and _tooltip.has_method("reset"):
		_tooltip.call("reset")  # 复位 hover 记忆，重开后按当前鼠标位置重新评估


func _handle_left_click(screen_pos: Vector2) -> void:
	if api == null or not api.has_method("query_at_screen"):
		return
	var query: Dictionary = api.query_at_screen(screen_pos)
	var settlement: SettlementRef = query.get("settlement", null)
	var tile: L1TileDef = query.get("tile", null)
	if settlement == null:
		# 点击空聚落地块：选中地块但不进入
		if tile != null and left_click_selects and api.has_method("select"):
			api.select(tile.tile_id)
		return
	# 双击判定
	var now: float = Time.get_ticks_msec() / 1000.0
	var is_double: bool = (
		settlement.settlement_id == _last_click_settlement
		and now - _last_click_time <= DOUBLE_CLICK_INTERVAL
	)
	_last_click_time = now
	_last_click_settlement = settlement.settlement_id
	if is_double and double_click_enter:
		api.enter_settlement(settlement.settlement_id)
	elif left_click_selects:
		api.select(settlement.settlement_id)
		if api.has_signal("settlement_clicked"):
			api.settlement_clicked.emit(settlement.settlement_id)


## 打开指定老 L1 地图（L2 点击 L1 下钻）：加载数据 + 重置视角适配新 context。
## 返回是否成功打开。
func open_l1(l1_label: int) -> bool:
	if api == null or not api.has_method("open_l1"):
		return false
	if not api.open_l1(l1_label):
		return false
	_drill_from_l2 = true
	_view_initialized = false
	open()
	return true


## 游戏内移动逻辑：玩家移动到其他 L1 地块时调用，Tab 打开跟随显示该 L1
## （默认出生 L1；移动跨 L1 前不改变）
func set_player_l1(l1_label: int) -> void:
	_player_l1_label = l1_label


## 打开战略图（由接线方调用）
## 透明背景悬浮：地图内容显示在屏幕中央（场景图保持可见作背景）
func open() -> void:
	# Tab 打开跟随玩家当前所在 L1：下钻后数据可能是其他 L1，这里切回玩家所在 L1
	# （已是则不动；切换了则重置视角适配新 context）
	if api != null and api.has_method("ensure_player_l1"):
		if api.ensure_player_l1(_player_l1_label):
			_view_initialized = false
	visible = true
	# 首次打开：初始视角 = 整图适配（默认 100%），地图居中（出生 L1 在 context 中心）；
	# 之后保留用户位置/缩放（与 L2 一致）
	if not _view_initialized:
		_view_initialized = true
		if map_camera != null and map_camera.has_method("set_zoom"):
			var vp := get_viewport()
			if vp != null:
				var vp_size: Vector2 = vp.get_visible_rect().size
				var msize: float = 1024.0
				if api != null and api.has_method("get_data"):
					var d: RefCounted = api.get_data()
					if d != null and d.size > 0:
						msize = float(d.size)
				var target_h: float = vp_size.y * 0.85
				var fit_zoom: float = target_h / msize
				# 默认缩放 = 整图适配（全部周边陆地可见，出生 L1 居中）
				var default_zoom: float = clampf(fit_zoom * DEFAULT_ZOOM_MULT,
						map_camera.min_zoom, map_camera.max_zoom)
				map_camera.set_zoom(default_zoom)
				# 默认缩放 = 整图适配 = 100%（HUD 百分比按此归一化显示）
				if _hud != null and _hud.has_method("set_default_zoom"):
					_hud.set_default_zoom(default_zoom)
				if map_camera.has_method("set_offset"):
					# 地图中心对准屏幕中心，打开即居中
					map_camera.set_offset(vp_size * 0.5 - Vector2(
						msize * default_zoom * 0.5, msize * default_zoom * 0.5))
	if _hud != null:
		_hud.visible = true
	# 地图模式（B4）：本视图关闭期间他视图可能切过模式（全局静态），打开时同步渲染器
	if map_renderer != null and map_renderer.has_method("set_map_mode"):
		map_renderer.set_map_mode(MapModeManager.current_mode)
	# 粒度指示：层级 + 当前地块号 + ESC 语义（直开=关闭 / 下钻=返回 L2）
	if _indicator != null and api != null and api.has_method("get_current_l1_label"):
		var l1_label: int = api.get_current_l1_label()
		_indicator.set_view("L1", "#%d" % l1_label, _drill_from_l2)
		if _title_bar != null:
			_update_title_bar(l1_label)
	_fill_legend()
	_set_overlay_visible(true)
	if EventBus != null:
		EventBus.strategic_map_opened.emit()


## 名牌内容：地块 #N + 聚落数概览
func _update_title_bar(l1_label: int) -> void:
	if _title_bar == null:
		return
	var n_settlements := 0
	if api != null and api.has_method("get_data"):
		var data: L1WorldData = api.get_data()
		if data != null:
			for tile in data.tiles:
				if tile.settlement != null:
					n_settlements += 1
	var subtitle := "%d 聚落" % n_settlements if n_settlements > 0 else ""
	_title_bar.set_content("L1", "地块 #%d" % l1_label, subtitle)


## 图例内容随地图模式切换（B4，走 MapLegend.set_title/set_entries）：
## TERRAIN = 地物水系（海洋/湖泊；B2 群系底图落地后在此追加群系色条目）
## POLITICAL = 政权色条目（与地图填充同色源 get_state_color）
func _fill_legend() -> void:
	if _legend == null:
		return
	if MapModeManager.current_mode == MapModeManager.Mode.TERRAIN:
		_legend.set_title("地形")
		_legend.set_entries([
			{"color": MapRenderer.OCEAN_COLOR, "text": "海洋"},
			{"color": MapRenderer.LAKE_COLOR, "text": "湖泊"},
		])
		return
	if api == null or not api.has_method("get_states"):
		return
	var data: L1WorldData = api.get_data() if api.has_method("get_data") else null
	if data == null:
		return
	var states: Dictionary = api.get_states()
	var entries: Array = []
	for state_id in states:
		var info: Dictionary = states[state_id]
		entries.append({
			"color": data.get_state_color(state_id),
			"text": str(info.get("name", state_id)),
		})
	if entries.is_empty():
		_legend.set_entries(entries)  # 空态：set_shown 自动保持隐藏
		return
	_legend.set_title("政权")
	_legend.set_entries(entries)


## 地图模式切换（MapModeManager 广播）：渲染器换层 + 图例换内容
func _on_map_mode_changed(_mode: int) -> void:
	if map_renderer != null and map_renderer.has_method("set_map_mode"):
		map_renderer.set_map_mode(MapModeManager.current_mode)
	_fill_legend()


## 关闭战略图（恢复场景图输入，由接线方/ESC 调用）
func close() -> void:
	visible = false
	if _hud != null:
		_hud.visible = false
	_set_overlay_visible(false)
	if EventBus != null:
		EventBus.strategic_map_closed.emit()
