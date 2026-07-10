extends Node
## 全局事件总线 —— 模块间解耦的核心通信机制。
##
## 使用方式：
##   发布（广播）： EventBus.emit_signal("resource_changed", resource_name, amount)
##   订阅（监听）： EventBus.resource_changed.connect(_on_resource_changed)
##
## 约定：事件名用 snake_case，见名知意；参数放在信号声明里。

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

@warning_ignore("unused_signal") signal resource_changed(resource_name: String, amount: int, delta: int)
@warning_ignore("unused_signal") signal resource_depleted(resource_name: String)
@warning_ignore("unused_signal") signal resource_not_enough(resource_name: String, required: int)
# 价格波动（供需自动）：资源系统 → 组织、UI
@warning_ignore("unused_signal") signal price_changed(resource_id, old_price, new_price, region_id)
# 商队到货：运输系统 → 资源系统、UI
@warning_ignore("unused_signal") signal trade_completed(from_region, to_region, resource_id, quantity)
# CPI 超警戒线：资源系统 → UI
@warning_ignore("unused_signal") signal inflation_warning(rate)

# ─────────────────────────────── 人口 / 单位 ───────────────────────────────

@warning_ignore("unused_signal") signal population_changed(total: int, delta: int)
@warning_ignore("unused_signal") signal unit_recruited(unit_type: String)
@warning_ignore("unused_signal") signal unit_lost(unit_type: String)
# 消耗沥青召唤：组织系统 → 资源系统
@warning_ignore("unused_signal") signal unit_summoned(unit_id, asphalt_cost)
# 晋升/调岗：组织系统 → UI
@warning_ignore("unused_signal") signal unit_promoted(unit_id, old_role, new_role)
# 指挥官阵亡：战斗系统 → 组织系统
@warning_ignore("unused_signal") signal commander_died(org_id, commander_id)

# ─────────────────────────────── 建筑 / 建设 ────────────────────────────────

@warning_ignore("unused_signal") signal building_started(building_id: String, tile_pos: Vector2i)
@warning_ignore("unused_signal") signal building_completed(building_id: String, tile_pos: Vector2i)
@warning_ignore("unused_signal") signal building_removed(building_id: String, tile_pos: Vector2i)
# 被攻击：战斗系统 → 建设系统
@warning_ignore("unused_signal") signal building_damaged(building_id, damage_amount)
# 升级：建设系统 → UI
@warning_ignore("unused_signal") signal building_upgraded(building_id, old_tier, new_tier)

# ─────────────────────────────── 科技 ────────────────────────────────────

@warning_ignore("unused_signal") signal tech_researched(tech_id: String)
@warning_ignore("unused_signal") signal tech_started(tech_id: String)
# 研究停滞（资源不足/人员不足）：科技系统 → UI
@warning_ignore("unused_signal") signal tech_stalled(tech_id, reason)

# ─────────────────────────────── 战斗 / 扩张 ────────────────────────────────

@warning_ignore("unused_signal") signal battle_started(battle_id: String)
@warning_ignore("unused_signal") signal battle_ended(battle_id: String, victory: bool)
# 进入僵持：战斗系统 → UI
@warning_ignore("unused_signal") signal battle_stalemate(battle_id, duration)
# 补给被切断：战斗系统 → 运输系统、组织系统
@warning_ignore("unused_signal") signal supply_line_cut(org_id, supply_id)
# 关键战术事件：战斗系统 → UI（可选显示）
@warning_ignore("unused_signal") signal tactical_event(battle_id, event_type, data)
@warning_ignore("unused_signal") signal territory_gained(tile_id: String)
@warning_ignore("unused_signal") signal territory_lost(tile_id: String)
# 文化同化完成：扩张系统 → UI
@warning_ignore("unused_signal") signal culture_assimilated(region_id, from_culture, to_culture)
# 包围网形成：扩张系统 → UI、战斗系统
@warning_ignore("unused_signal") signal coalition_formed(members)
# 条约签订：扩张系统 → UI
@warning_ignore("unused_signal") signal treaty_signed(type, parties, terms)

# ─────────────────────────────── 组织 ─────────────────────────────────────
# 创建新组织：组织系统 → UI
@warning_ignore("unused_signal") signal org_created(org_id, parent_id, tag, tier)
# 解散组织：组织系统 → UI、Project系统
@warning_ignore("unused_signal") signal org_disbanded(org_id)
# 重组编制：组织系统 → UI
@warning_ignore("unused_signal") signal org_restructured(org_id, changes)
# 效率变动：组织系统 → UI
@warning_ignore("unused_signal") signal org_efficiency_changed(org_id, old, new)
# AI 自主行动：组织系统 → UI（可选）
@warning_ignore("unused_signal") signal org_autonomy_triggered(org_id, action)

# ─────────────────────────────── 项目 ─────────────────────────────────────
# 创建项目：组织系统 → 组织系统
@warning_ignore("unused_signal") signal project_created(project_id, owner_org_id, type)
# 项目完成：组织系统 → 组织系统、UI
@warning_ignore("unused_signal") signal project_completed(project_id, result)
# 项目失败：组织系统 → 组织系统、UI
@warning_ignore("unused_signal") signal project_failed(project_id, reason)
# 项目分解为子项目：组织系统 → 组织系统
@warning_ignore("unused_signal") signal project_decomposed(parent_id, child_ids)

# ─────────────────────────────── UI 通用信号 ───────────────────────────────

@warning_ignore("unused_signal") signal ui_notification(title: String, body: String, level: String)
@warning_ignore("unused_signal") signal ui_toggle_pause_requested
@warning_ignore("unused_signal") signal ui_switch_view(view_name: String)
# 缩放级别变化：相机 → UI
@warning_ignore("unused_signal") signal ui_zoom_level_changed(new_level)
# 附身操控单位：UI → 战斗系统
@warning_ignore("unused_signal") signal ui_possess_unit(unit_id)

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
