extends Node3D
## hd2d_world.gd —— 「八方旅人式 HD-2D」3D 世界：编排门面 + solids/相机域。
##
## 起源是可行性原型（把 2D 绘制的火柴人放进 3D 场景、配合景深 + 辉光 + 暗角 +
## 分级后处理得到 HD-2D 观感），正式化后为本模块的场景脚本；职责拆分后本文件
## 只保留：世界搭建编排（_build_world）、solid 数据域（碰撞/占地/城门/墙线）、
## 相机与构图数学、光照/天幕/小地图烘焙/出图工装各域的接线与公开转发壳
## （get_minimap_layout/bake_minimap_strip 被 Hd2dMapBase 按方法名 duck 调用）。
## 职责组件（scripts/ 下按域分子目录/平铺，_ready 注入门面回引 w）：
##   cards/      卡呈现域（卡材质/落位数学/接地影/画面宽）
##   placer/     摆街域（前排求解/三层背景/道具自然物摆放/布局查询）
##   ground/     地面域（分带铺设/台肩镶边/门前径/地面抬升/地表色账本）
##   walls/      城墙域（墙板/门楼几何/墙体材质）
##   char_stage/ 角色舞台域（关节烘焙桶与每实体装配）
##   clouds/     云牌域（云池/漂移/昼夜着色；节点即 Clouds 容器）
##   sky/        天幕天体域（贴图天幕/日月弧线/云牌装配口）
##   hd2d_light_rig.gd                 光照后处理域（昼夜档/后处理/DOF 档）
##   hd2d_minimap_baker.gd             小地图烘焙域（平面图数据/照片式底图）
##   diagnostics/hd2d_shots_harness.gd 出图工装（CLI 参数/截图 harness/辅助线）
## 组件间经 w 互访成员属模块内部自由域；对外契约只有 modules/hd2d/api.gd。
##
## 固定跑法（--shots 出图工装）见 diagnostics/hd2d_shots_harness.gd 文件头。
##
## 坐标约定：Godot 单位 = 1 格 = 24 引擎单位（2026-09-16 换轨，旧 32；zoom=1 时
## 1 单位 = 1 设计像素；卡 meta 里烘焙 px 口径的数据经 ×S 统一折算）。
##   相机正交、yaw=0°、俯角 26°（原 20°，创始人要求"稍微增加"）。
##
## ── 继承 proto_25d 的五条实测发现（不得回退）────────────────────────────
##   1. 卡与相机同基 → 像素级落位（cards 组件 _cam_basis 与卡 quad 的 basis 同源）；
##   2. albedo 亮度差分伪造法线，平面卡才吃真 3D 光照（card.gdshader）；
##   3. 光照别双计：卡是已带光照的烘焙图，场景光只做保底/氛围（现行昼档
##      太阳 1.10 = 创始人拍板的高调口径，覆盖旧"总和≈1.0"基线，见光照域
##      hd2d_light_rig.gd 的 _apply_light）；
##   4. render_mode depth_prepass_alpha 消矩形影（card.gdshader）；
##   5. 色调映射用 LINEAR —— 卡是已带光照的烘焙图，filmic/aces 会把它压灰。

const S := 1.0 / 32.0                    # 卡 meta 烘焙 px -> 格：json 恒 32px/格 记账（数据格式，不随换轨变）；
                                         # 24px/格 的屏幕密度由相机承担（set_cam_zoom），格数口径两侧一致
const TILT_DEG := 26.0                   # 俯角：创始人要求"稍微增加"（原 20°），本次 +6°
const CARD_SHADER := preload("res://modules/hd2d/shaders/card.gdshader")
const POST_SHADER := preload("res://modules/hd2d/shaders/post_hd2d.gdshader")

## ── 职责组件（scripts/ 按域分子目录；模块内部自由域，回引 w 在 _ready 注入）──
const Hd2dCards := preload("res://modules/hd2d/scripts/cards/hd2d_cards.gd")
const Hd2dStreetPlacer := preload("res://modules/hd2d/scripts/placer/hd2d_street_placer.gd")
const Hd2dGround := preload("res://modules/hd2d/scripts/ground/hd2d_ground.gd")
const Hd2dWalls := preload("res://modules/hd2d/scripts/walls/hd2d_walls.gd")
const Hd2dCharStage := preload("res://modules/hd2d/scripts/char_stage/hd2d_char_stage.gd")
const Hd2dSkyCelestial := preload("res://modules/hd2d/scripts/sky/hd2d_sky_celestial.gd")
const Hd2dMinimapBaker := preload("res://modules/hd2d/scripts/hd2d_minimap_baker.gd")
const Hd2dLightRig := preload("res://modules/hd2d/scripts/hd2d_light_rig.gd")
const Hd2dShotsHarness := preload("res://modules/hd2d/scripts/diagnostics/hd2d_shots_harness.gd")

const CARDS_JSON := "proto25d/cards.json"
const CARD_DIR := "proto25d/cards/"
const PROPS_JSON := "proto_hd2d/props.json"
const PROP_DIR := "proto_hd2d/props/"
const NATURE_JSON := "proto_hd2d/nature.json"
const NATURE_DIR := "proto_hd2d/nature/"
const LAYOUT_DIR := "proto_hd2d/hd2d_layouts/"   # city_layout 导出的布局 JSON（算法驱动模式）
const GROUND_DIR := "ground_tiles/"

const CAM_W := 74.0                      # 初始视宽（格）；游戏内由 set_cam_zoom 按 2D 1:1 动态接管
## 设计分辨率基准高（px）：与 CameraRig.DESIGN_HEIGHT 同源，1:1 换算用
const DESIGN_HEIGHT := 1080.0
const CAM_CY := 11.0                     # 相机视线轴的世界高度
const CAM_DIST := 40.0
## 底沿锚线地面的最小视深（格，近平面退避目标）：0.75/1.0 档天然 ≥18.9、
## 退避量为 0；更远档才把相机沿视轴后移到此深度（见 set_cam_zoom）
const CAM_NEAR_SAFE := 16.0

