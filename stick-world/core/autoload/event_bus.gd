extends Node
## 全局事件总线 —— 模块间解耦的核心通信机制。
##
## 使用方式：
##   发布（广播）： EventBus.emit_signal("resource_changed", resource_name, amount)
##   订阅（监听）： EventBus.resource_changed.connect(_on_resource_changed)
##
## 约定：事件名用 snake_case，见名知意；参数放在信号声明里。

# ─────────────────────────────── 游戏生命周期 ───────────────────────────────

signal game_started
signal game_loaded(slot_index: int)
signal game_saving(slot_index: int)
signal game_saved(slot_index: int)
signal game_paused
signal game_resumed

# ─────────────────────────────── 资源 / 经济 ────────────────────────────────

signal resource_changed(resource_name: String, amount: int, delta: int)
signal resource_depleted(resource_name: String)
signal resource_not_enough(resource_name: String, required: int)

# ─────────────────────────────── 人口 / 单位 ───────────────────────────────

signal population_changed(total: int, delta: int)
signal unit_recruited(unit_type: String)
signal unit_lost(unit_type: String)

# ─────────────────────────────── 建筑 / 建设 ────────────────────────────────

signal building_started(building_id: String, tile_pos: Vector2i)
signal building_completed(building_id: String, tile_pos: Vector2i)
signal building_removed(building_id: String, tile_pos: Vector2i)

# ─────────────────────────────── 科技 ────────────────────────────────────

signal tech_researched(tech_id: String)
signal tech_started(tech_id: String)

# ─────────────────────────────── 战斗 / 扩张 ────────────────────────────────

signal battle_started(battle_id: String)
signal battle_ended(battle_id: String, victory: bool)
signal territory_gained(tile_id: String)
signal territory_lost(tile_id: String)

# ─────────────────────────────── UI 通用信号 ───────────────────────────────

signal ui_notification(title: String, body: String, level: String)
signal ui_toggle_pause_requested
signal ui_switch_view(view_name: String)

# ─────────────────────────────── 通用工具 ────────────────────────────────

## 带"事件存在性检查"的安全发射。事件名写错时打印警告而不是静默失败。
func safe_emit(event_name: StringName, args: Array = []) -> void:
	if not has_signal(event_name):
		push_warning("[EventBus] 尝试发出未声明的信号: %s" % event_name)
		return
	# 按参数个数分支调用（最多支持 3 个动态参数，对当前信号足够）
	match args.size():
		0:
			emit_signal(event_name)
		1:
			emit_signal(event_name, args[0])
		2:
			emit_signal(event_name, args[0], args[1])
		3:
			emit_signal(event_name, args[0], args[1], args[2])
		_:
			push_warning("[EventBus] safe_emit 参数个数超过 3，未传递")
