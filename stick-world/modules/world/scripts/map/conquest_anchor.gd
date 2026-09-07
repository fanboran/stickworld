class_name ConquestAnchor
extends Node2D
## 敌据点征服锚点 —— 守军布阵/敌将位/集结线的场景化布局标记。
##
## 契约见 docs/技术/架构/出征与领地架构.md §2.3（对齐 MapBase.BattleAnchor 先例：
## 场景是布局唯一真相源，消费方读锚点布阵，不写死坐标）：
##   ConquestAnchor (Node2D, 本脚本)
##   ├── GarrisonSlots (Node2D)   ← 子 Marker2D 数组 = 守军出生点（按配置兵种刷军）
##   ├── CommanderSlot (Marker2D) ← 敌将位
##   └── RallyX (Marker2D)        ← 守军集结线（x 为线位置；消费端批次 C5 接线）
##
## 消费方：GarrisonSpawner（modules/expansion）。据点图未挂锚点时由消费方
## fallback 程序化布阵（右侧半区横排），不阻断玩法。

## 守军出生点组路径
const PATH_GARRISON_SLOTS := "GarrisonSlots"
## 敌将位路径
const PATH_COMMANDER_SLOT := "CommanderSlot"
## 集结线路径
const PATH_RALLY_X := "RallyX"


## 守军出生点（全局坐标，按子节点声明顺序）；无 GarrisonSlots 返回空数组
func get_garrison_slots() -> Array[Vector2]:
	var out: Array[Vector2] = []
	var slots: Node = get_node_or_null(PATH_GARRISON_SLOTS)
	if slots == null:
		return out
	for c in slots.get_children():
		if c is Marker2D:
			out.append((c as Marker2D).global_position)
	return out


## 敌将位（全局坐标）；无 CommanderSlot 返回 Vector2.INF（调用方判据 is_finite）
func get_commander_position() -> Vector2:
	var slot: Node2D = get_node_or_null(PATH_COMMANDER_SLOT) as Node2D
	if slot == null:
		return Vector2.INF
	return slot.global_position


## 守军集结线 x（全局坐标）；无 RallyX 返回 INF
func get_rally_x() -> float:
	var m: Node2D = get_node_or_null(PATH_RALLY_X) as Node2D
	if m == null:
		return INF
	return m.global_position.x


## 在地图实例下查找 ConquestAnchor（约定挂根级，与 BattleAnchor 平级；遍历兜底改名场景）
static func find_in(map: Node) -> ConquestAnchor:
	if map == null:
		return null
	var direct: Node = map.get_node_or_null("ConquestAnchor")
	if direct is ConquestAnchor:
		return direct
	for c in map.get_children():
		if c is ConquestAnchor:
			return c
	return null
