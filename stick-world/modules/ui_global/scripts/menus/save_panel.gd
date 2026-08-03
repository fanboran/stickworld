class_name SavePanel
extends BaseScreen
## 存档管理面板 -- 简易多槽位 UI。
##
## 详见 docs/技术/架构/SQLite存档迁移方案.md §7
## 由 GameRoot._setup_save_system() 实例化，挂到 UIRoot。
## 快捷键：Ctrl+S 打开/关闭面板。
## 模态面板生命周期（遮罩/居中/open/close/toggle）继承自 BaseScreen。

const SLOT_COUNT := 5

const PANEL_SIZE: Vector2 = Vector2(640, 480)

var _slot_container: VBoxContainer = null


func _ready() -> void:
	panel_size = PANEL_SIZE
	_build_screen()
	_refresh_slots()


## 构建面板内容（遮罩/居中面板由 BaseScreen 提供）
func _build_content() -> void:
	# 标题
	var title := Label.new()
	title.text = "存档管理"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UITheme.FONT_TITLE)
	title.position = Vector2(0, 10)
	title.size = Vector2(640, 40)
	_panel.add_child(title)
	# 槽位容器
	_slot_container = VBoxContainer.new()
	_slot_container.position = Vector2(20, 60)
	_slot_container.custom_minimum_size = Vector2(600, 340)
	_slot_container.add_theme_constant_override("separation", 8)
	_panel.add_child(_slot_container)
	# 关闭按钮
	var btn_close := Button.new()
	btn_close.text = "关闭"
	btn_close.position = Vector2(280, 420)
	btn_close.custom_minimum_size = Vector2(80, 36)
	btn_close.pressed.connect(_on_close_pressed)
	_panel.add_child(btn_close)


func _refresh_slots() -> void:
	if _slot_container == null:
		return
	for child in _slot_container.get_children():
		child.queue_free()
	var slots: Array = []
	if SaveManager and SaveManager.has_method("list_slots"):
		slots = SaveManager.list_slots()
	for i in range(SLOT_COUNT):
		var info: Dictionary = slots[i] if i < slots.size() else {}
		var row := _create_slot_row(i, info)
		_slot_container.add_child(row)


func _create_slot_row(slot: int, info: Dictionary) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.custom_minimum_size = Vector2(560, 36)
	# 槽位标签
	var label := Label.new()
	if info.get("exists", false):
		var dt: String = str(info.get("datetime", ""))
		var pt: float = float(info.get("playtime_seconds", 0))
		var ver: int = int(info.get("version", 0))
		var ver_str := "SQLite" if ver >= 2 else "JSON"
		label.text = "槽位%d  %s  游玩%.1fh  [%s]" % [slot, dt, pt / 3600.0, ver_str]
	else:
		label.text = "槽位%d  [空]" % slot
	label.custom_minimum_size = Vector2(380, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(label)
	# 保存按钮
	var btn_save := Button.new()
	btn_save.text = "保存"
	btn_save.custom_minimum_size = Vector2(60, 32)
	btn_save.pressed.connect(_on_save.bind(slot))
	hbox.add_child(btn_save)
	# 读取按钮
	var btn_load := Button.new()
	btn_load.text = "读取"
	btn_load.custom_minimum_size = Vector2(60, 32)
	btn_load.disabled = not info.get("exists", false)
	btn_load.pressed.connect(_on_load.bind(slot))
	hbox.add_child(btn_load)
	# 删除按钮
	var btn_del := Button.new()
	btn_del.text = "删除"
	btn_del.custom_minimum_size = Vector2(60, 32)
	btn_del.disabled = not info.get("exists", false)
	btn_del.pressed.connect(_on_delete.bind(slot))
	hbox.add_child(btn_del)
	return hbox


func _on_save(slot: int) -> void:
	if SaveManager and SaveManager.has_method("save_game"):
		SaveManager.save_game(slot)
	_refresh_slots()


func _on_load(slot: int) -> void:
	var game_root := get_tree().get_first_node_in_group("game_root")
	if game_root != null and game_root.has_method("load_game_from_slot"):
		game_root.load_game_from_slot(slot)
	close()


func _on_delete(slot: int) -> void:
	if SaveManager and SaveManager.has_method("delete_game"):
		SaveManager.delete_game(slot)
	_refresh_slots()


func _on_close_pressed() -> void:
	close()
