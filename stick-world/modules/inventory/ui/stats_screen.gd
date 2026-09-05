class_name StatsScreen
extends StickScreen
## 角色属性面板（C 键模态）—— 个体档案一页：生命 / 五属性 / 战场情绪 /
## 伤痕状态（激活状态效果）/ 装备概览。
##
## 面板刻意**不显示名字**（火柴人无名氏，用户定稿）；数据实时刷新
## （打开期间 0.25s 一拍）。未附身时显示占位提示。

const REFRESH_INTERVAL: float = 0.25

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
## 装备概览槽序（键 → [SlotType, 槽名]）
const EQUIP_SUMMARY: Array = [
	[PlayerInventory.SlotType.MAIN_HAND, "主手"],
	[PlayerInventory.SlotType.OFF_HAND, "副手"],
	[PlayerInventory.SlotType.HEAD, "头"],
	[PlayerInventory.SlotType.CHEST, "胸"],
	[PlayerInventory.SlotType.LEGS, "腿"],
]

var _game_root: Node = null
var _service: InventoryService = null
var _hp_label: Label = null
var _hp_bar: SketchProgress = null
var _attr_labels: Dictionary = {}   # 键 -> Label
var _mood_label: Label = null
var _effects_box: VBoxContainer = null
var _equip_widgets: Array[ItemSlotWidget] = []
var _no_entity_hint: Label = null
var _content_root: Control = null
var _refresh_timer: float = 0.0


func setup(game_root: Node, service: InventoryService) -> void:
	_game_root = game_root
	_service = service
	panel_size = Vector2(540, 640)
	panel_title = "角色"
	_build_screen()
	set_process(false)
	refresh()


func _build_content() -> void:
	_content_root = VBoxContainer.new()
	_content_root.add_theme_constant_override("separation", 10)
	_body.add_child(_content_root)
	# 未附身占位
	_no_entity_hint = StickKit.label(_content_root, "未附身任何火柴人", StickKit.LabelKind.HINT)
	# ── 生命 ──
	var hp_sec := StickKit.section(_content_root, "生命")
	var hp_row := StickKit.row(hp_sec)
	_hp_bar = SketchProgress.new()
	_hp_bar.custom_minimum_size = Vector2(240, 14)
	_hp_bar.show_percentage = false
	hp_row.add_child(_hp_bar)
	_hp_label = StickKit.label(hp_row, "0 / 0", StickKit.LabelKind.BODY)
	# ── 属性 ──
	var attr_sec := StickKit.section(_content_root, "属性")
	for key in ["str", "int", "agi", "cft", "cmd"]:
		var r := StickKit.row(attr_sec, 4)
		var name_l := StickKit.label(r, ATTR_NAMES[key], StickKit.LabelKind.BODY)
		name_l.custom_minimum_size.x = 64
		var val_l := StickKit.label(r, "10", StickKit.LabelKind.BODY)
		_attr_labels[key] = val_l
	# ── 战场情绪 ──
	var mood_sec := StickKit.section(_content_root, "战场情绪")
	_mood_label = StickKit.label(mood_sec, "稳定", StickKit.LabelKind.BODY)
	# ── 伤痕状态 ──
	var fx_sec := StickKit.section(_content_root, "伤痕状态")
	_effects_box = VBoxContainer.new()
	_effects_box.add_theme_constant_override("separation", 2)
	fx_sec.add_child(_effects_box)
	# ── 装备概览 ──
	var eq_sec := StickKit.section(_content_root, "装备")
	var eq_row := StickKit.row(eq_sec, 10)
	for pair in EQUIP_SUMMARY:
		var w := ItemSlotWidget.new(ItemSlotWidget.Mode.EQUIP)
		w.slot_index = pair[0]
		w.caption = pair[1]
		w.slot_left.connect(_on_equip_clicked)
		eq_row.add_child(w)
		_equip_widgets.append(w)


func _on_equip_clicked(_w: ItemSlotWidget) -> void:
	# 装备格点击 → 跳背包（换装在背包做，此处只读）
	if _game_root != null and _game_root.has_method("toggle_inventory"):
		_game_root.toggle_inventory()


func _process(delta: float) -> void:
	_refresh_timer += delta
	if _refresh_timer >= REFRESH_INTERVAL:
		_refresh_timer = 0.0
		refresh()


# ─────────────────────────────── 刷新 ────────────────────────────────

func refresh() -> void:
	var entity := _get_entity()
	_no_entity_hint.visible = entity == null
	for key in _attr_labels:
		(_attr_labels[key] as Label).visible = entity != null
	if _hp_bar != null:
		_hp_bar.visible = entity != null
	if _hp_label != null:
		_hp_label.visible = entity != null
	if _mood_label != null:
		_mood_label.visible = entity != null
	if entity == null:
		for w in _equip_widgets:
			w.stack = _equip_of(w)
		return
	# 生命
	var health: Node = entity.get_node_or_null("HealthComponent")
	var hp: float = float(health.hp) if health != null and "hp" in health else 0.0
	var max_hp: float = float(health.max_hp) if health != null and "max_hp" in health else 1.0
	if _hp_bar != null:
		_hp_bar.max_value = max_hp
		_hp_bar.value = hp
	if _hp_label != null:
		_hp_label.text = "%d / %d" % [roundi(hp), roundi(max_hp)]
	# 属性
	var attrs: Dictionary = entity.attributes if "attributes" in entity else {}
	for key in _attr_labels:
		(_attr_labels[key] as Label).text = str(int(attrs.get(key, 10)))
	# 情绪
	var wm: Node = entity.get_node_or_null("WeaponMount")
	var mood: int = int(wm.get_mood()) if wm != null and wm.has_method("get_mood") else 0
	if _mood_label != null:
		_mood_label.text = MOOD_NAMES[clampi(mood, 0, MOOD_NAMES.size() - 1)]
	# 伤痕状态（激活效果列表；先摘节点再释放，防帧末前新旧并存）
	for child in _effects_box.get_children():
		_effects_box.remove_child(child)
		child.queue_free()
	var se: Node = entity.get_node_or_null("StatusEffects")
	var actives: Array = se.list_active() if se != null and se.has_method("list_active") else []
	if actives.is_empty():
		_effects_box.add_child(StickKit.label(_effects_box, "无", StickKit.LabelKind.HINT))
	else:
		for e in actives:
			var fx_name: String = EFFECT_NAMES.get(int(e["type"]), "未知")
			var line := StickKit.label(_effects_box,
					"%s · 剩余 %.0f 秒" % [fx_name, float(e["remain"])],
					StickKit.LabelKind.BODY)
			line.modulate = Color(1, 0.75, 0.7)
	# 装备概览
	for w in _equip_widgets:
		w.stack = _equip_of(w)


func _equip_of(w: ItemSlotWidget) -> ItemStack:
	if _service == null:
		return null
	return _service.inventory.get_equipped(w.slot_index)


func _get_entity() -> Node:
	if _game_root == null or not _game_root.has_method("get_player_entity"):
		return null
	var e: Node = _game_root.get_player_entity()
	return e if (e != null and is_instance_valid(e)) else null


# ─────────────────────────────── 开关 ────────────────────────────────

func open() -> void:
	super.open()
	_refresh_timer = REFRESH_INTERVAL  # 首拍立即刷新
	refresh()
	set_process(true)


func close() -> void:
	set_process(false)
	super.close()
