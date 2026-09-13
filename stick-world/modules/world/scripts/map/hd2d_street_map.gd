extends MapBase
class_name Hd2dStreetMap
## HD-2D 街景地图 —— 3D 街景原型（tests/dev/proto_hd2d）作为游戏地图接入
## （创始人 2026-09-14：直接接入游戏内场景，接存档、复用原天空）。
##
## duck API（spawn_entity/get_entities/元数据 getter）全部继承 MapBase；
## 地图本体是**静态布景**：不实现 save_to_db/load_from_db（SaveHandler 的
## has_method 守卫自动跳过），current_map_id 由 save_meta 正常记录/恢复，
## 实体存取走 MapBase 默认实现（玩家存 entities 表，读档兜底重生成）。
##
## 玩家以 2D 实体（EntityHost）浮于 3D 街景之上（canvas 层在 3D 之后渲染），
## WASD 可走 —— 最小可玩版；3D 相机固定（Camera2D 只影响 2D 层/HUD）。
##
## TODO(提炼): 3D 街景场景与卡资产仍在 tests/dev/proto_hd2d（res://temp 产物），
## 正式化时迁入 modules 并改走随包导出路径。

const _HD2D_WORLD_SCENE := preload("res://tests/dev/proto_hd2d/proto_hd2d.tscn")


func _ready() -> void:
	super()
	var hd: Node3D = _HD2D_WORLD_SCENE.instantiate()
	hd.name = "HD2DWorld"
	add_child(hd)
