class_name WorldLedgerSetup extends RefCounted
## 世界账面装配器（M2 世界模型整合）——AR-1 装配下沉模式的最小样板。
##
## 职责：把 EventBus.world_day_advanced → WorldLedger.advance_day 的接线
## 绑定到常驻桥节点（GameRoot 子节点）。**必须走节点绑定的原因**：lambda/
## 静态 Callable 无绑定对象，GameRoot 重建（菜单往返 change_scene_to_file）
## 后重跑装配会叠连旧连接造成多倍日 tick；方法绑定的连接随宿主节点释放
## 自动断开，天然幂等。同 root 重复装配另有护栏（按桥节点名查重）。
##
## 生命周期：桥节点随 GameRoot 子树生灭；本装配器自身 RefCounted 无状态。

const ScriptLedger := preload("res://core/entities/world_ledger.gd")


## 桥节点：连接绑定自身方法（_on_day），宿主释放即断连。
class Bridge extends Node:
	func _ready() -> void:
		EventBus.world_day_advanced.connect(_on_day)


	func _on_day() -> void:
		ScriptLedger.advance_day(WorldState)


## 装配入口（幂等）。root 传 GameRoot；桥挂其下随树生灭。
static func assemble(root: Node) -> void:
	if root == null:
		return
	if root.get_node_or_null(^"WorldDayPulseBridge") != null:
		return
	var bridge := Bridge.new()
	bridge.name = "WorldDayPulseBridge"
	root.add_child(bridge)
