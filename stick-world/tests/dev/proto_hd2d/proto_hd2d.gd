extends Node3D
## proto_hd2d.gd —— 「八方旅人式 HD-2D」可行性原型（2D 火柴人挂进 3D 场景）
##
## 回答一个问题：把 2D 绘制的火柴人放进 SubViewport、再把该纹理贴到 3D 场景里的
## billboard/quad 上，配合景深 + 辉光 + 暗角 + 分级的后处理，能否得到
## "2D 角色清晰、3D 场景有电影感纵深"的 HD-2D 观感。
##
## 固定跑法（可反复运行，产物落 stick-world/temp/proto_hd2d/）::
##
##   "F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
##     --path stick-world res://tests/dev/proto_hd2d/proto_hd2d.tscn -- --shots=all
##
##   # 只出某一张：--shots=a | b | c | d | e
##   # 性能档（关 vsync + 可选放大分辨率压过刷新率上限）：--perf=1 [--res=2560x1440]
##   # SubViewport 更新模式对照：--sv=always|once|disabled
##   # 角色 quad 通道对照：--char=blend|scissor
##
## 依赖（复用 proto_25d 已提交的 Blender 半场产物，本目录不改它）::
##   stick-world/temp/proto25d/cards.json + cards/*.png    建筑卡（albedo + glow）
##   stick-world/temp/ground_tiles/*.png                   地面分带贴图
##   若缺，先跑： blender -b --factory-startup -P stick-world/tests/dev/proto_25d/blender_proto.py
##
## 坐标约定：Godot 单位 = 1 格 = 32 世界单位（同 proto_25d）。
##   相机正交、yaw=0°、俯角 20°（对齐交接档 §0.3「纯正面 + 20° 微俯视、禁水平偏航」）。
##
## ── 继承 proto_25d 的五条实测发现（不得回退）────────────────────────────
##   1. 卡与相机同基 → 像素级落位（本文件 _cam_basis 与卡 quad 的 basis 同源）；
##   2. albedo 亮度差分伪造法线，平面卡才吃真 3D 光照（card.gdshader）；
##   3. 光照别双计：环境光 + 太阳能量总和 ≈ 1.0（见 _apply_light）；
##   4. render_mode depth_prepass_alpha 消矩形影（card.gdshader）；
##   5. 色调映射用 LINEAR —— 卡是已带光照的烘焙图，filmic/aces 会把它压灰。
##
## ── 本原型相对 proto_25d 修掉的一个 bug ────────────────────────────────
##   proto_25d 把建筑卡 quad 的中心直接放在 y=0，**从未使用 cards.json 里的
##   `anchor`**。卡是按"相机平面包围盒"裁的，中心并不在地面 → 卡整体下沉
##   3.5~4 格（约 card 高度的 30~45%），建筑只剩上半截露在地面以上。
##   本原型按 anchor 落位（见 _spawn_card），建筑底部严格落在世界 y=0。

const S := 1.0 / 32.0                    # Blender 世界单位(px) -> Godot 单位(格)
const TILT_DEG := 26.0                   # 俯角：创始人要求"稍微增加"（原 20°），本次 +6°
const CARD_SHADER := preload("res://tests/dev/proto_hd2d/card.gdshader")
const CHAR_HOST := preload("res://tests/dev/proto_hd2d/char_sprite_3d.gd")
const POST_SHADER := preload("res://tests/dev/proto_hd2d/post_hd2d.gdshader")
const BUILDING_SHADOW_SHADER := preload("res://tests/dev/proto_hd2d/building_shadow.gdshader")

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

## 道具（bake_props.py 从 props.py 库烘的卡，26° 与建筑卡同视角）。
## 摆位（2026-09-14 手工摆=村A主场景语义翻译，随建筑落位走绝对坐标）：
## `x` = 街格坐标；`z` = 纵深（台面楼脚前带 ≈4.2~5.8 / 路面 ≈5.5~6.5）；
## `plat=true` → 台面（y+PLAT_H）；false → 路面（y=0）。
const PROPS: Array = [
	# 铁匠铺（smithy@-7.5）门前工位
	{"card": "anvil", "x": -9.5, "z": 4.5, "plat": true},
	{"card": "grindstone", "x": -5.0, "z": 4.3, "plat": true},
	# 宅邸（guildhall@+8）前市集面（路面上，井居中）
	{"card": "market_stall", "x": 14.5, "z": 4.6, "plat": false},
	{"card": "market_table", "x": 18.0, "z": 5.6, "plat": false},
	{"card": "produce_baskets", "x": 21.0, "z": 4.6, "plat": false},
	{"card": "well", "x": 3.0, "z": 5.2, "plat": false},
	{"card": "banner", "x": 12.5, "z": 4.5, "plat": true},
	{"card": "lantern", "x": 28.0, "z": 4.6, "plat": true},
	{"card": "bench", "x": 7.0, "z": 5.4, "plat": false},
	# 西村口民居（house_w16@-50）与石造仓库（warehouse@-26）前
	{"card": "basket", "x": -50.0, "z": 4.4, "plat": true},
	{"card": "cart", "x": -32.0, "z": 6.0, "plat": false},
	{"card": "crate", "x": -20.5, "z": 4.4, "plat": true},
	{"card": "barrel", "x": -17.0, "z": 4.2, "plat": true},
	{"card": "sack_stack", "x": -24.0, "z": 5.8, "plat": false},
	# 西城门塔（tower@-90）前
	{"card": "lantern", "x": -87.0, "z": 4.6, "plat": true},
	# 东民居（house_w8@+36）前
	{"card": "barrel_stand", "x": 30.5, "z": 4.3, "plat": true},
	{"card": "pot", "x": 33.5, "z": 4.4, "plat": true},
	# 谷仓（barn@+51.5 落地面）、风车（windmill@+67）与马厩（stable@+76）前
	{"card": "haystack", "x": 47.0, "z": 5.6, "plat": false},
	{"card": "log_pile", "x": 44.0, "z": 6.0, "plat": false},
	{"card": "trough", "x": 70.0, "z": 5.0, "plat": false},
	{"card": "bench", "x": 62.0, "z": 5.0, "plat": false},
	# 东城门塔（gatehouse@+88.5）前
	{"card": "flower_box", "x": 84.0, "z": 4.4, "plat": true},
	{"card": "wheelbarrow", "x": 90.5, "z": 5.4, "plat": false},
]

## 自然物（bake_nature.py 从 nature.py 16 类库烘的卡）——手摆**纯景**散布。
## 资源点不在此表：野外资源分布走 resource_gen 程序化算法（群落散布+林区
## 梯度，创始人：算法就在那），宿主生成 ResourceNode 后经 spawn_nature_card_at
## 让 PBR 卡随点落。`z` ≥ 5 前景带。
const NATURE_SPOTS: Array = [
	# 西墙外**开阔带**纯景（近墙净空 12 格后才是林线——创始人：传送出去先见野地）
	{"card": "dead_tree", "x": -118.0, "z": 9.0},
	{"card": "bush", "x": -114.0, "z": 5.5},
	{"card": "grass_clump", "x": -108.0, "z": 5.0},
	{"card": "mushrooms", "x": -116.0, "z": 5.2},
	{"card": "stump", "x": -111.0, "z": 5.5},
	# 东墙外东路开阔带纯景
	{"card": "grass_clump", "x": 98.5, "z": 5.0},
	{"card": "bush", "x": 101.0, "z": 5.5},
	{"card": "stump", "x": 100.0, "z": 5.4},
	{"card": "bush", "x": 109.0, "z": 5.0},
	{"card": "dead_tree", "x": 116.0, "z": 9.5},
	{"card": "rubble", "x": 114.0, "z": 5.5},
]

## 战场遗物（battlefield 模式手摆）：旧 12V12 战场旧址的残营读法——残旗/破车/
## 桶箱散在开阔地，全落地面（无台面）。活树/矿不在此表：野地资源走 resource_gen
## 算法全域撒布（宿主 Hd2dBattlefieldMap 消费），战场只做战痕。
const BF_PROPS: Array = [
	{"card": "banner", "x": -20.5, "z": 4.8},
	{"card": "banner", "x": 17.5, "z": 5.6},
	{"card": "cart", "x": 7.5, "z": 6.2},
	{"card": "barrel", "x": -31.0, "z": 5.2},
	{"card": "barrel", "x": 33.5, "z": 4.6},
	{"card": "crate", "x": -9.5, "z": 5.0},
	{"card": "crate", "x": 44.0, "z": 6.0},
	{"card": "wheelbarrow", "x": -45.5, "z": 5.4},
]

## 战场野地纯景（battlefield 模式手摆）：枯木/断桩/碎石堆 = 战痕，草丛灌木 =
## 荒野回生。`z` ≥ 5 前景带，x 铺满 ±94 格战场全域（中心留稀疏便于列阵读法）。
const BF_NATURE_SPOTS: Array = [
	{"card": "dead_tree", "x": -88.0, "z": 9.5},
	{"card": "dead_tree", "x": -62.0, "z": 6.0},
	{"card": "dead_tree", "x": 24.0, "z": 10.0},
	{"card": "dead_tree", "x": 77.0, "z": 8.0},
	{"card": "dead_tree", "x": 91.0, "z": 6.5},
	{"card": "stump", "x": -73.0, "z": 5.4},
	{"card": "stump", "x": -14.0, "z": 9.0},
	{"card": "stump", "x": 38.5, "z": 5.6},
	{"card": "stump", "x": 68.0, "z": 10.5},
	{"card": "rubble", "x": -52.0, "z": 6.4},
	{"card": "rubble", "x": -3.5, "z": 5.8},
	{"card": "rubble", "x": 12.5, "z": 9.4},
	{"card": "rubble", "x": 57.0, "z": 5.2},
	{"card": "boulder", "x": -81.0, "z": 7.5},
	{"card": "boulder", "x": 84.5, "z": 9.0},
	{"card": "bush", "x": -68.5, "z": 9.8},
	{"card": "bush", "x": -25.0, "z": 5.6},
	{"card": "bush", "x": 29.0, "z": 6.8},
	{"card": "bush", "x": 87.5, "z": 5.4},
	{"card": "grass_clump", "x": -58.0, "z": 5.2},
	{"card": "grass_clump", "x": -36.0, "z": 9.6},
	{"card": "grass_clump", "x": 3.0, "z": 5.4},
	{"card": "grass_clump", "x": 48.5, "z": 10.0},
	{"card": "grass_clump", "x": 72.5, "z": 5.8},
	{"card": "mushrooms", "x": -43.0, "z": 8.6},
	{"card": "mushrooms", "x": 62.0, "z": 6.2},
]

