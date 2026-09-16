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
## 3D 世界场景与卡资产已正式化迁入 modules/hd2d（烘卡机产物 temp/ 优先、
## 随包镜像 assets/tex 兜底，新机器 clone 后不跑 Blender 也能玩）。

const _HD2D_WORLD_SCENE := preload("res://modules/hd2d/scenes/hd2d_world.tscn")
## 野外资源分布算法（world 模块内，群落散布+林区梯度）
const _ResourceGenScript := preload("res://modules/world/scripts/map/resource_gen.gd")
## 城门选项框（玩家走近弹窗出城；村民走静默传送带）
const _GatePromptScript := preload("res://modules/world/scripts/map/hd2d_gate_prompt.gd")
## 初始城市档（八档链：townlet 村镇过渡——创始人"东西稍全、工区两三栋"）
## 城市规模只是建筑数量问题——扩建=换档重生成
const CITY_TIER := "townlet"

## 街面行走带的 2D y 范围（建筑墙挡住的后段 + 前景可横穿段）。
## 前端 = 3D 街面的可见近沿（z_near = 天际线基线 + 视高/3/sin26° = 18.93 格，
## 构图契约"地面占屏幕下 1/3"@zoom=1——默认缩放 0.75 下分界线压屏幕下 1/4，
## 见 HD-2D街景系统.md §4.0）——屏幕底沿、2D ground_bottom（蓝线）、
## 可行走深度三点合一，整条可见街面都能走。
const walk_back_y := 688.0
## 前界（屏幕底沿锚线）：_ready 经 _front_band_y() 初始化；战场图覆写钩子加深
var walk_front_y: float = 1294.0

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
## 上次广播描边补偿的世界 zoom（变化才广播）
var _last_outline_zoom := -1.0

## resource_gen 算法对接（野外资源分布）：算法只认"硬化地面不长资源"，
## 这里把 ±墙线内算硬化（城内无资源点），墙外算野外——林区梯度（近墙净空
## → 渐密 → 满密度）由此免费获得，兼作城中心→边缘的密度渐变。
const TERRAIN_DIRT_ROAD := 1
## 算法宿主图层（generate_resource_nodes 的入口守卫与节点父级）
var decoration_layer: Node2D = null
## 采集储量中值已随算法内置（resource_gen 按类型区间掷储量），不再手填
## 林线稀疏口径（创始人 2026-09-15：野外树/石稀疏、城门前尤甚——
## 净空 14 格起步，群落"一段一段"的聚簇感由 resource_gen 群落散布承担）
var forest_clear_cells := 14
var forest_ramp_cells := 10
## 资源间距（px）：树冠卡画面宽 2~3 格，64px 会互相穿模（创始人 2026-09-15）
var resource_min_spacing := 96.0
## 创始人 2026-09-15：视野内两三个露头即可（别写死数量，算法按带幅推），
## 大宗采集在城门传送的资源图（Hd2dResourceMap，密度另调）；
## 子类可调（战场图调稀——野地要开阔可列阵）
var resource_density := 0.03



