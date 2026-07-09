class_name ResourceState extends RefCounted
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
var base_price: float = 0.0
var weight_per_unit: float = 0.0
var perishable: bool = false
var current_stock: float = 0.0
var production_rate: float = 0.0
var consumption_rate: float = 0.0