extends VillageMap
## 城郊战场（独立区域，12v12 类骨架 + 守城布景）：
##   左侧 8 格宽 FIELD 形态巨墙——从战场地面（地图边缘的地面）垂直延伸到
##   地平线上 5 格的垛口线，横跨整屏高度；巡墙弓箭手贴立面上下往返射击。
##   城门在中，泥路从城门向右延伸一条窄带（中间泥、上下草坪，旧草地贴图）。
##   右端波次敌军（仅守城模式）；地面小队 + 巡墙弓手（仅守城模式布阵）。
##   树稀疏（一屏约两棵，战场障碍物玩法后续挂账）。

const SiegeWallScript := preload("res://modules/world/scripts/map/siege_wall.gd")
const SiegeDirectorScript := preload("res://modules/world/scripts/map/siege_director.gd")

## 城郊战场的进入模式（村A城门选项经 static 传递，读后即清）：
## true=守城战（波次敌军+我方小队），false=自由出城（只有巡墙弓手布防）
static var pending_siege_mode: bool = false

## 巨墙 x（门段中心；墙外即村A城内，视觉同堵墙的另一侧）
@export var field_wall_x: float = 380.0

var _siege_wall: SiegeWall = null


func _ready() -> void:
	super()
	_setup_field()


func _setup_field() -> void:
	# 巨墙（FIELD：墙脚=战场地面带底=地图边缘的地面；垛口线=地平线上 5 格）
	_siege_wall = SiegeWallScript.new()
	_siege_wall.name = "SiegeWallField"
	_siege_wall.form = SiegeWall.Form.FIELD
	_siege_wall.position = Vector2(field_wall_x, ground_y - 5.0 * 32.0)
	_siege_wall.top_y = ground_y - 5.0 * 32.0
	_siege_wall.foot_y = ground_bottom
	add_child(_siege_wall)
	# 泥路：墙脚（城门位，无门洞视觉）→ 向右延伸（窄带：中间泥、上下草）
	if _terrain != null and _terrain.has_method("enable_natural_ground"):
		_terrain.enable_natural_ground()
	if _terrain != null and _terrain.has_method("set_road_range"):
		var band: float = ground_bottom - ground_y
		var mid: float = ground_y + band * 0.5
		_terrain.set_road_range(field_wall_x + 150.0, map_right - 500.0,
				mid - 45.0, mid + 45.0)
	for cx in range(int((field_wall_x + 150.0) / 32.0), int((map_right - 500.0) / 32.0)):
		_terrain_types[cx] = TERRAIN_DIRT_ROAD
	_terrain.update_dirt_road_visual()
	# 稀树（一屏约两棵：密度 ~1棵/960px ≈ 0.033/格；不撒在路上——路 cell 已标 DIRT）
	generate_resource_nodes(int((field_wall_x + 200.0) / 32.0),
			int((map_right - 200.0) / 32.0), 0.03)
	# 守城导演：巡墙弓手常驻；波次/小队按进入模式
	var director: Node = Node.new()
	director.set_script(SiegeDirectorScript)
	director.name = "SiegeDirector"
	director.archer_count = 6
	director.waves_enabled = pending_siege_mode
	director.squad_enabled = pending_siege_mode
	director.city_target_x = field_wall_x + 400.0
	director.wave_trigger_x = -1.0
	pending_siege_mode = false
	add_child(director)
	director.setup(self, _siege_wall)
