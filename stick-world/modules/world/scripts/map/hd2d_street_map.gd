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

## 街面行走带的 2D y 范围（建筑墙挡住的后段 + 前景可横穿段）。
## 前端 = 3D 街面的可见近沿（z_near = 天际线基线 + 视高/3/sin26° = 18.93 格，
## 构图契约"地面占屏幕下 1/3"）——屏幕底沿、2D ground_bottom（蓝线）、
## 可行走深度三点合一，整条可见街面都能走。
const WALK_BACK_Y := 688.0
const WALK_FRONT_Y := 1294.0

## 3D 街景横移换算：1 格 = 32px
const CELL_PX := 32.0

## 光照档切换时刻（小时）：6:00 天亮、19:00 入夜
const HOUR_DAY_BREAK := 6.0
const HOUR_NIGHT_FALL := 19.0

## 村民闲逛锚（ai_controller.wander 用；街中心 = 出生点）
var town_center_world_x: float = 0.0

## 布局驱动模式（city_layout 算法村）：非空时 3D 场景按
## tex/hd2d_layouts/<名>.json 摆街；空 = 手摆主街。村B 等算法村用。
@export var layout_name: String = ""

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
	# 屏幕下边界（CameraRig ground_bottom，即 F3 地面蓝线）钉在 3D 街面的
	# 可见近沿上——与 3D 相机缩放锚线同一世界线，2D/3D 底沿逐像素重合
	ground_bottom = WALK_FRONT_Y
	# 注册 2D 特效坐标重映射器（FxLibrary.remap_pos 读此组）：HD-2D 图的地面
	# 受俯角前缩，飘字/粒子按 2D y 直绘会飘在半空，须压到 3D 投影同一地面线
	add_to_group("fx_pos_remapper")
	# 注册城门引导路由器（BehaviorHarvest 读此组）：村民采集直线 steering 遇
	# 城墙时，经 gate_steer_point 引导从门洞出/入城
	add_to_group("gate_router")
	_hd = _HD2D_WORLD_SCENE.instantiate()
	_hd.name = "HD2DWorld"
	if not layout_name.is_empty():
		_hd.set("layout_name", layout_name)
	add_child(_hd)
	_apply_layout_bounds()
	# 角色（玩家/NPC）渲染进 3D 场景：逻辑仍在 2D（物理/输入/AI 不动），
	# 视觉走 proto 的 billboard 通道——写深度、可被前景遮挡、自带接地影
	if _hd.has_method("enable_play_characters"):
		_hd.enable_play_characters()
	_build_solid_bodies(_hd)
	_spawn_resource_nodes(_hd)
	_build_exit_triggers()
	_apply_time_of_day(true)


func _process(_delta: float) -> void:
	# 3D 相机镜像 2D CameraRig：1/4 区域跟随、顶栏"居中"开关、边缘滚动、
	# 中键拖拽/滚轮缩放全部在 CameraRig 上驱动，3D 侧只镜像 x（正交 1:1）。
	var cam2d := get_viewport().get_camera_2d()
	if cam2d != null and _hd != null:
		if _hd.has_method("set_cam_x"):
			_hd.set_cam_x(cam2d.global_position.x / CELL_PX)
		if _hd.has_method("set_cam_zoom"):
			# CameraRig 的 zoom = base_zoom(分辨率适配) × user_zoom(玩家滚轮)。
			# 3D 侧只认玩家缩放：base_zoom 已经把"世界像素/屏幕像素"归一，
			# 不除掉它，换分辨率后 3D 构图整体错一档（默认缩放按绝对像素算）。
			var base: float = float(cam2d.get("base_zoom")) if "base_zoom" in cam2d else 1.0
			_hd.set_cam_zoom(cam2d.zoom.x / maxf(base, 0.001))   # 滚轮缩放同步，防两套相机脱钩
	_sync_character_render()
	_apply_time_of_day(false)


## 角色 → 3D billboard 渲染同步（HD-2D 最佳实践层）。
## 2D 实体只做逻辑（物理/输入/AI），RigHost 2D 视觉隐藏；
## 每实体一个 char_host（SubViewport billboard），逐帧镜像 x/z + 朝向 + 动画。
## 纵深缩放由 char 侧 depth 承担（近大远小）。
var _char_map: Dictionary = {}   # 实体 instance_id -> char_host(Node3D)

