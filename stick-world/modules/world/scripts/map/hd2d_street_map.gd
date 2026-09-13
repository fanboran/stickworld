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
## 碰撞：3D 街景的前排建筑/摆件映射成 2D 静态碰撞墙（get_solid_rects），
## 玩家在街上走不会被穿透。出生点 = 街中心前景（get_spawn_point）。
##
## TODO(提炼): 3D 街景场景与卡资产仍在 tests/dev/proto_hd2d（res://temp 产物），
## 正式化时迁入 modules 并改走随包导出路径。

const _HD2D_WORLD_SCENE := preload("res://tests/dev/proto_hd2d/proto_hd2d.tscn")

## 街面行走带的 2D y 范围（建筑墙挡住的后段 + 前景可横穿段）
const WALK_BACK_Y := 688.0
const WALK_FRONT_Y := 1080.0


func _ready() -> void:
	super()
	var hd: Node3D = _HD2D_WORLD_SCENE.instantiate()
	hd.name = "HD2DWorld"
	add_child(hd)
	_build_solid_bodies(hd)


func get_spawn_point() -> Vector2:
	# 街中心前景：玩家落在画面中下（3D 街景可见区内）
	return Vector2(0.0, 1010.0)


## 3D 街景的实心区间（格）→ 2D 静态碰撞墙（px）。
## 墙的 y 覆盖行走带后段（建筑/摆件所在），前景 y > WALK_FRONT 段留空可横穿。
func _build_solid_bodies(hd: Node3D) -> void:
	if not hd.has_method("get_solid_rects"):
		return
	var body := StaticBody2D.new()
	body.name = "HD2DSolids"
	for r: Variant in hd.get_solid_rects():
		var x0: float = float(r[0]) * 32.0
		var x1: float = float(r[1]) * 32.0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(maxf(8.0, x1 - x0), WALK_FRONT_Y - WALK_BACK_Y)
		shape.shape = rect
		shape.position = Vector2((x0 + x1) * 0.5, (WALK_BACK_Y + WALK_FRONT_Y) * 0.5)
		body.add_child(shape)
	if body.get_child_count() > 0:
		add_child(body)
