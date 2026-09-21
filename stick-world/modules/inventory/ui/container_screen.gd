class_name ContainerScreen
extends StickScreen
## 容器交互窗口（翻包/村仓共用，920×560，UIModalStack.Layer.CONTAINER 同类单例）。
##
## 左=外部容器（尸体遗物「翻检遗物」/ 区域仓储「村口仓库」），右=玩家背包
## （分类列表同背包窗口）。点选/双击经 ItemTransfer 原子转移——目标按单类
## max_stack 截断，余量留源容器（列表制两侧都不出错态）。
## 外部容器是 ItemContainer 实例（尸体遗物=内存容器；村仓=RegionStorage 视图），
## 由 open_with 注入，标题随实例。

## 分类标题（与 InventoryScreen 同源）
const CATEGORY_NAMES: Array[String] = [
	"武器", "盾", "头部护甲", "胸部护甲", "腿部护甲", "消耗品", "材料",
]

var _inv: PlayerInventory = null
var _external: ItemContainer = null
var _external_title: String = "容器"
var _left_box: VBoxContainer = null
var _right_box: VBoxContainer = null


func setup(_game_root: Node, service: Node) -> void:
	_inv = service.inventory
	panel_size = Vector2(920, 560)
	panel_title = "容器"
	_build_screen()


func _build_content() -> void:
	_body.add_child(StickKit.label(_body,
			"左键 = 转移到对面（按堆叠上限截断）· 右键 = 整类转完",
			StickKit.LabelKind.HINT))
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 24)
	_body.add_child(main)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 左：外部容器
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(left_scroll)
	_left_box = VBoxContainer.new()
	_left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_box.add_theme_constant_override("separation", 2)
	left_scroll.add_child(_left_box)
	# 中：转移指示
	StickKit.label(main, "⇄", StickKit.LabelKind.SECTION)
	# 右：玩家背包
	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(right_scroll)
	_right_box = VBoxContainer.new()
	_right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_box.add_theme_constant_override("separation", 2)
	right_scroll.add_child(_right_box)


## 打开并绑定外部容器（同类单例：开新容器替换旧绑定）
func open_with(external: ItemContainer, title: String) -> void:
	_external = external
	_external_title = title
	panel_title = title
	_rebuild_both()
	var stack := _modal_stack()
	if stack != null:
		stack.push(self, UIModalStack.Layer.CONTAINER)
	else:
		open()


func close() -> void:
	_external = null
	super.close()


# ─────────────────────────────── 刷新 ────────────────────────────────

func _rebuild_both() -> void:
	if _inv == null:
		return
	_rebuild_side(_left_box, _external, true)
	_rebuild_side(_right_box, _inv.bag, false)


## 一侧列表重建：条目行（格 + 名称 + 数量），左键转移 1 件/右键整类
func _rebuild_side(box: VBoxContainer, container: ItemContainer, to_player: bool) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	if container == null or container.is_empty():
		box.add_child(StickKit.label(box, "空空如也", StickKit.LabelKind.HINT))
		return
	var last_cat: int = -1
	for e in container.entries():
		var def: ItemDef = e["def"]
		if def.category != last_cat:
			last_cat = def.category
			var cat_name: String = CATEGORY_NAMES[def.category] \
					if def.category < CATEGORY_NAMES.size() else "其他"
			var head := StickKit.label(box, cat_name, StickKit.LabelKind.SECTION)
			head.modulate = Color(StickTokens.ACCENT, 0.9)
		var def_id: StringName = e["def_id"]
		var row := StickKit.row(box)
		row.add_theme_constant_override("separation", 10)
		var cell := ItemSlotWidget.new(ItemSlotWidget.Mode.BACKPACK)
		cell.stack = ItemStack.new(def_id, int(e["count"]))
		cell.slot_left.connect(_on_transfer.bind(def_id, 1, to_player))
		cell.slot_right.connect(_on_transfer.bind(def_id, int(e["count"]), to_player))
		row.add_child(cell)
		StickKit.label(row, def.display_name, StickKit.LabelKind.BODY).custom_minimum_size.x = 110
		StickKit.label(row, "×%d" % int(e["count"]), StickKit.LabelKind.BODY)


# ─────────────────────────────── 转移 ────────────────────────────────

## 转移 count 件（to_player=true：外部→玩家；false：玩家→外部）
func _on_transfer(def_id: StringName, count: int, to_player: bool, _w: ItemSlotWidget = null) -> void:
	if _external == null or _inv == null:
		return
	if to_player:
		ItemTransfer.move(_external, _inv.bag, def_id, count)
	else:
		ItemTransfer.move(_inv.bag, _external, def_id, count)
	_rebuild_both()


# ─────────────────────────────── 内部 ────────────────────────────────

func _modal_stack() -> UIModalStack:
	var root := Engine.get_main_loop() as SceneTree
	if root == null or root.root == null:
		return null
	var ui_root: Node = root.root.find_child("UIRoot", true, false)
	if ui_root != null and ui_root.has_method("get_modal_stack"):
		return ui_root.get_modal_stack()
	return null
