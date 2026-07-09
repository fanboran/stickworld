extends Node
## 游戏时间流速控制 —— 统一管理暂停/加速/减速。
##
## 各系统在 _process 中调用 should_update(system_name) 判断当前帧是否需要执行更新。
## 通过 EventBus 发射 game_paused / game_resumed 信号通知所有监听者。

class_name TimeManager

# ─────────────────────────────── 速度枚举 ────────────────────────────────

enum Speed {
	PAUSED,   ## 完全暂停
	X1,       ## 正常速度（1x）
	X2,       ## 2 倍速
	X4,       ## 4 倍速
}

# ─────────────────────────────── 状态 ───────────────────────────────────

var current_speed: Speed = Speed.X1

## 自动暂停条件列表。当任一条件触发时自动暂停。
## 示例：["battle_started", "commander_died", "ui_dialog_open"]
var auto_pause_conditions: Array[String] = []

## 附身（possess）时是否自动降速为 X1。
var auto_slow_on_possess: bool = true

# ─────────────────────────────── 内部状态 ────────────────────────────────

var _was_paused: bool = false


# ─────────────────────────────── 速度控制 ────────────────────────────────

## 设置当前时间流速。根据新旧速度状态发射 game_paused / game_resumed。
func set_speed(speed: Speed) -> void:
	if current_speed == speed:
		return

	var was_paused: bool = (current_speed == Speed.PAUSED)
	current_speed = speed
	var is_paused: bool = (current_speed == Speed.PAUSED)

	# 只在状态变化时发射信号
	if was_paused != is_paused:
		if is_paused:
			EventBus.game_paused.emit()
		else:
			EventBus.game_resumed.emit()


## 暂停游戏。
func pause() -> void:
	set_speed(Speed.PAUSED)


## 恢复游戏（恢复为 X1 速度）。
func resume() -> void:
	set_speed(Speed.X1)


## 切换暂停/恢复。
func toggle_pause() -> void:
	if current_speed == Speed.PAUSED:
		resume()
	else:
		pause()


## 当前是否处于暂停状态。
func is_paused() -> bool:
	return current_speed == Speed.PAUSED


# ─────────────────────────────── 更新判定 ────────────────────────────────

## 各系统调用此方法判断当前帧是否需要执行更新。
## 返回值取决于当前速度：PAUSED 时返回 false，X1 时每帧 true，X2/X4 时可做帧跳过。
## 当前实现：PAUSED → false，其他 → true（倍速由各系统自行处理帧间隔）。
func should_update(system_name: String) -> bool:
	if current_speed == Speed.PAUSED:
		return false
	# 检查自动暂停条件
	for condition in auto_pause_conditions:
		if _check_auto_pause_condition(condition):
			return false
	return true


# ─────────────────────────────── 自动暂停条件 ────────────────────────────

## 检查指定的自动暂停条件是否满足。
## 当前预留同步检查接口，后续可改为信号驱动。
func _check_auto_pause_condition(condition: String) -> bool:
	# 预留：各系统通过 EventBus 注册条件，此处仅检查已触发的条件列表
	# 当前占位，始终返回 false（不触发自动暂停）
	return false


## 添加自动暂停条件。
func add_auto_pause_condition(condition: String) -> void:
	if condition not in auto_pause_conditions:
		auto_pause_conditions.append(condition)


## 移除自动暂停条件。
func remove_auto_pause_condition(condition: String) -> void:
	var idx: int = auto_pause_conditions.find(condition)
	if idx != -1:
		auto_pause_conditions.remove_at(idx)