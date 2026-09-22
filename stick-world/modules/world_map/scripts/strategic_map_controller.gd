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
##   - 左键单击聚落：选中（发 settlement_clicked）+ 弹传送确认窗（直达传送，
##     不依赖 F3——创始人 2026-09-16 改为常规交互）
##   - 左键双击聚落：进入场景图（发 settlement_activated → api.enter_settlement；
##     单击确认窗弹出后双击被遮罩消费，旧旅行分流保留兜底）
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

## 切省箭头环半径比（× context 边长）：0.40 —— 环贴在地图内缘（离地图边框约 1/10 边长），
## 既不压住中心内容，也不越出地图框（地图外不放箭头）
const ARROW_RING_RATIO := 0.40

## 底部 HUD（CanvasLayer 直接子节点，open/close 同步显隐）
var _hud: Control = null

## 粒度指示器 + 聚落 tooltip（CanvasLayer 直接子节点，open/close 同步显隐；
## 文案更新在 open()，tooltip 内容由其 _process 轮询渲染器 hover 状态）
var _indicator: GranularityIndicator = null
var _tooltip: Control = null

## 旅行方式弹窗（P6/E3，CanvasLayer 直接子节点；双击聚落弹出[走过去|快速旅行|取消]）
var _travel_dialog: TravelDialog = null
## 快速旅行执行中（路由高亮展示期，忽略新的双击激活）
var _fast_travel_pending: bool = false
## 路由高亮展示时长（秒；「途经路径高亮」反馈，随后即时传送——调试期免费设定）
const FAST_TRAVEL_HIGHLIGHT_SEC: float = 0.8

## 视图名牌 + 图例（CanvasLayer 直接子节点，同批显隐；内容在 open() 喂）
var _title_bar: MapTitleBar = null
var _legend: MapLegend = null

## 据点面板（CanvasLayer 直接子节点，同批显隐；数据源与行回调在
## _auto_find_components 注入——面板不自己认识 expansion，见 territory_panel.gd）
var _territory_panel: TerritoryPanel = null

## 政权列表侧栏（CanvasLayer 直接子节点，同批显隐；当包 states 逐行，行点击聚焦都城）
var _states_panel: ProvinceStatesPanel = null

## 左右切省箭头（CanvasLayer 直接子节点，同批显隐；目标由本控制器按邻省方位算，
## 见 province_switch_arrows.gd）
var _arrows: ProvinceSwitchArrows = null

## 全屏海洋底（CanvasLayer 首子节点，z 最低）。C21：地图一打开就整屏铺海洋，
## 不再让场景图从地图四周（上下尤其明显）露出来。显隐随本视图（下钻 L2 时收起，
## 由 L2 自己的海洋底接管）。
var _ocean_backdrop: Control = null

## 地图层开关管理器（Content 子节点，B4：图层开关广播；图例/渲染器随层刷新）
var _mode_manager: MapModeManager = null

## 首次打开时设置初始视角（之后保留用户位置/缩放）
var _view_initialized: bool = false

## 是否从 L2 下钻进入（ESC 时返回 L2 而非关闭）
var _drill_from_l2: bool = false

## 玩家当前所在 L1 全局 label（默认出生；游戏内跨 L1 移动逻辑移动到其他 L1 时
## 调 set_player_l1 更新，Tab 打开跟随显示该 L1 的地图——下钻是临时查看，不改变它）
var _player_l1_label: int = 69


