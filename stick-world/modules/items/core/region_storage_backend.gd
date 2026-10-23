class_name RegionStorageBackend
extends RefCounted
## 区域仓储账本端口 —— items 域定义、消费方绑定的抽象经济账本。
##
## RegionStorage 是经济台账的实时视图：存/取/查三操作转发给本端口
## （经济层 float 台账/供需/价格照旧，端口签名与 resources.ResourcesApi
## 的 produce/consume/get_stock 一一对应）。端口的具体绑定由 L2 消费方
## （units 交互层的 ResourcesStorageBackend）提供——items 域因此保持
## 零出向（L1 不引任何模块），依赖方向恒为 高层→低层。
##
## 基类即空账本：produce 无操作、consume 失败、get_stock 恒 0，
## 等价 RegionStorage 未注入账本时的只读空视图。


## 存入 amount 单位资源（region 粒度；source 为入账原因）
func produce(_res_id: String, _amount: float, _region: String, _source: String) -> void:
	pass


## 取出 amount 单位资源；返回 {ok: bool}（库存不足等失败 → ok=false）
func consume(_res_id: String, _amount: float, _region: String, _reason: String) -> Dictionary:
	return {"ok": false}


## 查询当前存量（float 台账）
func get_stock(_res_id: String, _region: String) -> float:
	return 0.0
