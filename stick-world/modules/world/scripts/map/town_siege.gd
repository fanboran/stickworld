extends VillageMap
## 家园守城布景（村A 城内）：
##   左右各一段 8 格宽城墙门段（TOWN 形态：城内地面高，只见立面+垛口，无上表面）
##   → 地图边界收窄到两墙外缘（出村只能走城门交互，不再走到屏幕尽头切图）
##   → 右墙前触发线弹"出城选项"（玩家头顶）：开守城战(Demo) / 出城逛战场 / 去隔壁地区
##   → 引路泥带从城镇硬化右缘连到右墙门前（同材质自然衔接）
## 树：城镇硬化区右侧一律净空（树林退位给城墙）；左侧森林保留。

const SiegeWallScript := preload("res://modules/world/scripts/map/siege_wall.gd")
const GatePromptScript := preload("res://modules/world/scripts/map/siege_gate_prompt.gd")

## 城镇硬化区（=出生土路范围，game_root set_dirt_road_range 会重设同值）
@export var city_left: float = -1280.0
@export var city_right: float = 1280.0
## 左右城墙门段中心 x
@export var left_wall_x: float = -1900.0
@export var right_wall_x: float = 1900.0
## 出城选项触发线（硬化右缘 + 约半屏）
@export var gate_prompt_x: float = 1600.0


func _ready() -> void:
	super()
	_setup_town_siege()


func _setup_town_siege() -> void:
	# 城墙（TOWN 形态：垛口线 = 地平线上 5 格；墙脚落城内地面带内偏下）
	var top_line: float = ground_y - 5.0 * 32.0
	var foot: float = ground_y + 230.0
	for wx: float in [left_wall_x, right_wall_x]:
		var wall: SiegeWall = SiegeWallScript.new()
		wall.name = "SiegeWallLeft" if wx < 0.0 else "SiegeWallRight"
		wall.form = SiegeWall.Form.TOWN
		wall.position = Vector2(wx, top_line)
		wall.top_y = top_line
		wall.foot_y = foot
		add_child(wall)
	# 地图边界收窄到墙外缘（出门=走交互，不再走到屏幕尽头）
	map_left = left_wall_x - 260.0
	map_right = right_wall_x + 260.0
	if placement_grid != null:
		placement_grid.expand_to(int(map_left / 32.0))
		placement_grid.expand_to(int(map_right / 32.0))
	_update_ground_polygon()
	# 引路泥带：硬化右缘 → 右墙门前（同材质渐隐衔接，数据层全速+净空）
	if _terrain != null and _terrain.has_method("set_road_range"):
		var band: float = ground_bottom - ground_y
		_terrain.set_road_range(city_right - 60.0, right_wall_x - 150.0,
				ground_y + band * 0.28, ground_y + band * 0.72)
	for cx in range(int((city_right - 60.0) / 32.0), int((right_wall_x - 150.0) / 32.0)):
		_terrain_types[cx] = TERRAIN_DIRT_ROAD
	# 出城选项（玩家头顶）
	var prompt: Node = GatePromptScript.new()
	prompt.name = "GatePrompt"
	prompt.gate_prompt_x = gate_prompt_x
	add_child(prompt)
	prompt.setup(self)


## 树：城镇硬化区右侧一律不撒（右侧树林退位给城墙；左侧森林保留）。
func generate_resource_nodes(start_cell: int, end_cell: int, density: float) -> Array:
	var clear_cell := int((city_right + 260.0) / 32.0)
	return super(start_cell, mini(end_cell, clear_cell), density)