## 前排**摆位意图表**（2026-09-15 行业惯例重构，创始人：别把位置绑死整数格）：
## 人只声明 card + 语义锚点 x + 纵深（"大概在哪"），实际 x 由 _resolve_front_row
## 按**画面宽**（cards.json units 数据包围盒）推挤分配——重叠在求解阶段就不可能
## 发生，锚点 ±0.2 格确定性微抖动破机械栅格感。顺序 = 村A 语义翻译：
## 西段居住/仓储（tower/hayloft/house_w16/warehouse）→ 中段市集/行政（smithy1/
## guildhall/shop/house_w8）→ 东段作坊/田园（barn/windmill/stable/gatehouse）；
## cottage 落墙外开阔带。未进前排的卡种全量参与背景层分带轮转。
## `z` = 纵深错落（0.4~1.3 台面为主，谷仓/孤屋落地面）；`door` = 门前短径。
const FRONT_ROW: Array = [
	{"card": "cottage_w6", "x": -102.0, "z": 2.4, "door": false},
	{"card": "tower_w6", "x": -90.0, "z": 0.9, "door": false},
	{"card": "hayloft_w8", "x": -69.0, "z": 0.7, "door": false},
	{"card": "house_w16", "x": -50.0, "z": 0.7, "door": true},
	{"card": "warehouse_w16", "x": -26.0, "z": 1.25, "door": false},
	{"card": "smithy1_w8", "x": -7.5, "z": 0.45, "door": true},
	{"card": "guildhall_w12", "x": 8.0, "z": 0.85, "door": true},
	{"card": "shop_w8", "x": 23.5, "z": 0.6, "door": false},
	{"card": "house_w8", "x": 36.0, "z": 0.6, "door": true},
	{"card": "barn_w12", "x": 51.5, "z": 2.4, "door": false},
	{"card": "windmill_w6", "x": 67.0, "z": 0.7, "door": false},
	{"card": "stable_w12", "x": 76.0, "z": 0.7, "door": false},
	{"card": "gatehouse_w8", "x": 88.5, "z": 0.4, "door": true},
]
## 背景层（创始人 2026-09-14 定案；2026-09-15 改两排——"后面有两排就够了"）：
##   · 第二排基线压**屏幕下 1/3 线**（33.3% 从底）——该线同时是第一排（+地面）
##     屏幕区的上边界：下 1/3 归前排与街面，中 1/3 起归背景楼群，两排在一条线交界；
##   · 前排楼身挡住 bg1 根部、bg1 从前排楼顶上方露出（高低咬合）＝"第二排插第一排缝"；
##   · 两排背景每层**楼间留缝不贴死**，后层楼**吸附进前层的缝隙**；
##   · 末层（bg2）基线 = 真实地平线（底衬远端同步收到此处），楼身把地平线遮死。
const SKYLINE_Z := -6.73                 # 基线压屏幕下 1/3 线：v=-h/6 → z=-(v+CY·cosθ)/sinθ
const BG_LAYERS := 2                     # 背景排数（创始人 2026-09-15：第三层挡天空+太阳，删掉）
const BG_LAYER_GAP := 3.5                # 背景层距（格）：屏幕上每层基线差 ≈3.7% 屏高（创始人：后排别内缩太多）
## 远焦模糊起点：天际线基线向镜头前移的格数（世界线，经 set_cam_zoom 随缩放换算、
## 不随缩放漂移）——前排零模糊口径不变，第二排从这里开始吃半档模糊
## （创始人 2026-09-15：第二排景深太不明显，根因=起点原钉在天际线上、第二排恰好吃不到）
const DOF_FAR_START_AHEAD := 0.0   # 回到初始渐变（创始人 2026-09-15：前移+强过渡让渐变糊成一档）
## 背景层距离染色（空气透视：越远越淡越冷）
const BG_TINTS: Array = [
	Color(0.80, 0.84, 0.93), Color(0.85, 0.885, 0.945), Color(0.90, 0.925, 0.96),
]

## 地面分带（格；z 增大 = 朝相机）。
## 基线纪律（创始人纠偏）：**建筑基线 = 路肩带顶线**。
## 路肩从 z=0.4 开始而不是 0：卡的**烘焙接触阴影**也画在卡的深度面上（z≈-1.5），
## 与路肩面在 z≈0 处深度相等 → 会 z-fighting 并露出一条带卵石纹理的"假暗地"。
## 路肩前移 0.4 格（屏幕上约 3px）后深度测试干净，且那 3px 正好留给建筑的接触阴影，
## 形成"建筑站在路肩上、脚下有一线接地影"的正确观感。
const BAND_SIDEWALK := Vector2(0.42, 1.95)  # 路肩（建筑根部 → 外缘；细条，占位）
const PLAT_H := 0.65                        # 人行道台面高（格）≈17px：整面垫高，建筑落在台面上
const BAND_ROAD := Vector2(1.9, 46.0)       # 道路（角色活动面，铺到画面外）

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
const WALK_FRONT_PX := 1294.0 # 行走带前端 px（宿主 WALK_FRONT_Y；= 688 + 18.93*32）
## 建筑接地影的 z 区间**必须整段落在路肩之外**（z ≥ 2.0）：
## 影和路肩都是贴地水平面，z 区间一旦重叠，深度值必然相等 → z-fighting。
const BSHADOW_Z := 3.3
const BSHADOW_DEPTH := 2.6

## 角色站位（3 个，全部正对相机）：主角色在路中、一前一后两个做纵深参照
const CHARS: Array = [
	{"x": -19.0, "z": 16.0, "flip": true},
	{"x": 6.0, "z": 12.0, "flip": false},
	{"x": 21.5, "z": 9.0, "flip": true},
]
## 遮挡验证：两个角色、同 x、只差 z。判读方式：
##   x=-11 的那个正对 house_w8 的墙心（会被房子挡住）；
##   x=-30.5 的那个在街排空隙（左边没房子，任何 z 都该看得见）—— 它是**对照组**，
##   证明"z=-3 这一层的角色确实被渲染了"，从而把 x=-11 那个的消失归因于遮挡
##   而不是"没画出来"。
## OCC_X := 被墙挡的那个的 x；OCC_CTRL_X := 对照组 x
const OCC_X := -11.0
const OCC_CTRL_X := -30.5
const OCC_FRONT_Z := 4.0
const OCC_BEHIND_Z := -3.0

var _root := ""
var _temp := ""
var _cards: Dictionary = {}
var _props: Dictionary = {}
var _nature: Dictionary = {}
var _layout: Dictionary = {}      # 布局驱动模式的数据（空 = 手摆主街模式）
## 运行时生成的布局（宿主"首次进入生成"注入，创始人 2026-09-15）——
## 优先于 JSON 文件；非空时 _ready 直接吃它。
@export var layout_data: Dictionary = {}
var layout_name := ""             # 布局名（--layout= 或地图宿主 set；空 = 手摆主街）
var battlefield := false          # 战场模式（城东开阔野地：无墙无街无楼群，战痕散布）
var resource_field := false       # 城外资源图模式（同战场式开阔，但无战争遗物、无天空剪影）
var _tex_cache: Dictionary = {}

var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _sun_disc: MeshInstance3D   # 显式太阳盘（相机子节点，昼显夜隐，建筑自动遮挡）
var _fill: DirectionalLight3D
var _ground_root: Node3D
var _card_root: Node3D
var _prop_root: Node3D
var _front_occ: Array = []
var _door_path_xs: Array = []   # 需要门前短径的建筑 x（guildhall / 落地面建筑）
var _prop_slots: Array = []     # 前排楼间空当 [x0,x1]（道具槽位）
var _prop_solids: Array = []    # 道具实心区间 [x0,x1]（碰撞用）
var _shadow_root: Node3D
var _lamp_root: Node3D
var _cam: Camera3D
var _cam_attrs: CameraAttributesPractical
var _char_host: Node3D = null
var _post_layer: CanvasLayer
var _post_rect: ColorRect
var _post_mat: ShaderMaterial
var _hud: Label
var _hud2: Label

var _card_mats: Array[ShaderMaterial] = []
var _lamps: Array[OmniLight3D] = []
var _bg_base_z := {}            # 背景层 -> 实测卡基线 z（辅助线/底衬远端对齐用）
var _bg_base_samples: Array = []  # 当前层各卡卡底 z 的采样（层结束取中位数）

var _opts := {
	"shots": "none", "perf": false, "res": "", "sv": "always", "layout": "",
	"char": "blend", "tag": "", "svscale": "2", "flat": false, "debug": false,
	"hide": "",
}  # shots 默认 "none" = 静默常驻模式（游戏地图挂载用；probe 出图须显式 --shots=…）

# 帧采样
var _measuring := false
var _samples: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_root = ProjectSettings.globalize_path("res://")
	_temp = _root + "temp/"
	_parse_args()
	if not layout_name.is_empty():
		_opts["layout"] = layout_name   # 地图宿主注入优先于命令行
	print("[hd2d] 工程根=", _root)
	print("[hd2d] 跑法: godot --path stick-world res://tests/dev/proto_hd2d/proto_hd2d.tscn -- --shots=all")
	_load_cards()
	# 运行时生成的布局优先（宿主"首次进入生成"）；否则读烘焙好的布局 JSON
	if not layout_data.is_empty():
		_layout = layout_data
	elif not str(_opts["layout"]).is_empty():
		_layout = _read_json_rel(LAYOUT_DIR + str(_opts["layout"]) + ".json")
		if _layout.is_empty():
			push_error("[hd2d] 布局缺失，退回手摆主街: " + str(_opts["layout"]))
	print("[hd2d] 模式=", "布局驱动:" + str(_opts["layout"]) if not _layout.is_empty() else "手摆主街")
	if battlefield:
		print("[hd2d] 战场模式（无墙无街开阔野地）")
	_build_world()
	_apply_hide_groups()
	if bool(_opts.get("save_scene", false)):
		# 只存**地面/台肩几何**（_ground_root 子树）——含运行时光栅的角色/后期会把场景撑到几百 MB
		var gr: Node = _ground_root
		_set_owner_recursive(gr, gr)
		var packed := PackedScene.new()
		var err := packed.pack(gr)
		if err == OK:
			var p := "res://tests/dev/proto_hd2d/proto_hd2d_ground.tscn"
			var e2 := ResourceSaver.save(packed, p)
			print("[hd2d] 地面场景已存 -> ", p, " err=", e2)
		else:
			print("[hd2d] pack 失败 err=", err)
		get_tree().quit(0)
		return
	if str(_opts["shots"]) == "none":
		# 静默常驻（游戏内地图模式）：白天全效档点亮场景即返回，不截屏不退出
		_apply_light("day")
		_apply_stage("c")
		_update_px_size()
		return
	if bool(_opts["perf"]):
		await _run_perf()
	else:
		await _run_shots(str(_opts["shots"]))
	print("[hd2d] DONE")
	await _settle(1.0)
	get_tree().quit(0)


# ------------------------------------------------------------------ 参数

## 诊断对照实验：按 --hide= 组名隐藏节点组（shadow=接地影面片 / plat=台面系几何 /
## cards=建筑卡 / kerb=台肩镶边）。只影响显示，不改落位。
func _apply_hide_groups() -> void:
	var spec := str(_opts.get("hide", ""))
	if spec.is_empty():
		return
	for grp: String in spec.split(","):
		var roots: Array = []
		match grp:
			"shadow":
				roots = [_shadow_root]
			"cards":
				roots = [_card_root]
			"plat":
				for n: Node in _ground_root.get_children():
					var nm := str(n.name)
					if nm.begins_with("Seg_") or nm.begins_with("Band_") \
							or nm.begins_with("PlatRim") or nm.begins_with("Decal_") \
							or nm.begins_with("DoorPath"):
						n.visible = false
				continue
			"kerb":
				for n: Node in _ground_root.get_children():
					if str(n.name).begins_with("PlatRim"):
						n.visible = false
				continue
			_:
				continue
		for r: Node3D in roots:
			r.visible = false
	print("[hd2d] 已隐藏分组: ", spec)


func _set_owner_recursive(n: Node, root: Node) -> void:
	for c in n.get_children():
		c.owner = root
		_set_owner_recursive(c, root)


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s == "--save-scene":
			_opts["save_scene"] = true
			continue
		if s.begins_with("--shots="):
			_opts["shots"] = s.get_slice("=", 1)
		elif s.begins_with("--perf="):
			_opts["perf"] = s.get_slice("=", 1) != "0"
		elif s.begins_with("--res="):
			_opts["res"] = s.get_slice("=", 1)
		elif s.begins_with("--sv="):
			_opts["sv"] = s.get_slice("=", 1)
		elif s.begins_with("--svscale="):
			_opts["svscale"] = s.get_slice("=", 1)
		elif s.begins_with("--char="):
			_opts["char"] = s.get_slice("=", 1)
		elif s.begins_with("--tag="):
			_opts["tag"] = s.get_slice("=", 1)
		elif s.begins_with("--flat="):
			# --flat=1：关远焦 DOF（辅助线核对版出图用——DOF 满糊会把辅助线一起晕开）
			_opts["flat"] = s.get_slice("=", 1) != "0"
		elif s.begins_with("--layout="):
			# 布局驱动：读 city_layout 导出的布局 JSON 摆街（算法村，如村B）
			_opts["layout"] = s.get_slice("=", 1)
		elif s.begins_with("--battlefield="):
			# 战场模式：无墙无街的开阔野地（战场图宿主注入同款）
			battlefield = s.get_slice("=", 1) != "0"
		elif s.begins_with("--debug="):
			# --debug=1：辅助线（网格/紫线/1/3 线/末层基线）——调试模式才出现（创始人口径）
			_opts["debug"] = s.get_slice("=", 1) != "0"
		elif s.begins_with("--hide="):
			# --hide=shadow,plat,cards：诊断用分组隐藏（对照实验定位视觉缺陷来源）
			_opts["hide"] = s.get_slice("=", 1)


# ------------------------------------------------------------------ 资源

