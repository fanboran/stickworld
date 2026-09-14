extends MapBase
class_name Hd2dStreetMap
## HD-2D 街景地图 —— 开局主场景（村A 的 HD-2D 语义翻译，2026-09-14 启动直连）。
##
## duck API（spawn_entity/get_entities/元数据 getter）全部继承 MapBase；
## 地图本体是**静态布景**：不实现 save_to_db/load_from_db（SaveHandler 的
## has_method 守卫自动跳过），current_map_id 由 save_meta 正常记录/恢复，
## 实体存取走 MapBase 默认实现（玩家存 entities 表，读档兜底重生成）。
##
## 碰撞：3D 街景的前排建筑/摆件/树木矿物映射成 2D 静态碰撞墙（get_solid_rects），
## 玩家在街上走不会被穿透。出生点 = 街中心前景（get_spawn_point）。
##
## 相机跟随：玩家 x（px）→ 3D 正交相机横移（set_cam_x，1 单位 = 1 格 = 32px），
## 街长铺满村A全域 ±67 格（约 ±2144px）。
##
## 昼夜：2D 链路的 CanvasModulate 够不到 3D 场景——这里直接读 WorldState.game_time
## 推小时数，切换 3D 光照档（set_light_mode("day"/"night")）。
##
## 资源点：3D 街景的树/矿卡是视觉，采集交互复用 2D 的 ResourceNode（同一
## resource_node 组、同一按 F 采集链路）；点位由 3D 侧 get_nature_spawns() 给出，
## ResourceNode 自身视觉隐藏（避免 2D 笔触树叠在 PBR 树卡上）。
##
## 出生村专属设施（运营仓库/村民 NPC）：无 2D 建筑宿主与工作场所，
## supports_village_facilities() 返回 false，GameRoot 门控跳过。
##
## TODO(提炼): 3D 街景场景与卡资产仍在 tests/dev/proto_hd2d（res://temp 产物），
## 正式化时迁入 modules 并改走随包导出路径。

const _HD2D_WORLD_SCENE := preload("res://tests/dev/proto_hd2d/proto_hd2d.tscn")

## 街面行走带的 2D y 范围（建筑墙挡住的后段 + 前景可横穿段）
const WALK_BACK_Y := 688.0
const WALK_FRONT_Y := 1080.0

## 3D 街景横移换算：1 格 = 32px
const CELL_PX := 32.0

## 光照档切换时刻（小时）：6:00 天亮、19:00 入夜
const HOUR_DAY_BREAK := 6.0
const HOUR_NIGHT_FALL := 19.0

## 村民闲逛锚（ai_controller.wander 用；街中心 = 出生点）
var town_center_world_x: float = 0.0

## 前景层（interaction_controller 交互提示挂这里；同 village_map 的暴露方式）
@onready var foreground_layer: Node2D = get_node_or_null("ForegroundLayer") as Node2D

## 3D 街景节点引用（相机/光照档驱动用）
var _hd: Node3D = null
## 当前光照档（避免每帧重复切换）
var _light_mode := ""

const _RESOURCE_TYPE_IDS := {
	"wood": 0, "stone": 1, "metal": 2, "diamond": 3, "gold": 4,
}
## 采集储量中值（resource_gen.gd 的类型区间：木 150-320/石 100-180/铁 80-140/
## 钻 40-70/金 60-100）
const _RESOURCE_AMOUNTS := {
	"wood": 230, "stone": 140, "metal": 110, "diamond": 55, "gold": 80,
}


func _ready() -> void:
	super()
	_hd = _HD2D_WORLD_SCENE.instantiate()
	_hd.name = "HD2DWorld"
	add_child(_hd)
	_build_solid_bodies(_hd)
	_spawn_resource_nodes(_hd)
	_build_exit_triggers()
	_apply_time_of_day(true)


func _process(_delta: float) -> void:
	# 相机横移：跟随附身玩家（正交相机，街景随世界坐标自然卷动）
	var p := get_possessed_entity()
	if p != null and is_instance_valid(p) and _hd != null and _hd.has_method("set_cam_x"):
		_hd.set_cam_x(p.global_position.x / CELL_PX)
	_apply_time_of_day(false)


func get_spawn_point() -> Vector2:
	# 街中心前景：玩家落在画面中下（3D 街景可见区内），正对宅邸地标
	return Vector2(0.0, 1010.0)


