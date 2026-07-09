class_name SupplyChainState extends RefCounted
## 物流链路运行时状态数据

enum State {
	ACTIVE,     ## 运行中
	BLOCKED,    ## 被阻断
	DEPLETED,   ## 资源枯竭
	CANCELLED,  ## 已取消
}

var id: String = ""
var origin_region: String = ""
var destination_region: String = ""
var resource_type: String = ""
var quantity: float = 0.0
var frequency: float = 0.0
var carrier_org_id: String = ""
var route: Array[Vector2] = []
var state: State = State.ACTIVE
var efficiency: float = 0.0