extends Node
## UI 重叠测试 Driver —— 挂 SceneTree.root 跨场景存活，boot 世界后跑断言。
##
## 运行（带显示）：godot --path stick-world res://tests/integration/test_ui_overlap.tscn --resolution 1920x1080
## 退出码：0 全过，1 有重叠。不进 run_all 清单（世界 boot ~20s，仅 UI 变更时手动跑）。

## 参与两两断言的部件节点名（system_setup/UIKit.widget 命名 + tscn 节点名）
const TARGET_NAMES := [
	"QuestPanel", "Minimap", "ZoomBar", "ResourceBarHost", "ClockWidget",
	"TimeLabel", "ModePanel", "NotificationFeed", "WeaponPanel", "BuildMenu",
	"DebugInfoPanel",
]

var _fails: PackedStringArray = []


func run() -> void:
	if SaveManager:
		SaveManager.boot_load_slot = 0
	get_tree().change_scene_to_file("res://modules/ui_global/scenes/menus/loading_screen.tscn")
	if not await _wait_world():
		print("[UIOverlap] FAIL: 世界加载超时")
		get_tree().quit(1)
		return
	await _frames(30)  # 等面板装配稳定
	_run()
	for f in _fails:
		print("[UIOverlap] FAIL: ", f)
	if _fails.is_empty():
		print("[UIOverlap] ALL PASS")
	get_tree().quit(1 if not _fails.is_empty() else 0)


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
	# 全屏布局根（BuildMenu/DebugInfoPanel 等铺满视口的容器）不算可视部件：
	# 它们与一切的"重叠"只是容器包含，真实按钮/内容自有局部定位
	var vp := node.get_viewport_rect().size if node is Control else Vector2(1920, 1080)
	if r.size.x * r.size.y > vp.x * vp.y * 0.5:
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