## 出生村专属设施（运营仓库/村民 NPC）是否适用本图（GameRoot 门控读）。
## HD-2D 静态布景图无 2D 建筑宿主与工作场所——全跳过（树/矿走自然物卡+资源点）。
func supports_village_facilities() -> bool:
	return false


## 3D 街景的实心区间（格）→ 2D 静态碰撞墙（px）。
## 墙的 y 覆盖行走带后段（建筑/摆件所在），前景 y > WALK_FRONT 段留空可横穿。
func _build_solid_bodies(hd: Node3D) -> void:
	if not hd.has_method("get_solid_rects"):
		return
	var body := StaticBody2D.new()
	body.name = "HD2DSolids"
	for r: Variant in hd.get_solid_rects():
		var x0: float = float(r[0]) * CELL_PX
		var x1: float = float(r[1]) * CELL_PX
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(maxf(8.0, x1 - x0), WALK_FRONT_Y - WALK_BACK_Y)
		shape.shape = rect
		shape.position = Vector2((x0 + x1) * 0.5, (WALK_BACK_Y + WALK_FRONT_Y) * 0.5)
		body.add_child(shape)
	if body.get_child_count() > 0:
		add_child(body)


## 采集资源点：点位/类型来自 3D 摆位表（get_nature_spawns），
## 视觉由 PBR 自然物卡承担——ResourceNode 自身的 2D 笔触画隐藏。
func _spawn_resource_nodes(hd: Node3D) -> void:
	if not hd.has_method("get_nature_spawns"):
		return
	var host: Node2D = get_node_or_null("EntityHost") as Node2D
	for s: Variant in hd.get_nature_spawns():
		var type_name: String = str(s["type"])
		var type_id: int = int(_RESOURCE_TYPE_IDS.get(type_name, -1))
		if type_id < 0:
			continue
		var node := ResourceNode.new()
		node.resource_type = type_id
		node.amount = int(_RESOURCE_AMOUNTS.get(type_name, 100))
		node.position = s["pos"]
		if host != null:
			host.add_child(node)
		else:
			add_child(node)
		# 隐藏 2D 笔触视觉（PBR 卡负责观感）；调试标签等行为子节点保留
		for c in node.get_children():
			if c is Node2D:
				(c as Node2D).visible = false


## 东西村口出口触发器（语义对齐村A旅行链：东出上路去 B 村方向、西出原野）。
## 触发区压在地图边界内侧一条（玩家走到村口即切图）。
func _build_exit_triggers() -> void:
	var triggers_host := Node2D.new()
	triggers_host.name = "ChunkTriggers"
	add_child(triggers_host)
	var specs := [
		{"name": "ExitLeft", "x": map_left + 48.0, "target": "road_a_b",
		 "entry": WorldAPI.EntrySide.LEFT},
		{"name": "ExitRight", "x": map_right - 48.0, "target": "battlefield",
		 "entry": WorldAPI.EntrySide.RIGHT},
	]
	for spec: Dictionary in specs:
		var trig := ChunkTrigger.new()
		trig.name = str(spec["name"])
		trig.target_map_id = str(spec["target"])
		trig.target_entry_side = int(spec["entry"])
		trig.trigger_width = 96.0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(96.0, WALK_FRONT_Y - WALK_BACK_Y)
		shape.shape = rect
		shape.position = Vector2(float(spec["x"]), (WALK_BACK_Y + WALK_FRONT_Y) * 0.5)
		trig.add_child(shape)
		triggers_host.add_child(trig)


## 昼夜挂钩：WorldState.game_time 单位即**小时（0~24，EnvironmentSystem 写入）**
## → 3D 光照档。只在档位变化时切换（_apply_light 幂等但不必每帧调）。
## force = 启动时立即对齐一次。
func _apply_time_of_day(force: bool) -> void:
	var hour: float = fposmod(WorldState.game_time, 24.0)
	var mode := "day"
	if hour < HOUR_DAY_BREAK or hour >= HOUR_NIGHT_FALL:
		mode = "night"
	if mode == _light_mode and not force:
		return
	_light_mode = mode
	if _hd != null and _hd.has_method("set_light_mode"):
		_hd.set_light_mode(mode)
