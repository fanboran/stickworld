class_name PlayerInventory
extends RefCounted
## 玩家背包 + 装备栏数据模型（纯数据，可 headless 单测）。
##
## 24 格背包（前 4 格 = Hotbar 物品组）+ 5 装备槽。所有操作走本类 API，
## 装备规则（双手锁副手 / 类型约束 / 卸装需背包有空位）收敛在 can_* 与
## 事务性 equip/unequip 里；战斗端桥接由 InventoryService 监听信号完成。

## 装备槽位
enum SlotType { HEAD, CHEST, LEGS, MAIN_HAND, OFF_HAND }

const BACKPACK_SIZE: int = 24
const HOTBAR_SIZE: int = 4
## 护甲减伤硬上限（三件锁子 0.5 仍留余量；防止未来词条堆穿）
const ARMOR_REDUCTION_CAP: float = 0.6

## slot key 序列化名（to_dict/from_dict 用；顺序对齐 SlotType）
const SLOT_KEYS: Array[String] = ["head", "chest", "legs", "main_hand", "off_hand"]

## 背包格（ItemStack or null）
var slots: Array = []
## 装备槽（SlotType -> ItemStack；无装备无键）
var equipped: Dictionary = {}

signal inventory_changed
signal equipment_changed
signal item_used(def_id: StringName)


func _init() -> void:
	slots.resize(BACKPACK_SIZE)


# ─────────────────────────────── 查询 ────────────────────────────────

func get_slot(index: int) -> ItemStack:
	if index < 0 or index >= slots.size():
		return null
	return slots[index]


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


## 背包是否还有空位（UI 背包满提示用）
func has_free_slot() -> bool:
	for s in slots:
		if s == null or s.is_empty():
			return true
	return false


# ─────────────────────────────── 存取 ────────────────────────────────

## 放入物品（先找可堆叠格再找空格）。返回没放下的数量（0 = 全放入）。
func add_item(def_id: StringName, count: int = 1) -> int:
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null or count <= 0:
		return count
	# 可堆叠物先合并
	if def.max_stack > 1:
		for i in slots.size():
			var s: ItemStack = slots[i]
			if s != null and s.def_id == def_id:
				var room: int = maxi(0, def.max_stack - s.count)
				var take: int = mini(room, count)
				if take > 0:
					s.count += take
					count -= take
					if count <= 0:
						inventory_changed.emit()
						return 0
	# 剩余放空格
	for i in slots.size():
		var s2: ItemStack = slots[i]
		if s2 == null or s2.is_empty():
			var put: int = mini(def.max_stack, count)
			slots[i] = ItemStack.new(def_id, put)
			count -= put
			if count <= 0:
				break
	inventory_changed.emit()
	return count


## 从背包格移除物品（数量递减，空了置 null）
func remove_at(index: int, count: int = 1) -> void:
	var s: ItemStack = get_slot(index)
	if s == null:
		return
	s.count -= count
	if s.count <= 0:
		slots[index] = null
	inventory_changed.emit()


## 背包内两格交换/合并（拖拽落地语义；a==b 或越界无操作）
func swap_slots(a: int, b: int) -> void:
	if a == b or a < 0 or b < 0 or a >= slots.size() or b >= slots.size():
		return
	var sa: ItemStack = slots[a]
	var sb: ItemStack = slots[b]
	if sa != null and sb != null and sa.can_merge_with(sb):
		var move: int = mini(sb.room_for(sa), sa.count)
		if move > 0:
			sb.count += move
			sa.count -= move
			if sa.count <= 0:
				slots[a] = null
			inventory_changed.emit()
			return
	slots[a] = sb
	slots[b] = sa
	inventory_changed.emit()


## 使用 Hotbar 物品格（数字键 1-4 → 下标 0-3）：消耗品类扣 1 件并广播。
## 返回使用的 def_id（非消耗品/空格返回空 StringName）。
func use_hotbar_item(index: int) -> StringName:
	var s: ItemStack = get_slot(index)
	if s == null or s.is_empty():
		return &""
	var def: ItemDef = s.def()
	if def == null or def.category != ItemDef.Category.CONSUMABLE:
		return &""
	var used_id: StringName = s.def_id
	remove_at(index, 1)
	item_used.emit(used_id)
	return used_id


# ─────────────────────────────── 装备操作 ────────────────────────────────

## 背包格物品对应的装备槽（不合法返回 -1）
func slot_for_index(index: int) -> int:
	var s: ItemStack = get_slot(index)
	if s == null or s.is_empty():
		return -1
	var def: ItemDef = s.def()
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


