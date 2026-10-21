extends Control
## 出图启动器 —— 把截图 driver 挂到 SceneTree.root（跨场景存活）后自身退场。
## 用法见 _arena_ext_shots.gd 头注释。

const _DriverScript: GDScript = preload("res://tests/dev/_arena_ext_shots.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "ArenaExtShotsDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
