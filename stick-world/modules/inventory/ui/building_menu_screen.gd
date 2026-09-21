class_name BuildingMenuScreen
extends StickScreen
## 建筑交互菜单（480×420，UIModalStack.Layer.CONTAINER 同层同类单例）。
##
## 走近建筑按 F 弹出的通用入口（预制框架，docs/设计/系统/背包与装备系统.md
## §2.4）：标题=建筑名，按钮组=建筑声明的 actions（数据驱动 Array[Dictionary]：
## {label, callback, enabled=false 占位}）。SystemSetup 装配在 ModalOverlay；
## 已实装动作：仓库的「拿/放建材」「打开村仓」（村仓=RegionStorage 物品视图）；
## 工坊/商店等后续系统落地时只需注册新 action，框架零改动。

var _action_box: VBoxContainer = null


func setup(_game_root: Node, _service: Node) -> void:
	panel_size = Vector2(480, 420)
	panel_title = "建筑"
	_build_screen()


func _build_content() -> void:
	_body.add_child(StickKit.label(_body, "选择与建筑的交互", StickKit.LabelKind.HINT))
	_action_box = VBoxContainer.new()
	_action_box.add_theme_constant_override("separation", 8)
	_action_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_action_box)


## 打开并绑定动作集（actions: [{label: String, callback: Callable,
## enabled: bool=true}]；disabled 项灰显"未实装"）。同类单例：重复打开替换。
func open_with(building_name: String, actions: Array) -> void:
	panel_title = building_name
	for child in _action_box.get_children():
		_action_box.remove_child(child)
		child.queue_free()
	for a in actions:
		var enabled: bool = bool(a.get("enabled", true))
		var btn := StickKit.sketch_button(_action_box, str(a.get("label", "?")), Callable(),
				StickKit.ButtonKind.NORMAL if enabled else StickKit.ButtonKind.PAPER)
		btn.disabled = not enabled
		if enabled:
			var cb: Callable = a.get("callback", Callable())
			if cb.is_valid():
				btn.pressed.connect(func() -> void:
					close()
					cb.call())
		else:
			StickKit.label(_action_box, "（未实装）", StickKit.LabelKind.TINY)
	var stack := _modal_stack()
	if stack != null:
		stack.push(self, UIModalStack.Layer.CONTAINER)
	else:
		open()


func _modal_stack() -> UIModalStack:
	var root := Engine.get_main_loop() as SceneTree
	if root == null or root.root == null:
		return null
	var ui_root: Node = root.root.find_child("UIRoot", true, false)
	if ui_root != null and ui_root.has_method("get_modal_stack"):
		return ui_root.get_modal_stack()
	return null