## 背景层（创始人 2026-09-14 定案；2026-09-15 补缝口径——"后两排的职责=遮挡地平线"）：
##   · bg1 基线压**屏幕下 1/3 线**（=前后景分界线，屏幕映射 §4.0）——下 1/3 归
##     前排与街面，中 1/3 起归背景楼群；
##   · bg1 整排连铺 = 主天际线；bg2 **地平线补缝**：只往 bg1 没遮住的地平线缝隙
##     里稀疏插楼（楼身站上真实地平线，穿缝可见、楼顶可越前排露出），不再整排铺；
##   · bg2 紧贴 bg1（层距 3.5 格——创始人 2026-09-15：第三排紧贴第二排）；
##   · bg2 基线 = 真实地平线（底衬远端同步收到此处）。
const SKYLINE_Z := -6.73                 # bg1 基线压屏幕下 1/3 线：v=-h/6 → z=-(v+CY·cosθ)/sinθ
## 战场地平线（格）：绿草地皮远端 z=0（=行走带后界 688px）。战场构图契约
## （全场景只有前景大地无后景）把地面高度钉在**半屏**——02-战斗系统.md 二-A
## Tier0「半屏高：战场高度约 1/2 屏幕高」（创始人 2026-10-05 改约，原为地平线
## 钉上 1/3 线/地占下 2/3），任意缩放档成立（见 set_cam_zoom 战场分支）
const BF_HORIZON_Z := 0.0
## 深端行走界（2D y）：前后景分界线（黄线）+2px 防与 bg1 卡共面闪烁——前景
## 整段可行走，建筑 footprint/城墙带是真正障碍（创始人 2026-09-15：黄线以下
## 就是可行走地面范围，碰撞箱顶到黄线才停，不留肉眼可见的余量）
const DEEP_WALK_Y := 516.0 + SKYLINE_Z * 24.0 + 1.5
const BG_LAYERS := 3                     # 背景层数（前排+三层后景；创始人 2026-09-14 定案三层背景，2026-09-17 恢复）
## 背景层距（格）：bg2 紧贴 bg1
const BG_LAYER_GAP := 3.5
## bg1 选卡的画面高上限（格）：排除塔楼/教堂/宫殿等"太抬高"卡
## （创始人 2026-09-15：第二排尽量别出现太抬高的建筑；过滤后无卡可用则放开）
const BG1_MAX_H := 14.0
## 远焦模糊起点：天际线基线向镜头前移的格数（世界线，经 set_cam_zoom 随缩放换算、
## 不随缩放漂移）——前排零模糊口径不变，第二排从这里开始吃半档模糊
## （创始人 2026-09-15：第二排景深太不明显，根因=起点原钉在天际线上、第二排恰好吃不到）
const DOF_FAR_START_AHEAD := 0.0   # 回到初始渐变（创始人 2026-09-15：前移+强过渡让渐变糊成一档）
## 背景层距离染色（空气透视：越远越淡越冷）
const BG_TINTS: Array = [
	Color(0.80, 0.84, 0.93), Color(0.85, 0.885, 0.945), Color(0.90, 0.925, 0.96),
]
## 卡窗光染色（创始人 2026-09-15：窗光去黄——旧档橙 (1.0,0.78,0.46) 把画面染黄）
const CARD_GLOW_TINT := Color(1.0, 0.90, 0.78)
## 后景卡窗光档（相对前排倍率）：后景窗火只做点缀，不与前排抢
const BG_GLOW_RATIO := 0.45
## 云牌容器名：小地图烘焙整体隐藏（云贴图**异步**烘制——按容器隐藏才与时序无关）
## 容器节点即云牌组件（hd2d_clouds.gd，自带漂移 _process）
const CLOUD_ROOT_NAME := &"Clouds"
## 云池规模（2D SkyDecor 同量：视带内 14、屏内约 9）
const CLOUD_POOL := 14

## 地面分带（格；z 增大 = 朝相机）。
## 基线纪律（创始人纠偏）：**建筑基线 = 路肩带顶线**。
## 路肩从 z=0.4 开始而不是 0：卡的**烘焙接触阴影**也画在卡的深度面上（z≈-1.5），
## 与路肩面在 z≈0 处深度相等 → 会 z-fighting 并露出一条带卵石纹理的"假暗地"。
## 路肩前移 0.4 格（屏幕上约 3px）后深度测试干净，且那 3px 正好留给建筑的接触阴影，
## 形成"建筑站在路肩上、脚下有一线接地影"的正确观感。
const BAND_SIDEWALK := Vector2(0.42, 1.95)  # 路肩（建筑根部 → 外缘；细条，占位）
const PLAT_H := 0.65                        # 人行道台面高（格）≈17px：整面垫高，建筑落在台面上
const BAND_ROAD := Vector2(1.9, 46.0)       # 道路（角色活动面，铺到画面外）
## 草地染色统一淡草档：草地贴图已换回创始人认可的原 AI 手绘源（自带花草
## 笔触与配色），深绿染色档会把花草压成暗橄榄——战场全幅草与街景城外草带
## 同用一档，野地草色一色（创始人 2026-09-17：AI 草地按原色呈现）
const GRASS_TINT := Color(0.90, 0.93, 0.80)

## 天幕色档（创始人 2026-09-16：纯蓝临时口径；夜档近黑蓝）。天幕天体域与
## 光照域经 w 共读；换手绘贴图时只动天幕域的材质贴图口。
const SKY_BLUE := Color(0.31, 0.47, 0.78)
const SKY_NIGHT := Color(0.03, 0.05, 0.12)

## 城墙（创始人 2026-09-14：地图两侧到城墙，城镇由城墙收口；2026-09-15
## 城镇扩到 ±95——"没走多久就城门"；墙高升 10 格 town 档——"城墙这么矮"）。
## 墙板沿纵深方向立在 ±WALL_X，正交视角下呈"窄竖条 + 墙顶垛口"的转角收边
## 读法；墙体碰撞整带封死，过墙唯一方式=城门传送带（宿主 Area2D，get_gates
## 供全带范围），城内资源点归零（resource_gen 算法只落墙外）。
const WALL_X := 95.0          # 城墙线（格，±）；地图边界 ±123 格
const WALL_T := 1.2           # 墙厚（格）
const WALL_H := 10.0          # 墙高（格，管线 v3 §4.1 town 档 320px）
const GATE_Z0 := 8.0          # 门洞纵深带起（格）
const GATE_Z1 := 14.0         # 门洞纵深带止（格）
const WALK_FRONT_PX := 970.5 # 行走带前端 px（宿主 WALK_FRONT_Y；= 516 + 18.94*24，旧 1294=688+18.93*32）
## 建筑接地影的 z 区间**必须整段落在路肩之外**（z ≥ 2.0）：
## 影和路肩都是贴地水平面，z 区间一旦重叠，深度值必然相等 → z-fighting。
const BSHADOW_Z := 3.3
const BSHADOW_DEPTH := 2.6

var _root := ""
var _temp := ""
## 卡库元数据字典（cards/props/nature.json 装载产物）：多组件共享的词汇，
## 留在门面（组件经 w 只读消费；装载出口 _load_cards 亦在门面）
var _cards: Dictionary = {}
var _props: Dictionary = {}
var _nature: Dictionary = {}
var _layout: Dictionary = {}      # 布局驱动模式的数据（空 = 手摆主街模式）
## 运行时生成的布局（宿主"首次进入生成"注入，创始人 2026-09-15）——
## 优先于 JSON 文件；非空时 _ready 直接吃它。
@export var layout_data: Dictionary = {}
var layout_name := ""             # 布局名（--layout= 或地图宿主 set；空 = 手摆主街）
var battlefield := false          # 战场模式（城东开阔野地：无墙无街无楼群，战痕散布）
## 战场行走带前缘的世界地面 z（格，含前缘余量；宿主地图算好 ground_bottom 后
## 经 set_bf_band_front_z 推入——set_cam_zoom 战场分支的出界兜底锚，0 = 未推入
var _bf_band_front_z := 0.0
## 最近一次 set_cam_zoom 的原始入参（set_bf_band_front_z 迟到时重算取景用）
var _last_user_zoom := -1.0
## 战场地面占比锚（02 二-A.2「半屏高」直给参数）：推入后草地远端（BF_HORIZON_Z）
## 钉在屏上 (1-p) 处——p=0.5 即地面占屏下 1/2；优先级高于带前缘兜底
var _bf_ground_ratio := -1.0

## ── 职责组件实例（回引 w 在 _ready 注入；分工见文件头与各组件文件头）──
var cards := Hd2dCards.new()                 # 卡呈现域（材质/落位/接地影/画面宽）
var placer := Hd2dStreetPlacer.new()         # 摆街域（前排求解/背景层/道具自然物）
var ground := Hd2dGround.new()               # 地面域（分带/镶边/抬升/地表账本）
var walls := Hd2dWalls.new()                 # 城墙域（墙板/门楼几何）
var char_stage := Hd2dCharStage.new()        # 角色舞台域（关节烘焙装配）
var sky := Hd2dSkyCelestial.new()            # 天幕天体域（天幕 quad/日月弧线/云牌装配）
var baker := Hd2dMinimapBaker.new()          # 小地图烘焙域（平面图/照片底图）
var light := Hd2dLightRig.new()              # 光照后处理域（昼夜档/后处理/DOF 档）
var shots := Hd2dShotsHarness.new()          # 出图工装（CLI/截图 harness/辅助线）