func _ready() -> void:
	super()
	# 屏幕下边界（CameraRig ground_bottom，即 F3 地面蓝线）钉在 3D 街面的
	# 可见近沿上——与 3D 相机缩放锚线同一世界线，2D/3D 底沿逐像素重合
	ground_bottom = walk_front_y
	# 注册 2D 特效坐标重映射器（FxLibrary.remap_pos 读此组）：HD-2D 图的地面
	# 受俯角前缩，飘字/粒子按 2D y 直绘会飘在半空，须压到 3D 投影同一地面线
	add_to_group("fx_pos_remapper")
	# 注册城门引导路由器（BehaviorHarvest 读此组）：村民采集直线 steering 遇
	# 城墙时，经 gate_steer_point 引导到门口，进传送带即跨墙
	add_to_group("gate_router")
	_hd = _HD2D_WORLD_SCENE.instantiate()
	_hd.name = "HD2DWorld"
	if not layout_name.is_empty():
		_hd.set("layout_name", layout_name)
		# 城市生成时机（创始人 2026-09-15：第一次进入该城市生成）——确定性
		# 种子（城名哈希）→ 多局尽量一致；同存档每次进图同城。城市扩建 =
		# 换档重生成（城墙自动前移，野地资源窗随之露出）
		var plan: Dictionary = CityGen.generate(CITY_TIER, hash("city:" + layout_name), CityGen.prop_names())
		_hd.set("layout_data", plan)
	_configure_hd(_hd)
	add_child(_hd)
	_apply_layout_bounds()
	# 深端行走界=前后景分界线（黄线）+2px 防与 bg1 卡共面闪烁：前景整段可行走，
	# 建筑 footprint/城墙带是真正障碍（创始人 2026-09-15：黄线以下就是可行走
	# 地面范围，两楼之间应能一路走到黄线）——不设则 MapBase 默认 720 把人拦在
	# 街心。须在 _hd 就绪后取值（边界来自 3D 侧构图常量），战场图覆写保旧带
	ground_y = _walk_deep_y()
	walk_front_y = _front_band_y()
	# 视野下边界契约（屏幕映射三同步之一）：CameraRig 只认 ground_y + 1080×ground_ratio
	# 的换算值（**不读 ground_bottom 变量**），此处强制换算使 rig 视野下边界钉在
	# 3D 底沿锚线 walk_front_y 上——差多少，F3 覆盖层/FX 等 2D 画布元素就整体
	# 偏多少（1080p 下曾差 95px 致 F3 碰撞箱全体错位；推导见 HD-2D街景系统.md §屏幕映射）
	ground_ratio = (walk_front_y - ground_y) / 1080.0
	# 角色（玩家/NPC）渲染进 3D 场景：逻辑仍在 2D（物理/输入/AI 不动），
	# 视觉走 proto 的 billboard 通道——写深度、可被前景遮挡、自带接地影
	if _hd.has_method("enable_play_characters"):
		_hd.enable_play_characters()
	_build_solid_bodies(_hd)
	_spawn_resource_nodes()
	_build_gate_portals()
	_build_exit_triggers()
	# 城门选项框（玩家走近 ±城门弹"出城/收起"，2D 村图同款；村民走静默带）
	var prompt := Node.new()
	prompt.set_script(_GatePromptScript)
	prompt.name = "GatePrompt"
	add_child(prompt)
	if prompt.has_method("setup"):
		prompt.setup(self)
	_apply_time_of_day(true)


## 深端行走界（origin 空间钳制下限，_ready 在 _hd 就绪后调用）：黄线+2px。
## 战场图覆写维持旧带（688）——战斗阵型间距按旧可行走域调的，不随本契约扩
func _walk_deep_y() -> float:
	return get_fg_bg_boundary_y() + 2.0


