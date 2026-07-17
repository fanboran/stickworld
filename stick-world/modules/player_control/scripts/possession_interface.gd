class_name PossessionInterface
extends Node
## 附身接口 -- POSSESS 模式 handler。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1.3、§7.5。
##
## 职责：
##   1. 进入 POSSESS 模式时，从 SelectionSystem 取选中单位（或沿用 EXPLORE 已附身实体）
##   2. 调用 entity.set_possessed(true)，暂停 AIController
##   3. CameraRig 跟随该实体 + 居中模式
##   4. 消费 TimeManager.auto_slow_on_possess（自动降速到 X1）
##   5. 发射 EventBus.possession_started / possession_ended
##   6. ESC 退出附身，回到进入前的模式
##
## 实际 WASD/鼠标输入由 StickmanEntity._physics_process / _input 读取（P0 简化）。

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _input_dispatcher: Node = null
var _camera_rig: Camera2D = null
var _selection: Node = null

# ─────────────────────────────── 状态 ────────────────────────────────
## 当前附身的实体
var _possessed_entity: Node2D = null
## 进入 POSSESS 前的模式（退出时恢复）
var _previous_mode: int = PlayerControlAPI.Mode.NONE
## 附身前的时间速度（退出时恢复）
var _previous_speed: int = TimeManager.Speed.X1
## 是否已降速
var _slowed_time: bool = false
## 待附身实体（由外部在模式切换前设置，解决 SelectionSystem 清空选择的问题）
var _pending_entity: Node2D = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	call_deferred("_resolve_references")


func _resolve_references() -> void:
	var p := get_parent()
	while p != null:
		if p.has_method("get_current_map"):
			_game_root = p
			break
		p = p.get_parent()
	if _game_root == null:
		return
	_input_dispatcher = _game_root.input_dispatcher if _game_root.has_method("get") and _game_root.get("input_dispatcher") != null else null
	_camera_rig = _game_root.camera_rig if _game_root.has_method("get") and _game_root.get("camera_rig") != null else null
	_selection = _game_root.get_selection_system() if _game_root.has_method("get_selection_system") else null


func _input(event: InputEvent) -> void:
	# ESC 退出附身
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _input_dispatcher != null and _input_dispatcher.has_method("is_mode") and _input_dispatcher.is_mode(PlayerControlAPI.Mode.POSSESS):
			_release_and_exit()
			get_viewport().set_input_as_handled()


# ─────────────────────────────── 模式回调 ────────────────────────────────

## 设置待附身实体（在 enter_possess_mode() 之前调用）
func set_pending_entity(entity: Node2D) -> void:
	_pending_entity = entity
	# 提前捕获当前模式（_on_mode_activated 时模式已切换为 POSSESS）
	if _input_dispatcher != null and _input_dispatcher.has_method("get_mode"):
		_previous_mode = _input_dispatcher.get_mode()


func _on_mode_activated(_mode: int) -> void:
	# 记录之前的模式（若 set_pending_entity 已设置则不覆盖）
	if _pending_entity == null:
		if _input_dispatcher != null and _input_dispatcher.has_method("get_mode"):
			_previous_mode = _input_dispatcher.get_mode()
	# 取选中单位附身
	_possess_selected_or_current()


func _on_mode_deactivated(_mode: int) -> void:
	_release_possession()


# ─────────────────────────────── 附身逻辑 ────────────────────────────────