## 战场地面占比推入（一屏战场宿主调；同带前缘的迟到重算语义）
func set_bf_ground_ratio(p: float) -> void:
	if not battlefield or absf(p - _bf_ground_ratio) < 0.001:
		return
	_bf_ground_ratio = p
	if _last_user_zoom > 0.0:
		set_cam_zoom(_last_user_zoom)


## 战场带前缘推入（宿主 battlefield 图 _ready 里 ground_bottom 定稿后调）：
## 迟到重算——世界场景 build 时 set_cam_zoom(0.75) 先跑，此刻带前缘还没推入，
## 推入后按同缩放档重跑一遍取景
func set_bf_band_front_z(z: float) -> void:
	if not battlefield or absf(z - _bf_band_front_z) < 0.001:
		return
	_bf_band_front_z = z
	if _last_user_zoom > 0.0:
		set_cam_zoom(_last_user_zoom)
var resource_field := false       # 城外资源图模式（同战场式开阔，但无战争遗物、无天空剪影）
var _tex_cache: Dictionary = {}

var _env: Environment
var _sun: DirectionalLight3D   # 主光（昼=太阳档/夜=月光档，方向按档位固定不随盘走）
var _fill: DirectionalLight3D
var _ground_root: Node3D
var _card_root: Node3D
var _prop_root: Node3D
var _front_occ: Array = []
var _door_path_xs: Array = []   # 需要门前短径的建筑 x（guildhall / 落地面建筑）
var _prop_slots: Array = []     # 前排楼间空当 [x0,x1]（道具槽位）
var _prop_solids: Array = []    # 道具实心区间 [x0,x1]（碰撞用）
var _clutter_occ: Array = []    # 建筑间杂物占格带（F3 建筑辅助线用，同建筑 rect 口径）
## 地面条带账本随地面组件（ground._ground_strips）；本面只留快照缓存
## 小地图布局快照缓存（首次查询构建；运行期内容变更走 mark_minimap_base_dirty 失效）
var _minimap_layout_cache: Dictionary = {}
## 照片底图脏信号：光照档切换或 3D 街景内容变更时发（Hd2dMapBase 收到后
## 防抖重烘，小地图 15Hz 快照自动换图）——运行时重烘管线的脏标记入口
signal minimap_base_dirty
## 烘焙排除层常量（BAKE_EXCLUDE_LAYER）随小地图烘焙域组件；rig 节点挂门面。
## 小地图烘焙 rig（懒建；共享主视口 World3D 的 SubViewport + 专用正交相机）
var _bake_vp: SubViewport = null
var _bake_cam: Camera3D = null
## 云牌容器 = 云牌组件节点（hd2d_clouds.gd；烘焙整体归排除层，容器是时序无关
## 的排除单位——云贴图异步烘制，逐节点排除会漏掉烘焙后才入树的那些）
var _cloud_root: Node3D = null
var _shadow_root: Node3D
var _lamp_root: Node3D
var _cam: Camera3D
var _cam_attrs: CameraAttributesPractical
var _char_host: Node3D = null
## 实体宿主容器（spawn_character 的挂点；烘焙整体归排除层）——
## 与演示宿主 _char_host 分开：游戏图的火柴人全在这，不在演示宿主下
var _char_entities_root: Node3D = null
var _post_layer: CanvasLayer
var _post_rect: ColorRect
var _post_mat: ShaderMaterial
var _post_viewport_msaa2d := 0   # 进树时视口 msaa_2d 原值（_exit_tree 恢复）
var _hud: Label
var _hud2: Label

## 卡材质账本随卡组件（cards._card_mats / cards._bg_card_mats，_apply_light 遍历写昼夜参数）
var _lamps: Array[OmniLight3D] = []
var _bg_base_z := {}            # 背景层 -> 实测卡基线 z（辅助线/底衬/墙远端/云层对齐用；
                                # 摆街组件写、门面读）

var _last_light_mode := "day"

# 帧采样
var _measuring := false
var _samples: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_root = ProjectSettings.globalize_path("res://")
	_temp = _root + "temp/"
	# 组件接线（回引注入；组件实例化在成员声明处，先于一切组件调用）
	cards.w = self
	placer.w = self
	ground.w = self
	walls.w = self
	char_stage.w = self
	sky.w = self
	baker.w = self
	light.w = self
	shots.w = self
	shots._parse_args()
	if not layout_name.is_empty():
		shots._opts["layout"] = layout_name   # 地图宿主注入优先于命令行
	if _verbose():
		print("[hd2d] 工程根=", _root)
	_load_cards()
	# 运行时生成的布局优先（宿主"首次进入生成"）；否则读烘焙好的布局 JSON
	if not layout_data.is_empty():
		_layout = layout_data
	elif not str(shots._opts["layout"]).is_empty():
		_layout = _read_json_rel(LAYOUT_DIR + str(shots._opts["layout"]) + ".json")
		if _layout.is_empty():
			push_error("[hd2d] 布局缺失，退回手摆主街: " + str(shots._opts["layout"]))
	if _verbose():
		print("[hd2d] 模式=", "布局驱动:" + str(shots._opts["layout"]) if not _layout.is_empty() else "手摆主街")
		if battlefield:
			print("[hd2d] 战场模式（无墙无街开阔野地）")
	_build_world()
	shots._apply_hide_groups()
	if bool(shots._opts.get("save_scene", false)):
		shots._save_ground_scene_then_quit()
		return
	if str(shots._opts["shots"]) == "none":
		# 静默常驻（游戏内地图模式）：白天全效档点亮场景即返回，不截屏不退出
		light._apply_light("day")
		# 渲染链二分诊断口：STICK_HD2D_STAGE=a/b 跳过后处理/辉光/DOF（默认 c 全效）
		light._apply_stage(OS.get_environment("STICK_HD2D_STAGE") if OS.get_environment("STICK_HD2D_STAGE") != "" else "c")
		light._update_px_size()
		return
	else:
		await shots._run_shots(str(shots._opts["shots"]))
	print("[hd2d] DONE")
	await shots._settle(1.0)
	get_tree().quit(0)


## 运行期诊断 verbose 门（units 模块 STICK_TRACE_* 同款做法）：生产路径零
## 无条件 print，排查时设 STICK_HD2D_VERBOSE=1 打开
func _verbose() -> bool:
	return OS.get_environment("STICK_HD2D_VERBOSE") != ""


# ------------------------------------------------------------------ 参数

func _exit_tree() -> void:
	# 恢复 post 通道关掉的视口 2D MSAA（缘由见 post 层创建处注释）
	if _post_viewport_msaa2d != 0 and get_viewport() != null:
		get_viewport().msaa_2d = _post_viewport_msaa2d
	_post_viewport_msaa2d = 0


# ------------------------------------------------------------------ 资源