func _ready() -> void:
	add_to_group(MapControllerUtil.GROUP_L1_VIEW)
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
	# 地图层开关（B4）：图层开/关 → 渲染器刷新 + 图例重算（HUD 开关条自行订阅广播）
	if _mode_manager != null and not _mode_manager.layer_toggled.is_connected(_on_layer_toggled):
		_mode_manager.layer_toggled.connect(_on_layer_toggled)
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
	if _travel_dialog == null:
		_travel_dialog = MapControllerUtil.find_sibling(self, "TravelDialog") as TravelDialog
		if _travel_dialog != null \
				and not _travel_dialog.travel_confirmed.is_connected(_on_travel_confirmed):
			_travel_dialog.travel_confirmed.connect(_on_travel_confirmed)
		# 步行可达性复核（F6）：弹窗按 get_walk_status 适配「走过去」按钮
		if _travel_dialog != null and api != null and api.has_method("get_walk_status"):
			_travel_dialog.walk_status_fn = get_walk_status_checked
	if _title_bar == null:
		_title_bar = MapControllerUtil.find_sibling(self, "MapTitleBar") as MapTitleBar
	if _legend == null:
		_legend = MapControllerUtil.find_sibling(self, "MapLegend") as MapLegend
	if _territory_panel == null:
		_territory_panel = MapControllerUtil.find_sibling(self, "TerritoryPanel") as TerritoryPanel
		if _territory_panel != null:
			_territory_panel.targets_fn = _list_territories
			_territory_panel.activate_fn = _on_territory_row_activated
			_territory_panel.refresh()
	if _states_panel == null:
		_states_panel = MapControllerUtil.find_sibling(self, "ProvinceStatesPanel") as ProvinceStatesPanel
		if _states_panel != null and api != null and api.has_method("get_data"):
			_states_panel.focus_fn = _focus_state_capital
	if _arrows == null:
		_arrows = MapControllerUtil.find_sibling(self, "ProvinceSwitchArrows") as ProvinceSwitchArrows
		if _arrows != null:
			_arrows.targets_fn = _arrow_ring_config
			_arrows.activate_fn = switch_province
			_arrows.screen_pos_fn = map_to_screen_pos
	if _ocean_backdrop == null:
		_ocean_backdrop = MapControllerUtil.find_sibling(self, "OceanBackground")
	if _mode_manager == null:
		_mode_manager = MapControllerUtil.find_child(self, func(c: Node) -> bool: return c is MapModeManager) as MapModeManager


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	# 左键：单击选中 / 双击进入
	if event is InputEventMouseButton and event.is_action_pressed("strategy/select"):
		var mb: InputEventMouseButton = event as InputEventMouseButton
		# GUI 先决：指针悬停在控件上（HUD 模式条/滑块/名牌等）时点击归 UI。
		# 本回调先于 GUI 处理执行，不判空会穿透点选 HUD 底下的地块（F1 验收反馈）
		if get_viewport().gui_get_hovered_control() != null:
			return
		_handle_left_click(mb.position)
	# ESC：统一走 handle_escape（下钻返回 L2 / 关闭地图）；消费事件防止
	# GameRoot 再收到后弹暂停菜单（GameRoot 也通过 handle_escape 分发，双路径互斥）
	elif event is InputEventKey and event.pressed and not event.is_echo():
		var key: InputEventKey = event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			handle_escape()
			get_viewport().set_input_as_handled()


## ESC 语义（由 GameRoot._handle_escape 统一分发，战略图打开时优先于暂停菜单）：
## 旅行弹窗开 → 仅关弹窗；从 L2 下钻进入则返回 L2；否则关闭战略图
func handle_escape() -> bool:
	if _travel_dialog != null and _travel_dialog.is_open():
		_travel_dialog.close()
		return true
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
	# 全屏海洋底同批显隐（open / close / 下钻 L2 三条路径都经过本函数）
	if _ocean_backdrop != null:
		_ocean_backdrop.visible = v
	if _indicator != null:
		_indicator.visible = v
	if _title_bar != null:
		_title_bar.visible = v
	if _legend != null:
		_legend.set_shown(v)
	if _territory_panel != null:
		_territory_panel.set_shown(v)
	if _states_panel != null:
		_states_panel.set_shown(v)
	if _arrows != null:
		_arrows.set_shown(v)
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
		activate_settlement(settlement.settlement_id)
	elif left_click_selects:
		api.select(settlement.settlement_id)
		if api.has_signal("settlement_clicked"):
			api.settlement_clicked.emit(settlement.settlement_id)
		# 常规传送（创始人 2026-09-16：单击聚落弹确认窗直达传送，不依赖 F3）；
		# 无 map_id 聚落不弹（无处可传，tooltip 已提示「未开放进入」）
		if _travel_dialog != null and not _travel_dialog.is_open() \
				and not settlement.map_id.is_empty():
			var display_name: String = settlement.name if not settlement.name.is_empty() else settlement.settlement_id
			_travel_dialog.open_confirm(settlement.settlement_id, display_name)