## 前界钩子（屏幕底沿锚线，_ready 初始化 walk_front_y；战场图覆写加深：
## HD-2D 俯角把纵深压扁 ~2.3 倍，带浅了大战场只占屏幕下 1/4——
## 战场前界 = 688 + 88 格×32 = 3504，与旧 2D 演练场带深同刻度）
func _front_band_y() -> float:
	return walk_front_y


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
			var z: float = cam2d.zoom.x / maxf(base, 0.001)
			_hd.set_cam_zoom(z)   # 滚轮缩放同步，防两套相机脱钩
			# 描边 zoom 补偿广播（变化才推；billboard 纹理在变焦后描边会等比变粗，
			# 武器薄刃上尤其刺眼——SubViewport 无相机，rig 自动补偿恒按 zoom=1 烘）
			if not is_equal_approx(z, _last_outline_zoom):
				_last_outline_zoom = z
				for id in _char_map:
					var ch: Node3D = _char_map[id]
					if ch != null and is_instance_valid(ch) and ch.has_method("set_outline_zoom"):
						ch.set_outline_zoom(z)
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
		# freed 实体（观察场清场等）先于类型判断——对已释放对象做 is 运算会报
		# "Trying to cast a freed object"
		if not is_instance_valid(e) or e is not Node2D:
			continue
		# 只有火柴人角色有 billboard：箭矢/法术弹等弹道体也挂在 entity_host
		# （武器远程开火的 parent = 实体父节点），此前每支箭被生成一个整版
		# SubViewport billboard（idle 鬼影立在插箭点上）+ play("<null>")
		# 动画状态机三连报错（str(null) 字面化）+ 每箭一个 SubViewport 的浪费
		if e is not StickmanEntity:
			continue
		var body := e as Node2D
		# 2D 骨架树已随「视觉唯一骨架」删除（实体侧按图自删）：全部实体直接
		# 走 billboard 镜像，动画数据源 = 实体 _current_anim（状态先行推进）
		var id: int = e.get_instance_id()
		var ch: Node3D = _char_map.get(id)
		if ch == null or not is_instance_valid(ch):
			ch = _hd.spawn_character()
			_char_map[id] = ch
		alive[id] = ch
		# possessed 玩家：脚下四角框走 3D（与 billboard 同空间同相机，
		# 速度位置天然一致；2D 画布框在 HD-2D 图上会与角色脱钩）
		if ch.has_method("set_bracket_visible"):
			ch.set_bracket_visible(e.has_method("is_possessed") and e.is_possessed())
		# y 行走带 → 3D 纵深 z（道具/树的 z 同一映射，遮挡关系自动正确）；
		# 线性格 1 格 = 32px——行走带前端即 3D 屏幕底沿锚线（z_near）
		var z: float = (body.position.y - depth_y_min) / CELL_PX
		var vel: Vector2 = (body as CharacterBody2D).velocity if body is CharacterBody2D else Vector2.ZERO
		var moving: bool = vel.length_squared() > 25.0
		if ch.has_method("set_world_pos"):
			# 台面/台后地面抬升：落点在路肩前缘以内且墙内 → 脚底抬到台面标高
			var lift: float = 0.0
			if _hd.has_method("get_ground_lift_world"):
				lift = float(_hd.get_ground_lift_world(
						body.position.x / CELL_PX, z))
			var flipped: bool = body.has_method("get_facing") and body.call("get_facing") < 0
			ch.set_world_pos(body.position.x / CELL_PX, z,
					flipped,
					depth_scale_at(body.position.y),
					lift)
		if ch.has_method("set_anim"):
			# 动画镜像读实体真实状态：walk/run/idle + 劳作 attack 全放行。
			# attack 是 oneshot——播完实体侧自动回切 idle/walk，逐拍重触发由
			# set_anim 的变更检测天然完成（此前 attack 被强制降级 walk/idle，
			# 挥镐/挥锤在街上不可见 = 干活与罚站无法区分，创始人 2026-09-15）
			var anim: String = str(body.get("_current_anim"))
			if anim.is_empty():
				anim = "walk" if moving else "idle"
			ch.set_anim(anim)
		# 劳作进度镜像：2D 进度条挂 RigHost 已随街景隐藏，billboard 用自带
		# 3D 头顶条（-1 = 隐藏）。采集/派工/搬运同源（set_action_progress 通道）
		if ch.has_method("set_work_progress") and body.has_method("get_action_progress"):
			ch.set_work_progress(float(body.get_action_progress()))
		# 武器/工具镜像：2D 骨架已隐藏，武器须挂进 billboard 内部骨架
		# （职业识别走武器——工具不渲染 = 村民"没有职业"的观感）
		var mount: Variant = body.get("weapon_mount")
		if mount != null and is_instance_valid(mount) and ch.has_method("set_weapon_type"):
			ch.set_weapon_type(int(mount.get("weapon_type")))
		# 血条随骨架进 billboard：2D 血条切数据模式（停画、状态机照跑——
		# 在战/掉血/悬浮/LOD 语义全留在实体侧），快照喂 billboard 内镜像。
		# 2D 画布坐标与 3D 投影对不上，2D 直画会飘；数据模式 = 同一实现两处渲染
		var bar: Node = body.get_node_or_null("HealthBar")
		if bar != null and bar.has_method("set_crowd_data_mode"):
			bar.set_crowd_data_mode(true)
			if ch.has_method("apply_health_state"):
				ch.apply_health_state(bar.call("get_bar_state"))
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
var depth_y_min: float = 688.0
var depth_y_max: float = 1294.0
const DEPTH_SCALE_MIN := 0.92
const DEPTH_SCALE_MAX := 1.10

