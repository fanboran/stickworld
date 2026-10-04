class_name InventoryScreen
extends StickScreen
## 背包·角色合一窗口（E 键模态）—— 左装备+角色卡 / 右分类列表。
##
## 布局（docs/设计/系统/14-背包与装备系统.md §2.4）：
##   左栏：装备 5 槽（头/胸/腿竖排 + 主/副手横排）+ 角色卡
##         （HP/五属性/战场情绪/伤痕状态——吸收原 StatsScreen）
##   右栏：背包分类列表（列表制：按 类别→名称 排序的条目行，滚动）
## 交互（点击制，无拖拽）：
##   左键条目 = 智能装备（装备类）/使用（消耗品）
##   右键条目 = 指派到 Hotbar 下一空格（再右键同物=取消指派）
##   左/右键装备槽 = 卸下（列表制恒成功）
## 挂 UIModalStack.Layer.INVENTORY。

## 分类标题（ItemDef.Category 序 → 中文；仅 UI 分组）
const CATEGORY_NAMES: Array[String] = [
	"武器", "盾", "头部护甲", "胸部护甲", "腿部护甲", "消耗品", "材料",
]
## 属性键 → 中文名（GDD §6.1 个体属性标签）
const ATTR_NAMES: Dictionary = {
	"str": "力量", "int": "智力", "agi": "敏捷", "cft": "工艺", "cmd": "指挥",
}
## 情绪 → 中文（战场导演标签）
const MOOD_NAMES: Array[String] = ["稳定", "犹豫", "亢奋", "恐慌"]
## 状态效果 → 中文（伤痕状态）
const EFFECT_NAMES: Dictionary = {
	0: "燃烧", 1: "中毒", 2: "迟缓", 3: "眩晕", 4: "治疗中",
}
## 角色卡刷新间隔（附身实体状态是活的）
const REFRESH_INTERVAL: float = 0.25

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
var _equip_widgets: Dictionary = {}    # SlotType -> ItemSlotWidget
var _list_box: VBoxContainer = null
var _list_scroll: ScrollContainer = null
# 角色卡控件
var _hp_label: Label = null
var _hp_bar: SketchProgress = null
var _attr_labels: Dictionary = {}
var _mood_label: Label = null
var _effects_box: VBoxContainer = null
var _no_entity_hint: Label = null
var _refresh_timer: float = 0.0
var _game_root: Node = null


func setup(game_root: Node, service: Node) -> void:
	_game_root = game_root
	_inv = service.inventory
	panel_size = Vector2(880, 560)
	panel_title = "背包 · 角色"
	_build_screen()
	_inv.inventory_changed.connect(queue_refresh)
	_inv.equipment_changed.connect(queue_refresh)
	refresh()
	set_process(false)


func _build_content() -> void:
	# StickKit.label 内部已挂父（勿再外层 add_child——双重挂父报错，下同）
	StickKit.label(_body,
			"左键 装备/使用 · 右键 指派快捷栏 · 滚轮（游戏中）切武器",
			StickKit.LabelKind.HINT)
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 24)
	_body.add_child(main)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# ── 左栏：装备 + 角色卡 ──
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.custom_minimum_size.x = 216
	main.add_child(left)
	var equip_box := VBoxContainer.new()
	equip_box.add_theme_constant_override("separation", 8)
	left.add_child(equip_box)
	for pair in EQUIP_ROWS:
		equip_box.add_child(_make_equip_widget(pair[0], pair[1]))
	var hand_row := HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 8)
	equip_box.add_child(hand_row)
	for pair in HAND_ROW:
		hand_row.add_child(_make_equip_widget(pair[0], pair[1]))
	_build_stats_card(left)
	# ── 右栏：背包分类列表 ──
	_list_scroll = ScrollContainer.new()
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(_list_scroll)
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 2)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(_list_box)


func _make_equip_widget(slot: int, cap: String) -> ItemSlotWidget:
	var w := ItemSlotWidget.new(ItemSlotWidget.Mode.EQUIP)
	w.slot_index = slot
	w.caption = cap
	w.slot_left.connect(_on_equip_clicked.bind(slot))
	w.slot_right.connect(_on_equip_clicked.bind(slot))
	_equip_widgets[slot] = w
	return w


