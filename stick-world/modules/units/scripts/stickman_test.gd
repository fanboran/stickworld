extends Node2D
## 火柴人渲染测试控制器
##
## WASD / 方向键 持续移动，自动加速→奔跑
## 1/2/3/4 切换 idle/walk/attack/dead 动画 | Q/E 缩放

# ===== 速度系统参数 =====
# walk 动画 length=1.0s，2步/周期，每步 50px → 基准速度 100 px/s
const WALK_BASE_SPEED := 100.0
const WALK_ACCEL := 120.0       # 加速度 px/s²
const WALK_DECEL := 200.0       # 减速度 px/s²
const RUN_SPEED := 130.0        # 奔跑速度（达到阈值后跳变）
const MIN_ANIM_SCALE := 0.2     # walk 动画最低播放速率
const IDLE_THRESHOLD := 5.0     # 低于此速度切到 idle
const BASE_SCALE := 0.267       # 火柴人缩放（原 0.8 的 1/3）

var _rig: Node2D
var _markers_parent: Node2D
var _label: Label
var _anim_label: Label
var _current_anim: String = "idle"
var _current_speed: float = 0.0
var _is_running: bool = false
var _scale_factor := 1.0
# 开场 workaround：前 0.25 秒模拟向右移动，触发 IK 正确解算
var _startup_fix_time := 0.25
var _startup_fix_elapsed := 0.0
var _startup_done := false
var _facing := 1  # 1=向右, -1=向左


func _ready() -> void:
	_rig = get_node("StickmanRig") as Node2D
	_markers_parent = get_node("Node2D") as Node2D
	# Marker2D 的父节点必须与 StickmanRig 保持相同 transform，
	# 否则 IK target 全局位置与骨骼全局位置不匹配，IK 不可达
	_rig.position = Vector2(400, 300)
	_apply_scale()

	_label = Label.new()
	_label.position = Vector2(10, 10)
	_label.text = "WASD/方向键 移动（持续按住加速→奔跑）| 1/2/3/4 切换动画 | Q/E 缩放"
	add_child(_label)

	_anim_label = Label.new()
	_anim_label.name = "AnimLabel"
	_anim_label.position = Vector2(10, 35)
	_anim_label.text = "动画: idle | 速度: 0"
	_anim_label.add_theme_font_size_override("font_size", 20)
	add_child(_anim_label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var key := event as InputEventKey
		match key.keycode:
			KEY_1: _switch_anim("idle")
			KEY_2: _switch_anim("walk")
			KEY_3: _switch_anim("attack")
			KEY_4: _switch_anim("dead")
			KEY_Q: _scale_factor *= 1.1; _apply_scale()
			KEY_E: _scale_factor *= 0.9; _apply_scale()


func _process(delta: float) -> void:
	# 开场 workaround：前 0.25 秒模拟向右移动，触发 IK 正确解算
	if not _startup_done:
		_startup_fix_elapsed += delta
		if _startup_fix_elapsed < _startup_fix_time:
			_rig.position += Vector2.RIGHT * 30 * delta
			_sync_markers_transform()
			if _current_anim == "idle":
				_switch_anim("walk")
			_update_label()
			return
		else:
			_startup_done = true
			_switch_anim("idle")
			_current_speed = 0.0

	# 检测方向输入
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0

	if dir != Vector2.ZERO:
		if dir.length() > 1.0:
			dir = dir.normalized()
		if dir.x != 0:
			_facing = 1 if dir.x > 0 else -1
			_apply_scale()
		_handle_acceleration(delta)
		_rig.position += dir * _current_speed * delta
		_sync_markers_transform()
	else:
		_handle_deceleration(delta)

	_update_label()


func _handle_acceleration(delta: float) -> void:
	if _is_running:
		_current_speed = RUN_SPEED
		return
	_current_speed += WALK_ACCEL * delta
	if _current_speed >= WALK_BASE_SPEED:
		# 达到阈值 → 奔跑，速度跳变
		_is_running = true
		_current_speed = RUN_SPEED
		_switch_anim("run")
		_rig.set_anim_speed(1.0)
	elif _current_anim != "walk" and _current_anim != "run":
		_switch_anim("walk")
	# walk 动画速率匹配速度（步幅同步）
	if _current_anim == "walk" and not _is_running:
		var s := _current_speed / WALK_BASE_SPEED
		_rig.set_anim_speed(maxf(s, MIN_ANIM_SCALE))


func _handle_deceleration(delta: float) -> void:
	if _is_running:
		# 从奔跑降速，先切回 walk
		_is_running = false
		_current_speed = WALK_BASE_SPEED
		_switch_anim("walk")
	if _current_speed > 0:
		_current_speed -= WALK_DECEL * delta
		if _current_speed <= IDLE_THRESHOLD:
			_current_speed = 0.0
			_switch_anim("idle")
		else:
			if _current_anim == "idle":
				_switch_anim("walk")
			var s := _current_speed / WALK_BASE_SPEED
			_rig.set_anim_speed(maxf(s, MIN_ANIM_SCALE))


func _apply_scale() -> void:
	var s := BASE_SCALE * _scale_factor
	_rig.scale = Vector2(s * _facing, s)
	_sync_markers_transform()


func _sync_markers_transform() -> void:
	if _markers_parent == null:
		return
	_markers_parent.global_transform = _rig.global_transform


func _switch_anim(anim_name: String) -> void:
	_rig.play(anim_name)
	_current_anim = anim_name


func _update_label() -> void:
	if _anim_label:
		var state := "run" if _is_running else _current_anim
		_anim_label.text = "动画: %s | 速度: %d" % [state, int(_current_speed)]