## F3 调试传送开关已撤（创始人 2026-09-16）：传送改为常规单击交互走确认弹窗
## （TravelDialog.open_confirm），确认后经 TELEPORT 直达 enter_settlement。

## 激活聚落（**公共**：地图双击与据点面板行点击共用同一分流，两入口不分叉）：
##   敌据点（expansion 有对位且未臣服）→ 征伐确认
##   无 map_id → 不动作（tooltip 已提示「未开放进入」）
##   SELF（已在此聚落）→ 直接进城（不构成旅行，无弹窗）
##   其余 → 弹旅行方式窗[走过去|快速旅行|取消]（快速旅行可达性在窗内展示）
## 快速旅行高亮展示期（_fast_travel_pending）忽略新激活。
func activate_settlement(settlement_id: String) -> void:
	if api == null or not api.has_method("get_travel_status"):
		return
	if _fast_travel_pending:
		return
	# 出征入口（出征与领地架构 §九 入口二）：双击敌据点 → 出征确认，而不是
	# 走进敌城；已臣服/无对位聚落回落旅行分流（占领后双击=巡视自家）
	var target := _conquest_target_for(settlement_id)
	if not target.is_empty():
		_confirm_conquest(target)
		return
	var status: Dictionary = api.get_travel_status(settlement_id)
	var code: String = str(status.get("code", ""))
	if code == "NO_SCENE":
		# 与旧口径一致：无 map_id 聚落双击不进入（api.enter_settlement 会 push_warning）
		api.enter_settlement(settlement_id)
		return
	if code == "SELF":
		api.enter_settlement(settlement_id)
		return
	if _travel_dialog == null:
		# 弹窗缺失兜底：直接进（保持 P5 行为，不因 UI 缺位锁死进城）
		api.enter_settlement(settlement_id)
		return
	var sref: SettlementRef = api.get_settlement_ref(settlement_id) if api.has_method("get_settlement_ref") else null
	var display_name: String = sref.name if sref != null and not sref.name.is_empty() else settlement_id
	_travel_dialog.open_for(settlement_id, display_name, status)


## 弹窗确认：TELEPORT → 直达传送（enter_settlement 不查可达性，传送即到访）；
## FAST_TRAVEL → 快速旅行（可达性校验 + 途经路径高亮）；WALK → 步行道路流程
## 该聚落对应的可征伐敌据点（无对位/已臣服 → 空字典）。取实例走组查找
## （expansion/api.gd 的 GROUP），不引全局类名——契约面仍经 api.gd 方法调用
func _conquest_target_for(settlement_id: String) -> Dictionary:
	var expansion := _expansion_api()
	if expansion == null or not expansion.has_method("find_target_by_settlement"):
		return {}
	return expansion.find_target_by_settlement(settlement_id)


func _expansion_api() -> Node:
	var tree := get_tree()
	return tree.get_first_node_in_group("expansion_api") if tree != null else null


## 据点清单数据源（据点面板 targets_fn）：转发 expansion api.list_targets；
## 未装配 expansion（dev 直开战略图）返回空表 → 面板空态隐藏
func _list_territories() -> Array:
	var expansion := _expansion_api()
	if expansion == null or not expansion.has_method("list_targets"):
		return []
	return expansion.list_targets()


## 玩家已占地块 id（政治图例的「我方疆域」条目用；染色本身在渲染器侧按同一份
## expansion 真值逐地块取色）。未装配 expansion → 空表
func _owned_tile_keys() -> Array:
	var expansion := _expansion_api()
	if expansion == null or not expansion.has_method("get_owned_tile_keys"):
		return []
	return expansion.get_owned_tile_keys()


