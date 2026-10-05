extends Control
## NN 实机演示启动器 —— 把演示 driver 挂到 SceneTree.root（跨场景存活）后自身退场。
## 用法（必须带显示）：
##   godot --path stick-world res://tests/dev/nn_live_demo.tscn -- --preset=2 --side=1
## 产物：无（肉眼观察；横幅由 driver 常驻）

const _DriverScript: GDScript = preload("res://tests/dev/nn_live_demo_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "NNLiveDemoDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