## 读卡元数据 JSON：优先烘焙工作区 temp/（烘卡机上的最新产物）；缺失回退
## 工程内 tex/ 副本（随包入库——别的机器 clone 后没跑过烘焙也能出图）。
func _load_meta_json(rel: String) -> Array:
	for p: String in [_temp + rel, "res://tests/dev/proto_hd2d/tex/" + rel]:
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
	print("[hd2d] 烘焙卡 %d 张" % _cards.size())
	for c: Variant in _load_meta_json(PROPS_JSON):
		_props[str(c["card"])] = c
	print("[hd2d] 道具卡 %d 张" % _props.size())
	for c: Variant in _load_meta_json(NATURE_JSON):
		_nature[str(c["card"])] = c
	print("[hd2d] 自然物卡 %d 张" % _nature.size())


## 读 JSON（Object）：优先烘焙工作区 temp/，缺失回退工程内 tex/ 入库副本。
func _read_json_rel(rel: String) -> Dictionary:
	for p: String in [_temp + rel, "res://tests/dev/proto_hd2d/tex/" + rel]:
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
		var q := "res://tests/dev/proto_hd2d/tex/" + p.get_slice("/temp/", 1)
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
		var q := "res://tests/dev/proto_hd2d/tex/" + p.get_slice("/temp/", 1)
		if FileAccess.file_exists(q):
			return _tex_abs(p)
	if FileAccess.file_exists(p):
		return _tex_abs(p)
	return null


func _cam_basis() -> Basis:
	var t := deg_to_rad(TILT_DEG)
	return Basis(Vector3(1, 0, 0),
		Vector3(0, cos(t), -sin(t)), Vector3(0, sin(t), cos(t)))


