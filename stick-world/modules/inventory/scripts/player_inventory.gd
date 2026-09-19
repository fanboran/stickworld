class_name PlayerInventory
extends RefCounted
## 玩家背包 + 装备栏 + Hotbar 指派（纯数据，可 headless 单测）。
##
## 列表制（创始人裁决，docs/设计/系统/背包与装备系统.md §2.2/§2.3）：
## 背包 = items 域 ItemContainer——**无总数量限制，唯一上限=每类 max_stack**；
## 装备规则（双手锁副手 / 类别约束）收敛在 can_* 与装备事务里；列表制下
## "背包满"不存在（装备/卸装恒可行，无回滚分支）。战斗端桥接由
## InventoryService 监听信号完成。
##
## Hotbar 指派（10 格）：存 def_id（指向而非移动）——只收 WEAPON/TOOL/
## CONSUMABLE（护甲/材料无高频切换语义）；wield() 是数字键/滚轮切换武器
## 的共用路径。

## 装备槽位
enum SlotType { HEAD, CHEST, LEGS, MAIN_HAND, OFF_HAND }

## Hotbar 指派格数（数字键 1-9/0）
const HOTBAR_SIZE: int = 10
## 护甲减伤硬上限（三件锁子 0.5 仍留余量；防止未来词条堆穿）
const ARMOR_REDUCTION_CAP: float = 0.6

## slot key 序列化名（to_dict/from_dict 用；顺序对齐 SlotType）
const SLOT_KEYS: Array[String] = ["head", "chest", "legs", "main_hand", "off_hand"]

## 背包（items 域列表制容器；无总数量限制）
var bag: ItemContainer = ItemContainer.new()
## 装备槽（SlotType -> ItemStack；无装备无键）
var equipped: Dictionary = {}
## Hotbar 指派（def_id 或 &""；空=未指派）
var hotbar: Array[StringName] = []
## Hotbar 当前选中格（滚轮/数字键切换的锚点）
var hotbar_selected: int = 0

signal inventory_changed
signal equipment_changed
signal item_used(def_id: StringName)


func _init() -> void:
	hotbar.resize(HOTBAR_SIZE)
	hotbar.fill(&"")
	bag.contents_changed.connect(func() -> void: inventory_changed.emit())


# ─────────────────────────────── 查询 ────────────────────────────────

func get_equipped(slot: SlotType) -> ItemStack:
	return equipped.get(slot, null)


func get_main_weapon() -> ItemStack:
	return get_equipped(SlotType.MAIN_HAND)


func has_shield() -> bool:
	var s: ItemStack = get_equipped(SlotType.OFF_HAND)
	return s != null and not s.is_empty()


## 主手是否双手武器（弓）——锁副手
func is_offhand_locked() -> bool:
	var w: ItemStack = get_main_weapon()
	return w != null and not w.is_empty() and w.def() != null and w.def().two_handed


## 护甲总减伤率（三件加和，封顶 ARMOR_REDUCTION_CAP）
func armor_damage_reduction() -> float:
	return minf(ARMOR_REDUCTION_CAP,
			_stat_sum(SlotType.HEAD, "damage_reduction")
			+ _stat_sum(SlotType.CHEST, "damage_reduction")
			+ _stat_sum(SlotType.LEGS, "damage_reduction"))


## 护甲总移速乘子（三件乘积）
func armor_speed_factor() -> float:
	return _stat_product(SlotType.HEAD, "speed_penalty", 1.0) \
			* _stat_product(SlotType.CHEST, "speed_penalty", 1.0) \
			* _stat_product(SlotType.LEGS, "speed_penalty", 1.0)


# ─────────────────────────────── 背包存取 ────────────────────────────────

## 放入物品（列表制：合并进该类条目，超 max_stack 的部分返回余量）
func add_item(def_id: StringName, count: int = 1) -> int:
	return bag.add(def_id, count)


## 移除物品（数量不足整体失败）
func remove_item(def_id: StringName, count: int = 1) -> bool:
	return bag.remove(def_id, count)


