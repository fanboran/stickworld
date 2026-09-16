extends Control
## 诊断启动器 —— 把相机探针 driver 挂到 SceneTree.root 后自身退场。
## 用法：godot --path stick-world res://tests/dev/probe_arena_cam.tscn --resolution 1920x1080


const _DriverScript: GDScript = preload("res://tests/dev/probe_arena_cam_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "ProbeArenaCamDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