## 读卡元数据 JSON：优先烘焙工作区 temp/（烘卡机上的最新产物）；缺失回退
## 工程内 tex/ 副本（随包入库——别的机器 clone 后没跑过烘焙也能出图）。
func _load_meta_json(rel: String) -> Array:
	for p: String in [_temp + rel, "res://modules/hd2d/assets/tex/" + rel]:
		if FileAccess.file_exists(p):
			var f := FileAccess.open(p, FileAccess.READ)
			var arr: Variant = JSON.parse_string(f.get_as_text())
			if arr is Array:
				return arr
			push_error("[hd2d] JSON 解析失败: " + p)
			return []
	push_warning("[hd2d] 缺卡元数据（先跑对应烘焙脚本）: " + rel)
	return []


func _load_cards() -> void:
	for c: Variant in _load_meta_json(CARDS_JSON):
		_cards[str(c["card"])] = c
	for c: Variant in _load_meta_json(PROPS_JSON):
		_props[str(c["card"])] = c
	for c: Variant in _load_meta_json(NATURE_JSON):
		_nature[str(c["card"])] = c
	# 卡库规模属运行期诊断信息——verbose 门控（生产路径零无条件 print）
	if _verbose():
		print("[hd2d] 烘焙卡 %d 张" % _cards.size())
		print("[hd2d] 道具卡 %d 张" % _props.size())
		print("[hd2d] 自然物卡 %d 张" % _nature.size())


## 读 JSON（Object）：优先烘焙工作区 temp/，缺失回退工程内 tex/ 入库副本。
func _read_json_rel(rel: String) -> Dictionary:
	for p: String in [_temp + rel, "res://modules/hd2d/assets/tex/" + rel]:
		if FileAccess.file_exists(p):
			var f := FileAccess.open(p, FileAccess.READ)
			var v: Variant = JSON.parse_string(f.get_as_text())
			if v is Dictionary:
				return v
			push_error("[hd2d] JSON 解析失败: " + p)
			return {}
	return {}


func _tex_abs(p: String) -> Texture2D:
	if _tex_cache.has(p):
		return _tex_cache[p]
	# 优先用**工程内副本**（res://…/tex/）——这样场景存成 .tscn 时是外链引用而非内嵌
	if p.contains("/temp/"):
		var q := "res://modules/hd2d/assets/tex/" + p.get_slice("/temp/", 1)
		if ResourceLoader.exists(q):
			var rt := ResourceLoader.load(q)
			if rt is Texture2D:
				_tex_cache[p] = rt
				return rt
	if not FileAccess.file_exists(p):
		push_error("[hd2d] 纹理缺失: " + p)
		return null
	var img := Image.new()
	if img.load(p) != OK:
		return null
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_tex_cache[p] = t
	return t


## 软探测贴图：缺失返回 null 不报错。高清 src/<key>_alb/_nrm 变体是
## "烘卡机上有则用之"的增强档，缺失属常态（回退游戏档贴图），不该
## 每次启动都往报错日志里灌"纹理缺失"污染报错自检。
## 解析优先级与 _tex_abs 一致（temp 实文件 → 工程 tex/ 副本）。
func _tex_abs_soft(p: String) -> Texture2D:
	if p.contains("/temp/"):
		var q := "res://modules/hd2d/assets/tex/" + p.get_slice("/temp/", 1)
		if FileAccess.file_exists(q):
			return _tex_abs(p)
	if FileAccess.file_exists(p):
		return _tex_abs(p)
	return null


## 卡装配与背景卡落位随卡/摆街组件（cards._spawn_card / placer._spawn_bg_card）；
## 本面只留 solids 消费口径。


## 单栋前排建筑的地基实心带（[x0,x1,y0,y1,基线y,卡可见高]：**x=格、y=px** 的
## 混合口径，与碰撞墙消费端一致）。
## 宽度=**占位槽宽**（cells，4 格整倍数）——创始人 2026-09-15 定案：紫占地带
## 起码与白包楼框同宽（墙脚实测宽常远小于槽位，house_w16 实测仅 3.9 格，
## "比白色框还窄"读作错误）；[6][7] 与 [0][1] 因此同为槽位宽。
## 深度=烘焙实测 footprint[1]（贴地顶点相对阈值，烘端 2026-09-15 修正扁片后
## 为真实基座深），下限 2 格防个别模型仍量出扁片；落位 dz 相对墙脚基线
## （`footprint_off`[1]，烘端实测，正=朝相机），带前后沿 y = 基线
## +(dz ± fd/2)×32。旧 JSON 无 footprint_off 时默认 dz=-fd/2（带=[基线-fd×32,
## 基线]），不重烘行为不变。旧口径 [688, 基线+44] 前端比楼脚多伸 1.4 格、
## 后端退到街心 z=0（创始人：显示的碰撞箱比楼低很多），已废。
## [4]=卡底基线 px（F3 直立包楼框的底）、[5]=卡可见高 px。get_solid_rects
## 与 get_building_rects 共用。
func _building_solid_rect(occ: Array) -> Array:
	var cx: float = (float(occ[0]) + float(occ[1])) * 0.5
	var card: String = str(occ[2])
	var meta: Dictionary = _cards.get(card, {})
	var cells := float(meta.get("cells", 8.0))
	# 深度=**全模型占地深**（含屋顶出檐，footprint_full[1]；旧 JSON 回退贴地
	# 实测 footprint[1] 再回退 2.0），下限 2 格防扁片——创始人 2026-09-15：
	# 紫色不能是扁片，墙脚贴地实测对大屋顶建筑只是窄条
	var fp_full: Array = meta.get("footprint_full", Array())
	var fp: Array = meta.get("footprint", [cells, 2.0])
	var fd: float = 2.0
	if fp_full.size() > 1:
		fd = float(fp_full[1])
	elif fp.size() > 1:
		fd = float(fp[1])
	fd = maxf(fd, 2.0)
	var z: float = float(occ[3]) if occ.size() > 3 else 0.6
	var base_y: float = 516.0 + z * 24.0
	# 带后沿不越过深端行走界（黄线）——大屋顶卡的全深可能越过可行走边界
	var y0: float = maxf(base_y - fd * 24.0, DEEP_WALK_Y)
	# [0][1] 与 [6][7] 同为占位槽宽（宽度口径=白包楼框，创始人定案：
	# 紫带起码与白框同宽）
	return [cx - cells * 0.5, cx + cells * 0.5,
			y0, base_y,
			base_y, cards._card_visual_height(card),
			cx - cells * 0.5, cx + cells * 0.5]


## 前排建筑+道具的实心区间（格，[x0,x1]）——宿主映射成 2D 碰撞墙，
## 玩家在街上走不会被楼/摆件穿透（创始人 2026-09-14）。
## 建筑按**建筑格宽**对齐中心（画面宽含出檐，碰撞不该把出檐也堵死）；
## 道具按卡宽收窄 15%（视觉留余量）。细杆件（灯笼）不挡。
func get_solid_rects() -> Array:
	var out: Array = []
	for occ in _front_occ:
		out.append(_building_solid_rect(occ))
	for r in _prop_solids:
		out.append(r)
	if battlefield:
		return out   # 战场无城墙（开阔野地，四向可走）
	# 城墙碰撞带（±墙线，整带封死）：过墙只走门洞传送带（宿主 Area2D，
	# 到门口即跨墙同图瞬移——创始人口径"到门口就传送，门外也得传送过去"；
	# 整面直墙同时消除门缝夹角楔人问题）
	var wx: float = _wall_x()
	for sx: float in [-1.0, 1.0]:
		out.append([sx * wx - WALL_T * 0.5, sx * wx + WALL_T * 0.5, DEEP_WALK_Y, WALK_FRONT_PX])
	return out


