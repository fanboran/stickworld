extends Node
## 出征与领地模块（expansion）公共接口契约。
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互，
## 禁止跨模块直接引用 expansion 内部脚本（契约详见
## docs/技术/架构/出征与领地架构.md §五；广播类信号走 EventBus §六）。
##
## 装配：SystemSetup 动态挂载（ExpansionApi + ConquestManager + 共享 TerritoryRegistry，
## 与 ConstructionApi 同模式）——_ready 自载 territories 配置，
## ConquestManager 装配时可经 setup 注入共享实例。
## 广播给全局的信号在 EventBus（territory_state_changed / region_owner_changed /
## unlock_granted）；本文件两条信号是模块间点对点契约。

# ===== 公共常量 =====

## 领地状态枚举转发：跨模块消费 EventBus.territory_state_changed(new_state) 时
## 经本 api 取值（模块对外契约面），不引 expansion 内部脚本 territory_registry.gd
## 显式 preload 防 headless class_name 未注册（unit 批量加载本脚本）——
## 与项目既有 idiom 一致（测试/无头环境不依赖全局类名注册）
const _RegistryScript := preload("res://modules/expansion/scripts/territory_registry.gd")
const STATE_HOSTILE := _RegistryScript.State.HOSTILE
const STATE_CAPTURED := _RegistryScript.State.CAPTURED


# ===== 公共信号 =====

## 领地被占领：ConquestManager（批次 C5）发射 → 装饰/UI 等点对点订阅方
@warning_ignore("unused_signal")
signal territory_captured(territory_id: String, rewards: Dictionary)

## 全部领地占领（通关）：ConquestManager（批次 C5）发射 → 通关结算（victory_overlay 复用）
@warning_ignore("unused_signal")
signal conquest_completed(stats: Dictionary)


# ===== 内部引用 =====

## _ready 自载配置；SystemSetup 装配 ConquestManager 时可注入共享实例（批次 C5）
var _registry := _RegistryScript.new()

## 流程编排器（ConquestManager，SystemSetup 装配后注入；流程方法转发目标）
var _flow: Node = null

## 装配组名：展示层（城门出门框 / 战略图控制器）经组查找取本 api 实例——
## 不出全局 class_name（实测：出门框脚本在 hd2d_map_base 的 preload 链里，
## 新增全局类名会致该链 parse 期解析失败），与 fx_pos_remapper 同口径。
const GROUP := "expansion_api"


func _ready() -> void:
	if not is_in_group(GROUP):
		add_to_group(GROUP)
	if _registry.get_count() == 0:
		_registry.load_config()


func setup(registry) -> void:
	_registry = registry


## 注入流程编排器（SystemSetup 装配尾部调用；查询面不依赖它，流程面转发给它）
func set_flow_manager(manager: Node) -> void:
	_flow = manager


# ===== 查询（C1 实装）=====

## 可征伐据点列表（出征入口数据源：城门出城选项 / 战略图双击确认）：
## {id, name_zh, map_id, settlement_key, state, captured, garrison_count,
##  garrison: [{profile, name_zh, count, tier}], commander: {profile, name_zh},
##  rewards: {resources: [{id, name_zh, amount}], unlocks: [String]},
##  rewards_preview: {res_id: amount}}（展示层便捷：describe_target()）
## garrison_count = 当前剩余守军（配置 − garrison_losses 车轮战扣减，clamp 0；
## 不含敌将——敌将每次进图均在位，架构 §2.3）
func list_targets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row in _registry.get_all():
		if not (row is Dictionary):
			continue
		var id := String(row.get("id", ""))
		var state := get_territory_state(id)
		var commander: Dictionary = row.get("commander", {}) if row.get("commander") is Dictionary else {}
		var commander_profile := String(commander.get("profile", ""))
		out.append({
			"id": id,
			"name_zh": String(row.get("name_zh", "")),
			"map_id": String(row.get("map_id", "")),
			"settlement_key": String(row.get("settlement_key", "")),
			"entry_side": int(row.get("entry_side", 0)),
			"state": state,
			"captured": state == _RegistryScript.State.CAPTURED,
			"garrison_count": maxi(0, _registry.get_garrison_count(id) - _registry.get_garrison_losses(id)),
			"garrison": _registry.get_remaining_garrison(id),
			"commander": {
				"profile": commander_profile,
				"name_zh": _registry.profile_name(commander_profile),
			},
			"rewards": {
				"resources": _reward_resource_rows(row.get("rewards", {})),
				"unlocks": _reward_unlock_ids(row.get("rewards", {})),
			},
			"rewards_preview": row.get("rewards", {}).get("resources", {}) if row.get("rewards") is Dictionary else {},
		})
	return out


