class_name ItemStack
extends RefCounted
## 物品运行时堆（def_id + count；背包与装备槽的最小存储单元）。
##
## 引用 ItemDef 的 id 而非对象本身——序列化只存 (id, count)，ItemDB 查表还原，
## 存档体积极小且定义热改即时生效。

var def_id: StringName = &""
var count: int = 1


func _init(p_def_id: StringName = &"", p_count: int = 1) -> void:
	def_id = p_def_id
	count = p_count


func def() -> ItemDef:
	return ItemDB.get_def(def_id)


func is_empty() -> bool:
	return count <= 0 or def_id == &""


## 与另一堆是否同物且可合并（装备类 max_stack=1 永远不可）
func can_merge_with(other: ItemStack) -> bool:
	if other == null or is_empty() or other.is_empty():
		return false
	if def_id != other.def_id:
		return false
	return def() != null and def().max_stack > 1


## 还能吃进多少件（对同物 other）
func room_for(other: ItemStack) -> int:
	if not can_merge_with(other):
		return 0
	return maxi(0, def().max_stack - count)


func to_dict() -> Dictionary:
	return {"id": String(def_id), "count": count}


static func from_dict(d: Dictionary) -> ItemStack:
	return ItemStack.new(StringName(str(d.get("id", ""))), int(d.get("count", 1)))
