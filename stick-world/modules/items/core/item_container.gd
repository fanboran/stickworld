class_name ItemContainer
extends RefCounted
## 列表制物品容器 —— items 域的统一库存抽象。
##
## 一切库存场景（玩家背包 / 尸体遗物 / 载具货舱 / 未来工坊仓库）都是本类的
## 实例；区域仓储（村仓）经 RegionStorage 桥接经济层，同以本类为物品语义出口。
##
## 容量语义（创始人裁决，docs/设计/系统/14-背包与装备系统.md §2.2）：
##   **无总格数/总数量限制，唯一上限 = 每类物品的 max_stack**（条目即堆，
##   一类物品一条目）。超出上限的部分 add 返回余量，由来源处理。
##   容器级可用 stack_overrides 覆盖单类上限（如村仓大宗仓储放大石料上限）。

signal contents_changed

## 条目表：def_id(StringName) → count(int)
var _items: Dictionary = {}

## 单类堆叠上限覆盖（def_id → cap；缺省回落 def.max_stack）
var stack_overrides: Dictionary = {}


## 放入物品。返回**放不下的余量**（0 = 全放入；上限 = 该物品有效堆叠上限）。
func add(def_id: StringName, count: int = 1) -> int:
	if def_id == &"" or count <= 0:
		return count
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null:
		return count
	var cap: int = stack_cap(def_id)
	var cur: int = int(_items.get(def_id, 0))
	var room: int = maxi(0, cap - cur)
	var take: int = mini(room, count)
	if take > 0:
		_items[def_id] = cur + take
		contents_changed.emit()
	return count - take


## 移除物品。数量不足则整体失败（返回 false，不动条目）；够则递减。
func remove(def_id: StringName, count: int = 1) -> bool:
	if count <= 0:
		return true
	var cur: int = int(_items.get(def_id, 0))
	if cur < count:
		return false
	if cur == count:
		_items.erase(def_id)
	else:
		_items[def_id] = cur - count
	contents_changed.emit()
	return true


## 当前持有量
func count_of(def_id: StringName) -> int:
	return int(_items.get(def_id, 0))


## 是否持有至少 count 件
func has_item(def_id: StringName, count: int = 1) -> bool:
	return count_of(def_id) >= count


## 还能收进多少（对 def_id 的剩余容量）
func room_for(def_id: StringName) -> int:
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null:
		return 0
	return maxi(0, stack_cap(def_id) - count_of(def_id))


## 单类有效堆叠上限（override 优先，回落 def.max_stack）
func stack_cap(def_id: StringName) -> int:
	if stack_overrides.has(def_id):
		return int(stack_overrides[def_id])
	var def: ItemDef = ItemDB.get_def(def_id)
	return def.max_stack if def != null else 0


## 全部条目（只读快照）：[{def_id, count, def}]，按 类别序→名称序 排列
## （UI 分类列表直接消费；def 引用随行省一次查表）
func entries() -> Array:
	var out: Array = []
	for key in _items:
		var d: ItemDef = ItemDB.get_def(key)
		if d == null:
			continue
		out.append({"def_id": key, "count": int(_items[key]), "def": d})
	out.sort_custom(func(a, b):
		if a["def"].category != b["def"].category:
			return a["def"].category < b["def"].category
		return a["def"].display_name < b["def"].display_name)
	return out


func is_empty() -> bool:
	return _items.is_empty()


## 总物品种类数（非总件数——列表制无总件数上限语义）
func entry_count() -> int:
	return _items.size()


func clear() -> void:
	if _items.is_empty():
		return
	_items.clear()
	contents_changed.emit()


# ─────────────────────────────── 序列化 ────────────────────────────────

func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for key in _items:
		out[String(key)] = int(_items[key])
	return out


func from_dict(d: Dictionary) -> void:
	_items.clear()
	for key in d:
		var def_id := StringName(String(key))
		if ItemDB.get_def(def_id) != null and int(d[key]) > 0:
			_items[def_id] = int(d[key])
	contents_changed.emit()
