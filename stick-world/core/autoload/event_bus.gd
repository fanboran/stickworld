extends Node
## 全局事件总线 —— 模块间解耦的核心通信机制。
##
## 使用方式：
##   发布（广播）： EventBus.safe_emit("game_paused")
##   订阅（监听）： EventBus.game_paused.connect(_on_game_paused)
##
## 约定：事件名用 snake_case，见名知意；参数放在信号声明里。
## 注意：
## - 资源/科技/组织/建筑等状态变更信号由对应模块 api.gd 自建并转发，EventBus 不重复声明。
## - 本文件只保留"已实际接线"的信号（2026-08 审计清理 35 个零引用信号）；
##   实现新系统时按当时契约重新声明，不要预先占位。
## - 单向广播（生产 emit 无订户，2026-08 审计标注，UI/外部接入时连接）：
##   game_saved（SaveManager 广播）、balance_changed（热重载预留）、
##   battle_started/battle_ended（战斗生命周期）、selection_changed/squad_created/order_issued（编队 UI 数据通道）、
##   chunk_loaded/chunk_unloaded（scene_loader 本地+EventBus 双发：生产消费方连本地信号，外部/测试连 EventBus）

# 信号是公共 API，供其他模块 connect/emit。
# @warning_ignore("unused_signal") 对每个信号逐条标注，因为该注解只作用于下一条语句。

# ─────────────────────────────── 游戏生命周期 ───────────────────────────────

@warning_ignore("unused_signal") signal game_started
@warning_ignore("unused_signal") signal game_loaded(slot_index: int)
@warning_ignore("unused_signal") signal game_saving(slot_index: int)
@warning_ignore("unused_signal") signal game_saved(slot_index: int)
@warning_ignore("unused_signal") signal game_paused
@warning_ignore("unused_signal") signal game_resumed

# ─────────────────────────────── 资源 / 经济 ────────────────────────────────
# 资源变化/不足信号：由 resources/api.gd 自建信号承担（4 参），EventBus 不重复声明

# ─────────────────────────────── 配置 / 平衡 ──────────────────────────────

# 平衡配置变更：BalanceConfig → 订阅方（运行时热重载数值）
@warning_ignore("unused_signal") signal balance_changed

# ─────────────────────────────── 建筑 / 建设 ────────────────────────────────
# 建筑开工/完工/拆除/受损/升级信号：由 construction/api.gd 自建信号承担，EventBus 不重复声明

# ─────────────────────────────── 战斗 ────────────────────────────────

@warning_ignore("unused_signal") signal battle_started(battle_id: String)
@warning_ignore("unused_signal") signal battle_ended(battle_id: String, victory: bool)

# ─────────────────────────────── 战斗编队（§14.4）────────────────────────────────
# 框选/选择变化：SelectionSystem -> UI
@warning_ignore("unused_signal") signal selection_changed(unit_ids: Array)
# 编队创建：FormationSystem -> UI、Organization
@warning_ignore("unused_signal") signal squad_created(squad_id, unit_ids)
# 号令下达（source_tier=发令层级，0=玩家直接指挥）：TacticalOrders -> UI、Units
@warning_ignore("unused_signal") signal order_issued(order_type, target_squad_id, source_tier)
# 任命指挥官：Organization -> UI
@warning_ignore("unused_signal") signal commander_assigned(squad_id, unit_id)

# ─────────────────────────────── 场景 / 地图 / 旅行（§14.1 / §14.2）────────────────────────────────
# 旅行请求：战略图 -> SceneLoader（玩家点击聚落进入场景图）
@warning_ignore("unused_signal") signal travel_requested(map_id: String)
# 地图加载完成：SceneLoader -> UI / Environment
@warning_ignore("unused_signal") signal map_loaded(map_id: String, map_type: int)
# 地图卸载完成：SceneLoader -> UI
@warning_ignore("unused_signal") signal map_unloaded(map_id: String)
# Chunk 加载完成：SceneLoader -> MapInstance
@warning_ignore("unused_signal") signal chunk_loaded(chunk_idx: int)
# Chunk 卸载完成：SceneLoader -> MapInstance
@warning_ignore("unused_signal") signal chunk_unloaded(chunk_idx: int)
# 旅行开始：SceneLoader -> UI / WorldClock
@warning_ignore("unused_signal") signal travel_started(from_id: String, to_id: String, mode: int)
# 旅行完成：SceneLoader -> UI
@warning_ignore("unused_signal") signal travel_completed(to_id: String)
# 战略图打开：world_map -> UI / InputDispatcher
@warning_ignore("unused_signal") signal strategic_map_opened
# 战略图关闭：world_map -> UI / InputDispatcher
@warning_ignore("unused_signal") signal strategic_map_closed

# ─────────────────────────────── UI 通用信号 ───────────────────────────────

@warning_ignore("unused_signal") signal ui_notification(title: String, body: String, level: String)
# 附身开始：PossessionInterface -> UI、Units、TimeManager
@warning_ignore("unused_signal") signal possession_started(entity)
# 附身结束：PossessionInterface -> UI、Units、TimeManager
@warning_ignore("unused_signal") signal possession_ended(entity)

# ─────────────────────────────── 调试可见性（debug_GUI → 生产解耦）──────────────────────────────
# 调试覆盖层显隐广播：生产代码（如 resource_node 调试标签）订阅此信号，
# 避免生产模块直接依赖 debug_GUI autoload（2026-08 修复依赖反转）。
@warning_ignore("unused_signal") signal debug_visibility_changed(visible: bool)

# ─────────────────────────────── 室内 / 建筑交互（§5.2）──────────────────────────────

# 进入室内交互区：Building -> InputDispatcher、UI
@warning_ignore("unused_signal") signal interior_entered(building_id: int)
# 离开室内交互区：Building -> InputDispatcher、UI
@warning_ignore("unused_signal") signal interior_exited(building_id: int)
# 传送进入大建筑：Building -> GameRoot
@warning_ignore("unused_signal") signal mega_interior_entered(building_id: int, map_id: String)
# 从大建筑返回：MegaInteriorMap -> GameRoot
@warning_ignore("unused_signal") signal mega_interior_exited(return_map_id: String)

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
