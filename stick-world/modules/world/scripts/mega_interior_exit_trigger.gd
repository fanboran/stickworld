class_name MegaInteriorExitTrigger
extends Area2D
## 大建筑内部出口触发器 —— 玩家进入后返回原地图。
##
## 在 MegaInteriorMap 场景中放置此节点，玩家走到出口区域时
## 触发 EventBus.mega_interior_exited 信号，GameRoot 负责
## 执行过场 + 旅行回 return_map_id。

func _ready() -> void:
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node2D) -> void:
	# 只触发玩家实体
	if not body.has_method("is_possessed") or not body.is_possessed():
		return
	if EventBus != null:
		EventBus.mega_interior_exited.emit("")