## 据点面板行点击：先按 tile_key 定位到该聚落地块，再走 activate_settlement
## 同一交互链（未易手据点弹征伐确认 / 我方已占据点弹旅行窗）
func _on_territory_row_activated(target: Dictionary) -> void:
	var tile_key := String(target.get("tile_key", ""))
	if not tile_key.is_empty() and api != null and api.has_method("camera_focus"):
		api.camera_focus(tile_key)
	activate_settlement(String(target.get("settlement_key", "")))


## 政权列表行点击：相机聚焦该政权都城所在地块（复用 api.camera_focus 的
## 地块质心聚焦路径，不另起一套定位；未知聚落/无地块静默不动）
func _focus_state_capital(settlement_id: String) -> void:
	if api == null or settlement_id.is_empty() or not api.has_method("get_data"):
		return
	var data: L1WorldData = api.get_data()
	if data == null:
		return
	for tile in data.tiles:
		if tile.settlement != null and tile.settlement.settlement_id == settlement_id:
			if api.has_method("camera_focus"):
				api.camera_focus(tile.tile_id)
			return


## 切省箭头环配置（province_switch_arrows.targets_fn）：
## **每个相邻老 L1 省份一个箭头**，排在**地图内容区内的虚拟圆环**上——圆心 = 本省
## context 中心，半径 = context 边长 × ARROW_RING_RATIO；每个箭头的方位角 = 该邻省
## 全局质心相对本省的方位（方向背离圆心，即指向该省）。
## 方向用**全局质心**（ProvincePolitics 侧表；局部多边形被 context 裁过、方位会偏心）。
## 侧表缺失 / 邻省无质心 / 无包数据 → 该邻省不出箭头（不出死箭头）。
## 返回 {"center": Vector2, "radius": float, "arrows": [{label, angle, color, text}]}。
func _arrow_ring_config() -> Dictionary:
	var cfg := {"center": Vector2.ZERO, "radius": 0.0, "arrows": []}
	if api == null or not api.has_method("get_data"):
		return cfg
	var data: L1WorldData = api.get_data()
	if data == null:
		return cfg
	var pol := ProvincePolitics.load_shared()
	if pol == null:
		return cfg
	var self_label: int = int(api.get_current_l1_label()) \
			if api.has_method("get_current_l1_label") else 0
	var self_center := pol.centroid_of(self_label)
	if self_center == Vector2.INF:
		return cfg
	var side := float(maxi(data.context_size.x, data.context_size.y))
	if side <= 0.0:
		side = float(data.size)
	cfg["center"] = Vector2(side, side) * 0.5
	cfg["radius"] = side * ARROW_RING_RATIO
	var arrows: Array = []
	for nb in data.neighbors:
		var label := int((nb as Dictionary).get("label", 0))
		if label <= 0 or label == self_label:
			continue
		var center := pol.centroid_of(label)
		if center == Vector2.INF:
			continue
		if api.has_method("has_l1_data") and not api.has_l1_data(label):
			continue
		var dir := center - self_center
		if dir.length() <= 0.0001:
			continue
		var state_name := pol.state_name_of(label)
		arrows.append({
			"label": label,
			"angle": dir.angle(),
			"color": pol.color_of(label),
			"text": "切到相邻省份 #%d%s" % [
				label, " · %s" % state_name if not state_name.is_empty() else ""],
		})
	cfg["arrows"] = arrows
	return cfg


## 地图坐标 → 屏幕坐标（切省箭头环定位用；相机缺失时原样返回）
func map_to_screen_pos(map_pos: Vector2) -> Vector2:
	if api != null and api.has_method("map_to_screen"):
		return api.map_to_screen(map_pos)
	return map_pos


