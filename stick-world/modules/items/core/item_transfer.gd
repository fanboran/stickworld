class_name ItemTransfer
extends Object
## 容器间原子转移原语 —— items 域唯一的物品搬运语义。
##
## 翻包（尸体→玩家背包）、村仓存取（玩家背包↔区域仓储）、给 NPC 发装备等
## 一切"物品从 A 到 B"都走 move()；不存在绕过本类的直接条目操作。
## 原子性：按目标剩余容量与源持有量的最小值转移，不足部分留在源容器。


## 转移 count 件 def_id：from → to。返回**未转移的余量**（0 = 全部转移）。
## 目标按单类堆叠上限截断、源不足按持有量截断——两侧都不出错态。
static func move(from: ItemContainer, to: ItemContainer,
		def_id: StringName, count: int) -> int:
	if from == null or to == null or count <= 0:
		return count
	var take: int = mini(mini(count, from.count_of(def_id)), to.room_for(def_id))
	if take <= 0:
		return count
	if not from.remove(def_id, take):
		return count
	to.add(def_id, take)
	return count - take


## 整类转移（翻包"全部拿走"按钮）：搬空源容器里的 def_id。
static func move_all(from: ItemContainer, to: ItemContainer,
		def_id: StringName) -> int:
	if from == null or to == null:
		return 0
	return move(from, to, def_id, from.count_of(def_id))