## 前排建筑占地带（px 四元组 [x0,x1,y0,y1]，不含道具/城墙）——宿主转发给
## F3 建筑宽度辅助线：左右边界竖线 + 整格浅网格（创始人 2026-09-15，
## 2D 图 F3 版式样原样搬入 HD-2D；宽度口径=建筑格宽，与碰撞同源）。
## 建筑间杂物占格带同列（创始人 2026-09-15：杂物按建筑算，F3 里同样
## 画出双黄线与紫占地带——4 元组 rect，无直立包楼框）
func get_building_rects() -> Array:
	var out: Array = []
	for occ in _front_occ:
		out.append(_building_solid_rect(occ))
	for occ in _clutter_occ:
		out.append(occ)
	return out


## ── 小地图数据供给（宿主 Hd2dMapBase 按方法名 duck 调用，签名不变）──
## 实现在小地图烘焙域组件（hd2d_minimap_baker.gd）：平面图数据 + 照片式底图
## 烘焙；缓存（_minimap_layout_cache）与烘焙 rig（_bake_vp/_bake_cam）状态留本面。
## 返回结构与格→px 换算口径见该组件文件头。

func get_minimap_layout(cell_px: float = 24.0) -> Dictionary:
	return baker.get_minimap_layout(cell_px)


## 照片式底图烘焙转发（bake_minimap_strip 是协程，壳须 await 保持可等待——
## Hd2dMapBase 侧 `await _hd.bake_minimap_strip(...)` 语义不变）
func bake_minimap_strip(world_x0: float, world_x1: float,
		canvas_ground_y: float, canvas_ground_bottom: float,
		tex_w: int, tex_h: int) -> Dictionary:
	return await baker.bake_minimap_strip(world_x0, world_x1,
			canvas_ground_y, canvas_ground_bottom, tex_w, tex_h)


## 前后景分界线的 2D 等价 y（px）——可行走地面（前景）与后景的构图分界：
## zoom=1 压屏幕下 1/3 线（SKYLINE_Z 的推导即来自该契约）。注意术语：
## 旧文档多把这条线叫"地平线/天际线基线"，实为**前后景分界线**；真实地平线
## （新地平线）是末排背景基线，在这条线更远更高处，勿混淆（创始人 2026-09-15）。
## F3 黄线（ground_line_drawer）在 HD-2D 图画这条世界线，缩放时跟着真实分界走
func get_fg_bg_boundary_y() -> float:
	return 516.0 + SKYLINE_Z * 24.0


## 城门洞表（x 格 / y px **全行走带**）——传送带贴整面墙（创始人：城墙即
## 传送门；只开洞口带会把走到洞外的角色藏进墙条后面 = "靠近城门角色消失"）
## 战场无墙无门：返回空表，宿主据空表跳过传送带/引导（空 = 无需引导）
func get_gates() -> Array:
	if battlefield:
		return []
	return [
		{"x": -_wall_x(), "y0": 516.0, "y1": WALK_FRONT_PX},
		{"x": _wall_x(), "y0": 516.0, "y1": WALK_FRONT_PX},
	]


## 墙线取值（格）：手摆主街 = WALL_X；布局驱动（算法村/生成器）= 布局半宽
## ——城墙位置由布局宽度推导（城市扩建墙自动前移的运行时根基）。
func _wall_x() -> float:
	if not _layout.is_empty():
		var w: float = get_layout_width()
		if w > 8.0:
			return w * 0.5
	return WALL_X


## 墙线取值公开口（宿主地形硬化判定用：城内 = 资源算法的"硬化地面"）
func get_wall_x() -> float:
	return _wall_x()


## 摆街域（前排求解器/道具卡装配/卡底留白与 base_cut 数学）随卡组件与摆街
## 组件（cards / placer）——本面只留 duck 委托与数据消费口。


## 宿主按资源分布算法落卡（ResourceNode 点位 → 匹配自然物 PBR 卡，卡随点落）
func spawn_nature_card_at(card: String, x_px: float, y_px: float) -> void:
	placer.spawn_nature_card_at(card, x_px, y_px)


## 露天工位点（宿主转发给 TownLife 露天工位 duck）：台面上的铁砧=铁匠工位。
## 返回 2D 行走带坐标（z → y 近似映射同 _place_nature）。
func get_open_work_sites() -> Array:
	return placer.get_open_work_sites()


## 布局道具表（宿主工位/NPC 出生点推导用；手摆模式返回空）
func get_layout_props() -> Array:
	return placer.get_layout_props()


## 布局驱动模式的街宽（格）；手摆主街返回 0（宿主用 tscn 边界）
func get_layout_width() -> float:
	return placer.get_layout_width()


## 3D 街景横移（宿主按玩家 x 驱动；正交相机，视宽 74 格）
func set_cam_x(cx: float) -> void:
	if _cam != null:
		_cam.position.x = cx


## 3D 相机缩放镜像——与 2D CameraRig **逐像素 1:1**（创始人：紫箱水平移动
## 比角色快 / 蓝线与屏幕下边界不重合的根因 = 旧固定视宽 74 格在 1920 下
## 25.9 px/格，与 2D 的 24 px/格差档，所有 2D 投影物相对 3D 世界漂移）。
## 可视宽（格）= 2D 可视世界宽 px / 24 = DESIGN_HEIGHT·宽高比/(24·user_zoom)；
## 纵向 px/格 随之同为 24。锚线 z_near 按"地面占屏幕下 1/3、天际线基线压
## 1/3 线"的构图契约取值，缩放时钉死在屏幕底沿。
## 推导：屏幕底沿地面 z = z_c + h_v/(2 sinθ)（z_c = P.z − P.y/tanθ，
## h_v = DESIGN_HEIGHT/(24·user_zoom)）⇒ P.z = z_near − h_v/(2 sinθ) + P.y/tanθ。
func set_cam_zoom(user_zoom: float) -> void:
	if _cam == null or user_zoom <= 0.05:
		return
	_last_user_zoom = user_zoom
	var uz: float = clampf(user_zoom, 0.25, 8.0)
	char_stage.update_outline_eff(uz)   # 关节桶描边宽档（未装配时组件内静默跳过）
	var vp := _cam.get_viewport().get_visible_rect().size
	_apply_cam_framing(DESIGN_HEIGHT * vp.x / (24.0 * vp.y * uz), _cam)


## 按**世界可视宽**取景（px；正交 KEEP_WIDTH 下 size 即可视宽）。专供小地图烘焙：
## 玩家缩放档钳在 [0.25, 8]，全图取景常需更远（本作城镇 7080px → 需 uz≈0.27、
## 更宽的地图还要更小），故走本口绕开缩放钳制。构图锚（地面压屏下 1/3 线）与
## set_cam_zoom 同一份代码，两路口径不会分叉。
func set_cam_fit_width_px(world_px: float) -> void:
	if _cam == null or world_px <= 1.0:
		return
	_apply_cam_framing(world_px / 24.0, _cam)


