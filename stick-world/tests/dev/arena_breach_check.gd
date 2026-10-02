extends Control
## 诊断启动器 —— 把遇阻接战无头验收 driver 挂到 SceneTree.root（跨场景存活）后
## 自身退场（先例 diag_arena_metrics_shots）。
## 用法（headless 即可，无需显示）：
##   godot --headless --path stick-world res://tests/dev/arena_breach_check.tscn

const _DriverScript: GDScript = preload("res://tests/dev/arena_breach_check_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "ArenaBreachCheckDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
