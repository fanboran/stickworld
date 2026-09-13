extends Node
## 主菜单「制作人员」页验收：
##   1. 菜单里存在「制作人员」入口（CC-BY 署名的合规出口，缺它=发布义务没兑现）
##   2. 点击后弹出面板，且署名文本包含必须履行的 CC-BY 条目（钢琴采样 / 两条环境音素材）
##   3. 关闭后面板被清理
## 另留菜单页与面板打开两张截图（res://../temp/shots_credits/，gitignored）。
##
## 运行（不要 --headless：要真实渲染截图）：
##   godot --path stick-world res://tests/dev/verify_credits_menu.tscn
## 退出码：0 全部通过 / 1 有失败。

const MainMenuScene := preload("res://modules/ui_global/scenes/menus/main_menu.tscn")
const OUT_DIR := "res://../temp/shots_credits"

var _fails: Array[String] = []
var _pass_count: int = 0
var _menu: Control = null


func _ready() -> void:
	# 看门狗：任何脚本错误中断协程时也能退出（不留挂死进程拖垮 CI）
	get_tree().create_timer(120.0, true, false, true).timeout.connect(
		func() -> void:
			print("=== 制作人员页验收：看门狗超时 ===")
			get_tree().quit(1))
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame

	_menu = MainMenuScene.instantiate()
	add_child(_menu)
	for i in 60:
		await get_tree().process_frame
		if _menu.get_node_or_null("MenuColumn") != null \
				and _menu.get_node("MenuColumn").get_child_count() > 0:
			break
	await get_tree().process_frame

	var btn := _find_credits_button()
	_check(btn != null, "菜单存在「制作人员」入口")
	if btn == null:
		return _finish()
	_check(not btn.disabled, "入口可用（未禁用）")
	await _shot("credits_menu.png")

	# 触发入口（等价于点击；直接走按钮信号，避开窗口缩放下的坐标换算）
	var panel_before: Control = _menu.get("_credits_panel")
	btn.pressed.emit()
	for i in 5:
		await get_tree().process_frame
	var panel: Control = _menu.get("_credits_panel")
	_check(panel != null and is_instance_valid(panel), "点击后弹出面板")
	_check(panel != panel_before, "面板是新开的（不是残留的旧面板）")
	var body := _find_label_with(panel, "Salamander")
	_check(body != null, "面板含署名正文")
	if body != null:
		var text := (body as Label).text
		for must in ["Salamander Grand Piano V3", "Alexander Holm", "CC BY 3.0",
				"MuseScore General", "Florida Cicada Song", "Chicken Sound Effect",
				"Godot Engine"]:
			_check(text.contains(must), "署名含必须条目：%s" % must)
	await _shot("credits_open.png")

	_menu._close_credits_panel()
	for i in 3:
		await get_tree().process_frame
	# ⚠ 不能声明成 Control：queue_free 后属性里是"已释放实例"，
	# 赋给类型化变量会报错中断协程（探针曾因此挂死到超时）
	var after = _menu.get("_credits_panel")
	_check(after == null or not is_instance_valid(after), "关闭后面板被清理")

	_finish()


## 在 MenuColumn 里找「制作人员」按钮
func _find_credits_button() -> Button:
	var column: VBoxContainer = _menu.get_node_or_null("MenuColumn")
	if column == null:
		return null
	for child in column.get_children():
		if child is Button and (child as Button).text == "制作人员":
			return child
	return null


## 在面板子树里找文本包含 key 的 Label
func _find_label_with(root: Node, key: String) -> Label:
	if root is Label and (root as Label).text.contains(key):
		return root
	for child in root.get_children():
		var hit := _find_label_with(child, key)
		if hit != null:
			return hit
	return null


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + file_name
	var err := img.save_png(path)
	if err != OK:
		_fail("截图保存失败 %s（err=%d）" % [path, err])
	else:
		print("[SHOT] ", path, " ", img.get_size())


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass_count += 1
		print("[OK] ", label)
	else:
		_fails.append(label)
		print("[FAIL] ", label)


func _fail(label: String) -> void:
	_fails.append(label)
	print("[FAIL] ", label)


func _finish() -> void:
	print("=== 制作人员页验收：%d 项断言，%d 失败 ===" % [_pass_count + _fails.size(), _fails.size()])
	if _fails.is_empty():
		print("=== 制作人员页验收：全部通过 ===")
		get_tree().quit(0)
	else:
		for f in _fails:
			print("[FAIL] ", f)
		get_tree().quit(1)