## 按战略图聚落 id 反查据点（双击聚落判"这是不是可征伐的敌据点"）——
## 无对位/已臣服返回空字典
func find_target_by_settlement(settlement_id: String) -> Dictionary:
	if settlement_id.is_empty():
		return {}
	for t in list_targets():
		if String(t.get("settlement_key", "")) == settlement_id and not bool(t.get("captured", false)):
			return t
	return {}


## 目标情报一句话（确认框/提示文案共用；展示层不各自拼串）：
## 「守军 剑士×2、弓手×1（敌将：平原步兵）｜战利品 木材30、石料20」
func describe_target(target: Dictionary) -> String:
	var parts: Array[String] = []
	var units: Array[String] = []
	for entry in target.get("garrison", []):
		if entry is Dictionary and int(entry.get("count", 0)) > 0:
			units.append("%s×%d" % [String(entry.get("name_zh", "")), int(entry.get("count", 0))])
	if units.is_empty():
		parts.append("守军 已无")
	else:
		parts.append("守军 " + "、".join(units))
	var cmdr: Dictionary = target.get("commander", {}) if target.get("commander") is Dictionary else {}
	var cmdr_name := String(cmdr.get("name_zh", ""))
	if not cmdr_name.is_empty():
		parts.append("（敌将：%s）" % cmdr_name)
	var loot: Array[String] = []
	var rewards: Dictionary = target.get("rewards", {}) if target.get("rewards") is Dictionary else {}
	for res in rewards.get("resources", []):
		if res is Dictionary:
			loot.append("%s%d" % [String(res.get("name_zh", "")), int(res.get("amount", 0))])
	for unlock in rewards.get("unlocks", []):
		loot.append(String(unlock))
	if not loot.is_empty():
		parts.append("｜战利品 " + "、".join(loot))
	return " ".join(parts)


## 奖励资源行（res_id → name_zh；资源表缺失回落 id）
func _reward_resource_rows(rewards: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (rewards is Dictionary):
		return out
	var amounts: Variant = (rewards as Dictionary).get("resources", {})
	if not (amounts is Dictionary):
		return out
	var names: Dictionary = _resource_names()
	for res_id in (amounts as Dictionary):
		var key := String(res_id)
		out.append({
			"id": key,
			"name_zh": String(names.get(key, key)),
			"amount": int((amounts as Dictionary)[res_id]),
		})
	return out


func _reward_unlock_ids(rewards: Variant) -> Array[String]:
	var out: Array[String] = []
	if rewards is Dictionary:
		var unlocks: Variant = (rewards as Dictionary).get("unlocks", [])
		if unlocks is Array:
			for u in unlocks:
				out.append(String(u))
	return out


## 资源 id → name_zh（BalanceConfig 资源表；缺表回落 id）
func _resource_names() -> Dictionary:
	var names: Dictionary = {}
	var rows: Variant = BalanceConfig.get_value("resources.resources") if BalanceConfig else null
	if rows is Array:
		for row in rows:
			if row is Dictionary:
				names[String(row.get("id", ""))] = String(row.get("name_zh", ""))
	return names


## 领地运行时状态：HOSTILE / CAPTURED；未知 id 或 WorldState 无记录按 HOSTILE
func get_territory_state(id: String) -> int:
	var record: Dictionary = WorldState.territories.get(id, {})
	return int(record.get("state", _RegistryScript.State.HOSTILE))


## 通关判定：全部领地 CAPTURED（无领地配置时恒 false，防装配期误判通关）
func is_all_captured() -> bool:
	if _registry.get_count() == 0:
		return false
	for row in _registry.get_all():
		if get_territory_state(String(row.get("id", ""))) != _RegistryScript.State.CAPTURED:
			return false
	return true


# ===== 流程（ConquestManager 编排，本 api 转发）=====

## 出征：校验状态 → SceneLoader.travel_to_map(map_id)。可出征返回 true
func launch_campaign(territory_id: String) -> bool:
	if _flow != null and _flow.has_method("launch_campaign"):
		return _flow.launch_campaign(territory_id)
	push_warning("[expansion] ConquestManager 未装配，出征不可用")
	return false


## 占领：battle_ended 后由 ConquestManager 调（也供测试直达）——
## 写状态/发奖励/广播 territory_state_changed + region_owner_changed
func capture_territory(territory_id: String) -> void:
	if _flow != null and _flow.has_method("capture_territory"):
		_flow.capture_territory(territory_id)
		return
	push_warning("[expansion] ConquestManager 未装配，占领不可用")