func _apply_depth_visual() -> void:
	for e in get_entities():
		# freed 实体（观察场清场等）先于类型判断——对已释放对象做 is 运算会报
		# "Trying to cast a freed object"
		if not is_instance_valid(e) or e is not Node2D:
			continue
		var rig := (e as Node2D).get_node_or_null("RigHost") as Node2D
		if rig == null:
			continue
		if not e.has_meta("hd2d_base_rig_scale"):
			e.set_meta("hd2d_base_rig_scale", rig.scale)
		rig.scale = (e.get_meta("hd2d_base_rig_scale") as Vector2) * depth_scale_at((e as Node2D).position.y)


func get_spawn_point() -> Vector2:
	# 街中心前景：玩家落在画面中下（3D 街景可见区内）。
	# 布局驱动模式与手摆模式都以 0 为街中心（导出器已把布局 x 中心化）。
	return Vector2(0.0, 1010.0)


## HD 场景模式注入钩子（add_child 前调，子类覆写开模式；如战场图开 battlefield）
func _configure_hd(_hd: Node3D) -> void:
	pass


## 布局驱动模式：按布局街宽收地图边界（±半宽 + 8 格余量），覆盖 tscn 默认值。
func _apply_layout_bounds() -> void:
	if layout_name.is_empty() or _hd == null or not _hd.has_method("get_layout_width"):
		return
	var w: float = _hd.get_layout_width()
	if w <= 0.0:
		return
	# 墙外只留半屏（≈30 格）野地带——创始人口径：可以走出城墙，但墙外就
	# 半屏距离；地图边界随布局宽度推导（城市扩建 → 墙前移 → 野地窗跟着挪）
	var half_px: float = (w * 0.5 + 30.0) * CELL_PX
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
	# 布局感知：铁匠跟铁砧（布局 props/手摆 PROPS 均可），其余按墙线比例
	# 分散内街（伐木/矿工靠西侧待命，出城引导走城门）；不绑死整数格坐标
	var pts: Array = []
	var anvil := Vector2.ZERO
	for s: Variant in get_open_work_sites():
		anvil = s["pos"]
		break
	pts.append(anvil + Vector2(0.0, 60.0))
	var half: float = get_wall_px() / CELL_PX
	if half <= 1.0:
		half = 95.0   # 布局缺失兜底（tscn 手摆语义）
	for i in 6:
		pts.append(Vector2((-0.55 + i * 0.16) * half * CELL_PX, 985.0 + (i % 3) * 30.0))
	pts.append(Vector2(-6.0 * CELL_PX, 1000.0))   # 市集广场
	pts.append(Vector2(2.0 * CELL_PX, 1030.0))
	pts.append(Vector2(half * 0.3 * CELL_PX, 1000.0))
	return pts


## 3D 脚下四角框声明（SelectionSystem 读到后跳过 2D 画布框）
func wants_3d_bracket() -> bool:
	return true


## 行走带约束口径：HD-2D 图按 origin 空间直用（视觉脚线=origin，billboard
## 脚锚；2D 图是 origin+foot_offset=脚）。基类默认 false（脚部约束口径）。
func _origin_space_walk_band() -> bool:
	return true


