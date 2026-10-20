extends Control
## 鼠标悬停指示器 -- 4 角直角呼吸方框（游玩 UI，非调试）。
##
## 鼠标悬停在 NPC/玩家上时显示 4 角方框。方框 = 实体 Range 框经地图视觉域
## 协议（MapBase.entity_hover_rect）映射出的矩形——**画与命中判定共用同一
## 矩形（所见即所判）**：HD-2D 图下即 billboard 几何（视觉脚线锚定+深度缩放），
## 2D 图恒等。鼠标屏幕点经 viewport canvas_transform 逆变换进视觉域，
## 不手搓相机公式（协议铁律见 MapBase 视觉域坐标协议段）。
##
## 事件驱动（悬停检测已移出 _process）：鼠标移动（_unhandled_input，GUI 未消费
## 的移动才触发——光标在 UI 上时不做世界悬停）按 0.1s 节流触发扫描；空闲时
## set_process(false) 零轮询。悬停期间恢复 _process：呼吸动画逐帧 + 0.1s 复扫
## （鼠标静止时实体会走出光标，靠复扫清框）。已知取舍：暂停解除后光标不动
## 则悬停框不重现（TimeManager 无变速信号可钩），动一下鼠标即恢复。
##
## 依赖由 SystemSetup 装配时 setup() 注入，不自行查找。

const FRAME_COLOR: Color = Color(1.0, 1.0, 1.0, 0.9)
const BREATH_AMP: float = 3.0
const BREATH_SPEED: float = 3.0
const CORNER_LEN: float = 10.0
const CORNER_WIDTH: float = 2.0
## 扫描节流间隔（秒）：移动事件合并扫描 / 悬停复扫同节拍
const SCAN_INTERVAL_MSEC := 100

var _hovered_entity: Node2D = null
var _hovered_range: CollisionShape2D = null
## 悬停复扫节拍累计（悬停期间 _process 内）
var _scan_acc: float = 0.0
var _breath_time: float = 0.0
## 上次扫描时刻（msec，移动事件节流）
var _last_scan_msec: int = -SCAN_INTERVAL_MSEC

var _game_root: Node = null


func setup(game_root: Node) -> void:
	_game_root = game_root


func _ready() -> void:
	# 例外节点（process_mode 分层表）：本节点 ALWAYS——暂停期要跑"清屏重绘"
	# 摘掉悬停框（下方 is_paused 分支），冻结期间不 tick 框会残留整场暂停
	process_mode = Node.PROCESS_MODE_ALWAYS
	size = get_viewport_rect().size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	if get_viewport() != null:
		get_viewport().size_changed.connect(_on_viewport_resized)


func _on_viewport_resized() -> void:
	size = get_viewport_rect().size
	queue_redraw()


## 鼠标移动驱动扫描（GUI 消费过的移动不触发——光标悬在界面控件上时不做世界
## 悬停）；0.1s 节流合并高频移动事件
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion):
		return
	var now := Time.get_ticks_msec()
	if now - _last_scan_msec < SCAN_INTERVAL_MSEC:
		return
	_last_scan_msec = now
	if TimeManager and TimeManager.is_paused():
		_set_hovered(null, null)
		return
	_update_hovered()
	_after_scan()


func _process(delta: float) -> void:
	_breath_time += delta
	# 模态/暂停时（时间冻结）不显示悬停反馈，避免反馈漏过遮罩层；
	# 清屏重绘一次后即停.process（恢复需再动鼠标）
	if TimeManager and TimeManager.is_paused():
		if _hovered_entity != null:
			_set_hovered(null, null)
		else:
			set_process(false)
		return
	# 悬停复扫：鼠标静止、实体走出光标时清框（画与判定共用矩形，框会跟人走）
	_scan_acc += delta
	if _scan_acc >= SCAN_INTERVAL_MSEC / 1000.0:
		_scan_acc = 0.0
		var prev: Node2D = _hovered_entity
		_update_hovered()
		if _hovered_entity != prev:
			_after_scan()
			return
	queue_redraw()


## 扫描后同步：目标变化才重绘；有悬停才需要 _process（呼吸），空闲即停
func _after_scan() -> void:
	set_process(_hovered_entity != null)
	queue_redraw()