## 切到相邻 L1 省份（箭头入口）：换包 + 重适配视角 + 刷新名牌/图例/据点/箭头。
## 与 L2 下钻（open_l1）的**语义差别**：不改 _drill_from_l2——ESC 行为跟"从哪进来的"走，
## Tab 直开切省后 ESC 仍是关闭地图，下钻态切省后 ESC 仍是返回 L2。
## 返回是否切换成功（无数据 / 同一省份 / api 缺位 → false，视图不动）。
func switch_province(l1_label: int) -> bool:
	if api == null or not api.has_method("open_l1") \
			or not api.has_method("get_current_l1_label"):
		return false
	if l1_label == api.get_current_l1_label():
		return false
	if not api.open_l1(l1_label):
		return false
	_view_initialized = false
	_reset_view_for_current_l1()
	_refresh_view_meta()
	return true


## 出征确认（双击敌聚落）：先给情报（守军编成/敌将/战利品），确认才动身
func _confirm_conquest(target: Dictionary) -> void:
	var expansion := _expansion_api()
	if expansion == null or not expansion.has_method("describe_target"):
		return
	var layer := _ui_layer()
	if layer == null:
		# 弹窗宿主缺失（dev 直开战略图）→ 直接出征，不锁死玩法
		_launch_conquest(String(target.get("id", "")))
		return
	StickKit.confirm(layer, "征伐 · %s" % String(target.get("name_zh", "")),
			expansion.describe_target(target),
			func() -> void: _launch_conquest(String(target.get("id", ""))),
			"出征", StickKit.ButtonKind.DANGER)


func _launch_conquest(territory_id: String) -> void:
	var expansion := _expansion_api()
	if expansion == null or not expansion.has_method("launch_campaign"):
		return
	if expansion.launch_campaign(territory_id):
		close()


## 弹窗宿主（SystemOverlay 槽；UIRoot 缺失返回 null）
func _ui_layer() -> Control:
	var tree := get_tree()
	if tree == null:
		return null
	var ui_root: CanvasLayer = tree.get_first_node_in_group("ui_root")
	if ui_root == null:
		return null
	var slot := ui_root.get_node_or_null("SystemOverlay")
	return slot if slot is Control else null


func _on_travel_confirmed(settlement_id: String, mode: int) -> void:
	if api == null:
		return
	if mode == WorldAPI.TravelMode.TELEPORT:
		var sref: SettlementRef = api.get_settlement_ref(settlement_id) if api.has_method("get_settlement_ref") else null
		var display_name: String = sref.name if sref != null and not sref.name.is_empty() else settlement_id
		if api.enter_settlement(settlement_id, mode):
			EventBus.ui_notification.emit("传送", "已传送到 %s" % display_name, "info")
		else:
			EventBus.ui_notification.emit("传送失败", "%s 未开放场景图" % display_name, "warn")
	elif mode == WorldAPI.TravelMode.FAST_TRAVEL:
		_start_fast_travel(settlement_id)
	elif api.has_method("walk_to"):
		api.walk_to(settlement_id)
	else:
		api.enter_settlement(settlement_id, mode)


## 步行可达性复核（travel_dialog.walk_status_fn 消费）：转发 api.get_walk_status
func get_walk_status_checked(settlement_id: String) -> Dictionary:
	if api != null and api.has_method("get_walk_status"):
		return api.get_walk_status(settlement_id)
	return {"ok": false, "reason": "步行不可用"}


## 快速旅行执行：途经路径高亮（§5.10「长距离自动显示导航路径」）→
## 短暂展示后即时传送（调试期免费）。api.fast_travel_to 内部二次校验可达性。
func _start_fast_travel(settlement_id: String) -> void:
	var status: Dictionary = api.get_travel_status(settlement_id)
	if str(status.get("code", "")) != "OK":
		return
	_fast_travel_pending = true
	if is_instance_valid(map_renderer) and map_renderer.has_method("set_route_highlight"):
		map_renderer.set_route_highlight(status.get("roads", []), _route_nodes(status.get("path", [])))
	await get_tree().create_timer(FAST_TRAVEL_HIGHLIGHT_SEC).timeout
	_fast_travel_pending = false
	# 高亮展示期间 map_renderer 可能已随场景释放（freed 非 null，须 is_instance_valid 判活）
	if is_instance_valid(map_renderer) and map_renderer.has_method("clear_route_highlight"):
		map_renderer.clear_route_highlight()
	if not is_visible_in_tree():
		return  # 展示期间视图被关闭（ESC/边界触发），放弃传送
	api.fast_travel_to(settlement_id)


