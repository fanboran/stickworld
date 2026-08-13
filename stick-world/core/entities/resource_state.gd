class_name ResourceState extends RefCounted

## ⚠️ 预留状态类（2026-08 审计）：本类暂未被生产模块接入
## （world_state.gd 提供 register_* 容器接口，模块数据流落地时按需启用；technology 阶段 1 重建时用）。

## 资源运行时状态数据

enum Category {
	BASIC,      ## 基础资源
	PROCESSED,  ## 加工品
	STRATEGIC,  ## 战略资源
	LUXURY,     ## 奢侈品
}

var id: String = ""
var name: String = ""
var category: Category = Category.BASIC
var initial_price: float = 0.0
var weight_per_unit: float = 0.0
var perishable: bool = false
var current_stock: float = 0.0
var production_rate: float = 0.0
var consumption_rate: float = 0.0