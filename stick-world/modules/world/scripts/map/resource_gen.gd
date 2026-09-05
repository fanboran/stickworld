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

## 生态群落表：按群落生成而非逐格均匀撒点（树成林、石成场、铁矿成露头）。
## weight=群落出现权重；size=[最少,最多]成员数；radius=散布半径（格）；
## types=[类型, 占比]——群落内同生态为主、自然混生少量伴生种。
const _COMMUNITY_KINDS: Array = [
	{"weight": 0.55, "size": Vector2i(5, 10), "radius": 4.5,
		"types": [[0, 0.85], [1, 0.15]]},  # 树林：树为主夹零星岩石
	{"weight": 0.30, "size": Vector2i(3, 6), "radius": 2.2,
		"types": [[1, 0.80], [0, 0.20]]},  # 石场：岩石为主夹零星树
	{"weight": 0.15, "size": Vector2i(2, 4), "radius": 1.8,
		"types": [[2, 0.70], [1, 0.30]]},  # 铁矿露头：稀有，伴生岩石
]
## 群落内最小株距（px）：树冠交叠成墙、树干不贴干（树显示 500px 宽冠）
const MIN_SPACING: float = 72.0

var _root: Node2D = null


func setup(root: Node2D) -> void:
	_root = root


## 获取地面垂直行数（ground_y ~ ground_bottom 之间按 32px 分行）
func get_terrain_row_count() -> int:
	return maxi(1, int((_root.ground_bottom - _root.ground_y) / TERRAIN_CELL_SIZE_Y))


## 在指定 cell_x 的地面上生成随机 Y 位置（垂直网格内随机行）
func random_resource_y(_cell_x: int) -> float:
	var rows: int = get_terrain_row_count()
	var row: int = randi_range(0, maxi(0, rows - 1))
	return _root.ground_y + row * TERRAIN_CELL_SIZE_Y + TERRAIN_CELL_SIZE_Y * 0.5


## Box-Muller 标准正态采样（群落散布"中心密边缘疏"用）
func _gauss() -> float:
	var u1 := maxf(randf(), 0.0001)
	var u2 := randf()
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)


## 按权重随机挑一个群落类型
func _pick_community() -> Dictionary:
	var total: float = 0.0
	for k in _COMMUNITY_KINDS:
		total += float(k["weight"])
	var roll: float = randf() * total
	for k in _COMMUNITY_KINDS:
		roll -= float(k["weight"])
		if roll <= 0.0:
			return k
	return _COMMUNITY_KINDS[_COMMUNITY_KINDS.size() - 1]


## 群落内按占比掷资源类型
func _pick_type(kind: Dictionary) -> int:
	var roll: float = randf()
	for pair in kind["types"]:
		roll -= float(pair[1])
		if roll <= 0.0:
			return int(pair[0])
	return int(kind["types"][0][0])


## 与已放置资源点间距检查（同父节点局部坐标比较）
func _too_close(px: float, py: float, nodes: Array) -> bool:
	var pos := Vector2(px, py)
	for n in nodes:
		if (n as Node2D).position.distance_to(pos) < MIN_SPACING:
			return true
	return false


## 树林区梯度（用户 2026-09-06）：距硬化地面（土路带）一个屏幕（1920px）内不长树，
## 再花一个屏幕从稀疏渐密，之外达到基线 2 倍密度（森林感）。石/铁不受限。
const FOREST_CLEAR_CELLS := 60    ## 1920px / 32px：硬化区旁净空（一屏）
const FOREST_RAMP_CELLS := 60    ## 再 60 格（又一屏）渐密
const FOREST_DENSITY_MULT := 2.0 ## 最密处 = 基线密度的倍数

## 该 cell 的树密度倍率（0 = 不长树；FOREST_DENSITY_MULT = 满密度）
func _forest_rate(cell_x: int, road_min: int, road_max: int) -> float:
	if road_min > road_max:
		return FOREST_DENSITY_MULT  # 无硬化区（异常兜底）：不限制
	var dist: int = maxi(maxi(road_min - cell_x, cell_x - road_max), 0)
	if dist <= FOREST_CLEAR_CELLS:
		return 0.0
	var ramp: float = clampf(
		float(dist - FOREST_CLEAR_CELLS) / float(FOREST_RAMP_CELLS), 0.0, 1.0)
	return ramp * FOREST_DENSITY_MULT


