extends Node
## 全局事件总线 —— 模块间解耦的核心通信机制。
##
## 使用方式：
##   发布（广播）： EventBus.game_paused.emit()
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
##   team_ai_stance_changed/heal_cast（战斗可观测性：调试 HUD/测试断言接入时连接）、
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
# 阵营 AI 姿态变更（TeamAi -> 调试 HUD/测试断言）：from/to_stance 值序 0=GARRISON/1=DEFEND/2=ATTACK
# （对齐 dump Team.Stance 枚举序）
@warning_ignore("unused_signal") signal team_ai_stance_changed(battle_id: String, faction: int, from_stance: int, to_stance: int, reason: String)
# 治疗施放（WeaponMount.cast_heal -> battle_sim 采样/可观测性，P7 批次 7b）：
# battle_id 经施法者 get_battle_instance().get_battle_id()；caster/target 用 instance_id；
# anim_name ∈ {"heal_meric_1","heal_meric_2"}（随机分布统计源，spec §5.4.3）
@warning_ignore("unused_signal") signal heal_cast(battle_id: String, caster_id: int, target_id: int, anim_name: String)

# ─────────────────────────────── 战斗编队（§14.4）────────────────────────────────
# 框选/选择变化：SelectionSystem -> UI
@warning_ignore("unused_signal") signal selection_changed(unit_ids: Array)
# 编队创建：FormationSystem -> UI、Organization
@warning_ignore("unused_signal") signal squad_created(squad_id: String, unit_ids: Array)
# 号令下达（source_tier=发令层级，0=玩家直接指挥）：TacticalOrders -> UI、Units
@warning_ignore("unused_signal") signal order_issued(order_type: int, target_squad_id: String, source_tier: int)
# 任命指挥官：Organization -> UI
@warning_ignore("unused_signal") signal commander_assigned(squad_id: String, unit_id: int)

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
# 聚落规模变化（construction/事件系统 -> world_map）：payload 带新 population_score，
# 战略图 L1 重算该聚落建成区 blob（总体设计 §5.7 实时变动；发射方建设系统接线前测试代发）
@warning_ignore("unused_signal") signal settlement_updated(settlement_id: String, population_score: float)

# ─────────────────────────────── UI 通用信号 ───────────────────────────────

@warning_ignore("unused_signal") signal ui_notification(title: String, body: String, level: String)
# 附身开始：PossessionInterface -> UI、Units、TimeManager
@warning_ignore("unused_signal") signal possession_started(entity)
# 附身结束：PossessionInterface -> UI、Units、TimeManager
@warning_ignore("unused_signal") signal possession_ended(entity)

# ─────────────────────────────── 调试可见性（debug_gui → 生产解耦）──────────────────────────────
# 调试覆盖层显隐广播：生产代码（如 resource_node 调试标签）订阅此信号，
# 避免生产模块直接依赖 debug_gui autoload（2026-08 修复依赖反转）。
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

# safe_emit 已移除（2026-08-22）：改用类型化 .emit()，信号名拼写错误在编译期暴露。
