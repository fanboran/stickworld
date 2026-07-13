class_name CameraRig
extends Camera2D
## 相机系统 —— 水平卷轴 + 自由镜头 + 缩放 + 震屏。
##
## 详见 docs/技术/架构/场景与战斗架构.md §2.4。
## - 垂直显示范围限定：camera_y 由 ground_y + ground_ratio 计算，不跟随角色 Y
## - 水平 1/4 区域跟随：角色进入屏幕两侧 1/4 才触发跟随
## - 手动控制：左键拖动 / 边缘滚动 / 滚轮缩放 / 小地图跳转
## - 缩放：1.0~2.0，以鼠标为锚点，缩放时不重算 camera_y
## - 居中模式：强制角色到屏幕中心

# ─────────────────────────────── 常量 ────────────────────────────────
## 设计基准垂直像素（世界坐标恒定，= 1080P 垂直分辨率）
## 1080P 为默认设计分辨率，其他分辨率按此换算（base_zoom = vp_h / 1080）
const DESIGN_HEIGHT: float = 1080.0
## 用户缩放下限（默认最小，1.0=设计基准视野）
const ZOOM_MIN: float = 1.0
## 用户缩放上限（最大迫近，2.0=放大2倍看特写）
const ZOOM_MAX: float = 2.0
## 缩放步长
const ZOOM_STEP: float = 0.1
## 边缘滚动死区（屏幕宽度比例）
const EDGE_DEAD_ZONE: float = 0.05
## 边缘滚动速度（世界坐标 px/s）
const EDGE_SCROLL_SPEED: float = 400.0
## 跟随平滑系数（值越大越跟手）
const FOLLOW_SMOOTHING: float = 8.0
## 居中模式平滑系数
const CENTER_SMOOTHING: float = 10.0
## 手动控制冷却时间（拖动/缩放结束后等待 N 秒无操作才弹回跟随）
const MANUAL_COOLDOWN_TIME: float = 5.0

# ─────────────────────────────── 配置 ────────────────────────────────
## 地面线 Y（世界坐标）
var ground_y: float = 300.0
## 地面占屏幕高度比例（默认 0.4 = 2/5）
var ground_ratio: float = 0.4
## 地图水平边界
var map_left: float = 0.0
var map_right: float = 8192.0
## 是否已配置（未配置时不执行跟随逻辑）
var _configured: bool = false

# ─────────────────────────────── 跟随状态 ────────────────────────────────
## 跟随目标
var follow_target: Node2D = null
## 居中模式（强制角色到中心；可拖动，但禁用边缘滚动，松手即弹回）
var centered_mode: bool = false
## 手动控制激活中（拖动/边缘/小地图跳转）
var _manual_active: bool = false
## 手动控制冷却剩余时间（拖动/缩放结束后递减，归零时退出 manual）
var _manual_cooldown: float = 0.0
## 边缘滚动方向（-1 左 / 0 无 / 1 右）
var _edge_scroll_dir: int = 0
## 拖动状态
var _dragging: bool = false
## 拖动起始鼠标位置（屏幕坐标）
var _drag_start_mouse: Vector2 = Vector2.ZERO
## 拖动起始相机位置（世界坐标）
var _drag_start_cam: Vector2 = Vector2.ZERO

# ─────────────────────────────── 缩放状态 ────────────────────────────────
## 基础缩放（适配分辨率，= viewport_height / DESIGN_HEIGHT，使世界垂直范围恒定）
var base_zoom: float = 1.0
## 用户缩放（1.0~2.0，玩家可调看特写）
var user_zoom: float = 1.0:
	set(v):
		user_zoom = clampf(v, ZOOM_MIN, ZOOM_MAX)
		_apply_zoom()
## 有效缩放（= base_zoom * user_zoom，Camera2D 实际 zoom）
var effective_zoom: float = 1.0

# ─────────────────────────────── 震屏状态 ────────────────────────────────
var _shake_intensity: float = 0.0
var _shake_time: float = 0.0
var _shake_decay: float = 5.0


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# Camera2D 默认即激活
	make_current()
	_recompute_base_zoom()
	_apply_zoom()