## 附身选中单位，若无选中则沿用当前已附身实体（从 EXPLORE 切换时）。
func _possess_selected_or_current() -> void:
	var target: Node2D = null
	# 优先使用 pending entity（由 BattlePanel 在模式切换前设置）
	if _pending_entity != null and is_instance_valid(_pending_entity):
		if not (_pending_entity.has_method("is_dead") and _pending_entity.is_dead()):
			target = _pending_entity
		_pending_entity = null
	# 若无 pending，从 SelectionSystem 取选中单位
	if target == null and _selection != null and _selection.has_method("get_selected_units"):
		var units: Array = _selection.get_selected_units()
		if not units.is_empty():
			for u in units:
				if is_instance_valid(u) and u.has_method("set_possessed"):
					if not (u.has_method("is_dead") and u.is_dead()):
						target = u
						break
	# 若无选中，尝试沿用当前已附身实体（EXPLORE -> POSSESS）
	if target == null and _possessed_entity != null and is_instance_valid(_possessed_entity):
		if not (_possessed_entity.has_method("is_dead") and _possessed_entity.is_dead()):
			target = _possessed_entity
	# 若仍无目标，尝试从地图取第一个可附身实体
	if target == null:
		target = _find_first_entity()
	if target == null:
		push_warning("[PossessionInterface] 未找到可附身实体")
		return
	# 附身
	if target.has_method("set_possessed"):
		# 先解除之前附身的实体
		if _possessed_entity != null and _possessed_entity != target and is_instance_valid(_possessed_entity):
			_possessed_entity.set_possessed(false)
		target.set_possessed(true)
	_possessed_entity = target
	# 相机跟随 + 居中
	if _camera_rig != null:
		if _camera_rig.has_method("set_follow_target"):
			_camera_rig.set_follow_target(target)
		if _camera_rig.has_method("set_centered_mode"):
			_camera_rig.set_centered_mode(true)
	# 自动降速
	_slow_time()
	# 发射信号
	if EventBus != null:
		EventBus.possession_started.emit(target)


## 释放附身
func _release_possession() -> void:
	if _possessed_entity == null or not is_instance_valid(_possessed_entity):
		_possessed_entity = null
		_restore_time()
		return
	if _possessed_entity.has_method("set_possessed"):
		_possessed_entity.set_possessed(false)
	# 发射信号
	if EventBus != null:
		EventBus.possession_ended.emit(_possessed_entity)
	_possessed_entity = null
	# 恢复时间速度
	_restore_time()


## 释放附身并退出 POSSESS 模式
func _release_and_exit() -> void:
	_release_possession()
	# 回到之前的模式（BATTLE 或 EXPLORE）
	if _input_dispatcher != null and _input_dispatcher.has_method("set_mode"):
		var restore_mode: int = _previous_mode
		if restore_mode == PlayerControlAPI.Mode.NONE or restore_mode == PlayerControlAPI.Mode.POSSESS:
			restore_mode = PlayerControlAPI.Mode.EXPLORE
		_input_dispatcher.set_mode(restore_mode)
	# 相机取消居中
	if _camera_rig != null and _camera_rig.has_method("set_centered_mode"):
		_camera_rig.set_centered_mode(false)


## 从地图找第一个可用 StickmanEntity
func _find_first_entity() -> Node2D:
	if _game_root == null:
		_resolve_references()
	if _game_root == null:
		return null
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		return null
	if map.has_method("get_entities"):
		for e in map.get_entities():
			if e is CharacterBody2D and e.has_method("set_possessed"):
				if not (e.has_method("is_dead") and e.is_dead()):
					return e
	return null


# ─────────────────────────────── 时间控制 ────────────────────────────────

## 附身时自动降速到 X1
func _slow_time() -> void:
	if TimeManager == null:
		return
	if not TimeManager.auto_slow_on_possess:
		return
	# 记录当前速度
	_previous_speed = TimeManager.current_speed
	# 降速到 X1（如果当前不是暂停）
	if not TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)
	_slowed_time = true


## 恢复附身前的时间速度
func _restore_time() -> void:
	if not _slowed_time:
		return
	_slowed_time = false
	if TimeManager == null:
		return
	if not TimeManager.is_paused():
		TimeManager.set_speed(_previous_speed)


# ─────────────────────────────── 公共 API ────────────────────────────────

## 获取当前附身的实体
func get_possessed_entity() -> Node2D:
	return _possessed_entity


## 主动附身指定实体（供测试或 UI 按钮调用）
func possess(entity: Node2D) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if not entity.has_method("set_possessed"):
		return
	# 死亡单位不可附身
	if entity.has_method("is_dead") and entity.is_dead():
		return
	# 先释放当前
	if _possessed_entity != null and _possessed_entity != entity and is_instance_valid(_possessed_entity):
		_possessed_entity.set_possessed(false)
	# 附身新目标
	entity.set_possessed(true)
	_possessed_entity = entity
	# 相机跟随 + 居中
	if _camera_rig != null:
		if _camera_rig.has_method("set_follow_target"):
			_camera_rig.set_follow_target(entity)
		if _camera_rig.has_method("set_centered_mode"):
			_camera_rig.set_centered_mode(true)
	_slow_time()
	if EventBus != null:
		EventBus.possession_started.emit(entity)


## 释放附身并退出（公共方法，供 UI 按钮调用）
func release() -> void:
	_release_and_exit()
