extends Node
## 测试辅助：模式切换 handler
## 配合 InputDispatcher 测试使用。

func _init() -> void:
	set_meta("activated_count", 0)
	set_meta("deactivated_count", 0)


func _on_mode_activated(_mode: int) -> void:
	var c: int = get_meta("activated_count", 0)
	set_meta("activated_count", c + 1)


func _on_mode_deactivated(_mode: int) -> void:
	var c: int = get_meta("deactivated_count", 0)
	set_meta("deactivated_count", c + 1)
