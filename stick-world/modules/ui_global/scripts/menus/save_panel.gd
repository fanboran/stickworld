class_name SavePanel
extends StickScreen
## 存档管理面板 -- 简易多槽位 UI（统一弹窗骨架，Container 布局）。
##
## 详见 modules/README.md §8 存储分层
## 由 SaveHandler 实例化挂到 UIRoot / 主菜单读档用。
## 快捷键：Ctrl+S 打开/关闭面板。
## 模态面板生命周期继承自 StickScreen。

const PANEL_SIZE: Vector2 = Vector2(640, 480)
const SLOT_COUNT := 5

## 面板标题（主菜单读档模式改标题）
var title_text: String = "存档管理"

## 只读模式：隐藏「保存」按钮（主菜单没有游戏世界可存）
var read_only: bool = false

var _slot_container: VBoxContainer = null

## 读档回调（由装配方 SaveHandler 注入，替代 group 反查 game_root）
var _load_callback: Callable = Callable()


## 注入读档回调（SaveHandler.load_game_from_slot 转发）
func setup_load_callback(cb: Callable) -> void:
	_load_callback = cb


func _ready() -> void:
	panel_size = PANEL_SIZE
	panel_title = title_text
	_build_screen()
	_refresh_slots()


## 构建面板内容（统一骨架：_body 槽位列表 + _footer 关闭）
func _build_content() -> void:
	_slot_container = VBoxContainer.new()
	_slot_container.add_theme_constant_override("separation", 8)
	_body.add_child(_slot_container)
	StickKit.auto_button(_footer, "关闭", close)


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
		_slot_container.add_child(_create_slot_row(i, info))


func _create_slot_row(slot: int, info: Dictionary) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.custom_minimum_size = Vector2(0, 40)
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
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(label)
	# 保存按钮（只读模式隐藏）
	if not read_only:
		StickKit.auto_button(hbox, "保存", _on_save.bind(slot), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	# 读取按钮
	var btn_load := StickKit.auto_button(hbox, "读取", _on_load.bind(slot), StickKit.ButtonKind.ACCENT, StickTokens.BTN_H_SM)
	btn_load.disabled = not info.get("exists", false)
	# 删除按钮
	var btn_del := StickKit.auto_button(hbox, "删除", _on_delete.bind(slot), StickKit.ButtonKind.DANGER, StickTokens.BTN_H_SM)
	btn_del.disabled = not info.get("exists", false)
	return hbox


func _on_save(slot: int) -> void:
	if SaveManager and SaveManager.has_method("save_game"):
		SaveManager.save_game(slot)
	_refresh_slots()


func _on_load(slot: int) -> void:
	if _load_callback.is_valid():
		var ok: Variant = _load_callback.call(slot)
		# 拒读（回调返回 false，原因已弹 ui_notification）时保持面板打开，便于换槽重试；
		# 主菜单 _boot_load 回调无返回值（null），照常关闭并走场景切换
		if ok == false:
			return
	close()


func _on_delete(slot: int) -> void:
	if SaveManager and SaveManager.has_method("delete_game"):
		SaveManager.delete_game(slot)
	_refresh_slots()