## 建筑卡：**卡底贴地落位**（与 _spawn_prop 道具卡同口径）。
## 旧公式把 cards.json 的 anchor 当"画面中心"落位——anchor 实际是"前墙基线"
## （bake_export: kind="front_wall_baseline"），导致卡几何底边插进台面下方约 2 格，
## 卡面底部（台阶/台基带）被台面深度遮挡压暗——创始人指出的"最下方一段被截断"
## 与"地基上一圈浅灰方形"同源于此。现改为卡底贴地：可视底（裁掉台基后的墙脚线）
## 正好落在 ground 平面（台面 PLAT_H 或路面 0），z 落在 z_off。
func _spawn_card(card: String, x: float, z_off: float, skyline: bool = false,
		ground: float = 0.0) -> MeshInstance3D:
	var meta: Dictionary = _cards.get(card, {})
	if meta.is_empty():
		push_warning("[hd2d] 无此卡: " + card)
		return null
	var units: Array = meta["units"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * S, float(units[1]) * S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var t := deg_to_rad(TILT_DEG)
	# 可视半高：卡底被 base_cut 裁掉后，以"墙脚线"为落地点取 quad 中心
	var half: float = q.size.y * (0.5 - _card_base_cut(card))
	mi.position = Vector3(x, ground + cos(t) * half, z_off - sin(t) * half)
	mi.basis = _cam_basis()
	var m := _card_material(card)
	if skyline:
		# 远景剪影层：① 不投真阴影 —— 卡片会按 alpha 剪影向地面投真影，一张 17 格高的
		# 塔会在中部空地上拖出一大片斜影，而那片空地没有别的东西来"接住"它，读作脏斑；
		# ② 用一份独立材质做距离染色（tint 由 _spawn_bg_card 按层分档）且**不注册进
		# _card_mats**（不参与夜景窗火自发光），让它彻底退到背景层。
		m = m.duplicate()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_card_mats.erase(m)
	mi.material_override = m
	mi.name = "Card_" + card
	_card_root.add_child(mi)
	return mi


## 背景卡 = skyline 卡 + 按层距离染色；同时**实测卡底世界 z**（供层基线辅助线与
## 底衬远端对齐）。卡底贴地落位后底边 z = 层 z 本身，不再依赖 anchor 推导。
func _spawn_bg_card(card: String, x: float, lz: float, tint: Color) -> void:
	var mi := _spawn_card(card, x, lz, true)
	if mi == null:
		return
	(mi.material_override as ShaderMaterial).set_shader_parameter("tint", tint)
	_bg_base_samples.append(lz)


## 前排建筑+道具的实心区间（格，[x0,x1]）——宿主映射成 2D 碰撞墙，
## 玩家在街上走不会被楼/摆件穿透（创始人 2026-09-14）。
## 建筑按**建筑格宽**对齐中心（画面宽含出檐，碰撞不该把出檐也堵死）；
## 道具按卡宽收窄 15%（视觉留余量）。细杆件（灯笼）不挡。
func get_solid_rects() -> Array:
	var out: Array = []
	for occ in _front_occ:
		var cx: float = (float(occ[0]) + float(occ[1])) * 0.5
		var card: String = str(occ[2])
		var cells := float(_cards.get(card, {}).get("cells", 8.0))
		# 建筑碰撞=**地基范围**（创始人 2026-09-14）：x=建筑格宽，
		# y=行走带后段到建筑基线外扩 1.4 格的一条带——不再贯穿整条街
		var z: float = float(occ[3]) if occ.size() > 3 else 0.6
		var base_y: float = 688.0 + z * 32.0
		out.append([cx - cells * 0.5, cx + cells * 0.5, 688.0, base_y + 44.0])
	for r in _prop_solids:
		out.append(r)
	if battlefield:
		return out   # 战场无城墙（开阔野地，四向可走）
	# 城墙碰撞带（±墙线，整带封死）：过墙只走门洞传送带（宿主 Area2D，
	# 到门口即跨墙同图瞬移——创始人口径"到门口就传送，门外也得传送过去"；
	# 整面直墙同时消除门缝夹角楔人问题）
	var wx: float = _wall_x()
	for sx: float in [-1.0, 1.0]:
		out.append([sx * wx - WALL_T * 0.5, sx * wx + WALL_T * 0.5, 688.0, WALK_FRONT_PX])
	return out


## 城门洞表（x 格 / y px **全行走带**）——传送带贴整面墙（创始人：城墙即
## 传送门；只开洞口带会把走到洞外的角色藏进墙条后面 = "靠近城门角色消失"）
## 战场无墙无门：返回空表，宿主据空表跳过传送带/引导（空 = 无需引导）
func get_gates() -> Array:
	if battlefield:
		return []
	return [
		{"x": -_wall_x(), "y0": 688.0, "y1": WALK_FRONT_PX},
		{"x": _wall_x(), "y0": 688.0, "y1": WALK_FRONT_PX},
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


## 前排摆位求解器（行业惯例，创始人 2026-09-15：别把位置绑死整数格）：
##   1. 意图表的锚点只是"想要的位置"，占位/间隙一律用**画面宽**（cards.json
##      units 的数据包围盒）计算——重叠在求解阶段就不可能出现；
##   2. 左→右逐栋推挤：本栋画面左缘 ≥ 前栋画面右缘 + 保底间隙（0.6 格）；
##   3. 确定性微抖动 ±0.2 格（锚点哈希种子，同 seed 同街景）破机械栅格感；
##      抖动后再次保底夹回，间隙承诺不破。
func _resolve_front_row(intent: Array) -> Array:
	var MIN_GAP := 0.6
	var out: Array = []
	var prev_right := -INF
	for e: Variant in intent:
		var card: String = str(e["card"])
		var w := _cw(card)
		if w < 1.0:
			w = 8.0   # 卡元数据缺失兜底（_cw 同口径）
		var x: float = float(e["x"])
		# 微抖动（±0.2 格）：锚点哈希做种子
		var jit: float = (fposmod(absf(x) * 0.618, 0.4) - 0.2) * 0.5
		x += jit
		# 推挤保底（抖动前后各夹一次）
		x = maxf(x, prev_right + MIN_GAP + w * 0.5)
		prev_right = x + w * 0.5
		out.append({"card": card, "x": x, "z": e.get("z", 0.6),
			"door": bool(e.get("door", false))})
	return out


func _median(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var a := arr.duplicate()
	a.sort()
	return float(a[a.size() / 2])


## 道具卡：与建筑卡同一套 anchor 落位（基座落 z_off 平面；plat 版再加台面高）。
func _spawn_prop(card: String, x: float, z_off: float, plat: bool) -> MeshInstance3D:
	var meta: Dictionary = _props.get(card, {})
	if meta.is_empty():
		push_warning("[hd2d] 无此道具卡: " + card)
		return null
	var units: Array = meta["units"]
	var anc: Array = meta["anchor"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * S, float(units[1]) * S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	# 卡底贴地落位（创始人 2026-09-14 修穿模）：道具卡的 anchor 是"画面中心对应点"，
	# 沿用建筑卡公式会让卡底按半高入地。地面高 = 台面(0.65) 或 路面(0)。
	var ground: float = PLAT_H if plat else 0.0
	var half: float = float(units[1]) * S * 0.5
	var t := deg_to_rad(TILT_DEG)
	# 卡底留白下沉（创始人 2026-09-15：浮空摆件）——alpha 扫描卡底透明行，
	# 卡内容实际落到地面（留白比例每卡只扫一次，缓存）
	mi.position = Vector3(x, ground + cos(t) * half - _prop_bottom_pad(card) * S,
			z_off - sin(t) * half)
	mi.basis = _cam_basis()
	var m := ShaderMaterial.new()
	m.shader = CARD_SHADER
	m.set_shader_parameter("albedo_tex", _tex_abs(_temp + PROP_DIR + card + ".png"))
	m.set_shader_parameter("glow_tex", _tex_abs(_temp + PROP_DIR + card + "_glow.png"))
	var px: Array = meta.get("px", [128, 128])
	m.set_shader_parameter("tex_px", Vector2(float(px[0]), float(px[1])))
	m.set_shader_parameter("relief", 4.5)
	m.set_shader_parameter("alpha_cut", 0.4)
	m.set_shader_parameter("glow_energy", 0.0)
	m.set_shader_parameter("tint", Color(1, 1, 1))
	_card_mats.append(m)
	mi.material_override = m
	mi.name = "Prop_" + card
	_prop_root.add_child(mi)
	# 实心区间（格）：卡宽收窄 15%；细杆件（灯笼）不挡人。
	# 道具是台面/路面上的点障碍——碰撞只在其纵深带附近（z→y 窄带），
	# 不挡整条行走带（玩家/NPC 从前景绕过去）。
	if card != "lantern":
		var half_w: float = float(units[0]) * S * 0.5 * 0.85
		var y_c: float = 688.0 + z_off * 32.0
		_prop_solids.append([x - half_w, x + half_w, y_c - 26.0, y_c + 26.0])
	return mi


## 道具卡底部透明留白（世界格）——卡底贴地公式只把卡底边放地面，卡内容
## 底部若留白就浮空；按留白行数下沉。缓存避免重复扫图。
var _prop_pad_cache: Dictionary = {}
func _prop_bottom_pad(card: String) -> float:
	if _prop_pad_cache.has(card):
		return float(_prop_pad_cache[card])
	var pad := 0.0
	for base_path: String in [_temp + PROP_DIR + card + ".png",
			"res://tests/dev/proto_hd2d/tex/proto_hd2d/props/" + card + ".png"]:
		if not FileAccess.file_exists(base_path):
			continue
		var img := Image.new()
		var gp: String = ProjectSettings.globalize_path(base_path) if base_path.begins_with("res://") else base_path
		if img.load(gp) != OK:
			continue
		var w := img.get_width()
		var h := img.get_height()
		if h == 0 or w == 0:
			break
		var rows := 0
		for yy in range(h - 1, -1, -1):
			var any := false
			for xx in range(0, w, maxi(1, w / 32)):
				if img.get_pixel(xx, yy).a > 0.12:
					any = true
					break
			if any:
				break
			rows += 1
		pad = float(rows) / 32.0
		break
	_prop_pad_cache[card] = pad
	return pad


## 建筑卡底部台基裁剪比例（founder 2026-09-15："地基上一圈浅灰方形"=浅灰台基，
## 处置=整段删除）。裁剪高度直接取 cards.json 的 anchor 纵深分量占卡高之比：
## anchor[1] 烘焙时记录的就是"墙脚基线到卡底的纵深带"=台基/台阶带高度
## （实证 barn：57.3px/403.5 = 0.142，与贴图实测台基带 0.146 吻合；
## 全卡落在此 0.13~0.20 区间）。该带含台阶、左右基座柱与透明留白，整段删除后
## 墙体底缘 = 可视底 = 落地线，不再出现铺在楼脚前的浅灰方框。
var _card_cut_cache: Dictionary = {}

func _card_base_cut(card: String) -> float:
	if _card_cut_cache.has(card):
		return float(_card_cut_cache[card])
	var meta: Dictionary = _cards.get(card, {})
	var cut := 0.0
	var anc: Array = meta.get("anchor", [0.0, 0.0, 0.0])
	var units: Array = meta.get("units", [0.0, 0.0])
	if float(units[1]) > 1.0:
		cut = clampf(float(anc[1]) / float(units[1]), 0.0, 0.24)
	_card_cut_cache[card] = cut
	return cut


func _place_props() -> void:
	if battlefield and not resource_field:
		for e in BF_PROPS:
			_spawn_prop(str(e["card"]), float(e["x"]), float(e.get("z", 5.0)), false)
		return
	if not _layout.is_empty():
		for e: Variant in _layout.get("props", []):
			_spawn_prop(str(e["card"]), float(e["x"]), float(e.get("z", 5.0)),
					bool(e.get("plat", false)))
		return
	for e in PROPS:
		_spawn_prop(str(e["card"]), float(e["x"]), float(e["z"]), bool(e.get("plat", true)))


## 自然物卡：与道具同一套卡底贴地落位（全落地面/草地面，不上台面）。
func _place_nature() -> void:
	if battlefield and not resource_field:
		for e in BF_NATURE_SPOTS:
			_spawn_nature_card(str(e["card"]), float(e["x"]), float(e["z"]))
		return
	if not _layout.is_empty():
		for e: Variant in _layout.get("trees", []):
			_spawn_nature_card(str(e["card"]), float(e["x"]), float(e.get("z", 5.5)))
		return
	for e in NATURE_SPOTS:
		_spawn_nature_card(str(e["card"]), float(e["x"]), float(e["z"]))


## 宿主按资源分布算法落卡（ResourceNode 点位 → 匹配自然物 PBR 卡，卡随点落）
func spawn_nature_card_at(card: String, x_px: float, y_px: float) -> void:
	_spawn_nature_card(card, x_px / 32.0, (y_px - 688.0) / 32.0)


## 自然物卡落位（卡底贴地，同 _spawn_prop 公式；目录/元数据走 nature 侧）。
func _spawn_nature_card(card: String, x: float, z_off: float) -> MeshInstance3D:
	var meta: Dictionary = _nature.get(card, {})
	if meta.is_empty():
		push_warning("[hd2d] 无此自然物卡: " + card)
		return null
	var units: Array = meta["units"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * S, float(units[1]) * S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var half: float = float(units[1]) * S * 0.5
	var t := deg_to_rad(TILT_DEG)
	mi.position = Vector3(x, cos(t) * half, z_off - sin(t) * half)
	mi.basis = _cam_basis()
	var m := ShaderMaterial.new()
	m.shader = CARD_SHADER
	m.set_shader_parameter("albedo_tex", _tex_abs(_temp + NATURE_DIR + card + ".png"))
	m.set_shader_parameter("glow_tex", _tex_abs(_temp + NATURE_DIR + card + "_glow.png"))
	var px: Array = meta.get("px", [128, 128])
	m.set_shader_parameter("tex_px", Vector2(float(px[0]), float(px[1])))
	m.set_shader_parameter("relief", 4.5)
	m.set_shader_parameter("alpha_cut", 0.4)
	m.set_shader_parameter("glow_energy", 0.0)
	m.set_shader_parameter("tint", Color(1, 1, 1))
	_card_mats.append(m)
	mi.material_override = m
	mi.name = "Nature_" + card
	_prop_root.add_child(mi)
	# 自然物有建模体积（创始人 2026-09-15）：恢复实体——但碰撞收窄成
	# "树干/岩心"窄条（±0.4 格，非整卡宽）：挡得住穿体，村民又能走到
	# 资源点 24px 阈值内（此前整卡宽碰撞把采集 AI 卡死在卡边的教训）
	if bool(meta.get("solid", false)):
		var half_w: float = 0.4
		var y_c: float = 688.0 + z_off * 32.0
		_prop_solids.append([x - half_w, x + half_w, y_c - 26.0, y_c + 26.0])
	return mi


## 露天工位点（宿主转发给 TownLife 露天工位 duck）：台面上的铁砧=铁匠工位。
## 返回 2D 行走带坐标（z → y 近似映射同 _place_nature）。
func get_open_work_sites() -> Array:
	var out: Array = []
	for e in PROPS:
		if str(e["card"]) == "anvil":
			out.append({
				"pos": Vector2(float(e["x"]) * 32.0, 688.0 + float(e["z"]) * 32.0),
				"work_site_def": "smithy_lv1",
			})
	return out


## 布局道具表（宿主工位/NPC 出生点推导用；手摆模式返回空）
func get_layout_props() -> Array:
	return _layout.get("props", []) if not _layout.is_empty() else []


## 布局驱动模式的街宽（格）；手摆主街返回 0（宿主用 tscn 边界）
func get_layout_width() -> float:
	if not _layout.is_empty():
		return float(_layout.get("width_cells", 96.0))
	return 0.0


## 3D 街景横移（宿主按玩家 x 驱动；正交相机，视宽 74 格）
func set_cam_x(cx: float) -> void:
	if _cam != null:
		_cam.position.x = cx


## 3D 相机缩放镜像——与 2D CameraRig **逐像素 1:1**（创始人：紫箱水平移动
## 比角色快 / 蓝线与屏幕下边界不重合的根因 = 旧固定视宽 74 格在 1920 下
## 25.9 px/格，与 2D 的 32 px/格差 19%，所有 2D 投影物相对 3D 世界漂移）。
## 可视宽（格）= 2D 可视世界宽 px / 32 = DESIGN_HEIGHT·宽高比/(32·user_zoom)；
## 纵向 px/格 随之同为 32。锚线 z_near 按"地面占屏幕下 1/3、天际线基线压
## 1/3 线"的构图契约取值，缩放时钉死在屏幕底沿。
## 推导：屏幕底沿地面 z = z_c + h_v/(2 sinθ)（z_c = P.z − P.y/tanθ，
## h_v = DESIGN_HEIGHT/(32·user_zoom)）⇒ P.z = z_near − h_v/(2 sinθ) + P.y/tanθ。
func set_cam_zoom(user_zoom: float) -> void:
	if _cam == null or user_zoom <= 0.05:
		return
	var uz: float = clampf(user_zoom, 0.25, 8.0)
	var vp := _cam.get_viewport().get_visible_rect().size
	_cam.size = DESIGN_HEIGHT * vp.x / (32.0 * vp.y * uz)
	var t := deg_to_rad(TILT_DEG)
	var h_v: float = _cam.size * vp.y / maxf(vp.x, 1.0)   # = DESIGN_HEIGHT/(32·uz)
	var h_v1: float = DESIGN_HEIGHT / 32.0               # zoom=1 基准视高（格）
	var z_near: float = SKYLINE_Z + h_v1 / (3.0 * sin(t))
	_cam.position.z = z_near - h_v * 0.5 / sin(t) + _cam.position.y / tan(t)
	# 景深与缩放解耦：far blur 起点钉在**世界线**上——天际线基线向镜头前移
	# DOF_FAR_START_AHEAD 格（第二排从这条线起吃半档模糊；创始人：第二排景深要明显）。
	# dof_blur_far_distance 是相机本地距离，缩放移动相机后若不同步换算，
	# 模糊带会跟着缩放漂移（创始人：景深不应受镜头缩放影响）
	if _cam_attrs != null:
		_cam_attrs.dof_blur_far_distance = (_cam.position.z - SKYLINE_Z - DOF_FAR_START_AHEAD) / cos(t)


## 3D 视图对地面纵深的屏幕压缩率（俯角前缩）：3D 与 2D 逐像素 1:1 后，
## 1 格地面纵深在屏幕上的竖直像素 = 32·sin(俯角)，压缩率即纯 sin(俯角)。
## 2D 画布的特效/调试框按 2D y 直绘会与 3D 世界错开 (1-压缩率) 倍——
## 宿主用本值做坐标重映射（remap_fx_pos）。
func get_ground_squash() -> float:
	return sin(deg_to_rad(TILT_DEG))


## 光照档公开封装（宿主昼夜挂钩调；_apply_light 幂等可反复调）
func set_light_mode(mode: String) -> void:
	_apply_light(mode)


## 门前径（创始人 2026-09-14：宏伟建筑门前有特别短的小路接进街道）。
## dc_door_path decal 贴图尚未烘，先用低对比夯土贴条代替（楼脚 → 台肩 → 路面两段）。
func _add_door_path(x: float, _front_z: float = 3.4) -> void:
	# 两段：台面段（楼脚→台肩）+ 路面段（台肩→街面），在路肩石处断开避免穿插
	var segs := [
		{"z0": 1.0, "z1": 1.94, "y": PLAT_H + 0.012},
		{"z0": 1.96, "z1": 3.4, "y": 0.03},
	]
	for s in segs:
		var depth: float = float(s["z1"]) - float(s["z0"])
		if depth <= 0.05:
			continue
		var pm := PlaneMesh.new()
		pm.size = Vector2(1.6, depth)
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		var gm := StandardMaterial3D.new()
		var t := _tex_abs(_temp + GROUND_DIR + "rammed_earth_128.png")
		if t != null:
			gm.albedo_texture = t
		gm.albedo_color = Color(0.88, 0.80, 0.66)
		gm.roughness = 0.95
		gm.uv1_scale = Vector3(1.6 / 4.0, depth / 4.0, 1.0)
		gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		mi.material_override = gm
		mi.position = Vector3(x, float(s["y"]), (float(s["z0"]) + float(s["z1"])) * 0.5)
		mi.name = "DoorPath"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ground_root.add_child(mi)


## 从 list[ci] 起顺位找第一张**画面宽 ≤ room** 的卡（放得下才用）；找不到返回 ""。
## 背景"缝"按卡画面宽算（含出檐），cottage_w6 画面 ~9.1 格、townhouse_w12 ~15.9 格。
func _pick_card(list: Array, ci: int, room: float) -> String:
	for k in list.size():
		var c: String = str(list[(ci + k) % list.size()])
		var w := _cw(c)
		if w < 1.0 or w <= room:
			return c
	return ""


func _card_material(card: String) -> ShaderMaterial:
	var meta: Dictionary = _cards.get(card, {})
	var base := _temp + CARD_DIR
	var alb := _tex_abs(base + card + ".png")
	var glo := _tex_abs(base + card + "_glow.png")
	if alb == null:
		return null
	var m := ShaderMaterial.new()
	m.shader = CARD_SHADER
	m.set_shader_parameter("albedo_tex", alb)
	m.set_shader_parameter("glow_tex", glo)
	var px: Array = meta.get("px", [1024, 1024])
	m.set_shader_parameter("tex_px", Vector2(float(px[0]), float(px[1])))
	m.set_shader_parameter("relief", 4.5)
	m.set_shader_parameter("alpha_cut", 0.4)
	m.set_shader_parameter("glow_energy", 0.0)
	m.set_shader_parameter("tint", Color(1, 1, 1))
	m.set_shader_parameter("base_cut", _card_base_cut(card))   # 浅灰台基整段删除
	_card_mats.append(m)
	return m


# ------------------------------------------------------------------ 世界

func _build_world() -> void:
	# --- 环境（天空 + 环境光 + 深雾 + 辉光）---
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	_env.sky = sky
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
	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = true
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
	if not battlefield:
		_place_rows()   # 前排吸附整格 + 两排背景留缝、后层插前层缝
	_prop_root = Node3D.new()
	_prop_root.name = "Props"
	add_child(_prop_root)
	_place_props()  # 街面小零件（摊/桶/车/井…）；战场模式 = 战场遗物（BF_PROPS）
	_place_nature() # 野外树木/矿物卡（西森林带+东段城外）；战场模式 = 战痕散布

	# --- 地面：底衬（远端=末层实测根部，即真实地平线）+ 台面 + 辅助线 + 道路 ---
	_ground_root = Node3D.new()
	_ground_root.name = "Ground"
	add_child(_ground_root)
	# 地表中远景用**低对比**贴图（rammed_earth std=0.034），别用 cobble（std=0.107）：
	# 20° 掠射下 128px 贴图被压 3 倍以上，用高对比纹理时 mip 会在中景糊出一片
	# "碎石噪声"，读作脏。路面同理，tile 放大到 10 减少 minification。
	# 中远景地面：低对比夯土（rammed_earth std=0.034）。中景已被 bg1（z=-6.7）
	# 楼群+前排楼身咬合遮住，只剩楼缝间少量露出；别用 cobble（std=0.107）——
	# 掠射下 mip 会把高对比石板糊成"碎石墙"（实测翻车）。
	var far_z: float = float(_bg_base_z.get(BG_LAYERS - 1,
		SKYLINE_Z - BG_LAYER_GAP * float(BG_LAYERS - 1)))
	_add_ground_plane("rammed_earth_128.png", far_z, 0.0,
		0.0, 14.0, Color(0.90, 0.86, 0.80))
	# 兜底大地皮：街面分段各有边界，缩太小视野越出分段范围就露天空
	# （创始人：缩太小下边界出现虚空）。这层压在所有分段之下（y=-0.05），
	# 只在分段没铺到的区域露脸；±600 格宽 + z -30~40，任何缩放都不露底。
	var fb_mesh := PlaneMesh.new()
	fb_mesh.size = Vector2(1200.0, 70.0)
	var fb_mi := MeshInstance3D.new()
	fb_mi.mesh = fb_mesh
	var fb_mat := StandardMaterial3D.new()
	var fb_tex := _tex_abs(_temp + GROUND_DIR + "rammed_earth_128.png")
	if fb_tex != null:
		fb_mat.albedo_texture = fb_tex
	fb_mat.albedo_color = Color(0.70, 0.65, 0.57)
	fb_mat.roughness = 0.95
	fb_mat.uv1_scale = Vector3(300.0, 17.5, 1.0)
	fb_mi.material_override = fb_mat
	fb_mi.position = Vector3(0.0, -0.05, 5.0)
	fb_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fb_mi.name = "GroundFallback"
	_ground_root.add_child(fb_mi)
	_add_sky_backdrop()                   # 原 2D 天空贴图（远山/树线）立于背景之后
	if battlefield:
		# 战场野地铺装：全域草灰绿（同主街墙外野地调）+ 中轴夯土东路
		# （东门大道的延续，压出"路通战场"的走向）。无台面/墙/街灯。
		_add_ground_plane_at("rammed_earth_128.png", 0.0, 600.0,
			0.0, BAND_ROAD.y, 0.0, 6.0, Color(0.68, 0.74, 0.54))
		_add_ground_plane_at("rammed_earth_128.png", 0.0, 600.0,
			2.0, 11.0, 0.01, 6.0, Color(0.80, 0.77, 0.62))
	else:
		_add_platform()                   # 人行道台面（三段：中石板/两侧夯土+交接条）+ 台肩长条石
		_build_walls()                    # 城墙转角收边 + 门洞（碰撞走 get_solid_rects）
	_add_width_guides()                   # 建筑宽度辅助线（--debug 才显示）
	_add_horizon_guides()                 # 1/3 线（橙）+ 第三排基线（绿）（--debug 才显示）
	for dx in _door_path_xs:
		_add_door_path(float(dx), 3.6)    # 门前短径（楼脚→台肩→路面）
	if not battlefield:
		# 三带明晰（创始人 2026-09-15，详见 HD-2D街景系统.md §三带）：
		#   建筑带（台面）= 城心石板/近缘草地；道路带（z 1.9~46）= 城心石板
		#   ±30 → 夯土过渡（不长草）→ 城外草地；背景地面带 = 兜底大地皮。
		# 路面 y 抬升防与兜底大地皮 z-fight
		var wx: float = _wall_x()
		_add_ground_plane_at("band_road_stone_128.png", 0.0, 60.0,
			BAND_ROAD.x, BAND_ROAD.y, 0.02, 10.0, Color(0.86, 0.89, 0.96))
		_add_ground_plane_at("rammed_earth_128.png", -(wx + 30.0) * 0.5, wx - 30.0,
			BAND_ROAD.x, BAND_ROAD.y, 0.015, 6.0, Color(0.80, 0.78, 0.62))
		_add_ground_plane_at("rammed_earth_128.png", (wx + 30.0) * 0.5, wx - 30.0,
			BAND_ROAD.x, BAND_ROAD.y, 0.015, 6.0, Color(0.80, 0.78, 0.62))
		# 城外野地 = 草地贴图（稀疏草土地，非道路带）
		_add_ground_plane_at("grass_sparse_alb_128.png", -(wx + 15.0), 30.0,
			0.0, BAND_ROAD.y, 0.0, 6.0, Color(0.88, 0.90, 0.80))
		_add_ground_plane_at("grass_sparse_alb_128.png", (wx + 15.0), 30.0,
			0.0, BAND_ROAD.y, 0.0, 6.0, Color(0.90, 0.88, 0.78))

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
			l.light_color = Color(1.0, 0.63, 0.30)
			l.light_energy = 1.6
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
	set_cam_zoom(1.0)   # 初始取景即按"下边界锚定"校正（否则首帧前是旧中心取景）

	# --- 太阳盘（相机子节点：固定在画面顶空带，建筑物自动遮挡它）---
	# 无阴影/无雾/自发光，昼档显示夜档隐藏（夜空有星）； Ortho 相机下
	# 程序化天空的太阳盘永远进不了视锥，只能用显式面片补
	_sun_disc = MeshInstance3D.new()
	var sd := SphereMesh.new()
	sd.radius = 1.8
	sd.height = 3.6
	_sun_disc.mesh = sd
	var sun_m := StandardMaterial3D.new()
	sun_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sun_m.albedo_color = Color(1.0, 0.94, 0.74)
	sun_m.emission_enabled = true
	sun_m.emission = Color(1.0, 0.9, 0.62)
	sun_m.emission_energy_multiplier = 2.8
	sun_m.disable_fog = true
	_sun_disc.material_override = sun_m
	_sun_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sun_disc.position = Vector3(-7.0, 12.5, -34.0)   # 相机局部：顶空带偏左
	_cam.add_child(_sun_disc)

	# --- 2D 角色宿主（SubViewport -> billboard）---
	# 静默常驻模式（游戏地图挂载）不生成写死的演示火柴人——街上有真玩家了；
	# 实体角色渲染由宿主调 enable_play_characters() 接管（玩家/NPC 进 3D 场景）
	if str(_opts["shots"]) != "none":
		_spawn_char_host(float(str(_opts["svscale"])))

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

	# HUD 标签（只在遮挡对照图里显示，给两格加字）
	_hud = _make_label(Vector2(24, 18), 30)
	_hud2 = _make_label(Vector2(984, 18), 30)
	_hud.visible = false
	_hud2.visible = false

	# 应用 SubViewport 更新模式选项（静默模式无 char_host，跳过）
	if _char_host != null:
		match str(_opts["sv"]):
			"once":
				_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			"disabled":
				_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			_:
				_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


## 游戏地图挂载：启用 3D 角色渲染通道（不生成演示站位）。
## 宿主把玩家/NPC 逐个 add_char 并逐帧 set_world_pos——角色写深度站进场景，
## 能被前景遮挡、与建筑正确排序（HD-2D 最佳实践，替代 2D canvas 浮层）。
func enable_play_characters() -> void:
	if _char_host == null:
		_spawn_char_host(1.0, false)


## 游戏接入：生成一个**独立**角色实例（各自 SubViewport/骨架/动画）。
## 玩家与村民各自独立动画（共享 viewport 会全员同姿态），由宿主逐帧驱动。
func spawn_character() -> Node:
	var h: Node = CHAR_HOST.new()
	h.name = "Char%d" % _char_seq
	_char_seq += 1
	add_child(h)
	h.set_px_scale(2.0)   # 2x 超采样：描边锐利无彩边
	h.build(self, "idle", TILT_DEG)
	h.add_char(0.0, 0.0, false)
	return h

var _char_seq: int = 0

## 建/重建 2D 角色宿主（SubViewport -> billboard）。px_scale > 1 = SubViewport
## 以更高分辨率渲染同一个 2D 角色（世界占位不变），用于隔离它的渲染开销。
func _spawn_char_host(px_scale: float = 1.0, with_demo: bool = true) -> void:
	if _char_host != null:
		_char_host.queue_free()
	_char_host = CHAR_HOST.new()
	_char_host.name = "CharHost"
	add_child(_char_host)
	_char_host.set_px_scale(px_scale)
	_char_host.build(self, "walk", TILT_DEG)
	if with_demo:
		for e in CHARS:
			_char_host.add_char(float(e["x"]), float(e["z"]), bool(e["flip"]))
		_char_host.mark_regular()


## 建筑接地影：贴在路肩带**之上**（y=0.07，高过所有分带面）的程序化软影。
## 为什么必须补：卡片里烘的接触阴影在卡的深度面上（z≈-1.5），而路肩面（z∈[0,4]）
## 比它更靠近相机 → 深度测试判路肩赢，烘的接触阴影会被路肩**整片盖掉**，
## 建筑就"浮"在路肩上、基线读不准。补一张贴地的程序化软影，把建筑钉在路肩上。
func _spawn_building_shadow(card: String, x: float, mi: MeshInstance3D) -> void:
	var meta: Dictionary = _cards.get(card, {})
	if meta.is_empty() or mi == null:
		return
	var w := float(meta["units"][0]) * S
	var sq := QuadMesh.new()
	sq.size = Vector2(w * 0.86, BSHADOW_DEPTH)
	var sh := MeshInstance3D.new()
	sh.mesh = sq
	var sm := ShaderMaterial.new()
	sm.shader = BUILDING_SHADOW_SHADER
	sh.material_override = sm
	sh.position = Vector3(x, 0.07, BSHADOW_Z)
	sh.rotation = Vector3(deg_to_rad(-90), 0, 0)
	sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sh.name = "BShadow_" + card
	_shadow_root.add_child(sh)


## 路肩（占位自救版；分段素材到位后整段替换）：
##   · 高度压到 ~1.5 格（屏上 ≈13px，远低于"半砖"观感阈值）；
##   · 沿 x 切成 30 段，每段前后边缘各抖 ±0.2 格 → 打断直线边，读作被啃噬的碎块；
##   · tint 0.78（贴图均值 0.588 → 有效 ≈0.46）与道路（0.455）同档，不再比路面浅一档。
## 固定的"路缘"整条已被去掉 —— 干净的直线边正是创始人说的"生硬"来源。
func _cw(card: String) -> float:
	var meta: Dictionary = _cards.get(card, {})
	if meta.is_empty():
		return 8.0
	return float(meta["units"][0]) * S


func _gaps(occ: Array, lo: float = -40.0, hi: float = 40.0) -> Array:
	# 已占用区间 [x0,x1] 的补集（在 [lo,hi] 内）——用于"后层插前层缝"
	var s := occ.duplicate()
	s.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out := []
	var cur := lo
	for iv in s:
		if float(iv[0]) > cur + 0.5:
			out.append([cur, float(iv[0])])
		cur = maxf(cur, float(iv[1]))
	if cur < hi - 0.5:
		out.append([cur, hi])
	return out


func _place_rows() -> void:
	# 前排：**手工摆**（2026-09-14，村A主场景 InitialBuildingsList 的语义翻译，
	# 街长铺到村A全域 -67~+67）——逐栋写死在 FRONT_ROW，不再随机轮转。
	# z 错落/门前径也随清单写死；建筑格宽重叠由摆位表保证（相邻名义缝 ≥0.5 格）。
	var occ_front := []
	var rng_f := RandomNumberGenerator.new()
	rng_f.seed = 20260914
	# 前排来源：布局驱动（city_layout row0，算法村）或手摆主街 FRONT_ROW
	# 布局 JSON 的 z 字段是定稿契约：0.45~1.3 = 台面、2.4 = 落地面，直接采用。
	var front_list: Array = FRONT_ROW
	if not _layout.is_empty():
		front_list = []
		for b: Variant in _layout.get("buildings", []):
			if int(b["row"]) != 0:
				continue
			front_list.append({"card": str(b["card"]), "x": float(b["x"]),
				"z": float(b.get("z", 0.6)), "door": bool(b.get("door", false))})
	else:
		# 手摆主街：意图表过摆位求解器（画面宽推挤 + 微抖动）
		front_list = _resolve_front_row(front_list)
	for e in front_list:
		var card: String = str(e["card"])
		var cx: float = float(e["x"])
		var z_off: float = float(e.get("z", 0.6))
		# 台面站位：卡底落在台面标高；谷仓 z>2 = 落地面（不上台面，路面标高）
		var on_plat: bool = z_off < 2.0
		var mi := _spawn_card(card, cx, z_off, false, PLAT_H if on_plat else 0.0)
		_spawn_building_shadow(card, cx, mi)
		if bool(e.get("door", false)) or not on_plat:
			_door_path_xs.append(cx)   # 宏伟建筑/落地建筑：门前短径
		var w: float = _cw(card)
		occ_front.append([cx - w * 0.5, cx + w * 0.5, card, z_off])
	_prop_slots = []
	_front_occ = occ_front
	# ── 背景连续铺装（创始人 2026-09-15：背景必须是连续天际线，只比前排
	#    短几格；随机但种子一致——多局游戏尽量相同；同屏尽量不重复用卡。
	#    此前"每前排一栋"的改法在核心区留空当，已废弃回连续扫铺）。
	_bg_rng.seed = 20260915
	_bg_recent.clear()
	# 前排跨度（背景铺满到只比前排短几格）
	var front_lo := INF
	var front_hi := -INF
	for e: Variant in front_list:
		var fw := _cw(str(e["card"]))
		front_lo = minf(front_lo, float(e["x"]) - fw * 0.5)
		front_hi = maxf(front_hi, float(e["x"]) + fw * 0.5)
	var span_lo: float = front_lo + 3.0
	var span_hi: float = front_hi - 3.0
	for li in BG_LAYERS:
		var lz: float = SKYLINE_Z - BG_LAYER_GAP * float(li)
		var tint: Color = BG_TINTS[0] if li == 0 else BG_TINTS[BG_TINTS.size() - 1]
		var gx: float = span_lo
		var guard := 0
		while gx < span_hi and guard < 80:
			guard += 1
			var card := _pick_bg_card("", gx, li)
			var w := _cw(card)
			if w < 1.0:
				w = 8.0
			if gx + w > span_hi + 2.0:
				break   # 末卡放不下（越界超 2 格就收边，不出墙）
			_spawn_bg_card(card, gx + w * 0.5, lz, tint)
			gx += w + _bg_rng.randf_range(1.2, 2.6)   # 楼间缝 1.2~2.6 格
		_bg_base_z[li] = _median(_bg_base_samples)
		_bg_base_samples.clear()


## 背景楼选卡：全卡池，排除前排本卡与最近用过的卡（同屏避同卡）；
## 种子由（前排 x, 层）决定——多局一致，加建前排时同样确定性补楼。
var _bg_rng := RandomNumberGenerator.new()
var _bg_recent: Array[String] = []

func _pick_bg_card(front_card: String, fx: float, li: int) -> String:
	_bg_rng.seed = int(abs(fx * 7919.0)) + li * 104729 + 13
	var pool: Array = []
	for c: String in _cards.keys():
		if c == front_card or _bg_recent.has(c):
			continue
		pool.append(c)
	if pool.is_empty():
		for c: String in _cards.keys():
			if c != front_card:
				pool.append(c)
	var card: String = str(pool[_bg_rng.randi_range(0, pool.size() - 1)])
	_bg_recent.append(card)
	while _bg_recent.size() > 4:
		_bg_recent.pop_front()
	return card


## 前排加建时补背景楼（建造系统事件接线入口；初始生成走 _place_rows）
func spawn_bg_for_front(front_card: String, fx: float) -> void:
	for li in BG_LAYERS:
		var lz: float = SKYLINE_Z - BG_LAYER_GAP * float(li)
		var tint: Color = BG_TINTS[0] if li == 0 else BG_TINTS[BG_TINTS.size() - 1]
		var card := _pick_bg_card(front_card, fx, li)
		_spawn_bg_card(card, fx + _bg_rng.randf_range(-4.0, 4.0), lz, tint)


func _add_width_guides() -> void:
	if not bool(_opts["debug"]):
		return
	# **整格网格**（1 格 = 一条线，每 4 格加亮）+ 每栋建筑左右边界紫线（方便数几格宽）
	var thin := StandardMaterial3D.new()
	thin.albedo_color = Color(0.55, 0.95, 1.0, 0.55)
	thin.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	thin.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var bold := StandardMaterial3D.new()
	bold.albedo_color = Color(0.35, 0.85, 1.0, 0.95)
	bold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bold.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var edge := StandardMaterial3D.new()
	edge.albedo_color = Color(1.0, 0.25, 0.85, 1.0)
	edge.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var x := -70.0
	while x <= 70.0:
		var pm := PlaneMesh.new()
		pm.size = Vector2(0.02 if int(x) % 4 != 0 else 0.035, 8.6)
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		mi.material_override = thin if int(x) % 4 != 0 else bold
		mi.position = Vector3(x, PLAT_H + 0.015, -2.6)
		mi.name = "GridX"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ground_root.add_child(mi)
		x += 1.0
	for occ in _front_occ:
		var w := float(occ[1]) - float(occ[0])
		var cx := (float(occ[0]) + float(occ[1])) * 0.5
		for s in [-1.0, 1.0]:
			var pm2 := PlaneMesh.new()
			pm2.size = Vector2(0.05, 8.6)
			var mi2 := MeshInstance3D.new()
			mi2.mesh = pm2
			mi2.material_override = edge
			mi2.position = Vector3(cx + s * w * 0.5, PLAT_H + 0.018, -2.6)
			mi2.name = "BldEdge"
			mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_ground_root.add_child(mi2)


func _add_horizon_guides() -> void:
	if not bool(_opts["debug"]):
		return
	# 两条全屏水平辅助线（创始人 2026-09-14 要求；贴地 unshaded，无阴影）：
	#   橙 = 屏幕 1/3 线（33.3% 从底）：第二排基线 + 第一排（+地面）屏幕区的上边界
	#   绿 = 末排（bg2）基线 = 真实地平线（底衬远端收到同一点）
	# z 取实测卡基线（anchor 深度偏移各卡不同，见 _spawn_bg_card）。
	var specs := [
		{"z": float(_bg_base_z.get(0, SKYLINE_Z)), "col": Color(1.0, 0.62, 0.10)},
		{"z": float(_bg_base_z.get(BG_LAYERS - 1,
			SKYLINE_Z - BG_LAYER_GAP * float(BG_LAYERS - 1))),
			"col": Color(0.20, 1.0, 0.45)},
	]
	for i in specs.size():
		var pm := PlaneMesh.new()
		pm.size = Vector2(150.0, 0.12)
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		var m := StandardMaterial3D.new()
		m.albedo_color = specs[i]["col"]
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = m
		mi.position = Vector3(0, 0.025, float(specs[i]["z"]))
		mi.name = "Guide%d" % i
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ground_root.add_child(mi)


func _add_platform() -> void:
	# 人行道台面（创始人 2026-09-14：路肩是**城中心专属**，城边是土路）：
	#   中段（±28 格）= 石板台面 + 石路肩镶边（城中心）；
	#   两侧 = 夯土台面 + 土坎镶边（近城边），材质在 ±28 格处交接。
	#   台面/镶边只铺城内（±墙线收口）；**城缘段台面换草地贴图**（创始人
	#   2026-09-15：边缘区只有道路带不长草，其他地方都是草地）
	_add_ground_plane_at("band_shoulder_stone_128.png", 0.0, 56.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 5.0, Color(1.04, 1.00, 0.93))
	_add_ground_plane_at("rammed_earth_128.png", -38.0, 20.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 8.0, Color(0.85, 0.79, 0.68))
	_add_ground_plane_at("rammed_earth_128.png", 38.0, 20.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 8.0, Color(0.85, 0.79, 0.68))
	# 近墙段台面换 v1 变体 + 再暗半档（台面也走中心→边缘渐变；±48 延到 ±墙线）
	_add_ground_plane_at("grass_alb_128.png", -71.5, 47.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 8.0, Color(0.86, 0.90, 0.76))
	_add_ground_plane_at("grass_alb_128.png", 71.5, 47.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 8.0, Color(0.86, 0.90, 0.76))
	# 石↔土交接条（gtx 手工收边件，压在交接线上）
	_add_decal("transitions/gtx_brick_gravel_road_v1.png", -28.0, PLAT_H + 0.008,
		Vector2(4.8, 1.55))
	_add_decal("transitions/gtx_brick_gravel_road_v2.png", 28.0, PLAT_H + 0.008,
		Vector2(4.8, 1.55))
	# 台肩镶边：中段石条 / 两侧土条（方形截面，高=深=台面高）
	_kerb_run(-28.0, 28.0, "band_kerb_stone")
	_kerb_run(-_wall_x(), -28.0, "band_kerb_earth")
	_kerb_run(28.0, _wall_x(), "band_kerb_earth")


## 原天空贴图剪影板：复用 2D 游戏的 assets/sky/*（SkyDecor 同源），两张不透明
## 剪影 quad（billboard 相机基）立在末层背景之后、底衬远端之前——基线落在地面内，
## 不露"3D 天空直连地面"的缝，楼群缝隙里透出远山/树线。
func _add_sky_backdrop() -> void:
	pass   # 解包山脉/树线剪影板已删（创始人 2026-09-15：assets/sky 贴图是解包素材）——
	# 远景 = 程序化天空 + 底衬远端，背景两层楼群自行遮地平线

## 城墙转角收边（§4.5）：±墙线立石墙板（沿纵深方向，正交视角下呈窄竖条
## + 墙顶垛口），门洞开在路面纵深带 GATE_Z0~Z1——门柱加厚、叠涩内挑、横梁
## 过顶组成"门楼"读法（深一档石材与墙面拉开），出城从门洞直穿。
func _build_walls() -> void:
	var wx: float = _wall_x()
	var mat := _wall_material(Color(0.85, 0.83, 0.79))
	var pmat := _wall_material(Color(0.62, 0.60, 0.57))
	var root := Node3D.new()
	root.name = "CityWalls"
	add_child(root)
	for sx: float in [-1.0, 1.0]:
		for seg: Variant in [[-1.0, GATE_Z0], [GATE_Z1, 19.5]]:
			var z0: float = float(seg[0])
			var z1: float = float(seg[1])
			_box(root, mat, Vector3(WALL_T, WALL_H, z1 - z0),
					Vector3(sx * wx, WALL_H * 0.5, (z0 + z1) * 0.5))
			var z: float = z0 + 0.7
			while z < z1 - 0.4:
				_box(root, mat, Vector3(WALL_T, 0.55, 0.85),
						Vector3(sx * wx, WALL_H + 0.275, z))
				z += 1.7
		for pz: float in [GATE_Z0 - 0.35, GATE_Z1 + 0.35]:
			_box(root, pmat, Vector3(WALL_T + 0.55, WALL_H + 0.7, 0.7),
					Vector3(sx * wx, (WALL_H + 0.7) * 0.5, pz))
		for cz: float in [GATE_Z0 + 0.45, GATE_Z1 - 0.45]:
			_box(root, pmat, Vector3(WALL_T + 0.35, 1.2, 0.55),
					Vector3(sx * wx, 4.4, cz))
		_box(root, pmat, Vector3(WALL_T + 0.3, WALL_H - 5.0, GATE_Z1 - GATE_Z0),
				Vector3(sx * wx, 5.0 + (WALL_H - 5.0) * 0.5, (GATE_Z0 + GATE_Z1) * 0.5))
		for mz: float in [GATE_Z0 + 0.9, (GATE_Z0 + GATE_Z1) * 0.5, GATE_Z1 - 0.9]:
			_box(root, pmat, Vector3(WALL_T + 0.3, 0.5, 0.8),
					Vector3(sx * wx, WALL_H + 0.25, mz))


## 墙体石材（路肩石贴图三平面投射，免逐面 UV；tint 分档）
func _wall_material(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var tex := _tex_abs(_temp + GROUND_DIR + "band_shoulder_stone_128.png")
	if tex != null:
		m.albedo_texture = tex
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(0.4, 0.4, 0.4)
	m.albedo_color = tint
	m.roughness = 0.92
	return m


func _box(root: Node3D, mat: Material, size: Vector3, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	root.add_child(mi)


func _add_decal(png_rel: String, x: float, y: float, size: Vector2) -> void:
	var t := _tex_abs(_temp + GROUND_DIR + png_rel)
	if t == null:
		return
	var pm := PlaneMesh.new()
	pm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_texture = t
	gm.roughness = 0.95
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = gm
	mi.position = Vector3(x, y, (BAND_SIDEWALK.x + BAND_SIDEWALK.y) * 0.5)
	mi.name = "Decal_" + png_rel.get_file().get_basename()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ground_root.add_child(mi)


## 台肩镶边：沿 [x0,x1) 一排方形截面长条石（高=深=台面高），逐块长度抖动。
func _kerb_run(x0: float, x1: float, tex_base: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260917 + int(x0)
	var t := _tex_abs_soft(_temp + GROUND_DIR + "src/" + tex_base + "_alb.png")
	if t == null:
		t = _tex_abs(_temp + GROUND_DIR + tex_base + "_128.png")
	var nt := _tex_abs_soft(_temp + GROUND_DIR + "src/" + tex_base + "_nrm.png")
	var x := x0
	while x < x1:
		var w: float = minf(rng.randf_range(1.7, 2.6), x1 - x)
		var bm := BoxMesh.new()
		bm.size = Vector3(w * 0.96, PLAT_H, PLAT_H)   # 方形截面：高 = 深 = 台面高
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		# 顶面压低一丝（-0.01）避免与台面共面 z-fighting；沿台面前沿镶边
		mi.position = Vector3(x + w * 0.5, PLAT_H * 0.5 - 0.01,
			BAND_SIDEWALK.y + PLAT_H * 0.35)
		var gm := StandardMaterial3D.new()
		if t != null:
			gm.albedo_texture = t
		if nt != null:
			gm.normal_enabled = true
			gm.normal_texture = nt
			gm.normal_scale = 1.0
		gm.uv1_scale = Vector3(w / 1.2, PLAT_H / 1.2, 1.0)   # 1 UV ≈ 1.2 格：方石尺度正常
		if tex_base != "band_kerb_stone":
			gm.albedo_color = Color(0.82, 0.76, 0.66)        # 土坎：偏夯土色
		gm.roughness = 0.90
		mi.material_override = gm
		mi.name = "PlatRim"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ground_root.add_child(mi)
		x += w


func _add_sidewalk() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260913
	var seg := 262.0 / 30.0
	for i in 30:
		var cx := -131.0 + (float(i) + 0.5) * seg
		var z0 := rng.randf_range(0.42, 0.56)
		# 外缘在 1.55~1.95 之间抖（上界 <2.0，保证不侵入接地影的 z 区间）
		var z1 := rng.randf_range(1.55, 1.95)
		_add_ground_plane_at("band_shoulder_stone_128.png", cx, seg * 0.985,
			z0, z1, 0.02 + rng.randf_range(0.0, 0.012), 3.6,
			Color(0.70 + rng.randf_range(-0.06, 0.06),
				0.69 + rng.randf_range(-0.06, 0.06),
				0.66 + rng.randf_range(-0.06, 0.06)))


func _make_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 6)
	_post_layer.add_child(l)
	return l


func _add_ground_plane_at(tex_name: String, cx: float, width: float,
		z0: float, z1: float, y: float, tile: float, tint: Color) -> void:
	var depth := z1 - z0
	if depth <= 0.0:
		return
	var pm := PlaneMesh.new()
	pm.size = Vector2(width, depth)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position = Vector3(cx, y, (z0 + z1) * 0.5)
	var gm := StandardMaterial3D.new()
	# 优先高清 albedo（src/<key>_alb.png = 512），否则退回游戏档 <key>
	var base := tex_name.get_basename().replace("_128", "")   # 高清图不带 _128 后缀
	var t := _tex_abs_soft(_temp + GROUND_DIR + "src/" + base + "_alb.png")
	if t == null:
		t = _tex_abs(_temp + GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
	# 法线（深度）：src/<key>_nrm.png
	var nt := _tex_abs_soft(_temp + GROUND_DIR + "src/" + base + "_nrm.png")
	if nt == null:
		nt = _tex_abs_soft(_temp + GROUND_DIR + "src/" + base + "_nrm_512.png")
	if nt != null:
		gm.normal_enabled = true
		gm.normal_texture = nt
		gm.normal_scale = 1.0
	gm.albedo_color = tint
	gm.roughness = 0.95
	gm.uv1_scale = Vector3(width / tile, depth / tile, 1.0)
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = gm
	mi.name = "Seg_" + tex_name.get_basename()
	_ground_root.add_child(mi)


func _add_ground_plane(tex_name: String, z0: float, z1: float, y: float,
		tile: float, tint: Color) -> void:
	var depth := z1 - z0
	if depth <= 0.0:
		return
	var pm := PlaneMesh.new()
	pm.size = Vector2(600.0, depth)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position = Vector3(0, y, (z0 + z1) * 0.5)
	var gm := StandardMaterial3D.new()
	# 优先高清 albedo（src/<key>_alb.png = 512），否则退回游戏档 <key>
	var base := tex_name.get_basename().replace("_128", "")   # 高清图不带 _128 后缀
	var t := _tex_abs_soft(_temp + GROUND_DIR + "src/" + base + "_alb.png")
	if t == null:
		t = _tex_abs(_temp + GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
	# 法线（深度）：src/<key>_nrm.png
	var nt := _tex_abs_soft(_temp + GROUND_DIR + "src/" + base + "_nrm.png")
	if nt == null:
		nt = _tex_abs_soft(_temp + GROUND_DIR + "src/" + base + "_nrm_512.png")
	if nt != null:
		gm.normal_enabled = true
		gm.normal_texture = nt
		gm.normal_scale = 1.0
	gm.albedo_color = tint
	gm.roughness = 0.95
	gm.uv1_scale = Vector3(600.0 / tile, depth / tile, 1.0)
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = gm
	mi.name = "Band_" + tex_name.get_basename()
	_ground_root.add_child(mi)


# ------------------------------------------------------------------ 光照档

func _apply_light(mode: String) -> void:
	# 每档先复位再覆盖（幂等，可反复调用）
	# 白天 = "阳光明媚 + 高调照明"（创始人最终口径）：
	#   · 去雾（fog 关）—— 大气不再把画面洗灰；
	#   · 主光金黄白 0.45 + 冷天空环境 0.56：**总和 ≈1.0**（继承 proto_25d 的"光照别
	#     双计"纪律，卡是已带白天光照的烘焙图）；最高 albedo 砖白 ≈0.85 → 峰值
	#     ≈0.85，再乘后处理曝光 1.06 ≈0.90，高光不溢出成白板；
	#   · 冷补光 0.12 抬暗部：明暗比从 ~1.6:1 压到 ~1.15:1（亮部 1.01 / 暗部 0.68
	#     → 乘 albedo 后 0.86 / 0.58），暗部抬亮但**不致死黑**；
	#   · 白平衡略偏暖（主光暖 + gain 微暖 + lift 微抬）。
	_sky_mat.sky_top_color = Color(0.31, 0.47, 0.78)
	_sky_mat.sky_horizon_color = Color(0.80, 0.87, 0.95)
	_sky_mat.ground_horizon_color = Color(0.78, 0.84, 0.92)
	_sky_mat.ground_bottom_color = Color(0.42, 0.44, 0.46)
	_sky_mat.energy_multiplier = 1.0
	_env.ambient_light_color = Color(0.64, 0.71, 0.86)
	_env.ambient_light_energy = 0.58
	# 去雾：阳光明媚口径下大气密度 ≈0（保留开关，量级调到看不出）
	_env.fog_enabled = false
	_env.fog_density = 0.06
	_env.fog_light_color = Color(0.84, 0.89, 0.96)
	_env.fog_depth_begin = 55.0
	_env.fog_depth_end = 160.0
	_sun.light_color = Color(1.0, 0.95, 0.83)
	_sun.light_energy = 0.48
	_sun.rotation = Vector3(deg_to_rad(-46.0), deg_to_rad(-62.0), 0)
	_fill.light_color = Color(0.70, 0.80, 1.0)
	_fill.light_energy = 0.12
	_fill.rotation = Vector3(deg_to_rad(-16.0), deg_to_rad(118.0), 0)
	var glow := 0.0
	var lamp := 0.0
	var char_tint := Color(1, 1, 1)
	var char_add := Color(0, 0, 0)
	var post := {
		# 主场景零模糊（创始人拍板）：移轴归零，模糊只由 DOF 的远焦层承担
		"tilt_level": 0.0, "tilt_radius": 7.0, "tilt_center": 0.72,
		"tilt_band": 0.17, "tilt_feather": 0.24,
		"vig_strength": 0.28, "vig_inner": 0.55, "vig_outer": 1.10,
		"exposure": 1.14, "contrast": 1.02, "saturation": 1.18,
		"lift": Color(0.024, 0.022, 0.024), "gain": Color(1.0, 0.996, 0.986),
		"split": 1.0,
	}
	match mode:
		"night":
			_sky_mat.sky_top_color = Color(0.015, 0.025, 0.07)
			_sky_mat.sky_horizon_color = Color(0.06, 0.08, 0.16)
			_sky_mat.ground_horizon_color = Color(0.05, 0.06, 0.11)
			_sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.04)
			_env.ambient_light_color = Color(0.14, 0.19, 0.34)
			_env.ambient_light_energy = 0.17
			# 夜景保留一点薄雾（白天的"去雾"口径只针对阳光明媚版主展示图）
			_env.fog_enabled = true
			_env.fog_density = 0.28
			_env.glow_intensity = 1.0
			_env.glow_bloom = 0.12
			_env.fog_light_color = Color(0.05, 0.07, 0.14)
			_env.fog_depth_begin = 32.0
			_env.fog_depth_end = 86.0
			_sun.light_color = Color(0.55, 0.68, 1.0)
			_sun.light_energy = 0.06
			_sun.rotation = Vector3(deg_to_rad(-62.0), deg_to_rad(140.0), 0)
			_fill.light_energy = 0.02
			glow = 1.15
			lamp = 1.1
			# 2D 角色在夜里被"场景光"照到：冷蓝压暗 + 灯笼暖光池（加色，别过量，
			# 加多了角色会拖一圈橙边，读作发热而不是被照亮）
			char_tint = Color(0.46, 0.52, 0.74)
			char_add = Color(0.16, 0.09, 0.03)
			# 夜景同样不做屏幕空间移轴：主场景零模糊是全局口径，夜幕的层次交给远焦 DOF
			post["tilt_level"] = 0.0
			post["vig_strength"] = 0.62
			post["exposure"] = 1.12
			post["saturation"] = 1.06
			post["lift"] = Color(0.006, 0.008, 0.018)
		_:
			pass  # day
	for m in _card_mats:
		m.set_shader_parameter("glow_energy", glow)
	for l in _lamps:
		l.visible = lamp > 0.0
		l.light_energy = lamp
	if _char_host != null:
		_char_host.set_light(char_tint, char_add)
	_set_post(post)
	print("[hd2d] 光照档=%s glow=%.2f lamp=%.2f" % [mode, glow, lamp])


func _set_post(d: Dictionary) -> void:
	for k in d.keys():
		_post_mat.set_shader_parameter(k, d[k])


## 屏幕像素尺寸（移轴模糊半径以 px 计）。canvas_item shader 在 4.7 没有
## SCREEN_PIXEL_SIZE 内建，只能由脚本灌；窗口 resize / 性能档改分辨率后必须重灌。
func _update_px_size() -> void:
	var sz := get_viewport().get_visible_rect().size
	if sz.x > 0.0 and sz.y > 0.0:
		_post_mat.set_shader_parameter("px_size", Vector2(1.0 / sz.x, 1.0 / sz.y))


## A/B/C 三张递进图的开关
##   a: 无角色 + 无后处理（glow/DOF/后处理层全关 → 只有 3D 场景 + 建筑卡）
##   b: 加角色（SubViewport -> billboard），仍无任何后处理
##   c: 再加 HD-2D 后处理（glow + DOF + 移轴 + 暗角 + 分级）
func _apply_stage(stage: String) -> void:
	if _char_host != null:
		_char_host.set_chars_visible(stage != "a")
	_post_rect.visible = stage == "c" or stage == "d" or stage == "e"
	_update_px_size()
	var hd := stage == "c" or stage == "d" or stage == "e"
	_env.glow_enabled = hd
	# 景深（CameraAttributesPractical；Godot 4 的 DOF 挂在相机属性上，不在 Environment）
	# **业界口径**：八方旅人初代的强移轴被广泛批评（"让玩家想关掉"），三角战略已把它
	# 改成可关设置。故本档口径 = 近焦**关**、主场景（临街一排 + 火柴人）**零模糊**，
	# 只让远背景层吃远焦模糊。
	# 深度坐标（相机视图空间，实测本机位）：角色 29~35 | 临街建筑卡 41~45.5 |
	# 中景地面 44~62 | 远景剪影层(z=-24) ≈ 66。
	# far 46.5 + 过渡 9：临街卡(41~45.5) 完全在 46.5 以内 → 100% 锐利；
	# 第二排 bg1（≈51）→ (51-46.5)/9 = 50% 半档模糊（创始人：第二排景深要明显）；
	# 末排 bg2（≈56）→ 满档。运行时经 set_cam_zoom 重算为同一世界线
	# （天际线前移 DOF_FAR_START_AHEAD 格），两处口径一致。
	_cam_attrs.dof_blur_near_enabled = false
	_cam_attrs.dof_blur_far_enabled = hd and not bool(_opts["flat"])
	_cam_attrs.dof_blur_near_distance = 24.0
	_cam_attrs.dof_blur_near_transition = 10.0
	_cam_attrs.dof_blur_far_distance = 48.0
	_cam_attrs.dof_blur_far_transition = 20.0
	# amount 0.20：回到初始渐变（第二排半档、远景满档）——0.26+9 过渡把两层
	# 糊成一档，渐变读不出来（创始人 2026-09-15）。
	_cam_attrs.dof_blur_amount = 0.20


# ------------------------------------------------------------------ 出图

func _settle(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(name: String) -> String:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_temp + "proto_hd2d")
	var tag := str(_opts.get("tag", ""))
	if not tag.is_empty():
		name += tag
	var p := _temp + "proto_hd2d/" + name + ".png"
	var err := img.save_png(p)
	if err != OK:
		push_error("[hd2d] 截图失败 %s (err=%d)" % [p, err])
	else:
		print("[hd2d] shot -> %s  %dx%d  帧时=%.2f ms" % [
			p, img.get_width(), img.get_height(), _last_frame_ms()])
	return p


func _last_frame_ms() -> float:
	return 1000.0 / max(1.0, Performance.get_monitor(Performance.TIME_FPS))


func _run_shots(which: String) -> void:
	var t0 := Time.get_ticks_usec()
	# SubViewport 实测：量 alpha 包围盒，证明 2D 像素真进了纹理
	var bb: Rect2i = await _char_host.measure_bbox()
	var px_per_grid := 32.0 * float(_char_host.px_scale)
	print("[hd2d] SubViewport %dx%d 角色 alpha 包围盒=%s  -> 角色高 %.2f 格 (契约 4.09；1px=%.5f 格)" % [
		_char_host.viewport.size.x, _char_host.viewport.size.y, str(bb),
		float(bb.size.y) / px_per_grid, 1.0 / px_per_grid])

	var do: Array = []
	if which == "all" or which == "":
		do = ["a", "b", "c", "d", "e"]
	else:
		do = [which]

	for st in do:
		match st:
			"a":
				_apply_light("day")
				_apply_stage("a")
				await _settle(1.4)
				await _shot("hd2d_a_base")
			"b":
				_apply_light("day")
				_apply_stage("b")
				await _settle(1.4)
				await _shot("hd2d_b_char")
			"c":
				_apply_light("day")
				_apply_stage("c")
				await _settle(1.4)
				await _shot("hd2d_c_final")
			"d":
				await _shot_occlusion()
			"e":
				_apply_light("night")
				_apply_stage("e")
				await _settle(1.6)
				await _shot("hd2d_e_night")
			"s":
				# 主街巡览（2026-09-14 手工摆+街长扩到村A全域的验收档）：
				# 沿街机位横移（set_cam_x），含两端城墙/门洞与墙外野外带，
				# 各出一张白天最终观感图
				_apply_light("day")
				_apply_stage("c")
				for cam_x: float in [-115.0, -55.0, 0.0, 55.0, 100.0, 122.0]:
					set_cam_x(cam_x)
					await _settle(1.2)
					await _shot("hd2d_s_street_x%d" % int(cam_x))
				set_cam_x(0.0)
	print("[hd2d] 出图用时 %.1f s" % (float(Time.get_ticks_usec() - t0) / 1000000.0))


## 遮挡验证：两个角色、同 x、只差 z。两格并排。
## 判读：
##   左格 FRONT  z=+4：两个角色都完整可见，且 x=-11 那个**盖住**建筑立面
##                     （角色更近 → 深度测试通过）；
##   右格 BEHIND z=-3：x=-30.5 的对照角色照常可见（证明这一层的角色在渲染）；
##                     x=-11 那个与墙体重叠的像素整片消失，只在卡的 alpha 剪影
##                     缺口（门柱边缘 alpha<0.4 的像素）透出几道细缝。
## 后者同时证明：遮挡是**逐像素 alpha 剪影**级，而不是整片 quad 级 ——
## 这是纸片路线能不能用的关键判据。
func _shot_occlusion() -> void:
	_apply_light("day")
	_apply_stage("d")
	var ch: Node3D = _char_host
	# 清掉常规站位（含接地影），换成验证站位
	for c in ch.get_children():
		if c is MeshInstance3D and (str(c.name).begins_with("Char_")
				or str(c.name).begins_with("Shadow_")):
			(c as MeshInstance3D).visible = false
	# 标签只用左边那一个：每格画面顶部写该格的状态，并排后读作 [FRONT…] | [BEHIND…]
	# （两个标签都用会让两格各自出现"FRONT + BEHIND"四个字样，判读混乱）
	_hud.text = "FRONT  z=+4（两角色都在街上：x=-11 盖住建面）"
	_hud.visible = true
	_hud2.visible = false
	# 左格：两个角色都在建筑之前
	var qf1: MeshInstance3D = ch.add_char(OCC_X, OCC_FRONT_Z)
	var qf2: MeshInstance3D = ch.add_char(OCC_CTRL_X, OCC_FRONT_Z, true)
	await _settle(1.2)
	var p1: String = await _shot("_occ_front")
	qf1.visible = false
	qf2.visible = false
	# 右格：同样的两个 x，退到建筑之后
	var qb1: MeshInstance3D = ch.add_char(OCC_X, OCC_BEHIND_Z)
	var qb2: MeshInstance3D = ch.add_char(OCC_CTRL_X, OCC_BEHIND_Z, true)
	_hud.text = "BEHIND  z=-3（对照角色仍在，x=-11 被墙吃掉）"
	await _settle(0.9)
	var p2: String = await _shot("_occ_behind")
	_hud.visible = false
	_hud2.visible = false
	_stitch(p1, p2, "hd2d_d_occlusion")
	# 验证站位用完即弃，避免污染后续镜头（夜景那格要保持与 _c 同内容）
	qf1.queue_free()
	qf2.queue_free()
	qb1.queue_free()
	qb2.queue_free()
	ch.clear_extra()
	# 常驻角色恢复可见（_apply_stage 下一档会再统一设一次，这里保证独立出图时也对）
	ch.set_chars_visible(true)


# ------------------------------------------------------------------ 出图（合成）

## 两图并排（中间 8px 分隔），落 hd2d_d_occlusion.png
func _stitch(p1: String, p2: String, out_name: String) -> void:
	var a := Image.new()
	var b := Image.new()
	if a.load(p1) != OK or b.load(p2) != OK:
		push_error("[hd2d] 并排失败：读不到 "+p1+" / "+p2)
		return
	var gap := 8
	var w := a.get_width() + b.get_width() + gap
	var h := maxi(a.get_height(), b.get_height())
	var out := Image.create(w, h, false, a.get_format())
	out.fill(Color(0.02, 0.02, 0.03))
	out.blit_rect(a, Rect2i(0, 0, a.get_width(), a.get_height()), Vector2i(0, 0))
	out.blit_rect(b, Rect2i(0, 0, b.get_width(), b.get_height()),
		Vector2i(a.get_width() + gap, 0))
	var p := _temp + "proto_hd2d/" + out_name + ".png"
	out.save_png(p)
	print("[hd2d] stitch -> %s  %dx%d" % [p, w, h])


# ------------------------------------------------------------------ 性能

func _run_perf() -> void:
	print("[hd2d] === 性能档 ===")
	if str(_opts["res"]) != "":
		var parts := str(_opts["res"]).split("x")
		if parts.size() == 2:
			DisplayServer.window_set_size(Vector2i(int(parts[0]), int(parts[1])))
			await _settle(0.8)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await _settle(0.5)
	print("[hd2d] vsync_mode=%d（2=disabled）  视口=%s" % [
		DisplayServer.window_get_vsync_mode(), str(get_viewport().get_visible_rect().size)])
	_update_px_size()

	_apply_light("day")
	_apply_stage("c")

	# 热身：**必须先跑一轮"角色 + SubViewport ALWAYS + 后处理全开"再开始计时**。
	# 实测（未热身）：L1 与 L4 是同一配置，却读到 55.6ms vs 6.06ms —— 差的就是
	# 首次用到 char shader / SubViewport 渲染目标时的一次性编译与显存分配。
	_char_host.set_chars_visible(true)
	_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await _settle(4.0)

	# L0: 无角色（对照，后处理开）
	_char_host.set_chars_visible(false)
	await _measure("L0 无角色（对照，后处理开）", 3.0)
	# L1: 角色 + SubViewport 每帧更新
	_char_host.set_chars_visible(true)
	_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await _measure("L1 角色 + SubViewport ALWAYS", 3.0)
	# L2: 角色 + SubViewport 冻结（只省 SubViewport 那一份）
	_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	await _settle(0.6)
	await _measure("L2 角色 + SubViewport DISABLED(冻结)", 3.0)
	# L3: 角色每帧更新 + 后处理关（量后处理成本）
	_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_apply_stage("b")
	await _measure("L3 角色 ALWAYS + 后处理关", 3.0)
	_apply_stage("c")
	await _measure("L4 = L1 复测（验证热身已消掉一次性成本）", 3.0)
	# L5: SubViewport 放大到 8x（相对默认 2x 是 16 倍像素）—— 把 SubViewport 的
	# 渲染开销顶出本机 vsync 天花板 + 外部进程抢占的噪声底，才量得出这一项。
	_spawn_char_host(8.0)
	await _settle(3.0)
	await _measure("L5 SubViewport 8x（16 倍像素，隔离该项开销）", 3.0)
	_spawn_char_host(2.0)
	await _settle(2.0)
	await _measure("L6 回到默认 2x 复测", 3.0)
	await _shot("hd2d_perf")
	print("[hd2d] === 性能档结束 ===")
	_apply_stage("c")


func _measure(label: String, seconds: float) -> void:
	await _settle(1.5)                     # 档内再稳一帧
	_samples = PackedFloat32Array()
	_measuring = true
	var t0 := Time.get_ticks_usec()
	await _settle(seconds)
	var el := float(Time.get_ticks_usec() - t0) / 1000000.0
	_measuring = false
	var arr := Array(_samples)
	arr.sort()
	if arr.is_empty():
		print("[perf] %s：无样本" % label)
		return
	var fps := float(arr.size()) / maxf(0.001, el)
	var draws := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	print("[perf] %-40s 帧时=%.2f ms (%.0f fps)  min=%.2f p10=%.2f med=%.2f p95=%.2f max=%.2f  draws=%d prims=%d" % [
		label, 1000.0 / maxf(0.01, fps), fps, float(arr[0]),
		float(arr[mini(arr.size() - 1, int(arr.size() * 0.10))]),
		float(arr[arr.size() / 2]),
		float(arr[mini(arr.size() - 1, int(arr.size() * 0.95))]),
		float(arr[arr.size() - 1]), draws, prims])


func _process(delta: float) -> void:
	if _measuring:
		_samples.append(delta * 1000.0)
