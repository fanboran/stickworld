class_name Hotbar
extends Control
## 底部常驻物品栏（HudOverlay 槽，ModePanel 上方居中）。
##
## 三段式（docs/设计/系统/背包与装备系统.md §2.4，数字键/滚轮语义见 09 文档 §二）：
##   [主手|左键] [副手|右键] │ [1][2][3][4][5][6][7][8]→ │ [F 交互] [E 背包]
##   └── 战斗组(装备镜像) ──┘  └─ 指派格(滑动窗口) ─┘    └─ 固定动作组 ─┘
## 指派格 ×10（数字键 1-9/0；滚轮=循环切武器），**可视窗口 8 格**——溢出两侧
## 渐隐三角指示，选中格自动滚入视野；格内容 = Hotbar 指派（武器=换装、消耗品=
## 使用）。战斗组点击 = 打开背包。动作组 = 固定快捷键指示格。
## 数据驱动：订阅 PlayerInventory 信号刷新，不轮询。

const GROUP_GAP: float = 26.0
const OFFSET_ABOVE_MODE_PANEL: float = 88.0
## 指派格可视窗口宽度（格数；超出滚动）
const VISIBLE_SLOTS: int = 8

var _service: InventoryService = null
var _game_root: Node = null
var _main_hand: ItemSlotWidget = null
var _off_hand: ItemSlotWidget = null
var _item_slots: Array[ItemSlotWidget] = []
# 滑动窗口
var _slot_clip: Control = null
var _slot_row: HBoxContainer = null
var _scroll_offset: int = 0   # 窗口首格下标
var _hint_left: Label = null
var _hint_right: Label = null


func setup(game_root: Node, service: InventoryService) -> void:
	_game_root = game_root
	_service = service
	# 底部通栏（内容水平居中；ModePanel 80px 上方留 8px 间隙）
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_top = -(OFFSET_ABOVE_MODE_PANEL + ItemSlotWidget.CELL + ItemSlotWidget.CAPTION_H)
	offset_bottom = -OFFSET_ABOVE_MODE_PANEL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	var inv: PlayerInventory = service.inventory
	inv.inventory_changed.connect(refresh)
	inv.equipment_changed.connect(refresh)
	refresh()


func _build() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(row)
	# ── 战斗组（装备镜像）──
	_main_hand = _make_cell("左键")
	_main_hand.slot_left.connect(_on_open_inventory)
	row.add_child(_main_hand)
	_off_hand = _make_cell("右键")
	_off_hand.slot_left.connect(_on_open_inventory)
	row.add_child(_off_hand)
	_add_gap(row)
	# ── 指派格（10 格，可视窗口 8 + 溢出指示）──
	_hint_left = StickKit.label(row, "◂", StickKit.LabelKind.TINY)
	_hint_left.modulate = Color(StickTokens.TEXT_DIM, 0.0)
	_slot_clip = Control.new()
	_slot_clip.clip_contents = true
	var clip_w: float = VISIBLE_SLOTS * (ItemSlotWidget.CELL + 6.0)
	_slot_clip.custom_minimum_size = Vector2(clip_w, ItemSlotWidget.CELL + ItemSlotWidget.CAPTION_H)
	row.add_child(_slot_clip)
	_slot_row = HBoxContainer.new()
	_slot_row.add_theme_constant_override("separation", 6)
	_slot_row.position = Vector2.ZERO
	_slot_clip.add_child(_slot_row)
	for i in PlayerInventory.HOTBAR_SIZE:
		var w := _make_cell(_key_caption(i))
		w.slot_index = i
		w.slot_left.connect(_on_use_slot.bind(i))
		w.slot_right.connect(_on_clear_slot.bind(i))
		_slot_row.add_child(w)
		_item_slots.append(w)
	_hint_right = StickKit.label(row, "▸", StickKit.LabelKind.TINY)
	_hint_right.modulate = Color(StickTokens.TEXT_DIM, 0.0)
	_add_gap(row)
	# ── 固定动作组（快捷键指示格）──
	row.add_child(_make_action("interact", "F"))
	var inv_btn := _make_action("inventory", "E")
	inv_btn.action_pressed.connect(_on_open_inventory)
	row.add_child(inv_btn)