## 2D 特效/坐标重映射（fx_pos_remapper 组协议 + MapBase 视觉域协议）：2D 世界
## y → 3D 投影呈现的同一地面线。锚线 walk_front_y 不动，纵深越深压缩越多
## （俯角前缩 k=sinθ，数学核 Hd2dProjection）——飘字/粒子由此与角色 feet 对齐。
func remap_fx_pos(pos: Vector2) -> Vector2:
	if _hd == null or not _hd.has_method("get_ground_squash"):
		return pos
	var k: float = float(_hd.get_ground_squash())
	var ry: float = Hd2dProjection.ground_to_visual_y(pos.y, k, walk_front_y)
	# 台面/台后地面抬升（2D 画布域）：与角色 billboard 脚底抬升同源同值——
	# 角色走上台面后，青箱/FX/选中框等一切锚 origin 的画布元素跟着贴到抬升后的地面
	if _hd.has_method("get_ground_lift_px"):
		ry -= float(_hd.get_ground_lift_px(pos.x, pos.y))
	return Vector2(pos.x, ry)


## 地面锚点逆映射（MapBase 协议覆写）：视觉域 → 画布域，与 remap_fx_pos 的
## 压缩项互为精确逆（台面 lift 区逆解未含，路面口径）。屏幕点击 → 世界判定
## （unmap）与 F3 鼠标读数（screen_y_to_ground_y，屏幕域版）共用同一压缩模型。
func unmap_fx_pos(pos: Vector2) -> Vector2:
	if _hd == null or not _hd.has_method("get_ground_squash"):
		return pos
	var k: float = float(_hd.get_ground_squash())
	return Vector2(pos.x, Hd2dProjection.visual_to_ground_y(pos.y, k, walk_front_y))


## billboard 深度缩放（0.92~1.10 随纵深线性）：3D billboard 渲染、2D rig 镜像
## 与悬浮框几何共用同一口径，禁止各处内联 lerp（改档位时三处必须同源）。
func depth_scale_at(y: float) -> float:
	return lerpf(DEPTH_SCALE_MIN, DEPTH_SCALE_MAX,
			clampf((y - depth_y_min) / (depth_y_max - depth_y_min), 0.0, 1.0))


## billboard 视觉身高（canvas px，悬浮框/选中框锚定用）：char_sprite_3d 尺寸
## 契约——rig 原生 ~274px × RIG_SCALE 0.475 = 130 SV px（§0.3 比例锚 130px=
## 1.70m）× SIZE_K 1.2（2026-09-14 偏小反馈的占位放大，纹理随 quad 同步放大
## = 视觉身高）= 156；PX(1/32 格/SV px) 与"1 格=32 canvas px"相抵，故 130×1.2
## 直接就是 canvas px。⚠ 改 char_sprite_3d 的 RIG_SCALE/SIZE_K 时同步本值。
## billlboard 不随 body_scale 缩放（set_world_pos 无此参），本值亦不乘。
const BILLBOARD_BODY_H_PX := 156.0


## 悬浮框视觉域矩形（MapBase 协议覆写）：HD-2D billboard 几何——origin=视觉
## 脚线（remap 压进投影域），**高=billboard 视觉身高**（156，非 Range 的 2D
## 全身高 277——那是髋部原点语义，比 billboard 高出约半个身子，创始人
## 2026-09-15"另一个线框比角色高半个身子"）；宽沿用 Range 宽（悬停放宽余量，
## 已烘焙 body_scale）。Range 框的 2D 局部语义在此不适用。_hd 未就绪时回退
## 2D 恒等框（super）。
func entity_hover_rect(range_center: Vector2, range_size: Vector2, entity: Node2D) -> Rect2:
	if _hd == null or not _hd.has_method("get_ground_squash"):
		return super(range_center, range_size, entity)
	var k: float = float(_hd.get_ground_squash())
	var box_size := Vector2(range_size.x, BILLBOARD_BODY_H_PX)
	return Hd2dProjection.billboard_hover_rect(
			entity.global_position, box_size, k, walk_front_y, depth_scale_at(entity.global_position.y))