## 装备是否可行（UI 灰显用；真正执行走 equip_from_backpack）
func can_equip(index: int) -> bool:
	var slot: int = slot_for_index(index)
	if slot < 0:
		return false
	var s: ItemStack = get_slot(index)
	var def: ItemDef = s.def()
	# 盾装不进被双手武器锁定的副手
	if def.category == ItemDef.Category.SHIELD and is_offhand_locked():
		return false
	# 双手武器需要能安置被顶掉的副手盾（连同旧主手）——保守估位：
	# 空格数 + 本格腾出 ≥ 需要安置的非堆叠件数
	var need_room: int = 0
	if def.two_handed and has_shield():
		need_room += 1
	var old: ItemStack = get_equipped(slot)
	if old != null and not old.is_empty():
		need_room += 1
	if need_room == 0:
		return true
	var free: int = 0
	for i in slots.size():
		var t: ItemStack = slots[i]
		if (t == null or t.is_empty()) and i != index:
			free += 1
	return free >= need_room


## 装备（背包格 → 装备槽）。事务性：中途放不下自动回滚，失败返回 false。
func equip_from_backpack(index: int) -> bool:
	var slot: int = slot_for_index(index)
	if slot < 0:
		return false
	var held: ItemStack = get_slot(index)
	var def: ItemDef = held.def()
	if def.category == ItemDef.Category.SHIELD and is_offhand_locked():
		return false
	# 取出手中物（腾出本格，也是第一个安置位）
	slots[index] = null
	var log: Array = [[index, null]]  # 存放/腾位记录 (格, 原内容)，失败回滚
	var removed: Array = []  # 事务中已移出装备槽的 [(SlotType, ItemStack)]，失败塞回
	# 双手武器顶掉副手盾
	if def.two_handed and equipped.has(SlotType.OFF_HAND):
		var off: ItemStack = equipped[SlotType.OFF_HAND]
		equipped.erase(SlotType.OFF_HAND)
		removed.append([SlotType.OFF_HAND, off])
		if not _store_tracked(off, log):
			_restore_removed(removed)
			_undo(log, held)
			return false
	# 旧装备回背包
	var old: ItemStack = equipped.get(slot, null)
	if old != null and not old.is_empty():
		equipped.erase(slot)
		removed.append([slot, old])
		if not _store_tracked(old, log):
			_restore_removed(removed)
			_undo(log, held)
			return false
	equipped[slot] = held
	inventory_changed.emit()
	equipment_changed.emit()
	return true


## 卸下装备（装备槽 → 背包）。背包放不下返回 false。
func unequip(slot: SlotType) -> bool:
	var old: ItemStack = get_equipped(slot)
	if old == null or old.is_empty():
		return false
	var log: Array = []
	if not _store_tracked(old, log):
		return false
	equipped.erase(slot)
	inventory_changed.emit()
	equipment_changed.emit()
	return true


# ─────────────────────────────── 光标堆操作（背包 UI 拿起/放下） ────────────────────────────────

## 整堆取出到光标（UI 左键拿起；空格返回 null）
func take_all(index: int) -> ItemStack:
	var s: ItemStack = get_slot(index)
	if s == null or s.is_empty():
		return null
	slots[index] = null
	inventory_changed.emit()
	return s


## 放下光标堆到背包格（UI 左键放下）：空格直放 / 同物合并 / 异物交换。
## 返回仍在光标上的堆（null = 全放下）
func place(index: int, cursor: ItemStack) -> ItemStack:
	if cursor == null or cursor.is_empty():
		return null
	if index < 0 or index >= slots.size():
		return cursor
	var s: ItemStack = get_slot(index)
	if s == null or s.is_empty():
		slots[index] = cursor
		inventory_changed.emit()
		return null
	if s.can_merge_with(cursor):
		var move: int = mini(s.room_for(cursor), cursor.count)
		s.count += move
		cursor.count -= move
		inventory_changed.emit()
		return cursor if cursor.count > 0 else null
	# 交换
	slots[index] = cursor
	inventory_changed.emit()
	return s


## 装备槽整件取到光标（UI 左键点装备槽；空槽返回 null）
func unequip_to_cursor(slot: SlotType) -> ItemStack:
	var s: ItemStack = get_equipped(slot)
	if s == null or s.is_empty():
		return null
	equipped.erase(slot)
	inventory_changed.emit()
	equipment_changed.emit()
	return s