## 扫描 cell 范围内的土路带边界（硬化区），供林区梯度用
func _road_cell_bounds(a: int, b: int) -> Vector2i:
	var lo := 1 << 30
	var hi := -(1 << 30)
	for cx in range(a, b):
		if _root.get_terrain_type_at_cell(cx) == _root.TERRAIN_DIRT_ROAD:
			lo = mini(lo, cx)
			hi = maxi(hi, cx)
	return Vector2i(lo, hi)


## 在指定 cell 范围内按生态群落程序化生成自然资源点。
## start_cell / end_cell: cell_x 范围
## density: 期望密度（0.0~1.0，语义=每格期望资源数，与旧逐格概率版总量一致）
## 返回生成的 ResourceNode 数组
func generate_resource_nodes(start_cell: int, end_cell: int, density: float) -> Array:
	if _root.decoration_layer == null:
		return []
	var nodes: Array = []
	# 保证 start <= end，避免调用端传反范围
	var a: int = mini(start_cell, end_cell)
	var b: int = maxi(start_cell, end_cell)
	var road := _road_cell_bounds(a, b)
	# target 扩容：树权重 0.55 × 2 倍密度 → 总量 ≈1.55×基线（石/铁供给率不变，
	# 近区树被梯度全拒时由 attempts 上限自然收口，不会灌满石/铁）
	var target: int = int((b - a) * clampf(density, 0.0, 1.0)
		* (1.0 + (FOREST_DENSITY_MULT - 1.0) * 0.55))
	var max_attempts: int = target * 8 + 16
	var attempts: int = 0
	var rows: int = get_terrain_row_count()
	while nodes.size() < target and attempts < max_attempts:
		attempts += 1
		var kind := _pick_community()
		# 群落中心：x 全范围随机，y 随机行起步（纵深聚拢成片）
		var center_px: float = (a + randf() * (b - a)) * PlacementGrid.CELL_SIZE
		var center_row: int = randi_range(0, maxi(0, rows - 1))
		var count: int = randi_range(kind["size"].x, kind["size"].y)
		for i in count:
			if nodes.size() >= target:
				break
			# 群落内高斯散布：中心密、边缘疏，树影交叠自然成林
			var px: float = center_px + _gauss() * float(kind["radius"]) * PlacementGrid.CELL_SIZE
			var row: int = clampi(center_row + int(round(_gauss() * 1.4)), 0, maxi(0, rows - 1))
			var py: float = _root.ground_y + row * TERRAIN_CELL_SIZE_Y + TERRAIN_CELL_SIZE_Y * 0.5
			var cx: int = int(px / PlacementGrid.CELL_SIZE)
			if cx < a or cx >= b:
				continue
			# 硬化路面/土路上不可能长资源
			if _root.get_terrain_type_at_cell(cx) == _root.TERRAIN_DIRT_ROAD:
				continue
			var rtype0 := _pick_type(kind)
			# 树受林区梯度约束：距硬化区一屏净空 → 一屏渐密 → 满密度 2×基线
			if rtype0 == 0:
				var rate := _forest_rate(cx, road.x, road.y)
				if randf() * FOREST_DENSITY_MULT >= rate:
					continue
			if _too_close(px, py, nodes):
				continue
			var node: Node2D = ScriptResourceNode.new()
			var rtype := rtype0
			node.resource_type = rtype
			# 储量按类型：大树给更多木（树变高变大后单株价值同步提升）
			match rtype:
				0: node.amount = 150 + randi_range(0, 170)  # WOOD
				1: node.amount = 100 + randi_range(0, 80)   # STONE
				_: node.amount = 80 + randi_range(0, 60)    # METAL
			node.position = Vector2(px, py)
			_root.decoration_layer.add_child(node)
			nodes.append(node)
	return nodes