## 途经聚落序列 → 地图坐标节点（路由高亮的圆点标记）
func _route_nodes(path: Array) -> PackedVector2Array:
	var nodes := PackedVector2Array()
	if api == null or not api.has_method("get_settlement_ref"):
		return nodes
	for sid in path:
		var sref: SettlementRef = api.get_settlement_ref(sid)
		if sref != null:
			nodes.append(sref.position)
	return nodes


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
	_reset_view_for_current_l1()
	if _hud != null:
		_hud.visible = true
	# 地图层开关（B4）：本视图关闭期间他视图可能切过图层（全局静态），打开时同步渲染器
	if map_renderer != null and map_renderer.has_method("set_layer_on"):
		for layer in [MapModeManager.Layer.POLITICAL, MapModeManager.Layer.CITY,
				MapModeManager.Layer.TRAFFIC, MapModeManager.Layer.RESOURCE]:
			map_renderer.set_layer_on(layer, MapModeManager.is_layer_on(layer))
	_refresh_view_meta()
	_set_overlay_visible(true)
	if EventBus != null:
		EventBus.strategic_map_opened.emit()


## 视角适配新 context（首次打开 / 换 L1 省份后调用一次）：整图适配 = 100%，地图居中
## （出生 L1 位于 context 中心）；已适配过则保留用户位置/缩放（与 L2/L3 一致）
func _reset_view_for_current_l1() -> void:
	if _view_initialized:
		return
	_view_initialized = true
	if map_camera == null or not map_camera.has_method("set_zoom"):
		return
	var vp := get_viewport()
	if vp == null:
		return
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


## 视图元信息刷新（打开 / 切省共用）：粒度指示器 + 名牌 + 图例 + 据点清单 + 切省箭头
func _refresh_view_meta() -> void:
	# 粒度指示：层级 + 当前地块号 + ESC 语义（直开=关闭 / 下钻=返回 L2）
	if _indicator != null and api != null and api.has_method("get_current_l1_label"):
		var l1_label: int = api.get_current_l1_label()
		_indicator.set_view("L1", "#%d" % l1_label, _drill_from_l2)
		if _title_bar != null:
			_update_title_bar(l1_label)
	_fill_legend()
	# HUD 层级按钮组（需求 8）：当前层级 L1 高亮；L2 可达 = 当前省有所属地区包；
	# L3 可达 = 大世界视图已装配（L1 场景直开时无 L3 节点 → 置灰不报错）
	_sync_hud_levels()
	# 据点清单按当前归属重刷（关图期间可能已占领/易手）
	if _territory_panel != null:
		_territory_panel.refresh()
	# 政权列表按当前包重刷（换省后整表换政权/都城）
	if _states_panel != null and api != null and api.has_method("get_data"):
		_states_panel.set_data(api.get_data())
	# 切省箭头按当前省份的邻省重算（换省后两侧目标都变）
	if _arrows != null:
		_arrows.refresh()


