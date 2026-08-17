extends Control
## UI 截图自检启动器 —— 把 Driver 挂到 SceneTree.root（跨场景存活）后自身退场。
##
## 用法（必须带显示，不能 --headless）：
##   godot --path stick-world res://tests/dev/ui_shots.tscn
## 产物：user://shots/*.png（%APPDATA%/Godot/app_userdata/stick_world/shots/）

const _DriverScript: GDScript = preload("res://tests/dev/ui_shots_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "UIShotsDriver"
	get_tree().root.add_child(driver)
	driver.call("run")