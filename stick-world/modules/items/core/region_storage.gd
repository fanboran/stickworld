class_name RegionStorage
extends ItemContainer
## 区域仓储的物品容器视图 —— items 域 ↔ resources 经济层的桥。
##
## 村仓 ContainerScreen 的数据源：把某区域的资源库存（resources float 台账）
## 呈现为 ItemContainer 语义（资源品 def 经 ItemsAPI.RESOURCE_BY_ITEM 映射），
## 存取经 ResourcesApi.produce/consume 既有链路——**经济层 float/供需/价格
## 照旧**，本类只做物品语义的读写视图（件数取整）。
##
## 注意：非资源品（武器/护甲/消耗品）不进区域仓储（个人口袋语义，
## 设计文档 10 §3.3 边界）——add/remove 对非映射物返回余量/失败。

const REGION_STACK_CAP: int = 999999  # 区域大宗仓储不设实质上限

var region_id: String = ""
var _api: Node = null  # ResourcesApi（弱类型注入；缺省时只读空视图）


func _init(p_region_id: String = "", p_api: Node = null) -> void:
	region_id = p_region_id
	_api = p_api


# ─────────────────────────────── ItemContainer 协议（ContainerScreen 消费）────

## 存入（玩家往村仓放资源品）：非资源品全量退回
func add(def_id: StringName, count: int) -> int:
	var res_id: StringName = ItemsAPI.resource_id_for(def_id)
	if res_id == &"" or count <= 0 or _api == null:
		return count
	_api.produce(String(res_id), float(count), region_id, "player_deposit")
	return 0


## 取出（玩家从村仓取资源品）：库存不足整体失败
func remove(def_id: StringName, count: int) -> bool:
	var res_id: StringName = ItemsAPI.resource_id_for(def_id)
	if res_id == &"" or count <= 0 or _api == null:
		return false
	if count_of(def_id) < count:
		return false
	var r: Dictionary = _api.consume(String(res_id), float(count), region_id, "player_withdraw")
	return bool(r.get("ok", false))


## 当前存量（float 台账取整；非资源品 0）
func count_of(def_id: StringName) -> int:
	var res_id: StringName = ItemsAPI.resource_id_for(def_id)
	if res_id == &"" or _api == null:
		return 0
	return int(_api.get_stock(String(res_id), region_id))


## 区域仓储不设实质上限（大宗语义）
func room_for(_def_id: StringName) -> int:
	return REGION_STACK_CAP


func stack_cap(def_id: StringName) -> int:
	return REGION_STACK_CAP if ItemsAPI.resource_id_for(def_id) != &"" else 0


## 条目快照（ContainerScreen 左栏）：只列**有库存的资源品**
func entries() -> Array:
	var out: Array = []
	if _api == null:
		return out
	for def_id in ItemsAPI.RESOURCE_BY_ITEM:
		var n: int = count_of(def_id)
		if n <= 0:
			continue
		var def: ItemDef = ItemDB.get_def(def_id)
		if def != null:
			out.append({"def_id": def_id, "count": n, "def": def})
	return out


func is_empty() -> bool:
	return entries().is_empty()
