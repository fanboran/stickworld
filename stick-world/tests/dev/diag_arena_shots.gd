extends Control
## 诊断启动器 —— 把截图 driver 挂到 SceneTree.root（跨场景存活）后自身退场。
## 用法（必须带显示）：
##   godot --path stick-world res://tests/dev/diag_arena_shots.tscn --resolution 1920x1080
## 产物：user://shots/arena_health_0.png / arena_health_1.png

const _DriverScript: GDScript = preload("res://tests/dev/diag_arena_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "DiagArenaDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
