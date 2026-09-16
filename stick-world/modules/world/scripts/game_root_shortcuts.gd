extends RefCounted
## GameRoot 快捷键/模态助手 —— 无 class_name（经 game_root.gd const preload 引用）。
##
## 职责域：
##   快捷键全分派（F5/F9/Ctrl+S/K/O/J/L/E/C/数字 1-4/空格/ESC）→ handle_shortcuts
##   ESC 统一模态栈逐层退栈（附身让位/战略图优先/暂停菜单兜底）→ _handle_escape
##   模态面板开关公共路径（背包/属性/设置菜单）→ toggle_inventory / toggle_stats_panel /
##   toggle_settings_menu / _toggle_modal_panel
##   Hotbar 物品格转发与占位面板 → _use_hotbar_slot / _open_placeholder_panel
##
## 设计：面板/服务引用（_inventory_screen / _stats_panel / _settings_menu_panel /
## _pause_menu_panel / inventory_service 等）全部留在宿主 GameRoot，本助手只承载
## 逻辑，经 _host 回引读写；宿主保留同名薄壳转发（ShortcutGate 转发与测试直调
## 的签名不变）。

var _host: GameRoot


func _init(host: GameRoot) -> void:
	_host = host


## 快捷键总入口（由子节点 ShortcutGate 转发，暂停期照常触发；宿主节点自身
## PAUSABLE，引擎暂停期 _unhandled_input 不再触发，故不经标准回调接入口）。
func handle_shortcuts(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var ek: InputEventKey = event as InputEventKey
	# F5 快速保存到槽位 0
	if ek.keycode == KEY_F5:
		_host.quick_save()
		_host.get_viewport().set_input_as_handled()
	# F9 快速读取槽位 0
	elif ek.keycode == KEY_F9:
		_host.quick_load()
		_host.get_viewport().set_input_as_handled()
	# Ctrl+S 打开/关闭存档面板
	elif ek.keycode == KEY_S and (ek.ctrl_pressed or ek.meta_pressed):
		_host.toggle_save_panel()
		_host.get_viewport().set_input_as_handled()
	# 功能面板快捷键（K/O/J/L → 空面板占位；系统落地后替换真实面板）
	elif ek.keycode == KEY_K:
		_open_placeholder_panel("tech_tree")
		_host.get_viewport().set_input_as_handled()
	elif ek.keycode == KEY_O:
		_open_placeholder_panel("empire_overview")
		_host.get_viewport().set_input_as_handled()
	elif ek.keycode == KEY_J:
		_open_placeholder_panel("collection")
		_host.get_viewport().set_input_as_handled()
	elif ek.keycode == KEY_L:
		_open_placeholder_panel("logistics")
		_host.get_viewport().set_input_as_handled()
	# E 开关背包（背包装备系统；其他模态打开时让位给 ESC 栈）
	elif ek.keycode == KEY_E:
		toggle_inventory()
		_host.get_viewport().set_input_as_handled()
	# C 开关角色属性面板（属性/伤痕状态/装备概览）
	elif ek.keycode == KEY_C:
		toggle_stats_panel()
		_host.get_viewport().set_input_as_handled()
	# 数字 1-4：使用 Hotbar 物品格（消耗品；同 Hotbar 点击）
	elif ek.keycode >= KEY_1 and ek.keycode <= KEY_4:
		_use_hotbar_slot(ek.keycode - KEY_1)
		_host.get_viewport().set_input_as_handled()
	# 空格切换暂停（Demo：战斗自动暂停后的直觉恢复键；模态打开时 ESC 栈优先，
	# 空格仅在世界层生效）
	elif ek.keycode == KEY_SPACE:
		if TimeManager != null:
			TimeManager.toggle_pause()
		_host.get_viewport().set_input_as_handled()
	# ESC：统一模态/暂停菜单栈控制（见 _handle_escape）
	elif ek.keycode == KEY_ESCAPE:
		if _handle_escape():
			_host.get_viewport().set_input_as_handled()


## 打开/关闭设置菜单（左上角齿轮按钮 / 暂停菜单「设置」调用）。
## 经模态栈开合（层键 SETTINGS）；无栈环境回退面板自身 toggle。
func toggle_settings_menu() -> void:
	if _host._settings_menu_panel == null:
		return
	var stack := _get_modal_stack()
	if stack != null:
		if stack.is_open(UIModalStack.Layer.SETTINGS):
			stack.pop(UIModalStack.Layer.SETTINGS)
		else:
			stack.push(_host._settings_menu_panel, UIModalStack.Layer.SETTINGS)
	elif _host._settings_menu_panel.has_method("toggle"):
		_host._settings_menu_panel.toggle()


## 开关背包界面（E 键）：开着则关；其他模态开着则让位（ESC 先退栈）；
## 无模态则压栈打开（自动暂停 + 遮罩）。Hotbar 的 E 动作格同路。
func toggle_inventory() -> void:
	_toggle_modal_panel(_host._inventory_screen, UIModalStack.Layer.INVENTORY)


## 开关角色属性面板（C 键）：与背包同款模态规则。Hotbar 的 C 动作格同路。
func toggle_stats_panel() -> void:
	_toggle_modal_panel(_host._stats_panel, UIModalStack.Layer.STATS)


## 模态面板开关公共路径：开着关 / 其他模态开着让位 / 压栈打开
func _toggle_modal_panel(panel: Control, layer: int) -> void:
	if panel == null:
		return
	var stack := _get_modal_stack()
	if panel.is_open():
		if stack != null:
			stack.pop(layer)
		else:
			panel.close()
		return
	if stack != null:
		if stack.is_any_open():
			return
		stack.push(panel, layer)
	else:
		panel.open()


## 使用 Hotbar 物品格（数字键 1-4；转发背包服务，需附身实体承接效果）
func _use_hotbar_slot(index: int) -> void:
	if _host.inventory_service != null and _host.inventory_service.has_method("use_hotbar_item"):
		_host.inventory_service.use_hotbar_item(index)


## 打开功能空面板（经 ui_global/placeholders，系统落地后替换真实面板）。
## 快捷键（K/O/J/L）与暂停菜单「功能」分区共用此入口。
func _open_placeholder_panel(preset_id: String) -> void:
	if _host.ui_root == null:
		return
	var overlay: Control = _host.ui_root.get_slot("ModalOverlay")
	if overlay == null:
		return
	UIPlaceholderPanel.open_panel(overlay, preset_id)


## ESC 语义（统一模态栈逐层退栈）：有模态 → 退栈顶（设置→关设置、确认框→取消、
## 占位面板→关面板，逐层返回）；无模态 → 开暂停菜单。附身模式返回 false
## （ESC 留给退出附身，不消费）。返回是否已消费事件。
func _handle_escape() -> bool:
	if _host.input_dispatcher != null and _host.input_dispatcher.get_mode() == PlayerControlAPI.Mode.POSSESS:
		return false
	# 战略图（Tab）打开时 ESC 先交给它：下钻返回 L2 / 关闭地图，不弹暂停菜单
	if _host._strategic_map != null:
		var sc: Node = _host._strategic_map.get_node_or_null("Content")
		if sc != null and sc.visible and sc.has_method("handle_escape"):
			sc.handle_escape()
			return true
	var stack := _get_modal_stack()
	if stack != null and stack.handle_escape():
		return true
	# 无模态 → 开暂停菜单
	if _host._pause_menu_panel != null:
		if stack != null:
			stack.push(_host._pause_menu_panel, UIModalStack.Layer.PAUSE_MENU)
		else:
			_host._pause_menu_panel.open()
	return true


## 取 UIRoot 统一模态栈（无则 null）
func _get_modal_stack() -> UIModalStack:
	if _host.ui_root == null:
		return null
	return _host.ui_root.get_modal_stack()
