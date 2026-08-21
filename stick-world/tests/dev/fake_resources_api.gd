extends Node
## 假资源 API（probe_hud_layout 用）：提供 ResourceBar 需要的 signal + get_stock

signal resource_changed(resource_id: String, amount: float, delta: float, region_id: String)

func get_stock(_resource_id: String, _region_id: String = "") -> float:
	return 300.0
