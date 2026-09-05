extends VillageMap
## 守城战地图 —— 在战场骨架上追加城防布景：
##   中部城镇硬地皮（fbm 参差边界）→ 泥土路向右延伸（shader 路带，进硬地皮渐隐）
##   → 右侧石砖城墙+城门（正侧视立面，垛口平台站弓箭手）→ 右端敌军波次入场。
##
## 相比 battlefield：右侧不再撒资源点（树林退位给城墙），改由 SiegeDirector
## 从右端持续刷进攻方。地形自然化走 TerrainRenderer 的 natural_edge 路径。

const SiegeWallScript := preload("res://modules/world/scripts/map/siege_wall.gd")
const SiegeDirectorScript := preload("res://modules/world/scripts/map/siege_director.gd")

# ───────────────────────── 守城布景参数（世界坐标 px）─────────────────────────
## 城镇硬地皮范围（中部）
@export var city_left: float = 1500.0
@export var city_right: float = 3400.0
## 泥土路带（硬地皮右缘 → 城墙脚）
@export var road_left: float = 3350.0
@export var road_right: float = 5360.0
## 城墙（墙脚线中心 x；墙体向两侧展开 total_width）
@export var wall_x: float = 5460.0
@export var wall_width: float = 1400.0
## 墙脚 y（地面带内：立在地平线上会整墙沉到屏幕外，弓箭手也看不到；
## 放玩家活动带上方 ~ground_y+430，正侧视立面朝左右两侧）
@export var wall_foot_y: float = 980.0
## 弓箭手数
@export var garrison_archers: int = 4

var _siege_wall: SiegeWall = null


func _ready() -> void:
	super()
	_setup_siege_scenery()


func _setup_siege_scenery() -> void:
	# 地形自然化：硬地皮参差边界 + shader 泥土路带（替换纯色多边形观感）。
	# 路带 y 窗=踩踏带（草地上中间踩出一条，不是整带土）
	if _terrain != null:
		if _terrain.has_method("enable_natural_ground"):
			_terrain.enable_natural_ground()
		if _terrain.has_method("set_road_range"):
			_terrain.set_road_range(road_left, road_right,
					ground_y + 120.0, ground_y + 620.0)
	# 数据层土路（移动速度 1.0 + 资源点净空）与 shader 路带同范围
	var start_cell := int(road_left / 32.0)
	var end_cell := int(road_right / 32.0)
	for cx in range(start_cell, end_cell):
		_terrain_types[cx] = TERRAIN_DIRT_ROAD
	_terrain.update_dirt_road_visual()
	set_city_bounds(city_left, city_right)
	# 城墙：墙脚落在地面带内（正侧视立面，垛口平台可站弓箭手）
	_siege_wall = SiegeWallScript.new()
	_siege_wall.name = "SiegeWall"
	_siege_wall.total_width = wall_width
	_siege_wall.has_gate = true
	_siege_wall.position = Vector2(wall_x, wall_foot_y)
	add_child(_siege_wall)
	# 守城导演：弓箭手上墙 + 右端波次刷敌
	var director: Node = Node.new()
	director.set_script(SiegeDirectorScript)
	director.name = "SiegeDirector"
	director.archer_count = garrison_archers
	add_child(director)
	director.setup(self, _siege_wall)


## 右段不撒资源点（树林退位给城墙）：收窄撒点范围并在城墙带前截断。
func generate_resource_nodes(start_cell: int, end_cell: int, density: float) -> Array:
	var wall_cell := int((wall_x - wall_width * 0.5 - 260.0) / 32.0)
	var nodes: Array = super(start_cell, mini(end_cell, wall_cell), density)
	return nodes
