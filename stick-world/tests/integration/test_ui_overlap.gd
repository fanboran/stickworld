extends Control
## 孤立测试：HUD 部件两两不重叠（UI 元素变更时手动跑，不进 run_all 清单）。
## 结构学 ui_shots：本节点是启动器，把 Driver 挂 SceneTree.root 跨场景存活后自退场
## （change_scene 会释放当前场景，测试逻辑不能住在被释放的节点里）。
##
## 动机：观察场战况板曾与 debug 图例左上重叠、材料条曾压顶栏按钮——这类
## "静默互盖"无报错，只有像素级重叠可查。本测试 boot 真实世界后收集全部
## 常驻 HUD 部件的 global_rect，两两相交即失败（白名单豁免嵌套容器）。
##
## 运行（带显示，需真实布局）：
##   godot --path stick-world res://tests/integration/test_ui_overlap.tscn --resolution 1920x1080
## 退出码：0 全过，1 有重叠。全量测试矩阵不含本套件（世界 boot ~20s 太重）。

## 参与两两断言的部件节点名（system_setup/UIKit.widget 命名 + tscn 节点名）
const TARGET_NAMES := [
	"QuestPanel", "Minimap", "ZoomBar", "ResourceBarHost", "ClockWidget",
	"TimeLabel", "ModePanel", "NotificationFeed", "Hotbar", "BuildMenu",
	"DebugInfoPanel", "DebugLegend",
]

const _DriverScript: GDScript = preload("res://tests/integration/test_ui_overlap_driver.gd")

var _fails: PackedStringArray = []


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	var driver := Node.new()
	driver.set_script(_DriverScript)
	driver.name = "UIOverlapDriver"
	get_tree().root.add_child(driver)
	driver.call("run")


func _run() -> void:
	var rects: Array = []
	# 顶栏整体（HBox 按钮行）作为一个部件
	_append(rects, "顶栏按钮行", _find_first("MarginContainer/HBoxContainer"))
	for name in TARGET_NAMES:
		_append(rects, name, _find_first(name))
	_append(rects, "FpsCounter", _find_first("FpsCounter"))
	if rects.size() < 4:
		_fails.append("部件收集不足（%d）——装配异常或命名变更" % rects.size())
	_report(rects)
	for f in _fails:
		print("[UIOverlap] FAIL: ", f)
	if _fails.is_empty():
		print("[UIOverlap] ALL PASS (%d 部件两两无重叠)" % rects.size())


func _append(rects: Array, label: String, node: CanvasItem) -> void:
	if node == null or not is_instance_valid(node):
		return
	var r: Rect2 = node.get_global_rect() if node is Control else Rect2()
	if node is Node2D:
		return  # 世界空间指示器不参与屏幕矩形断言
	if r.size.length() < 4.0:
		return
	rects.append([label, r])


func _report(rects: Array) -> void:
	var tol := 1.0  # 1px 容差（抗锯齿边）
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			var a: Rect2 = rects[i][1].grow(-tol)
			var b: Rect2 = rects[j][1].grow(-tol)
			if a.intersects(b):
				_fails.append("%s %s 与 %s %s 重叠" % [rects[i][0], _fmt(a), rects[j][0], _fmt(b)])


func _fmt(r: Rect2) -> String:
	return "(%.0f,%.0f %.0fx%.0f)" % [r.position.x, r.position.y, r.size.x, r.size.y]


func _find_first(node_name: String) -> Node:
	return get_tree().root.find_child(node_name, true, false)


func _wait_world() -> bool:
	var t := 0.0
	while t < 30.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var gr := get_tree().current_scene
		if gr != null and gr.has_method("get_current_map") and gr.has_method("get_player_entity"):
			if gr.get_current_map() != null and gr.get_player_entity() != null:
				return true
	return false


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
