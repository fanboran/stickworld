extends Node
## 验证探针：默认 INHERIT→PAUSABLE 节点（verify_pause_gate 专用，跑完即删）
var ticks: int = 0
func _process(_d: float) -> void:
	ticks += 1