func _make_cell(cap: String) -> ItemSlotWidget:
	var w := ItemSlotWidget.new(ItemSlotWidget.Mode.HOTBAR_ITEM)
	w.caption = cap
	return w


func _make_action(id: String, key: String) -> ItemSlotWidget:
	var w := ItemSlotWidget.new(ItemSlotWidget.Mode.ACTION)
	w.action_id = id
	w.caption = key
	return w


func _add_gap(row: HBoxContainer) -> void:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(GROUP_GAP, 4)
	row.add_child(sp)


## 数字键标注（1-9/0）
func _key_caption(i: int) -> String:
	return "0" if i == 9 else str(i + 1)


# ─────────────────────────────── 刷新 ────────────────────────────────

func refresh() -> void:
	if _service == null:
		return
	var inv: PlayerInventory = _service.inventory
	_main_hand.stack = inv.get_main_weapon()
	_off_hand.stack = inv.get_equipped(PlayerInventory.SlotType.OFF_HAND)
	_off_hand.locked = inv.is_offhand_locked()
	var mw: ItemStack = inv.get_main_weapon()
	var wielded_id: StringName = mw.def_id if mw != null and not mw.is_empty() else &""
	for i in _item_slots.size():
		var w: ItemSlotWidget = _item_slots[i]
		var id: StringName = inv.hotbar[i]
		if id == &"":
			w.stack = null
		elif id == wielded_id:
			w.stack = ItemStack.new(id, 1)
		else:
			# 指派格展示：消耗品显示剩余数量；武器/工具单件
			w.stack = ItemStack.new(id, maxi(1, inv.count_of(id)))
		# 当前武器所在格 = 琥珀高亮（滚轮切武器的视觉锚点）
		w.highlight = id != &"" and id == wielded_id
	# 选中格滚入可视窗口 + 溢出指示
	_scroll_to_visible(inv.hotbar_selected)
	_hint_left.modulate.a = 1.0 if _scroll_offset > 0 else 0.0
	_hint_right.modulate.a = 1.0 \
			if _scroll_offset + VISIBLE_SLOTS < PlayerInventory.HOTBAR_SIZE else 0.0


## 平移窗口使 target 滚入视野（数字键/滚轮切换后调用）
func _scroll_to_visible(target: int) -> void:
	if target < _scroll_offset:
		_scroll_offset = target
	elif target >= _scroll_offset + VISIBLE_SLOTS:
		_scroll_offset = target - VISIBLE_SLOTS + 1
	_scroll_offset = clampi(_scroll_offset, 0, PlayerInventory.HOTBAR_SIZE - VISIBLE_SLOTS)
	var x: float = _scroll_offset * (ItemSlotWidget.CELL + 6.0)
	var tween := create_tween()
	tween.tween_property(_slot_row, "position:x", -x, 0.12)


# ─────────────────────────────── 交互 ────────────────────────────────

## 使用指派格（点击；数字键同路：GameRoot 转发 InventoryService）
func _on_use_slot(index: int, _w: ItemSlotWidget = null) -> void:
	if _service != null and _service.has_method("use_hotbar_slot"):
		_service.use_hotbar_slot(index)


## 右键指派格 = 清除指派
func _on_clear_slot(index: int, _w: ItemSlotWidget = null) -> void:
	if _service != null:
		_service.inventory.hotbar_clear(index)


## 打开背包（战斗组点击 / E 动作格点击）
func _on_open_inventory(_w: ItemSlotWidget = null) -> void:
	if _game_root != null and _game_root.has_method("toggle_inventory"):
		_game_root.toggle_inventory()