func _physics_process(delta: float) -> void:
	# 分辨率变化时重算 base_zoom
	var cur_base: float = _compute_base_zoom()
	if absf(cur_base - base_zoom) > 0.001:
		base_zoom = cur_base
		_apply_zoom()
	if not _configured:
		return
	# 震屏衰减
	if _shake_time > 0.0:
		_shake_time -= delta
		_shake_intensity = maxf(0.0, _shake_intensity - _shake_decay * delta)
	# 更新边缘滚动方向
	_update_edge_scroll()
	# 更新手动控制（拖动 + 边缘）
	_update_manual_control(delta)
	# 手动控制冷却递减（拖动/缩放结束后等 N 秒无操作才弹回跟随）
	# 注：居中模式松手立即弹回（在 _unhandled_input / jump_to_x 中处理）
	if _manual_active and not _dragging and _edge_scroll_dir == 0 and _manual_cooldown > 0.0:
		_manual_cooldown -= delta
		if _manual_cooldown <= 0.0:
			_manual_cooldown = 0.0
			_manual_active = false
	# 更新位置（在 _physics_process 中执行，与 StickmanEntity._physics_process 同步，避免渲染重影）
	_update_position(delta)


func _unhandled_input(event: InputEvent) -> void:
	# 拖动开始/结束
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_manual_active = true
				_manual_cooldown = 0.0
				_drag_start_mouse = event.position
				_drag_start_cam = global_position
			else:
				if _dragging:
					_dragging = false
					if centered_mode:
						# 居中模式：松手立即弹回（类似王者荣耀）
						_manual_active = false
						_manual_cooldown = 0.0
					elif _edge_scroll_dir != 0:
						# 边缘滚动持续中：保持 manual，不计时
						_manual_cooldown = 0.0
					else:
						# 自由镜头模式：启动 5 秒冷却，期间无操作才弹回
						_manual_cooldown = MANUAL_COOLDOWN_TIME
		# 滚轮缩放
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at_mouse(ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at_mouse(-ZOOM_STEP)


# ─────────────────────────────── 位置更新 ────────────────────────────────

## 相机 X 边界约束：视野边缘不超出地图范围（不是中心点 clamp）
func _clamp_camera_x(x: float) -> float:
	var half_vp_w: float = get_viewport_rect().size.x / (2.0 * effective_zoom)
	var cam_x_min: float = map_left + half_vp_w
	var cam_x_max: float = map_right - half_vp_w
	if cam_x_min > cam_x_max:
		# 地图比视野窄，居中显示
		return (map_left + map_right) * 0.5
	return clampf(x, cam_x_min, cam_x_max)


func _update_position(delta: float) -> void:
	# 垂直位置：恒定（由 ground_y + ground_ratio 计算，缩放时不重算）
	var target_y: float = _compute_camera_y()
	# 水平位置
	var target_x: float = global_position.x

	if _manual_active:
		# 手动控制期间，水平位置由拖动/边缘滚动驱动，不自动跟随
		if _edge_scroll_dir != 0 and not _dragging:
			target_x = global_position.x + _edge_scroll_dir * EDGE_SCROLL_SPEED * delta
		# 拖动时位置在 _update_manual_control 里直接设置
		target_x = _clamp_camera_x(target_x)
	elif centered_mode and follow_target != null and is_instance_valid(follow_target):
		# 居中模式：强制角色到屏幕中心
		target_x = follow_target.global_position.x
		target_x = lerp(global_position.x, target_x, CENTER_SMOOTHING * delta)
		target_x = _clamp_camera_x(target_x)
	elif follow_target != null and is_instance_valid(follow_target):
		# 1/4 区域跟随
		target_x = _compute_follow_x(delta)

	global_position.x = target_x
	global_position.y = target_y
	# 震屏偏移
	if _shake_time > 0.0:
		var offset := Vector2(
			randf_range(-_shake_intensity, _shake_intensity),
			randf_range(-_shake_intensity, _shake_intensity)
		)
		global_position += offset


func _compute_camera_y() -> float:
	# 地面线 ground_y 应在屏幕下方 ground_ratio 处（距底部 ground_ratio * vp_h/zoom）
	# 推导：ground_y = camera_y + vp_h/zoom * (0.5 - ground_ratio)
	#        => camera_y = ground_y - vp_h/zoom * (0.5 - ground_ratio)
	# 注：缩放时不重算（保持当前 Y），仅 ground_y/ground_ratio 变化时重算
	var vp_h: float = get_viewport_rect().size.y
	return ground_y - vp_h / effective_zoom * (0.5 - ground_ratio)


func _compute_follow_x(delta: float) -> float:
	if follow_target == null or not is_instance_valid(follow_target):
		return global_position.x
	var target_world_x: float = follow_target.global_position.x
	var cam_x: float = global_position.x
	# 计算角色在屏幕水平方向的相对位置
	var vp_w: float = get_viewport_rect().size.x
	var screen_x_ratio: float = (target_world_x - cam_x) / vp_w * effective_zoom + 0.5
	# 中间 1/2 范围 [1/4, 3/4] → 不跟随；两侧各 1/4 触发跟随
	var left_trigger: float = 1.0 / 4.0
	var right_trigger: float = 3.0 / 4.0
	var new_cam_x: float = cam_x
	if screen_x_ratio < left_trigger:
		# 角色在左 1/4，相机向左跟随，让角色回到 left_trigger
		var desired_cam_x: float = target_world_x - (left_trigger - 0.5) * vp_w / effective_zoom
		new_cam_x = lerp(cam_x, desired_cam_x, FOLLOW_SMOOTHING * delta)
	elif screen_x_ratio > right_trigger:
		# 角色在右 1/4，相机向右跟随
		var desired_cam_x: float = target_world_x - (right_trigger - 0.5) * vp_w / effective_zoom
		new_cam_x = lerp(cam_x, desired_cam_x, FOLLOW_SMOOTHING * delta)
	return _clamp_camera_x(new_cam_x)


# ─────────────────────────────── 手动控制 ────────────────────────────────

func _update_edge_scroll() -> void:
	# 居中模式：禁用边缘滚动（仅允许拖动/小地图跳转，松手即弹回）
	if centered_mode:
		if _edge_scroll_dir != 0:
			_edge_scroll_dir = 0
		return
	if _dragging:
		_edge_scroll_dir = 0
		return
	var vp_size: Vector2 = get_viewport_rect().size
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	# 鼠标不在窗口内时不触发边缘滚动（headless 测试环境鼠标位置无效）
	if mouse_pos.x < 0 or mouse_pos.x > vp_size.x or mouse_pos.y < 0 or mouse_pos.y > vp_size.y:
		if _edge_scroll_dir != 0:
			_edge_scroll_dir = 0
			_manual_active = false
		return
	if mouse_pos.x < vp_size.x * EDGE_DEAD_ZONE:
		_edge_scroll_dir = -1
		_manual_active = true
		_manual_cooldown = 0.0
	elif mouse_pos.x > vp_size.x * (1.0 - EDGE_DEAD_ZONE):
		_edge_scroll_dir = 1
		_manual_active = true
		_manual_cooldown = 0.0
	else:
		if _edge_scroll_dir != 0:
			_edge_scroll_dir = 0
			# 边缘滚动刚退出，启动 5 秒冷却
			_manual_cooldown = MANUAL_COOLDOWN_TIME


func _update_manual_control(delta: float) -> void:
	if _dragging:
		# 拖动：鼠标移动量转换为相机世界移动量
		var mouse_delta: Vector2 = get_viewport().get_mouse_position() - _drag_start_mouse
		var world_delta: Vector2 = mouse_delta / effective_zoom
		var new_x: float = _drag_start_cam.x - world_delta.x
		global_position.x = _clamp_camera_x(new_x)


# ─────────────────────────────── 缩放 ────────────────────────────────

## 计算基础缩放（适配分辨率，使世界垂直可见范围 = DESIGN_HEIGHT）
func _compute_base_zoom() -> float:
	var vp_h: float = get_viewport_rect().size.y
	if vp_h <= 0.0:
		return 1.0
	return vp_h / DESIGN_HEIGHT


func _recompute_base_zoom() -> void:
	base_zoom = _compute_base_zoom()


func _apply_zoom() -> void:
	effective_zoom = base_zoom * user_zoom
	zoom = Vector2(effective_zoom, effective_zoom)


func _zoom_at_mouse(step: float) -> void:
	var old_user: float = user_zoom
	var new_user: float = clampf(user_zoom + step, ZOOM_MIN, ZOOM_MAX)
	if absf(new_user - old_user) < 0.001:
		return
	# 以鼠标位置为锚点：鼠标指向的世界点保持屏幕位置不变
	var vp_size: Vector2 = get_viewport_rect().size
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()
	var old_eff: float = base_zoom * old_user
	# 鼠标在世界坐标的位置（缩放前）
	var mouse_world_before: Vector2 = global_position + (mouse_screen - vp_size * 0.5) / old_eff
	# 应用新缩放
	user_zoom = new_user
	# 调整 global_position 使鼠标世界点保持屏幕位置
	var mouse_world_after: Vector2 = global_position + (mouse_screen - vp_size * 0.5) / effective_zoom
	global_position += mouse_world_before - mouse_world_after
	# 重新约束 X 边界（视野边缘不超出地图）
	global_position.x = _clamp_camera_x(global_position.x)
	# 缩放时 camera_y 不重算（保持当前 Y），但首次配置时需要
	if not _configured:
		global_position.y = _compute_camera_y()
	# 缩放算作一次手动操作：重置冷却计时
	# 注：居中模式缩放不立即弹回（玩家可能在居中模式下也想调缩放），但保持居中模式行为
	if not centered_mode and _manual_active and not _dragging and _edge_scroll_dir == 0:
		_manual_cooldown = MANUAL_COOLDOWN_TIME


# ─────────────────────────────── 公共 API（§2.4.7）────────────────────────────────

## 设置跟随目标
func set_follow_target(node: Node2D) -> void:
	follow_target = node


func clear_follow_target() -> void:
	follow_target = null


## 设置地面线 Y（地图加载时调用）
func set_ground_y(y: float) -> void:
	ground_y = y
	_recompute_vertical()


## 设置地面占比
func set_ground_ratio(ratio: float) -> void:
	ground_ratio = ratio
	_recompute_vertical()


## 设置地图水平边界
func set_map_bounds(left: float, right: float) -> void:
	map_left = left
	map_right = right
	_configured = true


## 设置用户缩放（1.0~2.0，玩家可调看特写；分辨率适配由 base_zoom 自动处理）
func set_user_zoom(level: float) -> void:
	user_zoom = level


func get_user_zoom() -> float:
	return user_zoom


## 获取有效缩放（= base_zoom * user_zoom，Camera2D 实际 zoom）
func get_effective_zoom() -> float:
	return effective_zoom


## 获取基础缩放（= viewport_height / DESIGN_HEIGHT，分辨率适配）
func get_base_zoom() -> float:
	return base_zoom


## 震屏
func shake(intensity: float) -> void:
	_shake_intensity = intensity
	_shake_time = 0.3


func is_shaking() -> bool:
	return _shake_time > 0.0


## 居中跟随开关
## 开启居中模式：保持当前镜头位置，但禁用边缘滚动，后续拖动/跳转松手立即弹回
## 关闭居中模式：恢复自由镜头（边缘滚动可用，拖动/缩放后 5 秒弹回）
func set_centered_mode(enabled: bool) -> void:
	centered_mode = enabled
	if enabled:
		# 切到居中模式：清除边缘滚动，但保持当前镜头（不立即弹回，等下次松手）
		_edge_scroll_dir = 0


func is_centered_mode() -> bool:
	return centered_mode


## RTS 式跳转：相机跳到指定 X 位置，暂停自动跟随
## 居中模式：立即弹回跟随（类似王者荣耀小地图）
## 自由镜头模式：启动 5 秒冷却
func jump_to_x(world_x: float) -> void:
	global_position.x = _clamp_camera_x(world_x)
	_manual_active = true
	if centered_mode:
		# 居中模式：松手即弹回
		_manual_cooldown = 0.0
		_manual_active = false
	else:
		_manual_cooldown = MANUAL_COOLDOWN_TIME


## 获取当前视野世界矩形（供小地图用）
func get_viewport_rect_world() -> Rect2:
	var vp_size: Vector2 = get_viewport_rect().size / effective_zoom
	var pos: Vector2 = global_position - vp_size * 0.5
	return Rect2(pos, vp_size)


## 重算垂直位置（ground_y/ground_ratio 变化时）
func _recompute_vertical() -> void:
	global_position.y = _compute_camera_y()
