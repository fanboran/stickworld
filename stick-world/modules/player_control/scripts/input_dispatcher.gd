class_name InputDispatcher
extends Node
## 输入分发器 —— 根据当前模式路由输入到对应处理器。
##
## 模式切换通过 set_mode() 触发，发射 mode_changed 信号。
## 各模式处理器通过 register_handler() 注册。
##
## 详见 docs/技术/架构/场景与战斗架构.md §二.2、§七.3。

const PlayerControlAPI := preload("res://modules/player_control/api.gd")

# ─────────────────────────────── 信号 ────────────────────────────────
signal mode_changed(old_mode: int, new_mode: int)

# ─────────────────────────────── 状态 ────────────────────────────────
var current_mode: int = PlayerControlAPI.Mode.EXPLORE

## 已注册的模式处理器：mode -> handler Node
## handler 需要实现 _on_mode_activated(mode) 和 _on_mode_deactivated(mode) 方法
var _handlers: Dictionary = {}


# ─────────────────────────────── 模式控制 ────────────────────────────────

## 设置当前模式。如新旧模式相同则不触发。
func set_mode(new_mode: int) -> void:
	if new_mode == current_mode:
		return
	var old := current_mode
	# 通知旧 handler
	_notify_deactivated(old)
	current_mode = new_mode
	# 通知新 handler
	_notify_activated(new_mode)
	mode_changed.emit(old, new_mode)


## 获取当前模式
func get_mode() -> int:
	return current_mode


## 是否处于指定模式
func is_mode(mode: int) -> bool:
	return current_mode == mode


# ─────────────────────────────── 处理器注册 ────────────────────────────────

## 注册模式处理器。当模式切换到 mode 时调用 handler._on_mode_activated。
func register_handler(mode: int, handler: Node) -> void:
	if handler == null:
		push_warning("[InputDispatcher] 注册空 handler, mode=%d" % mode)
		return
	_handlers[mode] = handler
	# 如果注册的就是当前模式，立即激活
	if mode == current_mode:
		_notify_activated(mode)


## 取消注册
func unregister_handler(mode: int) -> void:
	if mode == current_mode:
		_notify_deactivated(mode)
	_handlers.erase(mode)


## 获取指定模式的处理器
func get_handler(mode: int) -> Node:
	return _handlers.get(mode, null)


# ─────────────────────────────── 内部 ────────────────────────────────

func _notify_activated(mode: int) -> void:
	var handler: Node = _handlers.get(mode, null)
	if handler != null and is_instance_valid(handler):
		if handler.has_method("_on_mode_activated"):
			handler._on_mode_activated(mode)


func _notify_deactivated(mode: int) -> void:
	var handler: Node = _handlers.get(mode, null)
	if handler != null and is_instance_valid(handler):
		if handler.has_method("_on_mode_deactivated"):
			handler._on_mode_deactivated(mode)


# ─────────────────────────────── 便捷切换 ────────────────────────────────

func enter_build_mode() -> void:
	set_mode(PlayerControlAPI.Mode.BUILD)


func exit_build_mode() -> void:
	set_mode(PlayerControlAPI.Mode.EXPLORE)


func enter_battle_mode() -> void:
	set_mode(PlayerControlAPI.Mode.BATTLE)


func enter_possess_mode() -> void:
	set_mode(PlayerControlAPI.Mode.POSSESS)


func enter_indoor_mode() -> void:
	set_mode(PlayerControlAPI.Mode.INDOOR)


func exit_to_explore() -> void:
	set_mode(PlayerControlAPI.Mode.EXPLORE)
