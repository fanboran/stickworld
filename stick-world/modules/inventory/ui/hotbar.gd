class_name Hotbar
extends Control
## 底部常驻物品栏（HudOverlay 槽，ModePanel 上方居中）。
##
## 三组布局（用户定稿：格子下方标注按键）：
##   [主手|左键] [副手|右键] │ [1][2][3][4] │ [交互F] [脱困H] [背包E]
##   └── 战斗组(装备镜像) ──┘  └ Hotbar 物品组 ┘  └── 动作组(快捷键) ──┘
## 战斗组点击 = 打开背包；物品组点击/数字键 = 使用；动作组 E 格点击 = 开背包。
## 数据驱动：订阅 PlayerInventory 信号刷新，不轮询。

const GROUP_GAP: int = 26.0
const OFFSET_ABOVE_MODE_PANEL: float = 88.0

var _service: InventoryService = null
var _game_root: Node = null
var _main_hand: ItemSlotWidget = null
var _off_hand: ItemSlotWidget = null
var _item_slots: Array[ItemSlotWidget] = []


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
	_main_hand = _make_cell(ItemSlotWidget.Mode.HOTBAR_ITEM, "左键")
	_main_hand.slot_left.connect(_on_open_inventory)
	row.add_child(_main_hand)
	_off_hand = _make_cell(ItemSlotWidget.Mode.HOTBAR_ITEM, "右键")
	_off_hand.slot_left.connect(_on_open_inventory)
	row.add_child(_off_hand)
	_add_gap(row)
	# ── 物品组（背包前 4 格）──
	for i in PlayerInventory.HOTBAR_SIZE:
		var w := _make_cell(ItemSlotWidget.Mode.HOTBAR_ITEM, str(i + 1))
		w.slot_index = i
		w.slot_left.connect(_on_use_item.bind(i))
		row.add_child(w)
		_item_slots.append(w)
	_add_gap(row)
	# ── 动作组（角色快捷键）──
	row.add_child(_make_action("interact", "F"))
	row.add_child(_make_action("unstuck", "H"))
	var inv_btn := _make_action("inventory", "E")
	inv_btn.action_pressed.connect(_on_open_inventory)
	row.add_child(inv_btn)


func _make_cell(mode: int, cap: String) -> ItemSlotWidget:
	var w := ItemSlotWidget.new(mode)
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


# ─────────────────────────────── 刷新 ────────────────────────────────

func refresh() -> void:
	if _service == null:
		return
	var inv: PlayerInventory = _service.inventory
	_main_hand.stack = inv.get_main_weapon()
	_off_hand.stack = inv.get_equipped(PlayerInventory.SlotType.OFF_HAND)
	_off_hand.locked = inv.is_offhand_locked()
	for i in _item_slots.size():
		_item_slots[i].stack = inv.get_slot(_item_slots[i].slot_index)


# ─────────────────────────────── 交互 ────────────────────────────────

## 使用 Hotbar 物品格（数字键同路：GameRoot 转发 InventoryService）
func _on_use_item(index: int) -> void:
	if _service != null:
		_service.use_hotbar_item(index)


## 打开背包（战斗组点击 / E 动作格点击）
func _on_open_inventory(_w: ItemSlotWidget = null) -> void:
	if _game_root != null and _game_root.has_method("toggle_inventory"):
		_game_root.toggle_inventory()
