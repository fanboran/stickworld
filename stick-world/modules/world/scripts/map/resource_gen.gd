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

## 生态群落表（2026-09-06 用户重定调）：石头在森林里、密度远低于树
## （很多棵树才一个石头，与树互斥株距=长石头处不长树）；矿（铁/金/钻）
## 更稀疏地藏在林间缝隙。weight=群落出现权重；size=[最少,最多]成员数；
## radius=散布半径（格）；types=[类型, 占比]。
const _COMMUNITY_KINDS: Array = [
	{"weight": 0.88, "size": Vector2i(6, 12), "radius": 4.5,
		"types": [[0, 0.93], [1, 0.07]]},  # 树林：树为主，偶有一块伴生石
	{"weight": 0.08, "size": Vector2i(1, 2), "radius": 1.2,
		"types": [[1, 0.55], [2, 0.25], [3, 0.12], [4, 0.08]]},  # 林间岩块：石为主偶带矿
	{"weight": 0.04, "size": Vector2i(1, 2), "radius": 1.0,
		"types": [[2, 0.45], [3, 0.33], [4, 0.22]]},  # 矿脉露头：稀有
]
## 群落内最小株距（px）：树冠交叠成墙、树干不贴干；石/树互斥同用此距
## （72→64：2026-09-06 密度实收——56 时全图 378 棵超"2 倍"目标过多，
## 64 实测约 2.5-3 倍且树墙感保留）
## var 而非 const：HD-2D 卡的画面宽（含树冠）可达 3 格，64px 间距会互相
## 穿模——宿主按卡宽调大（主街 96）
var MIN_SPACING: float = 64.0

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


## 树林区梯度（用户 2026-09-06：树"略近一段出现"即可 + 稀疏→密集过渡可感知）：
## 距硬化地面（土路带）约半屏（960px）净空，再约 0.75 屏渐密，之外满密度 2×。
## 石/矿同样走梯度（石头在森林里，村庄净空区干净）。
## var 而非 const：小纵深图（HD-2D 主街墙外带仅 28 格）按需压缩梯度档，
## 否则默认净空 30 格 > 带宽会把整带清空。
var FOREST_CLEAR_CELLS := 30    ## 硬化区旁净空（格）
var FOREST_RAMP_CELLS := 45    ## 再 N 格渐密
var FOREST_DENSITY_MULT := 2.0 ## 最密处 = 基线密度的倍数

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


## 每积满这么多毫秒的放置工作就让一帧（与 boot_warmup.TIME_BUDGET_MS 同口径：
## 单次停顿肉眼近无感，同时把让帧开销摊到 ~10%）。
const TIME_BUDGET_MS := 150
## 每块放置节点数上限。放置本身比首绘便宜得多（实测 ~2ms/个 vs 树的 ~20ms/个
## 渲染），只按时间预算会让首块积累到 ~84 个才让帧（那一帧仍 1.6s）；按个数
## 封顶才真正把每帧要首绘的资源点数压下来。两条件取先到者。
const MAX_NODES_PER_CHUNK := 40


## 在指定 cell 范围内按生态群落程序化生成自然资源点（同步版）。
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
	var target: int = _target_count(a, b, density)
	var max_attempts: int = target * 12 + 16
	var attempts: int = 0
	var rows: int = get_terrain_row_count()
	while nodes.size() < target and attempts < max_attempts:
		attempts += 1
		_attempt_community(a, b, rows, road, target, nodes)
	return nodes


## 分块协程版：同一套放置算法，但按「时间预算满」或「本块满 `MAX_NODES_PER_CHUNK`
## 个」让一帧（先到者）——资源点的实例化与首绘（程序化树 `_draw` 的折线网格生成）
## 因此摊到多个较小帧，加载屏在本子阶段不再有一段数秒的整屏定格（vulkan 实测
## 改造前最长单帧 ~9s → 改造后 ~0.9s）。
## on_progress(placed, target)：已放置数/目标数（可空）——供加载屏副进度条。
## 返回生成的 ResourceNode 数组（与同步版同一批节点、同一随机序列）。
func generate_resource_nodes_chunked(start_cell: int, end_cell: int, density: float,
		on_progress: Callable = Callable()) -> Array:
	if _root.decoration_layer == null:
		if on_progress.is_valid():
			on_progress.call(0, 0)
		return []
	var nodes: Array = []
	var a: int = mini(start_cell, end_cell)
	var b: int = maxi(start_cell, end_cell)
	var road := _road_cell_bounds(a, b)
	var target: int = _target_count(a, b, density)
	var max_attempts: int = target * 12 + 16
	var attempts: int = 0
	var rows: int = get_terrain_row_count()
	var last: int = Time.get_ticks_msec()
	var chunk_start: int = 0
	while nodes.size() < target and attempts < max_attempts:
		attempts += 1
		_attempt_community(a, b, rows, road, target, nodes)
		if (nodes.size() - chunk_start >= MAX_NODES_PER_CHUNK
				or Time.get_ticks_msec() - last >= TIME_BUDGET_MS):
			if on_progress.is_valid():
				on_progress.call(nodes.size(), target)
			await _yield_frame()
			last = Time.get_ticks_msec()
			chunk_start = nodes.size()
	if on_progress.is_valid():
		on_progress.call(nodes.size(), target)
	return nodes


## 单次群落尝试：掷群落类型/中心/成员数，成员逐个按规则落位到 `nodes`。
## 同步版与分块版共用同一套放置规则（不维护第二份，行为与随机序列逐位一致）。
func _attempt_community(a: int, b: int, rows: int, road: Vector2i,
		target: int, nodes: Array) -> void:
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
		var cx: int = floori(px / PlacementGrid.CELL_SIZE)
		if cx < a or cx >= b:
			continue
		# 硬化路面/土路上不可能长资源
		if _root.get_terrain_type_at_cell(cx) == _root.TERRAIN_DIRT_ROAD:
			continue
		var rtype0 := _pick_type(kind)
		# 林区梯度：全部资源走同一规则（石/矿在森林里，净空带干净无资源）
		var rate := _forest_rate(cx, road.x, road.y)
		if randf() * FOREST_DENSITY_MULT >= rate:
			continue
		if _too_close(px, py, nodes):
			continue
		var node: Node2D = ScriptResourceNode.new()
		node.resource_type = rtype0
		# 储量按类型：大树给更多木；稀有矿储少而值高
		match rtype0:
			0: node.amount = 150 + randi_range(0, 170)  # WOOD
			1: node.amount = 100 + randi_range(0, 80)   # STONE
			2: node.amount = 80 + randi_range(0, 60)    # METAL
			3: node.amount = 40 + randi_range(0, 30)    # DIAMOND
			_: node.amount = 60 + randi_range(0, 40)    # GOLD
		node.position = Vector2(px, py)
		_root.decoration_layer.add_child(node)
		nodes.append(node)


## 目标资源点数：树权重 0.88 × 2 倍密度 → 总量 ≈1.88×基线（attempts 上限同步
## 放宽，间距 56 后成员放置成功率升，远端能真正填到 2 倍密度）。
func _target_count(a: int, b: int, density: float) -> int:
	return int((b - a) * clampf(density, 0.0, 1.0)
		* (1.0 + (FOREST_DENSITY_MULT - 1.0) * 0.88))


## 等一帧（与 game_root._yield_frame 同口径）：headless 下渲染服务器不绘制帧、
## frame_post_draw 永不发射——不短路则协程在首个让帧点永久挂起（装备/测试卡死）。
func _yield_frame() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