## HUD 层级按钮状态（进入本视图 / 切省后调用）：本省 L1 = 当前；
## 地区 L2 可达 = 当前省在 l2_packs 有对应地区包；世界 L3 可达 = L3 视图已装配。
func _sync_hud_levels() -> void:
	if _hud == null or not _hud.has_method("set_level_state"):
		return
	var l3_on := MapControllerUtil.view_in_tree(self, MapControllerUtil.GROUP_L3_VIEW)
	var l2_on := l3_on and MapControllerUtil.view_in_tree(self, MapControllerUtil.GROUP_L2_VIEW)
	if l2_on and api != null and api.has_method("get_region_for_l1") \
			and api.has_method("get_current_l1_label"):
		l2_on = not str(api.get_region_for_l1(api.get_current_l1_label())).is_empty()
	else:
		l2_on = false
	_hud.set_level_state("L1", {"L1": true, "L2": l2_on, "L3": l3_on}, {
		"L2": "查看本省所属地区" if l2_on else "本省无对应地区视图",
		"L3": "查看大世界" if l3_on else "大世界视图未装配",
	})


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


## 图例内容按开启的图层逐层拼条目（B4 开关层机制；走 MapLegend.set_title/set_entries）：
## 政治层开 = 政权色条目（与地图填充同色源；R7 80 国走文化圈聚合代表性子集）
## 城市层开 = 建成区条目；交通层开 = 土路/官道条目；资源层开 = 六种资源点色条目
## 标题 = 最上层（渲染叠放序最上的开启层）；全关时仍给底图说明（海洋/湖泊/群系）
func _fill_legend() -> void:
	if _legend == null:
		return
	var entries: Array = []
	# 标题 = 最上层（渲染叠放序最上的开启层；全关 = 底图）
	var title := "地形"
	for layer in [MapModeManager.Layer.RESOURCE, MapModeManager.Layer.TRAFFIC,
			MapModeManager.Layer.CITY, MapModeManager.Layer.POLITICAL]:
		if MapModeManager.is_layer_on(layer):
			title = MapModeManager.layer_name(layer)
			break
	if MapModeManager.is_layer_on(MapModeManager.Layer.POLITICAL):
		entries.append_array(_political_legend_entries_all())
	if MapModeManager.is_layer_on(MapModeManager.Layer.CITY):
		entries.append({"color": MapRenderer.BLOB_FILL, "text": "城镇建成区"})
	if MapModeManager.is_layer_on(MapModeManager.Layer.TRAFFIC):
		entries.append_array(MapRenderer.ROAD_LEGEND)
	if MapModeManager.is_layer_on(MapModeManager.Layer.RESOURCE):
		entries.append_array(_resource_legend_entries())
	if entries.is_empty():
		# 全关：底图（l1_terrain.png）自身的说明性条目
		entries = [
			{"color": MapRenderer.OCEAN_COLOR, "text": "海洋"},
			{"color": MapRenderer.LAKE_COLOR, "text": "湖泊"},
		]
		entries.append_array(MapRenderer.BIOME_LEGEND)
	_legend.set_title(title)
	_legend.set_entries(entries)


## 政治层图例条目（R7 80 国：图例只展示族色+明度档的代表性子集——每文化圈聚合一条 +
## 城邦聚合一条，不塞 80 条；LUT 缺失时回退出生 8 城邦逐条（旧口径））。
## 色源 = PoliticalLut（与 L2/L3 政治模式同一份运行时 LUT，改 LUT 全局生效）；
## 有已占地块时补一条「我方疆域」（P4 逐地块染色：占多少染多少）
func _political_legend_entries_all() -> Array:
	var pol_entries: Array = []
	var lut := PoliticalLut.load_shared()
	if lut != null:
		pol_entries = _political_legend_entries(lut)
	else:
		var data: L1WorldData = api.get_data() if api != null and api.has_method("get_data") else null
		var states: Dictionary = api.get_states() if api != null and api.has_method("get_states") else {}
		if data == null:
			return pol_entries
		for state_id in states:
			var info: Dictionary = states[state_id]
			pol_entries.append({
				"color": data.get_state_color(state_id),
				"text": str(info.get("name", state_id)),
			})
	var owned: Array = _owned_tile_keys()
	if not owned.is_empty():
		pol_entries.append({
			"color": MapTokens.L1_PLAYER_TERRITORY_COLOR,
			"text": "我方疆域 ×%d 地块" % owned.size(),
		})
	return pol_entries


