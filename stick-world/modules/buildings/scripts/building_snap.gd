@tool
extends Building
## 建筑编辑器吸附脚本 + Building 室内系统（§5）。
## 挂在建筑场景根节点上，在编辑器中拖动建筑时：
## - X 吸附到 32px 网格
## - Y 吸附到碰撞体下边界对齐草地中线
## 运行时继承 Building 的全部方法（透明化、工作位、状态机等）。

const CELL_SIZE := 32

## 是否正在执行吸附（防止递归）
var _snapping := false


func _ready() -> void:
	if not Engine.is_editor_hint():
		super()  # 调用 Building._ready() -> _lookup_children() + _apply_state_visual()
	set_notify_local_transform(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED and Engine.is_editor_hint() and not _snapping:
		_snap_position()


func _snap_position() -> void:
	if _snapping:
		return
	_snapping = true

	var map_root := _find_map_root(get_parent())
	if map_root == null:
		_snapping = false
		return

	var ground_y: float = map_root.get("ground_y") if "ground_y" in map_root else 810.0
	var ground_bottom: float = map_root.get("ground_bottom") if "ground_bottom" in map_root else 1080.0
	var midline: float = (ground_y + ground_bottom) / 2.0

	# X 吸附到 32px 网格
	var snapped_x: float = roundf(position.x / CELL_SIZE) * CELL_SIZE

	# Y 吸附：碰撞体下边界对齐草地中线
	# 碰撞体下边界(世界坐标) = building.y + CollisionShape2D.position.y + shape.size.y / 2
	# 要让它 = midline，所以 building.y = midline - CollisionShape2D.position.y - shape.size.y / 2
	var collision_bottom_local := _get_collision_bottom_local()
	var snapped_y: float = midline - collision_bottom_local

	if abs(snapped_x - position.x) > 0.5 or abs(snapped_y - position.y) > 0.5:
		position = Vector2(snapped_x, snapped_y)

	_snapping = false


## 获取碰撞体下边界相对于建筑原点的 Y 偏移
## = CollisionShape2D.position.y + shape.size.y / 2
func _get_collision_bottom_local() -> float:
	var pb := get_node_or_null("PassageBarrier")
	if pb == null:
		return 0.0
	for child in pb.get_children():
		if child is CollisionShape2D and child.shape is RectangleShape2D:
			return child.position.y + child.shape.size.y / 2.0
	return 0.0


func _find_map_root(node: Node) -> Node:
	while node != null:
		if "ground_y" in node:
			return node
		node = node.get_parent()
	return null