func _sync_character_render() -> void:
	if _hd == null or not _hd.has_method("spawn_character"):
		return
	var alive: Dictionary = {}
	for e in get_entities():
		if e is not Node2D or not is_instance_valid(e):
			continue
		var body := e as Node2D
		var rig_host := body.get_node_or_null("RigHost") as Node2D
		if rig_host == null:
			continue
		var id: int = e.get_instance_id()
		var ch: Node3D = _char_map.get(id)
		if ch == null or not is_instance_valid(ch):
			ch = _hd.spawn_character()
			_char_map[id] = ch
			# 关 2D 侧视觉（骨架 + 2D 接触影），渲染交给 3D billboard
			rig_host.visible = false
			var sh2d := body.get_node_or_null("ContactShadow") as Node2D
			if sh2d != null:
				sh2d.visible = false
		alive[id] = ch
		# possessed 玩家：脚下四角框走 3D（与 billboard 同空间同相机，
		# 速度位置天然一致；2D 画布框在 HD-2D 图上会与角色脱钩）
		if ch.has_method("set_bracket_visible"):
			ch.set_bracket_visible(e.has_method("is_possessed") and e.is_possessed())
		# y 行走带 → 3D 纵深 z（道具/树的 z 同一映射，遮挡关系自动正确）；
		# 线性格 1 格 = 32px——行走带前端即 3D 屏幕底沿锚线（z_near）
		var z: float = (body.position.y - DEPTH_Y_MIN) / CELL_PX
		var vel: Vector2 = (body as CharacterBody2D).velocity if body is CharacterBody2D else Vector2.ZERO
		var moving: bool = vel.length_squared() > 25.0
		if ch.has_method("set_world_pos"):
			ch.set_world_pos(body.position.x / CELL_PX, z,
					int(body.get("_facing")) < 0,
					lerpf(DEPTH_SCALE_MIN, DEPTH_SCALE_MAX,
							clampf((body.position.y - DEPTH_Y_MIN) / (DEPTH_Y_MAX - DEPTH_Y_MIN), 0.0, 1.0)))
		if ch.has_method("set_anim"):
			ch.set_anim("walk" if moving else "idle")
		# 武器/工具镜像：2D 骨架已隐藏，武器须挂进 billboard 内部骨架
		# （职业识别走武器——工具不渲染 = 村民"没有职业"的观感）
		var mount: Variant = body.get("weapon_mount")
		if mount != null and is_instance_valid(mount) and ch.has_method("set_weapon_type"):
			ch.set_weapon_type(int(mount.get("weapon_type")))
	# 清理已消失实体（死亡/切图）
	for id in _char_map.keys():
		if not alive.has(id):
			var ch: Node3D = _char_map[id]
			if ch != null and is_instance_valid(ch):
				ch.queue_free()
			_char_map.erase(id)


## 纵深融入（HD-2D 最佳实践第一层）：行走带 y → 实体视觉近大远小 + 接地感。
## 只缩 RigHost（视觉骨架），不碰碰撞体；实体体型缩放（_apply_scale）是稀有
## 事件，其结果会被本帧 base+depth 重建覆盖——以 meta 记录的基准为准。
const DEPTH_Y_MIN := 688.0
const DEPTH_Y_MAX := WALK_FRONT_Y
const DEPTH_SCALE_MIN := 0.92
const DEPTH_SCALE_MAX := 1.10

func _apply_depth_visual() -> void:
	for e in get_entities():
		if e is not Node2D or not is_instance_valid(e):
			continue
		var rig := (e as Node2D).get_node_or_null("RigHost") as Node2D
		if rig == null:
			continue
		if not e.has_meta("hd2d_base_rig_scale"):
			e.set_meta("hd2d_base_rig_scale", rig.scale)
		var t: float = clampf(((e as Node2D).position.y - DEPTH_Y_MIN) / (DEPTH_Y_MAX - DEPTH_Y_MIN), 0.0, 1.0)
		var k: float = lerpf(DEPTH_SCALE_MIN, DEPTH_SCALE_MAX, t)
		rig.scale = (e.get_meta("hd2d_base_rig_scale") as Vector2) * k


func get_spawn_point() -> Vector2:
	# 街中心前景：玩家落在画面中下（3D 街景可见区内）。
	# 布局驱动模式与手摆模式都以 0 为街中心（导出器已把布局 x 中心化）。
	return Vector2(0.0, 1010.0)


## 布局驱动模式：按布局街宽收地图边界（±半宽 + 8 格余量），覆盖 tscn 默认值。
func _apply_layout_bounds() -> void:
	if layout_name.is_empty() or _hd == null or not _hd.has_method("get_layout_width"):
		return
	var w: float = _hd.get_layout_width()
	if w <= 0.0:
		return
	var half_px: float = (w * 0.5 + 8.0) * CELL_PX
	map_left = -half_px
	map_right = half_px


## 出生村专属的 2D 建筑设施（运营仓库/2D 资源点生成）是否适用本图。
## HD-2D 街无 2D 建筑宿主——仓库/程序化资源点跳过（树/矿走自然物卡）。
## 村民 NPC 单独由 wants_villager_npcs() 门控（主街要有人干活）。
func supports_village_facilities() -> bool:
	return false