## 应用正交取景（size = 可视宽，格）到给定相机：算纵向构图锚 + 近平面退避 + 景深换算。
## 单一出口——玩家缩放（set_cam_zoom）、烘焙全图取景（set_cam_fit_width_px）与
## 烘焙相机（烘焙域组件 _ensure_bake_rig）共用同一份构图锚数学，三处口径不会分叉。
## cam 的视口尺寸决定纵向可视范围（烘焙相机挂在 SubViewport 上，与主窗口解耦）；
## 景深只对主相机（带相机属性的那台）换算，烘焙相机无属性、本就不吃景深。
func _apply_cam_framing(size_units: float, cam: Camera3D) -> void:
	if cam == null:
		return
	var vp := cam.get_viewport().get_visible_rect().size
	cam.size = maxf(size_units, 1.0)
	var t := deg_to_rad(TILT_DEG)
	var h_v: float = cam.size * vp.y / maxf(vp.x, 1.0)
	# 构图锚（格口径，换轨不变）：1080/32 = 33.75 格——天际线基线压 1/3 线的世界锚线
	var h_anchor: float = DESIGN_HEIGHT / 32.0
	var z_bottom: float                                  # 屏幕底沿锚线的世界地面 z
	if battlefield:
		# 战场构图契约（半屏高，02-战斗系统.md 二-A Tier0）：全场景只有前景大地
		# ——地平线（绿草地皮远端 BF_HORIZON_Z）名义钉屏幕中线，地面占下 1/2。
		# 带前缘兜底（2026-10-05 出界修复）：战场行走带深 85 格 + 前缘余量，半屏
		# 构图在近缩放档只能装下 ~51-68 格——纯钉中线会把带前缘投到屏幕底沿
		# 之外（战线贴前缘 = 整团出界）。取 max：半屏能装下时地平线恒中线；
		# 装不下时以带前缘+余量为底锚（地平线相应上移），任意缩放档带内单位
		# 永不出屏。推导同 village 分支：P.z = z_bottom − h_v/(2 sinθ) + P.y/tanθ
		if _bf_ground_ratio > 0.0:
			# 地面占比锚（半屏高直给）：屏幕底沿 = 草远端 + 占比×整屏地面深
			z_bottom = BF_HORIZON_Z + _bf_ground_ratio * h_v / sin(t)
		else:
			z_bottom = maxf(BF_HORIZON_Z + h_v * 0.5 / sin(t), _bf_band_front_z)
		cam.position.z = z_bottom - h_v * 0.5 / sin(t) + cam.position.y / tan(t)
	else:
		z_bottom = SKYLINE_Z + h_anchor / (3.0 * sin(t))
		cam.position.z = z_bottom - h_v * 0.5 / sin(t) + cam.position.y / tan(t)
	# 近平面退避：缩放拉远后 P.z 后退，底沿锚线的地面视深（P.y·sinθ −
	# cosθ·(z_bottom − P.z)）随之变浅，uz≲0.55 起穿进近平面(0.05)被整段
	# 裁掉——裁掉的下缘露出天幕蓝＝"缩到最小屏幕下方出蓝条"（uz=0.5 实测
	# 31px，越小越长，uz=0.25 时近 2/3 屏被裁）。正交相机沿视轴平移不改变
	# 取景：沿视轴反向退 back 使视深回到 CAM_NEAR_SAFE，锚线分毫不动。
	var depth_bottom: float = cam.position.y * sin(t) - cos(t) * (z_bottom - cam.position.z)
	var back: float = maxf(0.0, CAM_NEAR_SAFE - depth_bottom)
	cam.position += Vector3(0.0, sin(t), cos(t)) * back
	# 景深与缩放解耦：far blur 起点钉在**世界线**上——天际线基线向镜头前移
	# DOF_FAR_START_AHEAD 格（第二排从这条线起吃半档模糊；创始人：第二排景深要明显）。
	# dof_blur_far_distance 是相机本地距离，缩放移动相机后若不同步换算，
	# 模糊带会跟着缩放漂移（创始人：景深不应受镜头缩放影响）；上面的退避
	# 抬高 P.z，下式同量吸收（世界线的本地深度随之 +back，锚定关系不变）
	if cam == _cam and _cam_attrs != null:
		_cam_attrs.dof_blur_far_distance = (cam.position.z - SKYLINE_Z - DOF_FAR_START_AHEAD) / cos(t)


## 3D 视图对地面纵深的屏幕压缩率（俯角前缩）：3D 与 2D 逐像素 1:1 后，
## 1 格地面纵深在屏幕上的竖直像素 = 24·sin(俯角)，压缩率即纯 sin(俯角)。
## 2D 画布的特效/调试框按 2D y 直绘会与 3D 世界错开 (1-压缩率) 倍——
## 宿主用本值做坐标重映射（remap_fx_pos）。
func get_ground_squash() -> float:
	return sin(deg_to_rad(TILT_DEG))


## 3D 取景中心对应的地面世界 z（格）：z_c = P.z − P.y/tanθ（屏幕中心点
## 的地面深度，沿视轴退避不改变该值——正交投影）。视觉域坐标协议
##（remap_fx_pos 族）的活锚：取景中心随缩放档/构图契约变，旧实现锚死
## walk_front 常量，相机一对错位时 2D 画布特效（伤害飘字等）整体偏移
## （实测战场 Y 跟随态下沉半屏，2026-10-05）
func get_view_center_ground_z() -> float:
	if _cam == null:
		return 0.0
	return _cam.position.z - _cam.position.y / tan(deg_to_rad(TILT_DEG))


## 地面世界抬升（格）：台面/台后城内地面比街面高 PLAT_H——角色走到 z<路肩
## 前缘（BAND_SIDEWALK.y）且在墙线以内时脚底抬到台面标高（创始人 2026-09-15：
## 玩家移动到台面时该抬升）。战场/资源图无台面语义恒 0；墙外野地维持 y=0。
func get_ground_lift_world(x: float, z: float) -> float:
	return ground.get_ground_lift_world(x, z)


## 2D 画布域抬升（px，zoom=1 基准）：世界抬升 × 24 × cosθ——与角色 billboard
## 脚底抬升同源同值，宿主 remap_fx_pos 消费，青箱/FX/黄线随之贴到抬升后的地面
func get_ground_lift_px(x_px: float, y_px: float) -> float:
	return ground.get_ground_lift_px(x_px, y_px)


## 光照档公开封装（宿主昼夜挂钩调；_apply_light 幂等可反复调）。
## 档位实际切换时发底图脏信号——照片底图的光照冻结在烘焙时刻，昼夜换档
## 须重烘一版（Hd2dMapBase 防抖后自动执行）。
func set_light_mode(mode: String) -> void:
	var changed: bool = mode != _last_light_mode
	light._apply_light(mode)
	if changed:
		minimap_base_dirty.emit()


## 底图脏标记公开口：3D 街景内容在运行期变更时由变更方调用（换卡/扩建/
## 城墙升档等未来接入方）——照片底图防抖重烘 + 平面图缓存失效重建。
## 光照档切换走 set_light_mode（同发信号）。
func mark_minimap_base_dirty() -> void:
	_minimap_layout_cache = {}
	minimap_base_dirty.emit()


# ------------------------------------------------------------------ 世界

