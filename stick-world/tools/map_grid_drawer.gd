@tool
class_name MapGridDrawer
extends Node2D
## 编辑器网格绘制器 -- 在 2D 编辑器中显示 32px 网格竖线 + 地面线 + 建筑占地高亮。
##
## 挂在 VillageMap 下，读取父节点的 ground_y / ground_bottom / map_right 属性。
## 由 MapEditor 插件设置 ghost_* 属性来高亮建筑将占用的竖条。

## 建筑预览状态（由 EditorPlugin 设置）
var ghost_active: bool = false
var ghost_world_pos: Vector2 = Vector2.ZERO
var ghost_width_cells: int = 1


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		queue_redraw()


func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var parent := get_parent()
	if parent == null or not "ground_y" in parent:
		return
	var ground_y: float = parent.ground_y
	var map_right: float = parent.map_right if "map_right" in parent else 8192.0
	var ground_bottom: float = parent.ground_bottom if "ground_bottom" in parent else 1080.0

	# 网格竖线（每 32px 一条，每 8 格加粗）
	var cell_count: int = int(map_right / 32) + 1
	for x in range(cell_count):
		var c: Color = Color(1, 1, 1, 0.15) if x % 8 != 0 else Color(1, 1, 1, 0.35)
		draw_line(Vector2(x * 32, 0), Vector2(x * 32, ground_bottom), c, 1.0)

	# ground_y 线（黄色）
	draw_line(Vector2(0, ground_y), Vector2(map_right, ground_y), Color(1, 1, 0.2, 0.6), 2.0)
	# ground_bottom 线（青色）
	draw_line(Vector2(0, ground_bottom), Vector2(map_right, ground_bottom), Color(0.2, 1.0, 1.0, 0.4), 1.0)

	# 建筑占地高亮：将鼠标所在位置的建筑占用竖条变白
	if ghost_active and ghost_world_pos != Vector2.ZERO:
		var cell_x: int = int(ghost_world_pos.x / 32)
		var width_px: float = ghost_width_cells * 32.0
		# 白色半透明填充占用区域
		draw_rect(Rect2(cell_x * 32, 0, width_px, ground_bottom), Color(1, 1, 1, 0.35), true)
		# 占用区域边界亮白线
		draw_line(Vector2(cell_x * 32, 0), Vector2(cell_x * 32, ground_bottom), Color(1, 1, 1, 0.9), 2.0)
		draw_line(Vector2(cell_x * 32 + width_px, 0), Vector2(cell_x * 32 + width_px, ground_bottom), Color(1, 1, 1, 0.9), 2.0)

	# 建筑碰撞体标记：白色边框 + 红色下边界线 + 两端向上刻度
	_draw_building_markers(parent)


## 绘制所有建筑的碰撞体标记
func _draw_building_markers(map_root: Node) -> void:
	var tb := _find_node(map_root, "TerrainBuildings")
	if tb == null:
		return
	for building in tb.get_children():
		if not building is Node2D:
			continue
		var pb: Node = building.get_node_or_null("PassageBarrier")
		if pb == null or not pb is Area2D:
			continue
		for child in pb.get_children():
			if child is CollisionShape2D and child.shape is RectangleShape2D:
				var cs: CollisionShape2D = child
				var rs: RectangleShape2D = cs.shape
				var center: Vector2 = building.position + cs.position
				var top: float = center.y - rs.size.y / 2.0
				var bottom: float = center.y + rs.size.y / 2.0
				# 白色边框（碰撞体实际大小）
				var col_left: float = center.x - rs.size.x / 2.0
				var col_right: float = center.x + rs.size.x / 2.0
				draw_rect(Rect2(col_left, top, col_right - col_left, bottom - top), Color(1, 1, 1, 0.5), false, 1.5)
				# 红色下边界横线：按格子数 × 32px 绘制，居中对齐建筑位置
				var width_cells: int = maxi(1, int(round(rs.size.x / 32.0)))
				var footprint_px: float = width_cells * 32.0
				var foot_left: float = building.position.x - footprint_px / 2.0
				var foot_right: float = building.position.x + footprint_px / 2.0
				var red := Color(1.0, 0.2, 0.2, 0.9)
				draw_line(Vector2(foot_left, bottom), Vector2(foot_right, bottom), red, 2.0)
				# 两端向上刻度线
				draw_line(Vector2(foot_left, bottom), Vector2(foot_left, bottom - 20), red, 2.0)
				draw_line(Vector2(foot_right, bottom), Vector2(foot_right, bottom - 20), red, 2.0)


func _find_node(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find_node(child, node_name)
		if found:
			return found
	return null