func count_of(def_id: StringName) -> int:
	return bag.count_of(def_id)


## 使用一件物品（消耗品扣 1 并广播；非消耗品返回空 id）
func use_item(def_id: StringName) -> StringName:
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null or def.category != ItemDef.Category.CONSUMABLE:
		return &""
	if not bag.remove(def_id, 1):
		return &""
	item_used.emit(def_id)
	return def_id


# ─────────────────────────────── 装备操作 ────────────────────────────────

## 物品对应的装备槽（不合法返回 -1）
func slot_for(def_id: StringName) -> int:
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null or not def.is_equipment():
		return -1
	match def.category:
		ItemDef.Category.WEAPON, ItemDef.Category.SHIELD:
			# 双手约束在 equip 事务里校验（要看当前主手状态）
			return SlotType.MAIN_HAND if def.category == ItemDef.Category.WEAPON else SlotType.OFF_HAND
		ItemDef.Category.ARMOR_HEAD:
			return SlotType.HEAD
		ItemDef.Category.ARMOR_CHEST:
			return SlotType.CHEST
		ItemDef.Category.ARMOR_LEGS:
			return SlotType.LEGS
	return -1


## 装备是否可行（UI 灰显用）。列表制无"背包满"，唯一不可行项=盾进被双手锁的副手。
func can_equip(def_id: StringName) -> bool:
	var slot: int = slot_for(def_id)
	if slot < 0:
		return false
	var def: ItemDef = ItemDB.get_def(def_id)
	return not (def.category == ItemDef.Category.SHIELD and is_offhand_locked())


## 装备（背包条目 → 装备槽）。列表制下卸旧恒可行（无背包满分支）：
## 双手武器顶掉的副手盾与旧装备直接回背包条目。
func equip_from_backpack(def_id: StringName) -> bool:
	var slot: int = slot_for(def_id)
	if slot < 0 or not can_equip(def_id):
		return false
	if not bag.remove(def_id, 1):
		return false
	var def: ItemDef = ItemDB.get_def(def_id)
	# 双手武器顶掉副手盾（回背包条目）
	if def.two_handed and equipped.has(SlotType.OFF_HAND):
		var off: ItemStack = equipped[SlotType.OFF_HAND]
		equipped.erase(SlotType.OFF_HAND)
		bag.add(off.def_id, off.count)
	# 旧装备回背包
	var old: ItemStack = equipped.get(slot, null)
	if old != null and not old.is_empty():
		equipped.erase(slot)
		bag.add(old.def_id, old.count)
	equipped[slot] = ItemStack.new(def_id, 1)
	inventory_changed.emit()
	equipment_changed.emit()
	return true


## 卸下装备（装备槽 → 背包条目；列表制恒成功）
func unequip(slot: SlotType) -> bool:
	var old: ItemStack = get_equipped(slot)
	if old == null or old.is_empty():
		return false
	equipped.erase(slot)
	bag.add(old.def_id, old.count)
	inventory_changed.emit()
	equipment_changed.emit()
	return true


## 换装主手武器（Hotbar 数字键/滚轮切武器的共用路径）：
## 已在手=空操作返回 true；否则从背包装备（旧武器自动回背包）。
func wield(def_id: StringName) -> bool:
	var cur: ItemStack = get_main_weapon()
	if cur != null and not cur.is_empty() and cur.def_id == def_id:
		return true
	if not can_equip(def_id) or count_of(def_id) <= 0:
		return false
	return equip_from_backpack(def_id)


# ─────────────────────────────── Hotbar 指派 ────────────────────────────────

## 指派是否合法：只收武器/工具/消耗品（护甲/材料无高频切换语义）
func hotbar_assignable(def_id: StringName) -> bool:
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null:
		return false
	return def.category == ItemDef.Category.WEAPON \
			or def.category == ItemDef.Category.CONSUMABLE


