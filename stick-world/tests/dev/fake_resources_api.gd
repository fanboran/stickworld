extends Node
## 假资源 API（probe_hud_layout 用）：提供 ResourceBar 需要的 signal + get_stock

@warning_ignore("unused_signal")  # 替身契约：BuildMenu 经 has_signal("resource_changed") 字符串连接
signal resource_changed(resource_id: String, amount: float, delta: float, region_id: String)

func get_stock(_resource_id: String, _region_id: String = "") -> float:
	return 300.0