func _set_hovered(entity: Node2D, rng: CollisionShape2D) -> void:
	_hovered_entity = entity
	_hovered_range = rng
	_after_scan()


func _draw() -> void:
	var rect := _hovered_visual_rect()
	if rect.size == Vector2.ZERO:
		return
	var xform: Transform2D = get_viewport().get_canvas_transform()
	var screen_rect: Rect2 = xform * rect
	# 呼吸只往外扩：将 sin 映射到 [0,1]，基准大小即最小范围
	var breath: float = (sin(_breath_time * BREATH_SPEED) * 0.5 + 0.5) * BREATH_AMP
	var cl: float = CORNER_LEN * xform.get_scale().x
	var c: Vector2 = screen_rect.get_center()
	var hw: float = screen_rect.size.x * 0.5 + breath
	var hh: float = screen_rect.size.y * 0.5 + breath
	# 4 角直角方框
	_draw_corner(c + Vector2(-hw, -hh), Vector2(cl, 0), Vector2(0, cl))
	_draw_corner(c + Vector2(hw, -hh), Vector2(-cl, 0), Vector2(0, cl))
	_draw_corner(c + Vector2(-hw, hh), Vector2(cl, 0), Vector2(0, -cl))
	_draw_corner(c + Vector2(hw, hh), Vector2(-cl, 0), Vector2(0, -cl))


func _draw_corner(origin: Vector2, h_dir: Vector2, v_dir: Vector2) -> void:
	draw_polyline(PackedVector2Array([origin, origin + h_dir]), FRAME_COLOR, CORNER_WIDTH, true)
	draw_polyline(PackedVector2Array([origin, origin + v_dir]), FRAME_COLOR, CORNER_WIDTH, true)


func _update_hovered() -> void:
	if _game_root == null or not _game_root.has_method("get_current_map"):
		_clear_hovered()
		return
	var map: Node2D = _game_root.get_current_map()
	if map == null or not map.has_method("get_entities"):
		_clear_hovered()
		return
	# 鼠标屏幕点 → 视觉域：canvas_transform 逆变换（相机真值）。与
	# entity_hover_rect 输出同域——方框画在哪，鼠标就判在哪
	var mouse_visual: Vector2 = get_viewport().get_canvas_transform().affine_inverse() \
			* get_viewport().get_mouse_position()
	var closest: Node2D = null
	var closest_range: CollisionShape2D = null
	var closest_dist: float = 999999.0
	for entity in map.get_entities():
		if not entity is CharacterBody2D:
			continue
		var e: CharacterBody2D = entity as CharacterBody2D
		# 用 Range 节点检测悬停（比 Collider 大，更容易触发）
		var rng: CollisionShape2D = e.get_node_or_null("Range") as CollisionShape2D
		if rng == null or not (rng.shape is RectangleShape2D):
			continue
		var rect: Rect2 = map.entity_hover_rect(
				rng.global_position, (rng.shape as RectangleShape2D).size, e)
		if rect.has_point(mouse_visual):
			var d: float = mouse_visual.distance_to(rect.get_center())
			if d < closest_dist:
				closest_dist = d
				closest = e
				closest_range = rng
	_hovered_entity = closest
	_hovered_range = closest_range


## 当前悬停目标的视觉域矩形（画与判定共用）：Range 框经地图视觉域协议映射。
## 无有效目标/地图未就绪时返回零矩形（_draw 直接跳过）。
func _hovered_visual_rect() -> Rect2:
	if _hovered_entity == null or not is_instance_valid(_hovered_entity):
		return Rect2()
	if _hovered_range == null or not is_instance_valid(_hovered_range):
		return Rect2()
	if not (_hovered_range.shape is RectangleShape2D):
		return Rect2()
	if _game_root == null or not _game_root.has_method("get_current_map"):
		return Rect2()
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		return Rect2()
	return map.entity_hover_rect(_hovered_range.global_position,
			(_hovered_range.shape as RectangleShape2D).size, _hovered_entity)


func _clear_hovered() -> void:
	_hovered_entity = null
	_hovered_range = null
