class_name InventoryScreen
extends StickScreen
## 背包界面（E 键模态）—— 左装备区 + 右背包格网 + 光标堆拖放。
##
## 交互模型（原型阶段，点击制）：
##   左键：拿起整堆 / 放下 / 交换（光标顶图标跟随鼠标）
##   右键：空手点背包格 = 智能装备；点装备槽 = 一键卸回背包
##   数字 1-4 对应的 Hotbar 物品格在网格首行（琥珀高亮 + caption）
## 关闭时光标堆自动塞回背包。挂 UIModalStack.Layer.INVENTORY。

const GRID_COLS: int = 6
## 装备槽展示序（竖排头胸腿，横排主副手）
const EQUIP_ROWS: Array = [
	[PlayerInventory.SlotType.HEAD, "头"],
	[PlayerInventory.SlotType.CHEST, "胸"],
	[PlayerInventory.SlotType.LEGS, "腿"],
]
const HAND_ROW: Array = [
	[PlayerInventory.SlotType.MAIN_HAND, "主手"],
	[PlayerInventory.SlotType.OFF_HAND, "副手"],
]

var _inv: PlayerInventory = null
var _grid: Array[ItemSlotWidget] = []
var _equip_widgets: Dictionary = {}  # SlotType -> ItemSlotWidget
var _cursor_stack: ItemStack = null
var _cursor_layer: Control = null


func setup(_game_root: Node, service: Node) -> void:
	_inv = service.inventory
	panel_size = Vector2(720, 560)
	panel_title = "背包"
	_build_screen()
	_inv.inventory_changed.connect(queue_refresh)
	_inv.equipment_changed.connect(queue_refresh)
	refresh()


func _build_content() -> void:
	StickKit.label(_body, "左键拿起/放下 · 右键穿脱 · 数字 1-4 使用 Hotbar 物品",
			StickKit.LabelKind.HINT)
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 24)
	_body.add_child(main)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 左：装备区
	var equip_box := VBoxContainer.new()
	equip_box.add_theme_constant_override("separation", 8)
	equip_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	main.add_child(equip_box)
	for pair in EQUIP_ROWS:
		equip_box.add_child(_make_equip_widget(pair[0], pair[1]))
	var hand_row := HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 8)
	equip_box.add_child(hand_row)
	for pair in HAND_ROW:
		hand_row.add_child(_make_equip_widget(pair[0], pair[1]))
	# 右：背包格网
	var grid := GridContainer.new()
	grid.columns = GRID_COLS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	main.add_child(grid)
	for i in PlayerInventory.BACKPACK_SIZE:
		var w := ItemSlotWidget.new(ItemSlotWidget.Mode.BACKPACK)
		w.slot_index = i
		if i < PlayerInventory.HOTBAR_SIZE:
			w.caption = str(i + 1)
			w.highlight = true
		w.slot_left.connect(_on_slot_left)
		w.slot_right.connect(_on_slot_right)
		grid.add_child(w)
		_grid.append(w)
	# 光标堆渲染层（最后加，盖在最上）
	_cursor_layer = Control.new()
	_cursor_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_layer.draw.connect(_draw_cursor)
	add_child(_cursor_layer)
	set_process(true)


func _make_equip_widget(slot: int, cap: String) -> ItemSlotWidget:
	var w := ItemSlotWidget.new(ItemSlotWidget.Mode.EQUIP)
	w.slot_index = slot
	w.caption = cap
	w.slot_left.connect(_on_slot_left)
	w.slot_right.connect(_on_slot_right)
	_equip_widgets[slot] = w
	return w


func _process(_delta: float) -> void:
	# 光标层铺满自身并跟随重画（图标画在鼠标处）
	if _cursor_layer == null:
		return
	if _cursor_layer.size != size:
		_cursor_layer.size = size
	if _cursor_stack != null:
		_cursor_layer.queue_redraw()


# ─────────────────────────────── 交互 ────────────────────────────────

