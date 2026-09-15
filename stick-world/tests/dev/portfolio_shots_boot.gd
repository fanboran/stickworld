extends Control
## 作品集/README 实机截图启动器 —— 把 Driver 挂到 SceneTree.root（跨场景存活）后自身退场。
##
## 用法（必须带显示，不能 --headless）：
##   godot --path stick-world --resolution 1920x1080 res://tests/dev/portfolio_shots.tscn
## 产物：user://shots/portfolio_*.png

const _DriverScript: GDScript = preload("res://tests/dev/portfolio_shots.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "PortfolioShotsDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