## 角色卡（吸收原 StatsScreen：生命/属性/情绪/伤痕状态）
func _build_stats_card(parent: VBoxContainer) -> void:
	parent.add_child(SketchSeparator.new())
	_no_entity_hint = StickKit.label(parent, "未附身任何火柴人", StickKit.LabelKind.HINT)
	var hp_row := StickKit.row(parent)
	_hp_bar = SketchProgress.new()
	_hp_bar.custom_minimum_size = Vector2(150, 12)
	_hp_bar.show_percentage = false
	hp_row.add_child(_hp_bar)
	_hp_label = StickKit.label(hp_row, "0/0", StickKit.LabelKind.TINY)
	for key in ["str", "int", "agi", "cft", "cmd"]:
		var r := StickKit.row(parent)
		StickKit.label(r, ATTR_NAMES[key], StickKit.LabelKind.TINY).custom_minimum_size.x = 48
		_attr_labels[key] = StickKit.label(r, "10", StickKit.LabelKind.TINY)
	var mood_row := StickKit.row(parent)
	StickKit.label(mood_row, "情绪", StickKit.LabelKind.TINY).custom_minimum_size.x = 48
	_mood_label = StickKit.label(mood_row, "稳定", StickKit.LabelKind.TINY)
	_effects_box = VBoxContainer.new()
	_effects_box.add_theme_constant_override("separation", 1)
	parent.add_child(_effects_box)


func _process(delta: float) -> void:
	_refresh_timer += delta
	if _refresh_timer >= REFRESH_INTERVAL:
		_refresh_timer = 0.0
		_refresh_stats_card()


# ─────────────────────────────── 刷新 ────────────────────────────────

var _refresh_queued: bool = false


func queue_refresh() -> void:
	# 信号洪峰（批量操作）合并到帧末一刷
	if _refresh_queued:
		return
	_refresh_queued = true
	refresh.call_deferred()


func refresh() -> void:
	_refresh_queued = false
	if _inv == null:
		return
	for slot in _equip_widgets:
		(_equip_widgets[slot] as ItemSlotWidget).stack = _inv.get_equipped(slot)
	var off_w: ItemSlotWidget = _equip_widgets.get(PlayerInventory.SlotType.OFF_HAND, null)
	if off_w != null:
		off_w.locked = _inv.is_offhand_locked()
	_rebuild_list()
	_refresh_stats_card()


## 背包分类列表重建（条目行 = 格 + 名称 + 数量；类别分组标题）
func _rebuild_list() -> void:
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	var entries: Array = _inv.bag.entries()
	if entries.is_empty():
		StickKit.label(_list_box, "背包空空如也", StickKit.LabelKind.HINT)
		return
	var last_cat: int = -1
	for e in entries:
		var def: ItemDef = e["def"]
		if def.category != last_cat:
			last_cat = def.category
			var cat_name: String = CATEGORY_NAMES[def.category] \
					if def.category < CATEGORY_NAMES.size() else "其他"
			var head := StickKit.label(_list_box,
					"%s（%d）" % [cat_name, _entries_in_cat(entries, def.category)],
					StickKit.LabelKind.SECTION)
			head.modulate = Color(StickTokens.ACCENT, 0.9)
		# 行已在 _make_entry_row 内经 StickKit.row(_list_box) 挂父，勿再外层 add
		_make_entry_row(e)


func _entries_in_cat(entries: Array, cat: int) -> int:
	var n: int = 0
	for e in entries:
		if e["def"].category == cat:
			n += 1
	return n


## 一行条目：格子 + 名称 + 数量（+已装备/已指派角标）
func _make_entry_row(e: Dictionary) -> Control:
	var def_id: StringName = e["def_id"]
	var def: ItemDef = e["def"]
	var row := StickKit.row(_list_box)
	row.add_theme_constant_override("separation", 10)
	var cell := ItemSlotWidget.new(ItemSlotWidget.Mode.BACKPACK)
	cell.stack = ItemStack.new(def_id, int(e["count"]))
	# 已在 Hotbar 指派 = 琥珀高亮（右键同物=取消指派）
	for i in PlayerInventory.HOTBAR_SIZE:
		if _inv.hotbar[i] == def_id:
			cell.highlight = true
			break
	cell.slot_left.connect(_on_entry_left.bind(def_id))
	cell.slot_right.connect(_on_entry_right.bind(def_id))
	row.add_child(cell)
	var name_l := StickKit.label(row, def.display_name, StickKit.LabelKind.BODY)
	name_l.custom_minimum_size.x = 120
	StickKit.label(row, "×%d" % int(e["count"]), StickKit.LabelKind.BODY)
	var mw: ItemStack = _inv.get_main_weapon()
	if mw != null and not mw.is_empty() and mw.def_id == def_id:
		StickKit.label(row, "·已持", StickKit.LabelKind.TINY).modulate = Color(StickTokens.ACCENT, 0.8)
	return row