func _build_world() -> void:
	# --- 环境（天空 + 环境光 + 深雾 + 辉光）---
	_env = Environment.new()
	# 贴图天空（创始人 2026-09-16：弃程序化天空改天幕 quad，纯蓝临时口径）——
	# 程序化天空在 26° 俯角正交相机下其"天空/地面半球"分界压在屏幕中线，
	# 蓝天画不进"地面远端→中线"带（灰带读作天空只盖上半屏）。背景模式退
	# BG_COLOR 只作天幕外的兜底色，真正的天空 = 天幕域 _build_sky 的相机子天幕。
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = SKY_BLUE
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# 发现 5 继承：LINEAR。卡是已带光照的烘焙图，任何 filmic/aces 都会把它压灰。
	_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_env.tonemap_exposure = 1.0
	_env.tonemap_white = 1.0
	# 辉光（HD-2D 的"电影感"一半来自这里；_a 基线档会关掉做对照）
	_env.glow_enabled = true
	_env.glow_intensity = 0.85
	_env.glow_bloom = 0.10
	_env.glow_hdr_threshold = 1.05
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	# 深雾：给远景压出空气透视（这是"纵深"里除了 DOF 之外的另一半）。
	# 强度要克制：雾压过头会把整条街洗成奶白（实测 density 0.85/begin 30 直接毁画面）。
	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_depth_begin = 36.0
	_env.fog_depth_end = 92.0
	_env.fog_density = 0.72
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

	# --- 太阳（card 靠伪法线吃它）+ 冷天空补光 ---
	# 实时阴影是诊断口（STICK_SUN_SHADOW=0 关）：方向光 shadow pass 每帧把
	# 全 3D 场景（含 ~5k MultiMesh 实例）重渲一遍进 shadow map，成本与窗口
	# 分辨率无关（P0 实测 720p 与 1080p 帧时同阶）。战场模式单位全在一屏、
	# 接触阴影走脚底贴片，实时影的观感收益待与帧时一起验收定去留。
	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = OS.get_environment("STICK_SUN_SHADOW") != "0"
	_sun.directional_shadow_max_distance = 140.0
	add_child(_sun)
	# 补光（fill）：从主光反侧打一盏**不投影**的冷光，专门抬暗部。
	# 高调照明的关键是"明暗比小"——只靠环境光抬暗部会整体发灰，加一盏有方向性的
	# 补光才能在压反差的同时保住体积感。
	_fill = DirectionalLight3D.new()
	_fill.shadow_enabled = false
	add_child(_fill)

	# --- 建筑卡（先摆楼：底衬远端/辅助线要用实测的层基线）---
	_card_root = Node3D.new()
	_card_root.name = "Cards"
	add_child(_card_root)
	_shadow_root = Node3D.new()
	_shadow_root.name = "BuildingShadows"
	add_child(_shadow_root)
	_char_entities_root = Node3D.new()
	_char_entities_root.name = "CharEntities"
	add_child(_char_entities_root)
	if not battlefield:
		placer._place_rows()   # 前排吸附整格 + 两排背景留缝、后层插前层缝
	_prop_root = Node3D.new()
	_prop_root.name = "Props"
	add_child(_prop_root)
	placer._place_props()  # 街面小零件（摊/桶/车/井…）；战场模式 = 战场遗物（BF_PROPS）
	placer._place_nature() # 野外树木/矿物卡（西森林带+东段城外）；战场模式 = 战痕散布

	# --- 地面：底衬（远端=末层实测根部，即真实地平线）+ 台面 + 辅助线 + 道路 ---
	_ground_root = Node3D.new()
	_ground_root.name = "Ground"
	add_child(_ground_root)
	# 地表中远景用**低对比**贴图（rammed_earth std=0.034），别用 cobble（std=0.107）：
	# 20° 掠射下 128px 贴图被压 3 倍以上，用高对比纹理时 mip 会在中景糊出一片
	# "碎石噪声"，读作脏。路面同理，tile 放大到 10 减少 minification。
	# 中远景地面（背景地面带，仅城内街景）：**与台面同材质同高**（创始人
	# 2026-09-15：建筑带身后的城内地面保持台面标高一直到地平线，不存在
	# "踩空"落差）——世界锚定 UV 下与台面窄带无缝续接成一整块台面；野地
	# 在墙外，由草底层接管（y=0）。
	# 战场/资源图无台面语义，远景带维持旧分幅 y=0 平铺。所有地皮走世界锚定 UV
	# （_add_ground_plane_at 内统一）——同材质跨带无缝续接、缩放全局一致。
	# 战场无背景楼群：兜底远端与主地皮远端对齐（z=0 即地平线，set_cam_zoom
	# 战场契约把这条线钉屏幕上 1/3 线）——若吃 SKYLINE_Z 系默认值，绿兜底会
	# 越过地平线多铺 ~10 格，地面占比冲到 76%（创始人 2/3 口径被顶掉）
	var far_z: float = 0.0 if battlefield \
			else float(_bg_base_z.get(2, SKYLINE_Z - BG_LAYER_GAP * 2.0))
	var wx: float = _wall_x()
	var far_y: float = 0.0 if battlefield else PLAT_H
	if battlefield:
		# 战场地面：全幅绿草单一材质。近端铺到 z 210——缩放下限 0.25 档的
		# 屏幕底沿锚线在 z 51.32/uz ≈ 205（set_cam_zoom 战场分支），铺到 115
		# 会在深缩放档露出底沿外的天幕蓝条（创始人 2026-09-17 指认的"缩太小
		# 出蓝条"在战场/资源图的另一半成因）；常态缩放档这段在画面外零开销。
		# 木本杂物已清空
			ground._add_ground_plane_at("grass_alb_128.png", 0.0, 600.0,
				0.0, 210.0, 0.0, 8.0, GRASS_TINT)
	else:
		# 远景地面带（与台面同高 y=PLAT_H，**与台面同一块面、代码里同一段**）：
		# 城内段 flagstone 石板从第三层楼根拉通到台面外缘（创始人 2026-09-16：
		# 整个城内一个材质；2026-09-17：与台面合并成一块，不再分段），墙外段
		# 草地条铺到第三排楼根外 2 格，全程淡草色与城外近野同色不断缝。材质用
		# flagstone 干净方板——band_shoulder_stone 是贴墙根条带图，顶缘墙根
		# 暗带在世界锚定平铺下每 tile 复现成横贯的"污渍带"（创始人
		# 2026-09-16 指认），平铺地皮一律不用条带图。
		ground._add_ground_plane_at("flagstone_128.png", 0.0, wx * 2.0,
			far_z, BAND_SIDEWALK.y, far_y, 5.0, Color(1.04, 1.00, 0.93))
		var far_x: float = maxf(wx + 30.0, _bg_span_x + 2.0)
		ground._add_ground_plane_at("grass_alb_128.png", (wx + far_x) * 0.5, far_x - wx,
			far_z, BAND_SIDEWALK.x, far_y, 8.0, Color(0.90, 0.93, 0.80))
		ground._add_ground_plane_at("grass_alb_128.png", -(wx + far_x) * 0.5, far_x - wx,
			far_z, BAND_SIDEWALK.x, far_y, 8.0, Color(0.90, 0.93, 0.80))
	# 兜底大地皮：分段没铺到的区域露脸时防"露天空"（创始人：缩太小下边界
	# 出现虚空）。这层压在所有分段之下（y=-0.05），远端与远景地皮同深（第三
	# 层楼根）。近端到 z=40 防前缘露底。材质=草（创始人 2026-09-16：城外全是
	# 草地，兜底同步换草防边缘露夯土）
	var fb_near: float = 50.0 if battlefield else 40.0
	var fb_far: float = 0.0 if battlefield else far_z
	var fb_depth: float = fb_near - fb_far
	var fb_mesh := PlaneMesh.new()
	fb_mesh.size = Vector2(1200.0, fb_depth)
	var fb_mi := MeshInstance3D.new()
	fb_mi.mesh = fb_mesh
	var fb_mat := StandardMaterial3D.new()
	var fb_tex := _tex_abs(_temp + GROUND_DIR + "grass_alb_128.png")
	if fb_tex != null:
		fb_mat.albedo_texture = fb_tex
	# 战场与街景同用淡草档（草色一色，见 GRASS_TINT 注）
	fb_mat.albedo_color = GRASS_TINT
	fb_mat.roughness = 0.95
	fb_mat.uv1_triplanar = true
	fb_mat.uv1_world_triplanar = true
	fb_mat.uv1_scale = Vector3.ONE / 6.0
	fb_mi.material_override = fb_mat
	fb_mi.position = Vector3(0.0, -0.05, (fb_far + fb_near) * 0.5)
	fb_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fb_mi.name = "GroundFallback"
	_ground_root.add_child(fb_mi)
	ground._add_sky_backdrop()            # 原 2D 天空贴图（远山/树线）立于背景之后（已删空壳）
	sky._place_clouds()                   # 2D 手绘云烘贴图 → 漂移云牌（异步烘制）
	if not battlefield:
		ground._add_platform()            # 石板台面（拉通城内到墙线）+ 台肩石坎镶边
		walls._build_walls()              # 城墙转角收边 + 门洞（碰撞走 get_solid_rects）
		# 战场野地不再有第二/第三材质（创始人 2026-09-16：整个大地一个材质，
		# 草灰绿夯土带与中轴夯土东路已删——地面只有上方那层全幅绿草）
	shots._add_width_guides()             # 建筑宽度辅助线（--debug 才显示）
	shots._add_horizon_guides()           # 1/3 线（橙）+ 第三排基线（绿）（--debug 才显示）
	for dx in _door_path_xs:
		ground._add_door_path(float(dx), 3.6)   # 门前短径（楼脚→台肩→路面）
	if not battlefield:
		# 地面两态（创始人 2026-09-16：城内全部中心城区石板、城外全是草地；
		# 城乡过渡材质与稀疏草土退役，口径详见 HD-2D街景系统.md §三点五）。
		# 草底层全幅先铺（y=0，远端同远景地皮一块远退到地平线，不分段），城内
		# 石板分段压其上（路面 y 0.02 / 台面 0.65 防 z-fight）；淡草色与远景
		# 墙外段同色（2026-09-17：城外全程一个色调，近野/远条不断缝）
		ground._add_ground_plane_at("grass_alb_128.png", 0.0, 600.0,
			far_z, BAND_ROAD.y, 0.0, 8.0, Color(0.90, 0.93, 0.80))
		ground._add_ground_plane_at("band_road_stone_128.png", 0.0, wx * 2.0,
			BAND_ROAD.x, BAND_ROAD.y, 0.02, 10.0, Color(0.86, 0.89, 0.96))

	# --- 灯笼点光源（暖光；让"真 3D 光照"这条线可验证）---
	# 战场无街灯（野外夜档靠月光档，不沿街布灯）
	_lamp_root = Node3D.new()
	_lamp_root.name = "Lamps"
	add_child(_lamp_root)
	# 沿街每 8 格一盏，只铺城心 ±48——越近城墙越暗（昼夜渐变的一部分）
	if not battlefield:
		for i in 13:
			var l := OmniLight3D.new()
			l.position = Vector3(-48.0 + float(i) * 8.0, 2.5, 4.2)
			# 窗光去黄（创始人 2026-09-15）：街灯降饱和（旧 (1.0,0.63,0.30) 一路刷墙
			# 把画面带黄），能量档由 _apply_light 按昼/夜给
			l.light_color = Color(1.0, 0.72, 0.45)
			l.light_energy = 1.0
			l.omni_range = 9.5
			l.shadow_enabled = i % 2 == 0
			l.light_specular = 0.2
			_lamp_root.add_child(l)
			_lamps.append(l)

	# --- 相机：正交 + 纯正面 20° 俯视 ---
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_WIDTH
	_cam.size = CAM_W
	_cam.near = 0.05
	_cam.far = 600.0
	_cam.rotation = Vector3(deg_to_rad(-TILT_DEG), 0, 0)
	var t := deg_to_rad(TILT_DEG)
	_cam.position = Vector3(0, CAM_CY + sin(t) * CAM_DIST, cos(t) * CAM_DIST)
	# 景深挂在 CameraAttributes（Godot 4 的 DOF 不在 Environment 里，在相机属性上）
	_cam_attrs = CameraAttributesPractical.new()
	_cam.attributes = _cam_attrs
	add_child(_cam)
	_cam.current = true
	# 初始取景 = 正式场景默认档（CameraRig.user_zoom=0.75，正式链路由
	# hd2d_street_map 逐帧同步接管；测试场景没人接管，须同值否则渲染验收
	# 与正式画面差一档缩放）+ 下边界锚定校正
	set_cam_zoom(0.75)
	sky._build_sky()    # 贴图天幕 + 日/月盘（相机子节点，须在 set_cam_zoom 之后建）

	# --- HD-2D 后处理（屏幕空间：移轴 + 暗角 + 分级）---
	_post_layer = CanvasLayer.new()
	_post_layer.name = "PostHD2D"
	_post_layer.layer = 100
	add_child(_post_layer)
	_post_mat = ShaderMaterial.new()
	_post_mat.shader = POST_SHADER
	_post_rect = ColorRect.new()
	_post_rect.name = "PostRect"
	_post_rect.material = _post_mat
	_post_rect.color = Color(1, 1, 1, 1)
	_post_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_post_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_post_layer.add_child(_post_rect)

	# post 通道经 hint_screen_texture 整屏拷贝背缓冲：所在视口开着 msaa_2d 时，
	# 拷贝读回的是未 resolve 的多重采样数据，R/G/B 落自不同子像素采样点——
	# 全屏 RGB 色散，只在描边细线等高对比处肉眼可见（2026-09-30 验收指正根因；
	# HUD 在更高 CanvasLayer 自绘不经这份拷贝，所以只有 3D 世界内容花）。
	# 本视口 2D MSAA 关到退出树为止：3D 世界抗锯齿走 msaa_3d 不受影响；
	# 纯 2D 场景不经 hd2d_world，工程级 msaa_2d=2（2D 路径抗锯齿生命线）保持不动。
	_post_viewport_msaa2d = get_viewport().msaa_2d
	get_viewport().msaa_2d = Viewport.MSAA_DISABLED

	# HUD 标签（只在遮挡对照图里显示，给两格加字；工厂在出图工装组件）
	_hud = shots._make_label(Vector2(24, 18), 30)
	_hud2 = shots._make_label(Vector2(984, 18), 30)
	_hud.visible = false
	_hud2.visible = false