## 光标堆装入装备槽（UI 持物点装备槽）：类别须匹配；双手武器顶掉的副手盾
## 自动回背包。返回仍在光标上的堆（null = 装入成功；原样返回 = 校验失败）
func equip_stack(cursor: ItemStack, slot: SlotType) -> ItemStack:
	if cursor == null or cursor.is_empty():
		return null
	var def: ItemDef = cursor.def()
	if def == null or not def.is_equipment():
		return cursor
	# 类别匹配校验（武器→主手 / 盾→副手 / 护甲→对应槽）
	var want: int = -1
	match def.category:
		ItemDef.Category.WEAPON:
			want = SlotType.MAIN_HAND
		ItemDef.Category.SHIELD:
			want = SlotType.OFF_HAND
		ItemDef.Category.ARMOR_HEAD:
			want = SlotType.HEAD
		ItemDef.Category.ARMOR_CHEST:
			want = SlotType.CHEST
		ItemDef.Category.ARMOR_LEGS:
			want = SlotType.LEGS
	if want != slot:
		return cursor
	# 盾装不进被双手武器锁定的副手
	if def.category == ItemDef.Category.SHIELD and is_offhand_locked():
		return cursor
	# 双手武器：副手盾先回背包（回不去则整体失败）
	var log: Array = []
	if def.two_handed and equipped.has(SlotType.OFF_HAND):
		var off: ItemStack = equipped[SlotType.OFF_HAND]
		equipped.erase(SlotType.OFF_HAND)
		if not _store_tracked(off, log):
			equipped[SlotType.OFF_HAND] = off
			return cursor
	# 旧装备顶到光标
	var old: ItemStack = equipped.get(slot, null)
	equipped[slot] = cursor
	inventory_changed.emit()
	equipment_changed.emit()
	return old if (old != null and not old.is_empty()) else null


# ─────────────────────────────── 序列化 ────────────────────────────────

func to_dict() -> Dictionary:
	var slot_arr: Array = []
	for s in slots:
		slot_arr.append(s.to_dict() if s != null and not s.is_empty() else null)
	var eq: Dictionary = {}
	for key in equipped:
		var st: ItemStack = equipped[key]
		if st != null and not st.is_empty():
			eq[SLOT_KEYS[key]] = st.to_dict()
	return {"slots": slot_arr, "equipped": eq}


func from_dict(d: Dictionary) -> void:
	slots.clear()
	slots.resize(BACKPACK_SIZE)
	var slot_arr: Array = d.get("slots", [])
	for i in mini(slot_arr.size(), BACKPACK_SIZE):
		var v: Variant = slot_arr[i]
		slots[i] = ItemStack.from_dict(v) if v is Dictionary else null
	equipped.clear()
	var eq: Dictionary = d.get("equipped", {})
	for key in eq:
		var idx: int = SLOT_KEYS.find(str(key))
		if idx >= 0 and eq[key] is Dictionary:
			equipped[idx] = ItemStack.from_dict(eq[key])
	inventory_changed.emit()
	equipment_changed.emit()


# ─────────────────────────────── 内部 ────────────────────────────────

## 存入一个堆（合并优先，再空格）。所有改动记录进 log 供事务回滚。
func _store_tracked(stack: ItemStack, log: Array) -> bool:
	if stack == null or stack.is_empty():
		return true
	var def: ItemDef = stack.def()
	if def == null:
		return false
	var count: int = stack.count
	if def.max_stack > 1:
		for i in slots.size():
			var s: ItemStack = slots[i]
			if s != null and not s.is_empty() and s.def_id == stack.def_id:
				var room: int = maxi(0, def.max_stack - s.count)
				var take: int = mini(room, count)
				if take > 0:
					log.append([i, s.count])
					s.count += take
					count -= take
					if count <= 0:
						return true
	for i in slots.size():
		var s2: ItemStack = slots[i]
		if s2 == null or s2.is_empty():
			var put: int = mini(def.max_stack, count)
			log.append([i, null])
			slots[i] = ItemStack.new(stack.def_id, put)
			count -= put
			if count <= 0:
				return true
	return count <= 0


## 事务回滚：被移出的装备塞回原槽
func _restore_removed(removed: Array) -> void:
	for pair in removed:
		equipped[pair[0]] = pair[1]


## 事务回滚：按 log 逆序恢复格内容，装备中的手持物放回原格
func _undo(log: Array, held: ItemStack) -> void:
	for i in range(log.size() - 1, -1, -1):
		var entry: Array = log[i]
		var idx: int = entry[0]
		var prev: Variant = entry[1]
		if prev == null:
			slots[idx] = null
		elif prev is int:
			(slots[idx] as ItemStack).count = prev
		else:
			slots[idx] = prev
	if held != null:
		slots[log[0][0]] = held
	inventory_changed.emit()


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
