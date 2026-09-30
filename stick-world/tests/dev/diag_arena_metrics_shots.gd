extends Control
## 诊断启动器 —— 把无头指标采集 driver 挂到 SceneTree.root（跨场景存活）后自身退场。
## 用法（headless 即可，无需显示）：
##   godot --headless --path stick-world res://tests/dev/diag_arena_metrics_shots.tscn
## 产物：stdout 摘要 + user://shots/arena_ai_metrics.csv

const _DriverScript: GDScript = preload("res://tests/dev/diag_arena_metrics_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "DiagArenaMetricsDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