func _on_slot_left(w: ItemSlotWidget) -> void:
	match w.mode:
		ItemSlotWidget.Mode.BACKPACK:
			if _cursor_stack == null:
				_cursor_stack = _inv.take_all(w.slot_index)
			else:
				_cursor_stack = _inv.place(w.slot_index, _cursor_stack)
		ItemSlotWidget.Mode.EQUIP:
			if _cursor_stack == null:
				_cursor_stack = _inv.unequip_to_cursor(w.slot_index)
			else:
				_cursor_stack = _inv.equip_stack(_cursor_stack, w.slot_index)
	refresh()


func _on_slot_right(w: ItemSlotWidget) -> void:
	match w.mode:
		ItemSlotWidget.Mode.BACKPACK:
			# 智能装备（不合法/放不下时提示）
			if not _inv.can_equip(w.slot_index):
				_notify_blocked(w)
				return
			_inv.equip_from_backpack(w.slot_index)
		ItemSlotWidget.Mode.EQUIP:
			if not _inv.unequip(w.slot_index):
				_notify_pack_full()
	refresh()


func _notify_blocked(w: ItemSlotWidget) -> void:
	var s: ItemStack = _inv.get_slot(w.slot_index)
	if s == null or s.is_empty():
		return
	var def: ItemDef = s.def()
	var reason := "无法装备"
	if def != null and def.category == ItemDef.Category.SHIELD and _inv.is_offhand_locked():
		reason = "双手武器占用副手"
	StickKit.toast(get_parent(), "%s：%s" % [reason, def.display_name if def != null else ""])
	refresh()


func _notify_pack_full() -> void:
	StickKit.toast(get_parent(), "背包已满，无法卸下")


# ─────────────────────────────── 刷新 ────────────────────────────────

var _refresh_queued: bool = false


func queue_refresh() -> void:
	# 信号洪峰（_undo/批量操作）合并到帧末一刷
	if _refresh_queued:
		return
	_refresh_queued = true
	refresh.call_deferred()


func refresh() -> void:
	_refresh_queued = false
	for w in _grid:
		w.stack = _inv.get_slot(w.slot_index)
	for slot_key in _equip_widgets:
		var w2: ItemSlotWidget = _equip_widgets[slot_key]
		w2.stack = _inv.get_equipped(slot_key)
		w2.locked = (slot_key == PlayerInventory.SlotType.OFF_HAND
				and _inv.is_offhand_locked())
	if _cursor_layer != null:
		_cursor_layer.queue_redraw()


func _draw_cursor() -> void:
	if _cursor_stack == null or _cursor_stack.is_empty():
		return
	var def: ItemDef = _cursor_stack.def()
	if def == null:
		return
	var pos := get_global_mouse_position() - get_global_rect().position - Vector2(20, 20)
	if def.icon != null:
		var tex_size: Vector2 = def.icon.get_size()
		var scale: float = minf(40.0 / tex_size.x, 40.0 / tex_size.y)
		draw_texture_rect(def.icon, Rect2(pos, tex_size * scale), false)
	else:
		# 无贴图类：医疗十字示意（消耗品为主）
		var ink := Color(0.85, 0.82, 0.75, 0.9)
		draw_rect(Rect2(pos + Vector2(17, 5), Vector2(6, 22)), ink)
		draw_rect(Rect2(pos + Vector2(9, 13), Vector2(22, 6)), ink)


# ─────────────────────────────── 开关 ────────────────────────────────

func open() -> void:
	super.open()
	refresh()


func close() -> void:
	# 光标堆塞回背包（MC 同款语义；极端满仓放不下则丢弃并告警）
	if _cursor_stack != null and not _cursor_stack.is_empty():
		var rest: int = _inv.add_item(_cursor_stack.def_id, _cursor_stack.count)
		if rest > 0:
			push_warning("[Inventory] 关闭背包时 %s ×%d 无处安放，已丢弃"
					% [_cursor_stack.def_id, rest])
		_cursor_stack = null
	super.close()