## 指派物品到格（不合法返回 false；同物已在别格=先清旧格再指派）
func hotbar_assign(index: int, def_id: StringName) -> bool:
	if index < 0 or index >= HOTBAR_SIZE or not hotbar_assignable(def_id):
		return false
	for i in HOTBAR_SIZE:
		if hotbar[i] == def_id:
			hotbar[i] = &""
	hotbar[index] = def_id
	inventory_changed.emit()
	return true


## 清除指派格
func hotbar_clear(index: int) -> void:
	if index < 0 or index >= HOTBAR_SIZE:
		return
	hotbar[index] = &""
	inventory_changed.emit()


## 选中格（数字键/点击）；选中格即"当前武器格"（UI 高亮锚点）
func hotbar_select(index: int) -> void:
	if index < 0 or index >= HOTBAR_SIZE:
		return
	hotbar_selected = index


## 滚轮切换武器：从当前选中格出发，循环找上/下一个**武器类**指派格并 wield；
## 顺带把选中锚点移过去。返回切到的 def_id（无武器格返回空）。
func hotbar_cycle_weapon(dir: int) -> StringName:
	var n: int = 0
	var i: int = hotbar_selected
	while n < HOTBAR_SIZE:
		i = (i + dir + HOTBAR_SIZE) % HOTBAR_SIZE
		n += 1
		var id: StringName = hotbar[i]
		if id != &"":
			var def: ItemDef = ItemDB.get_def(id)
			if def != null and def.category == ItemDef.Category.WEAPON and wield(id):
				hotbar_selected = i
				return id
	return &""


## 使用 Hotbar 格（数字键/点击）：武器=换装；消耗品=使用；返回发生动作的 def_id
func use_hotbar_slot(index: int) -> StringName:
	if index < 0 or index >= HOTBAR_SIZE:
		return &""
	var id: StringName = hotbar[index]
	if id == &"":
		return &""
	hotbar_selected = index
	var def: ItemDef = ItemDB.get_def(id)
	if def == null:
		return &""
	if def.category == ItemDef.Category.WEAPON:
		return id if wield(id) else &""
	if def.category == ItemDef.Category.CONSUMABLE:
		return use_item(id)
	return &""


# ─────────────────────────────── 序列化 ────────────────────────────────

func to_dict() -> Dictionary:
	var eq: Dictionary = {}
	for key in equipped:
		var st: ItemStack = equipped[key]
		if st != null and not st.is_empty():
			eq[SLOT_KEYS[key]] = st.to_dict()
	var hb: Array = []
	for id in hotbar:
		hb.append(String(id))
	return {
		"items": bag.to_dict(),
		"equipped": eq,
		"hotbar": hb,
		"hotbar_selected": hotbar_selected,
	}


func from_dict(d: Dictionary) -> void:
	bag.from_dict(d.get("items", {}))
	equipped.clear()
	var eq: Dictionary = d.get("equipped", {})
	for key in eq:
		var idx: int = SLOT_KEYS.find(str(key))
		if idx >= 0 and eq[key] is Dictionary:
			equipped[idx] = ItemStack.from_dict(eq[key])
	var hb: Array = d.get("hotbar", [])
	hotbar.clear()
	hotbar.resize(HOTBAR_SIZE)
	hotbar.fill(&"")
	for i in mini(hb.size(), HOTBAR_SIZE):
		var id := StringName(String(hb[i]))
		hotbar[i] = id if ItemDB.get_def(id) != null else &""
	hotbar_selected = clampi(int(d.get("hotbar_selected", 0)), 0, HOTBAR_SIZE - 1)
	inventory_changed.emit()
	equipment_changed.emit()


# ─────────────────────────────── 内部 ────────────────────────────────

func _stat_sum(slot: SlotType, key: String) -> float:
	var s: ItemStack = get_equipped(slot)
	if s == null or s.is_empty() or s.def() == null:
		return 0.0
	return s.def().stat(key, 0.0)


func _stat_product(slot: SlotType, key: String, fallback: float) -> float:
	var s: ItemStack = get_equipped(slot)
	if s == null or s.is_empty() or s.def() == null:
		return fallback
	return s.def().stat(key, fallback)