## 是否生成村民 NPC（主街要有人劳作：伐木/采矿在资源点、铁匠在露天铁砧）
func wants_villager_npcs() -> bool:
	return true


## 村民落脚点（按主街语义分配，配比 professions：铁匠1/伐木3/矿工3/待业3）：
## 0 号 = 露天铁砧旁（铁匠），1~6 = 西城门内侧（伐木/矿工由此出城去墙外
## 森林带劳作，采集引导走 gate_steer_point），7~9 = 街市/东段（待业闲逛）。
func get_npc_spawn_points() -> Array:
	var pts: Array = [
		Vector2(-16.6 * CELL_PX, 1010.0),  # 铁砧旁（前方路面，避铁砧碰撞带）
		Vector2(-55.0 * CELL_PX, 1010.0),  # 西城门内侧（出城砍树/采矿）
		Vector2(-52.0 * CELL_PX, 1040.0),
		Vector2(-48.5 * CELL_PX, 1020.0),
		Vector2(-45.0 * CELL_PX, 1050.0),
		Vector2(-41.5 * CELL_PX, 1030.0),
		Vector2(-38.0 * CELL_PX, 1050.0),
		Vector2(-6.0 * CELL_PX, 1000.0),   # 市集广场
		Vector2(2.0 * CELL_PX, 1030.0),
		Vector2(30.0 * CELL_PX, 990.0),    # 谷仓前
	]
	return pts


## 3D 脚下四角框声明（SelectionSystem 读到后跳过 2D 画布框）
func wants_3d_bracket() -> bool:
	return true


## 2D 特效/坐标重映射（fx_pos_remapper 组协议）：2D 世界 y → 3D 投影呈现的
## 同一地面线。y=1080（前缘）不动，纵深越深压缩越多（俯角前缩率由 3D 侧
## get_ground_squash 给出）——飘字/粒子由此与角色 feet 对齐。
func remap_fx_pos(pos: Vector2) -> Vector2:
	if _hd == null or not _hd.has_method("get_ground_squash"):
		return pos
	var k: float = float(_hd.get_ground_squash())
	return Vector2(pos.x, WALK_FRONT_Y - (WALK_FRONT_Y - pos.y) * k)


## 城门引导点（gate_router 组协议，BehaviorHarvest 消费）：直线 steering 的
## 采集村民遇城墙时，引导其先走到门洞口（墙内侧 1 格、y 对齐门洞中心），
## 站到门口后直线不再被门洞带外的墙挡住，恢复直走。返回 Vector2.ZERO =
## 无需引导（不跨墙线 / 跨越点已落在门洞带内）。
func gate_steer_point(from: Vector2, to: Vector2) -> Vector2:
	if _hd == null or not _hd.has_method("get_gates"):
		return Vector2.ZERO
	for g: Variant in _hd.get_gates():
		var gx: float = float(g["x"]) * CELL_PX
		var y0: float = float(g["y0"])
		var y1: float = float(g["y1"])
		if (from.x - gx) * (to.x - gx) >= 0.0:
			continue   # 不跨这条墙线
		if absf(to.x - from.x) < 0.001:
			continue
		var t: float = (gx - from.x) / (to.x - from.x)
		var y_cross: float = from.y + (to.y - from.y) * t
		if y_cross >= y0 and y_cross <= y1:
			continue   # 正对门洞，直走即穿
		var side: float = signf(gx - from.x)   # 门洞口在墙的哪一侧（墙内）
		return Vector2(gx - side * CELL_PX, (y0 + y1) * 0.5)
	return Vector2.ZERO


## F3 调试可视化：把 HD-2D 碰撞墙并入 walk barrier 绘制（蓝框）
func get_walk_barriers() -> Array:
	var out: Array = super()
	var solids := get_node_or_null("HD2DSolids")
	if solids != null:
		out.append(solids)
	return out


## 露天工位（转发 3D 侧摆位表：铁砧 → 铁匠）
func get_open_work_sites() -> Array:
	if _hd != null and _hd.has_method("get_open_work_sites"):
		return _hd.get_open_work_sites()
	return []


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
		# y 带：实心条目统一 4 元组 [x0, x1, y0, y1]——建筑=地基带
		# [688, 基线+44]，道具/树=自身纵深带（点障碍，可绕行）
		var y0: float = float(r[2]) if r.size() > 2 else WALK_BACK_Y
		var y1: float = float(r[3]) if r.size() > 3 else WALK_FRONT_Y
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(maxf(8.0, x1 - x0), maxf(8.0, y1 - y0))
		shape.shape = rect
		shape.position = Vector2((x0 + x1) * 0.5, (y0 + y1) * 0.5)
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
