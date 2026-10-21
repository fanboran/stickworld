extends Control
## 诊断启动器 —— 寻路避障 9h 复验（无头卡死指标）driver 挂到 SceneTree.root
##（跨场景存活，先例 arena_breach_check）。
## 用法（headless 即可，无需显示）：
##   godot --headless --path stick-world res://tests/dev/nav_stuck_check.tscn
## 产物：stdout 指标（观察场 + 主街两场，逐场卡死窗口统计与永久卡死判定），
## 退出码 0 = 无永久卡死，1 = 有永久卡死/装配失败。

const _DriverScript: GDScript = preload("res://tests/dev/nav_stuck_check_driver.gd")


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "NavStuckCheckDriver"
	get_tree().root.add_child(driver)
	driver.call("run")