## 屏幕 y → 行走带世界 y（remap_fx_pos 的屏幕域逆变换，F3 鼠标世界坐标用）。
## 3D 取景垂直固定（不随 2D 相机纵移）：屏幕底沿 = 锚线 walk_front_y，
## 每格纵深在屏幕上占 32×压缩率×缩放 px（公式推导见 HD-2D街景系统.md §屏幕映射）
func screen_y_to_ground_y(screen_y: float, effective_zoom: float) -> float:
	if _hd == null or not _hd.has_method("get_ground_squash"):
		return screen_y
	var k: float = float(_hd.get_ground_squash())
	var vp_h: float = get_viewport_rect().size.y
	return walk_front_y - (vp_h - screen_y) / (k * maxf(effective_zoom, 0.001))


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


## F3 建筑宽度辅助线数据口（debug_gui 抽屉 duck 读取）：3D 侧前排建筑
## 占地实心带（[x0,x1,y0,y1]：x=格、y=px 混合口径，同 get_solid_rects）
func get_building_rects() -> Array:
	if _hd != null and _hd.has_method("get_building_rects"):
		return _hd.get_building_rects()
	return []


## F3 黄线数据口（debug_gui duck 读取）：前后景分界线的 2D 等价 y
## （zoom=1 压屏幕下 1/3 线；旧文档叫"地平线"，实为前后景分界，勿混淆）
func get_fg_bg_boundary_y() -> float:
	if _hd != null and _hd.has_method("get_fg_bg_boundary_y"):
		return float(_hd.get_fg_bg_boundary_y())
	return ground_y


## 露天工位（转发 3D 侧摆位表：铁砧 → 铁匠）
func get_open_work_sites() -> Array:
	var out: Array = []
	# 布局驱动：铁砧点位来自布局 props（生成器随工匠区落位）
	if _hd != null and _hd.has_method("get_layout_props"):
		for e: Variant in _hd.get_layout_props():
			if str(e.get("card", "")) == "anvil":
				out.append({
					"pos": Vector2(float(e["x"]) * CELL_PX,
							depth_y_min + float(e.get("z", 4.5)) * CELL_PX),
					"work_site_def": "smithy_lv1",
				})
		if not out.is_empty():
			return out
	# 手摆回退：PROPS 表的铁砧
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
	# 前排建筑形状打 meta（get_solid_rects 前 N 项=建筑，与 get_building_rects
	# 同序）：F3 显示改走直立包楼框（draw_buildings），障碍抽屉跳过防双重绘制
	var building_count: int = 0
	if hd.has_method("get_building_rects"):
		building_count = hd.get_building_rects().size()
	var idx: int = 0
	for r: Variant in hd.get_solid_rects():
		var x0: float = float(r[0]) * CELL_PX
		var x1: float = float(r[1]) * CELL_PX
		# y 带：实心条目统一 4 元组 [x0, x1, y0, y1]——建筑=地基带
		# [688, 基线+44]，道具/树=自身纵深带（点障碍，可绕行）
		var y0: float = float(r[2]) if r.size() > 2 else walk_back_y
		var y1: float = float(r[3]) if r.size() > 3 else walk_front_y
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(maxf(8.0, x1 - x0), maxf(8.0, y1 - y0))
		shape.shape = rect
		shape.position = Vector2((x0 + x1) * 0.5, (y0 + y1) * 0.5)
		if idx < building_count:
			shape.set_meta("hd2d_building", true)
		idx += 1
		body.add_child(shape)
	if body.get_child_count() > 0:
		add_child(body)


