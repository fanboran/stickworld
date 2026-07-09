extends Node
## 运行时世界状态中心 —— 集中管理所有实体状态。
##
## 所有游戏实体（stickmen、organizations、regions 等）的状态存储于此，
## 各模块通过 WorldState 读写实体数据，而非各自维护独立状态。
##
## 与 SaveManager 协作：通过 register_module_save_data 注册各模块的
## 序列化/反序列化回调，SaveManager 存档时收集所有模块数据。

class_name WorldState

# ─────────────────────────────── 实体容器 ────────────────────────────────

var stickmen: Dictionary = {}          # {id: StickmanState}
var organizations: Dictionary = {}      # {id: OrganizationState}
var regions: Dictionary = {}            # {id: RegionState}
var battles: Dictionary = {}            # {id: BattleState}
var projects: Dictionary = {}           # {id: ProjectState}
var supply_chains: Dictionary = {}      # {id: SupplyChainState}

# ─────────────────────────────── 全局状态 ────────────────────────────────

var game_time: float = 0.0

# ─────────────────────────────── 模块保存注册 ────────────────────────────

## 模块名 -> { "get_save": Callable, "load_save": Callable }
var _save_callbacks: Dictionary = {}


# ─────────────────────────────── 通用查询 ────────────────────────────────

## 根据实体类型和 ID 查找实体。
## 当前支持的 entity_type：stickmen, organizations, regions, battles, projects, supply_chains
func get_entity(entity_type: String, entity_id: String) -> Variant:
	var container: Dictionary = _get_container(entity_type)
	if container == null:
		push_warning("[WorldState] 未知实体类型: %s" % entity_type)
		return null
	return container.get(entity_id, null)


## 返回实体类型对应的容器字典引用，不存在则返回 null。
func _get_container(entity_type: String) -> Dictionary:
	match entity_type:
		"stickmen":
			return stickmen
		"organizations":
			return organizations
		"regions":
			return regions
		"battles":
			return battles
		"projects":
			return projects
		"supply_chains":
			return supply_chains
		_:
			return null


# ─────────────────────────────── 模块保存注册 ────────────────────────────

## 注册模块的序列化/反序列化回调。
## get_save_fn 应返回 Dictionary，load_save_fn 接收 Dictionary。
func register_module_save_data(module_name: String, get_save_fn: Callable, load_save_fn: Callable) -> void:
	_save_callbacks[module_name] = {
		"get_save": get_save_fn,
		"load_save": load_save_fn,
	}


## 收集所有已注册模块的保存数据。（由 SaveManager 调用）
func collect_save_data() -> Dictionary:
	var result: Dictionary = {}
	for module_name in _save_callbacks.keys():
		var cb: Callable = _save_callbacks[module_name]["get_save"]
		if cb.is_valid():
			result[module_name] = cb.call()
	return result


## 将保存数据分发到各模块。（由 SaveManager 调用）
func distribute_save_data(data: Dictionary) -> void:
	for module_name in _save_callbacks.keys():
		if data.has(module_name):
			var cb: Callable = _save_callbacks[module_name]["load_save"]
			if cb.is_valid():
				cb.call(data[module_name])