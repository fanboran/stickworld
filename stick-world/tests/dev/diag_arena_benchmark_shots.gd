extends Control
## 诊断启动器 —— 把自对弈 Benchmark driver 挂到 SceneTree.root（跨场景存活）后自身退场。
## 用法（headless 即可）：
##   godot --headless --path stick-world res://tests/dev/diag_arena_benchmark_shots.tscn
## 挑战者/卫冕者与场数在 diag_arena_benchmark_driver.gd 顶部常量里改。

const _DriverScript: GDScript = preload("res://tests/dev/diag_arena_benchmark_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "DiagArenaBenchmarkDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