## 野外资源点：走 resource_gen 程序化分布算法（创始人：算法就在那——群落
## 散布 + 林区梯度直接复用，不手摆）。点检经 spawn_nature_card_at 让 PBR 卡
## 随点落；ResourceNode 自身已无 2D 视觉（笔触树根除），无需隐藏。
func _spawn_resource_nodes() -> void:
	if _hd == null or not _hd.has_method("spawn_nature_card_at"):
		return
	# 算法入口守卫：无 decoration_layer 直接返回空——主街是 2D 静态布景图，
	# 没有该图层属性，这里补上（作 ResourceNode 的宿主）
	decoration_layer = Node2D.new()
	decoration_layer.name = "DecorationLayer"
	add_child(decoration_layer)
	var gen := Node.new()
	gen.set_script(_ResourceGenScript)
	gen.name = "ResourceGen"
	add_child(gen)
	# 墙外带只有 28 格，算法默认净空 30 格会把整带清空——压缩梯度档：
	# 近墙 3 格净空 → 12 格渐密 → 满密度（渐变读法保留，城门口即有活干）
	gen.set("FOREST_CLEAR_CELLS", forest_clear_cells)
	gen.set("FOREST_RAMP_CELLS", forest_ramp_cells)
	gen.set("MIN_SPACING", resource_min_spacing)
	if gen.has_method("setup"):
		gen.setup(self)
	var a: int = int(map_left / CELL_PX) + 2
	var b: int = int(map_right / CELL_PX) - 2
	var nodes: Array = gen.call("generate_resource_nodes", a, b, resource_density)
	# 类型 → 自然物卡池（多株轮转防同卡连排）
	var card_pools := {
		ResourceNode.ResourceType.WOOD: ["broadleaf", "conifer", "broadleaf_tall"],
		ResourceNode.ResourceType.STONE: ["boulder"],
		ResourceNode.ResourceType.METAL: ["iron_outcrop", "copper_vein"],
		ResourceNode.ResourceType.DIAMOND: ["crystal_cluster"],
		ResourceNode.ResourceType.GOLD: ["gold_vein"],
	}
	var cursors := {}
	for n: Node2D in nodes:
		var rtype: int = int(n.resource_type)
		var pool: Array = card_pools.get(rtype, ["broadleaf"])
		var ci: int = int(cursors.get(rtype, 0))
		cursors[rtype] = ci + 1
		_hd.spawn_nature_card_at(str(pool[ci % pool.size()]), n.position.x, n.position.y)
	print("[hd2d] 野外资源点 %d 处（resource_gen 算法分布，墙外带）" % nodes.size())


func get_terrain_type_at_cell(cx: int) -> int:
	var wall_x: float = _hd.get_wall_x() if _hd != null and _hd.has_method("get_wall_x") else 95.0
	return TERRAIN_DIRT_ROAD if absi(cx) <= int(wall_x) else 0


## 城门传送带（创始人 2026-09-14：到门口就传送，门外也得传送过去）。
## 每端城墙内外各一条 Area2D 竖带（贴墙、门洞纵深带内）：只对"朝着墙走"
## 的身体触发（斜向闲逛蹭到不触发），跨墙落到对面带外侧 + 冷却防弹跳。
## 墙体碰撞已整带封死（proto get_solid_rects），传送是唯一过墙方式。
const _TP_STRIP_W := 64.0          # 传送带厚度（px）
const _TP_COOLDOWN_MS := 600       # 防弹跳冷却
var _tp_cooldown: Dictionary = {}  # body instance_id -> 解禁时刻(msec)

func _build_gate_portals() -> void:
	if _hd == null or not _hd.has_method("get_gates"):
		return
	var host := Node2D.new()
	host.name = "GatePortals"
	add_child(host)
	for g: Variant in _hd.get_gates():
		var wx: float = float(g["x"]) * CELL_PX
		var y0: float = float(g["y0"])
		var y1: float = float(g["y1"])
		var toward_town: float = -signf(wx)   # 从墙指向城内的方向（西墙 +1）
		var inner_face: float = wx + toward_town * 19.0   # 墙内面（墙厚半宽 19px）
		for side: int in [-1, 1]:   # -1 = 城内侧带, +1 = 城外侧带
			var strip := Area2D.new()
			strip.name = "GateTP_%s_%s" % [("W" if wx < 0.0 else "E"), ("in" if side < 0 else "out")]
			# 角色本体在 collision_layer=2（hitbox.gd 位约定 BODY）——默认 mask 1
			# 只看得见墙体，永远收不到角色进入事件（创始人实测卡门口的根因）
			strip.collision_mask = 2
			strip.monitorable = false
			var shape := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(_TP_STRIP_W, y1 - y0 - 8.0)
			shape.shape = rect
			shape.position = Vector2(inner_face + toward_town * side * -40.0, (y0 + y1) * 0.5)
			strip.add_child(shape)
			strip.body_entered.connect(_on_gate_strip_entered.bind(wx, y0, y1))
			host.add_child(strip)


