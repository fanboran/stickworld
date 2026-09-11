extends Node
## 验证探针：ALWAYS 节点（verify_pause_gate 专用，跑完即删；process_mode 由宿主设）
var ticks: int = 0
func _process(_d: float) -> void:
	ticks += 1