## 游戏接入：生成一个独立角色实例（各自 rig/动画），由宿主逐帧驱动。
## 关节烘焙路线（裁决#15）装配随角色舞台组件（char_stage）。
func spawn_character() -> Node:
	return char_stage.spawn_character()


## 前排/背景摆街与接地影随摆街/卡组件（placer._place_rows / cards._spawn_building_shadow）；
## 布局驱动后景的最大根部半径留在本面（_build_world 远景地面带墙外段消费）。
## 布局驱动后景（plan.row1/2）的最大根部半径（格）——远景地面带墙外段铺到
## max(墙线+30, 它+2)，保证第三排楼脚脚下有地（地面远端与第三排根部对齐）
var _bg_span_x: float = 0.0


## 前排加建时补背景楼（建造系统事件接线入口；初始生成走 placer._place_rows）：
## 只补 bg1 主天际线——bg2 是地平线补缝位，由遮挡关系自然成立，不随加建补
func spawn_bg_for_front(front_card: String, fx: float) -> void:
	placer.spawn_bg_for_front(front_card, fx)


## 门面逐帧：帧采样 + 天体弧线驱动。云漂移随云组件自己的 _process
##（hd2d_clouds.gd，子节点后于父节点跑，两者状态互不依赖——拆分前后同帧完成）
func _process(delta: float) -> void:
	if _measuring:
		_samples.append(delta * 1000.0)
	sky._update_celestial()