# ─────────────────────────────── 交互 ────────────────────────────────

## 条目左键：智能装备（装备类）/ 使用（消耗品）
func _on_entry_left(def_id: StringName, _w: ItemSlotWidget = null) -> void:
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null:
		return
	if def.category == ItemDef.Category.CONSUMABLE:
		_inv.use_item(def_id)
	elif def.is_equipment():
		_inv.equip_from_backpack(def_id)


## 条目右键：指派到 Hotbar 下一空格（仅武器/消耗品；已指派则取消）
func _on_entry_right(def_id: StringName, _w: ItemSlotWidget = null) -> void:
	if not _inv.hotbar_assignable(def_id):
		return
	for i in PlayerInventory.HOTBAR_SIZE:
		if _inv.hotbar[i] == def_id:
			_inv.hotbar_clear(i)
			return
	for i in PlayerInventory.HOTBAR_SIZE:
		if _inv.hotbar[i] == &"":
			_inv.hotbar_assign(i, def_id)
			return


## 装备槽点击：卸下回背包（列表制恒成功）
func _on_equip_clicked(slot: int, _w: ItemSlotWidget = null) -> void:
	_inv.unequip(slot)


# ─────────────────────────────── 角色卡 ────────────────────────────────

func _refresh_stats_card() -> void:
	var entity := _get_entity()
	var has_entity: bool = entity != null
	_no_entity_hint.visible = not has_entity
	for key in _attr_labels:
		(_attr_labels[key] as Label).visible = has_entity
	_hp_bar.visible = has_entity
	_hp_label.visible = has_entity
	_mood_label.visible = has_entity
	if not has_entity:
		return
	var health: Node = entity.get_node_or_null("HealthComponent")
	var hp: float = float(health.hp) if health != null and "hp" in health else 0.0
	var max_hp: float = float(health.max_hp) if health != null and "max_hp" in health else 1.0
	_hp_bar.max_value = max_hp
	_hp_bar.value = hp
	_hp_label.text = "%d/%d" % [roundi(hp), roundi(max_hp)]
	var attrs: Dictionary = entity.attributes if "attributes" in entity else {}
	for key in _attr_labels:
		(_attr_labels[key] as Label).text = str(int(attrs.get(key, 10)))
	var wm: Node = entity.get_node_or_null("WeaponMount")
	var mood: int = int(wm.get_mood()) if wm != null and wm.has_method("get_mood") else 0
	_mood_label.text = MOOD_NAMES[clampi(mood, 0, MOOD_NAMES.size() - 1)]
	for child in _effects_box.get_children():
		_effects_box.remove_child(child)
		child.queue_free()
	var se: Node = entity.get_node_or_null("StatusEffects")
	var actives: Array = se.list_active() if se != null and se.has_method("list_active") else []
	if actives.is_empty():
		StickKit.label(_effects_box, "无伤痕", StickKit.LabelKind.TINY)
	else:
		for e in actives:
			var line := StickKit.label(_effects_box,
					"%s %.0fs" % [EFFECT_NAMES.get(int(e["type"]), "?"), float(e["remain"])],
					StickKit.LabelKind.TINY)
			line.modulate = Color(1, 0.75, 0.7)


func _get_entity() -> Node:
	if _game_root == null or not _game_root.has_method("get_player_entity"):
		return null
	var e: Node = _game_root.get_player_entity()
	return e if (e != null and is_instance_valid(e)) else null


# ─────────────────────────────── 开关 ────────────────────────────────

func open() -> void:
	super.open()
	_refresh_timer = REFRESH_INTERVAL
	refresh()
	set_process(true)


func close() -> void:
	set_process(false)
	super.close()