func _on_gate_strip_entered(body: Node2D, wx: float, y0: float, y1: float) -> void:
	if body is not CharacterBody2D or not is_instance_valid(body):
		return
	# 玩家不走静默瞬移：走近城门由 hd2d_gate_prompt 弹选项框（2D 村图同款
	# "靠近城门蹦出弹窗"口径，创始人 2026-09-15）；村民采集走静默带
	if body.has_method("is_possessed") and body.is_possessed():
		return
	# 方向判定：只传送"朝着墙走"的身体（沿街横穿/闲逛蹭进带子不触发）
	var toward: float = signf(wx - body.global_position.x)
	if toward == 0.0 or (body as CharacterBody2D).velocity.x * toward < 8.0:
		return
	_gate_teleport(body, wx, y0, y1)


## 跨墙瞬移核心（村民静默带与玩家弹窗选项共用）：带冷却防弹跳
func _gate_teleport(body: CharacterBody2D, wx: float, y0: float, y1: float) -> void:
	# 方向判定：朝墙才传（弹窗路径玩家可能静止/背向，按当前朝墙意图算）
	var toward: float = signf(wx - body.global_position.x)
	if toward == 0.0:
		return
	# 冷却防弹跳（刚被传过来的身体在对面带不回传）
	var id: int = body.get_instance_id()
	var now: int = Time.get_ticks_msec()
	if int(_tp_cooldown.get(id, 0)) > now:
		return
	_tp_cooldown[id] = now + _TP_COOLDOWN_MS
	# 跨墙落点：墙线对面 ~4.3 格（带外缘再留 32px 白区），y 夹回行走带内
	var land_x: float = wx + toward * 139.0
	var land_y: float = clampf(body.global_position.y, y0 + 8.0, y1 - 8.0)
	body.global_position = Vector2(land_x, land_y)



## 墙线 px（弹窗组件触发带用）
func get_wall_px() -> float:
	if _hd != null and _hd.has_method("get_wall_x"):
		return _hd.get_wall_x() * CELL_PX
	return 0.0


## 东西村口出口触发器（语义对齐村A旅行链：西出原野去 B 村方向、东出战场）。
## 触发区压在地图边界内侧一条（玩家走到村口即切图）。
func _build_exit_triggers() -> void:
	var triggers_host := Node2D.new()
	triggers_host.name = "ChunkTriggers"
	add_child(triggers_host)
	for spec: Dictionary in _exit_specs():
		var trig := ChunkTrigger.new()
		trig.name = str(spec["name"])
		trig.target_map_id = str(spec["target"])
		trig.target_entry_side = int(spec["entry"])
		trig.trigger_width = 96.0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		# 触发带纵深跨整个可行走域（深端=黄线，非旧墙脚线 688）——角色在
		# 两楼之间的台后区也能正常走出去
		rect.size = Vector2(96.0, walk_front_y - ground_y)
		shape.shape = rect
		shape.position = Vector2(float(spec["x"]), (ground_y + walk_front_y) * 0.5)
		trig.add_child(shape)
		triggers_host.add_child(trig)


## HD-2D 视觉声明（实体侧据此删除 2D 骨架树——视觉唯一骨架方向）
func uses_billboard_visuals() -> bool:
	return true


## 出口表（子类按旅行链覆写，如战场图左出回主街/右出去森林）。
## 东出进战场从其 LEFT 缘落（与步行方向一致——原 RIGHT 会把人扔到战场
## 最东端，背对全部内容）。
func _exit_specs() -> Array:
	return [
		{"name": "ExitLeft", "x": map_left + 48.0, "target": "road_a_b",
		 "entry": WorldAPI.EntrySide.LEFT},
		{"name": "ExitRight", "x": map_right - 48.0, "target": "battlefield",
		 "entry": WorldAPI.EntrySide.LEFT},
	]


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
