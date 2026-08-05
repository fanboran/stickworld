extends Node
## 村落地图资源点生成器 —— 垂直地形网格与程序化自然资源点。
##
## 职责：
## - 垂直格子行数计算（ground_y ~ ground_bottom 按 32px 分行）
## - 指定 cell 内随机 Y 位置采样
## - 程序化生成自然资源点（木材/石料/铁矿，跳过土路）
##
## 由 VillageMap._ready 挂载为 ResourceGen 子节点并调用 setup(root)，
## VillageMap 的 generate_resource_nodes 等公开方法转发到本组件。

## 垂直格子大小（与水平 CELL_SIZE 一致，32px）
const TERRAIN_CELL_SIZE_Y: float = 32.0
const ScriptResourceNode := preload("res://modules/world/scripts/map/resource_node.gd")

var _root: Node2D = null


func setup(root: Node2D) -> void:
	_root = root


## 获取地面垂直行数（ground_y ~ ground_bottom 之间按 32px 分行）
func get_terrain_row_count() -> int:
	return maxi(1, int((_root.ground_bottom - _root.ground_y) / TERRAIN_CELL_SIZE_Y))


## 在指定 cell_x 的地面上生成随机 Y 位置（垂直网格内随机行）
func random_resource_y(_cell_x: int) -> float:
	var rows: int = get_terrain_row_count()
	var row: int = randi() % rows
	return _root.ground_y + row * TERRAIN_CELL_SIZE_Y + TERRAIN_CELL_SIZE_Y * 0.5


## 在指定 cell 范围内程序化生成自然资源点。
## start_cell / end_cell: cell_x 范围
## density: 每格资源点概率（0.0~1.0）
## 返回生成的 ResourceNode 数组
func generate_resource_nodes(start_cell: int, end_cell: int, density: float) -> Array:
	if _root.decoration_layer == null:
		return []
	var nodes: Array = []
	# 保证 start <= end，避免调用端传反范围
	var a: int = mini(start_cell, end_cell)
	var b: int = maxi(start_cell, end_cell)
	for cx in range(a, b):
		# 硬化路面/土路上不可能长资源
		if _root.get_terrain_type_at_cell(cx) == _root.TERRAIN_DIRT_ROAD:
			continue
		if randf() > density:
			continue
		# 资源类型权重：WOOD 55% / STONE 35% / METAL 10%（树林密、石头次之、铁矿稀有）
		var r: float = randf()
		var rtype: int
		if r < 0.55:
			rtype = 0  # WOOD
		elif r < 0.9:
			rtype = 1  # STONE
		else:
			rtype = 2  # METAL
		var node: Node2D = ScriptResourceNode.new()
		node.resource_type = rtype
		node.amount = 50 + randi() % 100
		var px: float = cx * PlacementGrid.CELL_SIZE + PlacementGrid.CELL_SIZE * 0.5
		var py: float = random_resource_y(cx)
		node.position = Vector2(px, py)
		_root.decoration_layer.add_child(node)
		nodes.append(node)
	return nodes
