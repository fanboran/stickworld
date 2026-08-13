class_name SupplyChainState extends RefCounted

## ⚠️ 预留状态类（2026-08 审计）：本类暂未被生产模块接入
## （world_state.gd 提供 register_* 容器接口，模块数据流落地时按需启用；technology 阶段 1 重建时用）。

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