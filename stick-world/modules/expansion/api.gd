extends Node
## 出征与领地模块（expansion）公共接口契约。
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互，
## 禁止跨模块直接引用 expansion 内部脚本（契约详见
## docs/技术/架构/出征与领地架构.md §五；广播类信号走 EventBus §六）。
##
## 装配：SystemSetup 动态挂载（批次 C5，与 SaveHandler 同模式）——
## _ready 自载 territories 配置，ConquestManager 装配时可经 setup 注入共享实例。
## 广播给全局的信号在 EventBus（territory_state_changed / region_owner_changed /
## unlock_granted）；本文件两条信号是模块间点对点契约。

# ===== 公共信号 =====

## 领地被占领：ConquestManager（批次 C5）发射 → 装饰/UI 等点对点订阅方
@warning_ignore("unused_signal")
signal territory_captured(territory_id: String, rewards: Dictionary)

## 全部领地占领（通关）：ConquestManager（批次 C5）发射 → 通关结算（victory_overlay 复用）
@warning_ignore("unused_signal")
signal conquest_completed(stats: Dictionary)


# ===== 内部引用 =====

## _ready 自载配置；SystemSetup 装配 ConquestManager 时可注入共享实例（批次 C5）
var _registry := TerritoryRegistry.new()


func _ready() -> void:
	if _registry.get_count() == 0:
		_registry.load_config()


func setup(registry: TerritoryRegistry) -> void:
	_registry = registry


# ===== 查询（C1 实装）=====

## 可征伐据点列表（出城选项动态项数据源）：{id, name_zh, garrison_count, captured, rewards_preview}
func list_targets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row in _registry.get_all():
		if not (row is Dictionary):
			continue
		var id := String(row.get("id", ""))
		out.append({
			"id": id,
			"name_zh": String(row.get("name_zh", "")),
			"garrison_count": _registry.get_garrison_count(id),
			"captured": get_territory_state(id) == TerritoryRegistry.State.CAPTURED,
			"rewards_preview": row.get("rewards", {}).get("resources", {}),
		})
	return out


## 领地运行时状态：HOSTILE / CAPTURED；未知 id 或 WorldState 无记录按 HOSTILE
func get_territory_state(id: String) -> int:
	var record: Dictionary = WorldState.territories.get(id, {})
	return int(record.get("state", TerritoryRegistry.State.HOSTILE))


## 通关判定：全部领地 CAPTURED（无领地配置时恒 false，防装配期误判通关）
func is_all_captured() -> bool:
	if _registry.get_count() == 0:
		return false
	for row in _registry.get_all():
		if get_territory_state(String(row.get("id", ""))) != TerritoryRegistry.State.CAPTURED:
			return false
	return true


# ===== 流程（批次 C5 由 ConquestManager 实装，C1 仅占位契约）=====

## 出征：校验状态 → SceneLoader.travel_to_map(map_id)。可出征返回 true
func launch_campaign(territory_id: String) -> bool:
	push_warning("[expansion] launch_campaign 属批次 C5（ConquestManager）实装，当前恒拒")
	return false


## 占领：battle_ended 后由 ConquestManager 调（也供测试直达）——
## 写状态/发奖励/广播 territory_state_changed + region_owner_changed
func capture_territory(territory_id: String) -> void:
	push_warning("[expansion] capture_territory 属批次 C5（ConquestManager）实装，当前无操作")