## 资源层图例条目：六种资源 id 的色点 + 中文名（色源 = MapRenderer.RESOURCE_COLORS，
## 与地图上的资源点圆点同源；id 为资源表正式 id）
func _resource_legend_entries() -> Array:
	var out: Array = []
	for e in MapRenderer.RESOURCE_LEGEND:
		var id := str(e.get("id", ""))
		out.append({
			"color": MapRenderer.RESOURCE_COLORS.get(id, MapRenderer.RESOURCE_DEFAULT_COLOR),
			"text": _resource_display_name(id),
		})
	return out


## 资源表在 BalanceConfig 里的类型路径候选（config/ 目录扫描口径 = 目录名.表名：
## config/resources/resources.tres → "resources.resources"；若日后改放 config/resources.tres
## 则为 "resources"——两者都试，读不到就走兜底名）
const RESOURCE_TABLE_PATHS: Array[String] = ["resources.resources", "resources"]


## 资源 id 中文名：优先读物品域资源表（config/resources/resources.tres 经 BalanceConfig
## 装载，与物品系统同一份数据），表缺失/无该 id/无 name_zh 时回退 MapRenderer 兜底名
func _resource_display_name(id: String) -> String:
	if BalanceConfig != null:
		for path in RESOURCE_TABLE_PATHS:
			var row: Variant = BalanceConfig.data.get("%s.%s" % [path, id], null)
			if row is Dictionary:
				var name_zh := str((row as Dictionary).get("name_zh", ""))
				if not name_zh.is_empty():
					return name_zh
	return MapRenderer.resource_fallback_name(id)


## 政治图例的代表性子集（R7）：每文化圈一条（色 = 圈内最大国的政权色，
## 文本 = 「族标签 ×N 国」）+ 自由城邦聚合一条，按规模降序
func _political_legend_entries(lut: PoliticalLut) -> Array:
	var by_culture := {}
	var n_city_state := 0
	var cs_color := Color(0.6, 0.6, 0.6)
	for sid in lut.states:
		var info: Dictionary = lut.states[sid]
		if bool(info.get("is_city_state", false)):
			n_city_state += 1
			if n_city_state == 1:
				cs_color = lut.color_of(sid)
			continue
		var cu := str(info.get("culture", ""))
		if not by_culture.has(cu):
			by_culture[cu] = {
				"label": str(info.get("culture_label", cu)),
				"n": 0, "max_cities": -1, "color": cs_color,
			}
		var e: Dictionary = by_culture[cu]
		e["n"] += 1
		var nc := int(info.get("n_cities", 0))
		if nc > int(e["max_cities"]):
			e["max_cities"] = nc
			e["color"] = lut.color_of(sid)
	var grouped: Array = []
	for cu in by_culture:
		var e: Dictionary = by_culture[cu]
		grouped.append({
			"color": e["color"],
			"text": "%s ×%d 国" % [e["label"], e["n"]],
			"_n": int(e["n"]),
		})
	grouped.sort_custom(func(a, b): return int(a["_n"]) > int(b["_n"]))
	for e in grouped:
		e.erase("_n")
	if n_city_state > 0:
		grouped.append({"color": cs_color, "text": "自由城邦 ×%d" % n_city_state})
	return grouped


## 层开关变更（MapModeManager 广播）：渲染器刷新 + 图例重算
func _on_layer_toggled(layer: int, on: bool) -> void:
	if map_renderer != null and map_renderer.has_method("set_layer_on"):
		map_renderer.set_layer_on(layer, on)
	_fill_legend()


## 关闭战略图（恢复场景图输入，由接线方/ESC 调用）
func close() -> void:
	visible = false
	if _travel_dialog != null and _travel_dialog.is_open():
		_travel_dialog.close()
	if map_renderer != null and map_renderer.has_method("clear_route_highlight"):
		map_renderer.clear_route_highlight()
	if _hud != null:
		_hud.visible = false
	_set_overlay_visible(false)
	if EventBus != null:
		EventBus.strategic_map_closed.emit()
