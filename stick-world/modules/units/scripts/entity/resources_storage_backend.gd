class_name ResourcesStorageBackend
extends RegionStorageBackend
## RegionStorageBackend 账本端口的 resources 适配器 —— 村仓物品视图 ↔ 经济台账。
##
## items 域零出向：账本端口定义在 items，具体的 resources 绑定由本侧
## （L2 消费方）提供——produce/consume/get_stock 直转 ResourcesApi 既有链路
## （经济 float/供需/价格照旧）。api 为注入的 ResourcesApi（GameRoot →
## entity → 交互层注入链），缺省时空账本行为（视图只读、存量恒 0）。

var _api: Node = null  # ResourcesApi（弱类型注入，与 units 侧既有注入风格一致）


func _init(p_api: Node = null) -> void:
	_api = p_api


func produce(res_id: String, amount: float, region: String, source: String) -> void:
	if _api != null:
		_api.produce(res_id, amount, region, source)


func consume(res_id: String, amount: float, region: String, reason: String) -> Dictionary:
	if _api == null:
		return {"ok": false}
	return _api.consume(res_id, amount, region, reason)


func get_stock(res_id: String, region: String) -> float:
	if _api == null:
		return 0.0
	return _api.get_stock(res_id, region)
