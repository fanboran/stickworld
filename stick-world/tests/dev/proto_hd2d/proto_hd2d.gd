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
	# 铁匠铺（smithy@-17）门前工位
	{"card": "anvil", "x": -18.6, "z": 4.5, "plat": true},
	{"card": "grindstone", "x": -15.4, "z": 4.3, "plat": true},
	# 铁匠-宅邸之间市集广场（-12~-6）
	{"card": "market_stall", "x": -11.8, "z": 4.6, "plat": false},
	{"card": "market_table", "x": -9.0, "z": 5.6, "plat": false},
	{"card": "produce_baskets", "x": -7.0, "z": 4.6, "plat": false},
	{"card": "well", "x": -13.8, "z": 5.2, "plat": false},
	# 宅邸地标（guildhall@+1）前
	{"card": "banner", "x": -2.6, "z": 4.5, "plat": true},
	{"card": "lantern", "x": 5.6, "z": 4.6, "plat": true},
	{"card": "bench", "x": 1.2, "z": 5.4, "plat": false},
	# 西村口民居（house@-51）与石造仓库（warehouse@-34）前
	{"card": "basket", "x": -48.6, "z": 4.4, "plat": true},
	{"card": "cart", "x": -43.5, "z": 6.0, "plat": false},
	{"card": "crate", "x": -30.4, "z": 4.4, "plat": true},
	{"card": "barrel", "x": -27.6, "z": 4.2, "plat": true},
	{"card": "sack_stack", "x": -33.2, "z": 5.8, "plat": false},
	# 东民居（house@+17）前
	{"card": "barrel_stand", "x": 20.6, "z": 4.3, "plat": true},
	{"card": "pot", "x": 23.4, "z": 4.4, "plat": true},
	# 谷仓（barn@+33 落地面）与酒馆（tavern@+48）前
	{"card": "haystack", "x": 38.0, "z": 5.6, "plat": false},
	{"card": "log_pile", "x": 29.8, "z": 6.0, "plat": false},
	{"card": "flower_box", "x": 50.6, "z": 4.4, "plat": true},
	{"card": "bench", "x": 45.5, "z": 5.0, "plat": false},
	# 东城门塔（gatehouse@+59）前
	{"card": "wheelbarrow", "x": 55.2, "z": 5.4, "plat": false},
]

## 自然物（bake_nature.py 从 nature.py 16 类库烘的卡）——野外树木/矿物实装。
## 摆位语义对齐村A：西侧 -67~-42 是森林带（伐木/采矿劳作区），东段城外散布；
## `res` = 该点位同步生成的 2D ResourceNode 采集类型（wood/stone/metal/gold/
## diamond；空串 = 纯景，不可采）。`z` ≥ 5 前景带（玩家从树前走过）。
const NATURE_SPOTS: Array = [
	# 西森林带（村A 左侧森林带语义）
	{"card": "dead_tree", "x": -66.0, "z": 9.0, "res": ""},
	{"card": "broadleaf", "x": -62.5, "z": 8.0, "res": "wood"},
	{"card": "conifer", "x": -58.0, "z": 10.0, "res": "wood"},
	{"card": "bush", "x": -60.5, "z": 5.5, "res": ""},
	{"card": "grass_clump", "x": -56.5, "z": 5.0, "res": ""},
	{"card": "broadleaf_tall", "x": -54.0, "z": 7.5, "res": "wood"},
	{"card": "mushrooms", "x": -55.5, "z": 5.2, "res": ""},
	{"card": "iron_outcrop", "x": -51.5, "z": 8.5, "res": "metal"},
	{"card": "boulder", "x": -49.0, "z": 6.2, "res": "stone"},
	{"card": "copper_vein", "x": -46.5, "z": 9.5, "res": "metal"},
	{"card": "stump", "x": -45.0, "z": 5.5, "res": ""},
	{"card": "gold_vein", "x": -42.5, "z": 8.0, "res": "gold"},
	# 东段城外散布
	{"card": "grass_clump", "x": 38.5, "z": 5.0, "res": ""},
	{"card": "conifer", "x": 40.5, "z": 10.5, "res": "wood"},
	{"card": "bush", "x": 43.0, "z": 5.5, "res": ""},
	{"card": "broadleaf", "x": 44.5, "z": 8.5, "res": "wood"},
	{"card": "stump", "x": 42.5, "z": 5.4, "res": ""},
	{"card": "crystal_cluster", "x": 50.5, "z": 7.5, "res": "diamond"},
	{"card": "bush", "x": 52.5, "z": 5.0, "res": ""},
	{"card": "dead_tree", "x": 60.5, "z": 9.5, "res": ""},
	{"card": "conifer", "x": 55.5, "z": 11.0, "res": "wood"},
	{"card": "rubble", "x": 57.0, "z": 5.5, "res": ""},
	{"card": "iron_outcrop", "x": 63.5, "z": 8.0, "res": "metal"},
	{"card": "boulder", "x": 66.0, "z": 6.5, "res": "stone"},
]

## 前排主街（2026-09-14 **手工摆** = 村A主场景 InitialBuildingsList 的语义翻译，
## 规模按创始人指令放大到村A全域（左森林带 -67 → 右城墙 +59），不再随机轮转）：
##   cottage_w6   @-65  西村外孤屋（野外感起点，村A无对应，补景）
##   house_w16    @-51  西村口民居   ← 村A placeholder@-51
##   warehouse_w16@-34  石造仓库     ← 村A stone_warehouse@-34
##   smithy1_w8   @-17  铁匠铺       ← 村A smithy_lv1@-17
##   guildhall_w12@ +1  宅邸地标     ← 村A manor@+1（v3 无 manor 装配器，取最宏伟行政楼）
##   house_w16    @+17  东民居       ← 村A placeholder@+17（spawn_initial_warehouse 补建位）
##   barn_w12     @+33  田园谷仓（落地面，补景加密）
##   tavern_w12   @+48  酒馆（补景加密）
##   gatehouse_w8 @+59  东城门塔（村A右城墙@+59 语义收尾）
## `z` = 纵深错落（0.4~1.3 台面为主，谷仓落地面）；`door` = 门前短径。
const FRONT_ROW: Array = [
	{"card": "cottage_w6", "x": -65.0, "z": 0.9, "door": false},
	{"card": "house_w16", "x": -51.0, "z": 0.7, "door": true},
	{"card": "warehouse_w16", "x": -34.0, "z": 1.25, "door": false},
	{"card": "smithy1_w8", "x": -17.0, "z": 0.45, "door": true},
	{"card": "guildhall_w12", "x": 1.0, "z": 0.85, "door": true},
	{"card": "house_w16", "x": 17.0, "z": 0.6, "door": true},
	{"card": "barn_w12", "x": 33.0, "z": 2.4, "door": false},
	{"card": "tavern_w12", "x": 48.0, "z": 1.0, "door": true},
	{"card": "gatehouse_w8", "x": 59.0, "z": 0.4, "door": true},
]
## 背景层（创始人 2026-09-14 定案）：
##   · 第二排基线压**屏幕下 1/3 线**（33.3% 从底）——该线同时是第一排（+地面）
##     屏幕区的上边界：下 1/3 归前排与街面，中 1/3 起归背景楼群，两排在一条线交界；
##   · 前排楼身挡住 bg1 根部、bg1 从前排楼顶上方露出（高低咬合）＝"第二排插第一排缝"；
##   · 三层背景每层**楼间留缝不贴死**，后层楼**吸附进前层的缝隙**；
##   · 末层基线 = 真实地平线（底衬远端同步收到此处），楼身把地平线遮死。
const SKYLINE_Z := -6.73                 # 基线压屏幕下 1/3 线：v=-h/6 → z=-(v+CY·cosθ)/sinθ
const BG_LAYER_GAP := 6.0                # 背景层距（格）：屏幕上每层基线差 ≈6.3% 屏高
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
var layout_name := ""             # 布局名（--layout= 或地图宿主 set；空 = 手摆主街）
var _tex_cache: Dictionary = {}

var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _ground_root: Node3D
var _card_root: Node3D
var _prop_root: Node3D
var _front_occ: Array = []
var _door_path_xs: Array = []   # 需要门前短径的建筑 x（guildhall / 落地面建筑）
var _prop_slots: Array = []     # 前排楼间空当 [x0,x1]（道具槽位）
var _prop_solids: Array = []    # 道具实心区间 [x0,x1]（碰撞用）
var _res_spawns: Array = []     # 自然物对应的采集资源点位 [{pos,type}]（宿主读）
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
	if not str(_opts["layout"]).is_empty():
		_layout = _read_json_rel(LAYOUT_DIR + str(_opts["layout"]) + ".json")
		if _layout.is_empty():
			push_error("[hd2d] 布局缺失，退回手摆主街: " + str(_opts["layout"]))
	print("[hd2d] 模式=", "布局驱动:" + str(_opts["layout"]) if not _layout.is_empty() else "手摆主街")
	_build_world()
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
		elif s.begins_with("--debug="):
			# --debug=1：辅助线（网格/紫线/1/3 线/末层基线）——调试模式才出现（创始人口径）
			_opts["debug"] = s.get_slice("=", 1) != "0"


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


func _cam_basis() -> Basis:
	var t := deg_to_rad(TILT_DEG)
	return Basis(Vector3(1, 0, 0),
		Vector3(0, cos(t), -sin(t)), Vector3(0, sin(t), cos(t)))


## 建筑卡：**按 cards.json 的 anchor 落位**。
## anchor 是"卡画面中心对应的世界点"，它落在过建筑地面原点的相机平面内；
## 于是 quad 中心 = anchor，quad 底边在 cam_up 方向下移 cv px 正好是世界 y=0 线
## （cv = anchor.y / sin(TILT)，推导见汇报）。x 用槽位中心，anchor.x 只作参考。
func _spawn_card(card: String, x: float, z_off: float, skyline: bool = false) -> MeshInstance3D:
	var meta: Dictionary = _cards.get(card, {})
	if meta.is_empty():
		push_warning("[hd2d] 无此卡: " + card)
		return null
	var units: Array = meta["units"]
	var anc: Array = meta["anchor"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * S, float(units[1]) * S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.position = Vector3(x, float(anc[2]) * S, -float(anc[1]) * S + z_off)
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
## 底衬远端对齐）。卡底 z 不能直接用层 z：anchor 在卡画面上的深度偏移各卡不同，
## 正确推导 = 卡底点 = anchor 点沿 -cam_up 下移 cv，cv = anchor.y / cosθ
## → 底 z = pos.z + tanθ · anchor.y。
func _spawn_bg_card(card: String, x: float, lz: float, tint: Color) -> void:
	var mi := _spawn_card(card, x, lz, true)
	if mi == null:
		return
	(mi.material_override as ShaderMaterial).set_shader_parameter("tint", tint)
	var meta: Dictionary = _cards.get(card, {})
	if meta.is_empty():
		return
	var anc: Array = meta["anchor"]
	_bg_base_samples.append(mi.position.z + tan(deg_to_rad(TILT_DEG)) * float(anc[2]) * S)


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
	mi.position = Vector3(x, ground + cos(t) * half, z_off - sin(t) * half)
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


func _place_props() -> void:
	if not _layout.is_empty():
		for e: Variant in _layout.get("props", []):
			_spawn_prop(str(e["card"]), float(e["x"]), float(e.get("z", 5.0)),
					bool(e.get("plat", false)))
		return
	for e in PROPS:
		_spawn_prop(str(e["card"]), float(e["x"]), float(e["z"]), bool(e.get("plat", true)))


## 自然物卡：与道具同一套卡底贴地落位（全落地面/草地面，不上台面）；
## 实心卡（树/巨岩/矿露头）登记碰撞；带 res 的点位登记给宿主生成 ResourceNode。
func _place_nature() -> void:
	if not _layout.is_empty():
		for e: Variant in _layout.get("trees", []):
			_spawn_nature_card(str(e["card"]), float(e["x"]), float(e.get("z", 5.5)))
			if str(e.get("res", "")) != "":
				_res_spawns.append({
					"pos": Vector2(float(e["x"]) * 32.0, 688.0 + float(e.get("z", 5.5)) * 32.0),
					"type": str(e["res"]),
				})
		return
	for e in NATURE_SPOTS:
		var mi := _spawn_nature_card(str(e["card"]), float(e["x"]), float(e["z"]))
		if mi != null and str(e.get("res", "")) != "":
			# 2D 行走带 y 与 3D z 的近似映射：y = 688 + z*32（资源点必须落在
			# 玩家可达带内，交互距离判定才够得着）
			_res_spawns.append({
				"pos": Vector2(float(e["x"]) * 32.0, 688.0 + float(e["z"]) * 32.0),
				"type": str(e["res"]),
			})


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
	# 挡人的种类（树/巨岩/矿露头/水晶，bake_nature 的 solid 标记）：卡宽收窄 15%。
	# 同道具：点障碍只在自身纵深带附近（树干在脚下，不挡整条行走带）
	if bool(meta.get("solid", false)):
		var half_w: float = float(units[0]) * S * 0.5 * 0.85
		var y_c: float = 688.0 + z_off * 32.0
		_prop_solids.append([x - half_w, x + half_w, y_c - 30.0, y_c + 30.0])
	return mi


## 带采集资源的自然物点位（宿主 Hd2dStreetMap 读取后生成 ResourceNode）。
func get_nature_spawns() -> Array:
	return _res_spawns


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
	# 景深与缩放解耦：far blur 起点钉在天际线基线这条**世界线**上——
	# dof_blur_far_distance 是相机本地距离，缩放移动相机后若不同步换算，
	# 模糊带会跟着缩放漂移（创始人：景深不应受镜头缩放影响）
	if _cam_attrs != null:
		_cam_attrs.dof_blur_far_distance = (_cam.position.z - SKYLINE_Z) / cos(t)


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
	_place_rows()   # 前排吸附整格 + 三层背景留缝、后层插前层缝
	_prop_root = Node3D.new()
	_prop_root.name = "Props"
	add_child(_prop_root)
	_place_props()  # 街面小零件（摊/桶/车/井…）
	_place_nature() # 野外树木/矿物卡（西森林带+东段城外）

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
	var far_z: float = float(_bg_base_z.get(2, SKYLINE_Z - BG_LAYER_GAP * 2.0))
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
	_add_platform()                       # 人行道台面（三段：中石板/两侧夯土+交接条）+ 台肩长条石
	_add_width_guides()                   # 建筑宽度辅助线（--debug 才显示）
	_add_horizon_guides()                 # 1/3 线（橙）+ 第三排基线（绿）（--debug 才显示）
	for dx in _door_path_xs:
		_add_door_path(float(dx), 3.6)    # 门前短径（楼脚→台肩→路面）
	_add_ground_plane("band_road_stone_128.png", BAND_ROAD.x, BAND_ROAD.y,
		0.02, 10.0, Color(0.86, 0.89, 0.96))    # 道路：偏冷深石（与台面拉开）

	# --- 灯笼点光源（暖光；让"真 3D 光照"这条线可验证）---
	_lamp_root = Node3D.new()
	_lamp_root.name = "Lamps"
	add_child(_lamp_root)
	# 沿街每 8.5 格一盏，铺满村A全域街长（相机横移后夜灯不缺位）
	for i in 21:
		var l := OmniLight3D.new()
		l.position = Vector3(-85.0 + float(i) * 8.5, 2.5, 4.2)
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
	var front_list: Array = FRONT_ROW
	if not _layout.is_empty():
		front_list = []
		for b: Variant in _layout.get("buildings", []):
			if int(b["row"]) != 0:
				continue
			# 站位错落由 x 哈希确定（同 seed 同街景）
			var jitter: float = 0.55 + fposmod(absf(float(b["x"])) * 0.37, 0.7)
			front_list.append({"card": str(b["card"]), "x": float(b["x"]),
				"z": jitter, "door": bool(b.get("door", false))})
	for e in front_list:
		var card: String = str(e["card"])
		var cx: float = float(e["x"])
		var z_off: float = float(e.get("z", 0.6))
		# 台面站位：卡底落在台面标高；谷仓 z>2 = 落地面（不上台面，路面标高）
		var on_plat: bool = z_off < 2.0
		var mi := _spawn_card(card, cx, z_off)
		if mi != null and on_plat:
			mi.position.y += PLAT_H
		_spawn_building_shadow(card, cx, mi)
		if bool(e.get("door", false)) or not on_plat:
			_door_path_xs.append(cx)   # 宏伟建筑/落地建筑：门前短径
		var w: float = _cw(card)
		occ_front.append([cx - w * 0.5, cx + w * 0.5, card, z_off])
	_prop_slots = []
	_front_occ = occ_front
	# 三层背景（创始人 2026-09-14 定案，算法职责）：
	#   · 每层楼与楼**留缝不贴死**；后层的楼**吸附进前层的缝隙**——从缝里透出
	#     后层楼身，即"后层插前层缝"；
	#   · bg1 基线 = 屏幕 1/3 线（SKYLINE_Z），该线兼任前排建筑高度上限；
	#   · 末层缝最小 + 补洞，把地平线（底衬远端）遮死。
	#   注意"缝"按**卡画面宽**算（含出檐，cottage_w6 画面 9.1 格 ≠ 6 格建筑）。
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260914
	# 主题组合段（创始人 2026-09-14：背景种类要多、要有好看的组合，不要高重复轮转）：
	#   西段=教堂天际线（大教堂/礼拜堂/塔）· 中段=市集街屋（酒馆/商铺/联排）
	#   东段=田园作坊（谷仓/马厩/草棚/铁匠）——卡按楼所在 x 段从池里顺位取，防邻重
	var bands := [
		{"x0": -104.0, "x1": -16.0, "pool": ["cathedral_w16", "tower_w6", "house_w8", "guildhall_w12", "tower_w6", "house_w16"]},
		{"x0": -16.0, "x1": 16.0, "pool": ["shop_w8", "bakery_w8", "house_w8", "tower_w6", "tavern_w12", "townhouse_w12"]},
		{"x0": 16.0, "x1": 104.0, "pool": ["barn_w12", "stable_w12", "cottage_w6", "gatehouse_w8", "smithy1_w8", "cottage_w6"]},
	]
	var band_cursor := [0, 0, 0]
	var _pick_in_band := func(x: float, room: float) -> String:
		for bi in bands.size():
			var b: Dictionary = bands[bi]
			if float(b["x0"]) <= x and x < float(b["x1"]):
				var pool: Array = b["pool"]
				for k in pool.size():
					var c: String = str(pool[(band_cursor[bi] + k) % pool.size()])
					var cw := _cw(c)
					if cw < 1.0 or cw <= room:
						band_cursor[bi] = (band_cursor[bi] + k + 1) % pool.size()
						return c
				return ""
		return ""
	var prev_slots: Array = []      # 前一层楼的画面占用 [x0,x1]
	for li in 3:
		var lz: float = SKYLINE_Z - BG_LAYER_GAP * float(li)
		var occ: Array = []
		var tint: Color = BG_TINTS[li]
		if li == 0 and not _layout.is_empty():
			# bg1 = 布局后排（city_layout row>=1，x 由算法分配互不重叠）
			for b: Variant in _layout.get("buildings", []):
				if int(b["row"]) < 1:
					continue
				var card2: String = str(b["card"])
				var cx2: float = float(b["x"])
				var w2 := _cw(card2)
				_spawn_bg_card(card2, cx2, lz, tint)
				occ.append([cx2 - w2 * 0.5, cx2 + w2 * 0.5])
		elif li == 0:
			# bg1 自由铺：楼 + 2~3.5 格缝的节奏（根部被前排挡住，楼身从前排楼顶上露出）
			var gx := -104.0
			while gx < 104.0:
				var card: String = str(_pick_in_band.call(gx, 999.0))
				if card == "":
					card = "house_w8"
				var w := _cw(card)
				if w < 1.0:
					w = 8.0
				_spawn_bg_card(str(card), gx + w * 0.5, lz, tint)
				occ.append([gx, gx + w])
				gx += w + rng.randf_range(2.0, 3.5)
		else:
			# bg2/bg3 吸附前层缝：每条缝中心放一栋楼（从缝里露出楼身）。
			# 本层自身保持 ≥1 格缝（给再后一层插）；放不下的缝放弃（末层补洞兜底）。
			var last_x1 := -999.0
			for g in _gaps(prev_slots, -104.0, 104.0):
				var g0: float = float(g[0])
				var g1: float = float(g[1])
				if g1 - g0 < 1.0:
					continue
				var cx: float = (g0 + g1) * 0.5
				var room: float = cx - (last_x1 + 1.0)   # 左侧可用宽度
				var card: String = _pick_in_band.call(cx, room)
				if card == "":
					continue
				var w := _cw(card)
				if w < 1.0:
					w = 8.0
				_spawn_bg_card(card, cx, lz, tint)
				occ.append([cx - w * 0.5, cx + w * 0.5])
				last_x1 = cx + w * 0.5
			if li >= 1:
				# bg2/bg3 职责 = 遮死中景与地平线：吸附放不下的层再补大洞（近贴 0.6 格缝）。
				# 阈值 9.8 = 库里最小画面宽 cottage_w6(9.1) + 0.6 缝，更窄的洞放不下任何卡。
				for g in _gaps(occ, -104.0, 104.0):
					var g0: float = float(g[0])
					var g1: float = float(g[1])
					while g1 - g0 > 9.8:
						var room: float = g1 - g0 - 0.6
						var card: String = _pick_in_band.call((g0 + g1) * 0.5, room)
						if card == "":
							break
						var w := _cw(card)
						_spawn_bg_card(card, g0 + w * 0.5, lz, tint)
						occ.append([g0, g0 + w])
						g0 += w + 0.6
		prev_slots = occ
		_bg_base_z[li] = _median(_bg_base_samples)
		_bg_base_samples.clear()


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
	#   绿 = 第三排（末层）基线 = 真实地平线（底衬远端收到同一点）
	# z 取实测卡基线（anchor 深度偏移各卡不同，见 _spawn_bg_card）。
	var specs := [
		{"z": float(_bg_base_z.get(0, SKYLINE_Z)), "col": Color(1.0, 0.62, 0.10)},
		{"z": float(_bg_base_z.get(2, SKYLINE_Z - BG_LAYER_GAP * 2.0)),
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
	#   街长铺到村A全域 ±67（2026-09-14 规模放大），夯土段随之铺到 ±70。
	_add_ground_plane_at("band_shoulder_stone_128.png", 0.0, 56.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 5.0, Color(1.04, 1.00, 0.93))
	_add_ground_plane_at("rammed_earth_128.png", -66.0, 76.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 8.0, Color(0.85, 0.79, 0.68))
	_add_ground_plane_at("rammed_earth_128.png", 66.0, 76.0,
		-6.5, BAND_SIDEWALK.y, PLAT_H, 8.0, Color(0.85, 0.79, 0.68))
	# 石↔土交接条（gtx 手工收边件，压在交接线上）
	_add_decal("transitions/gtx_brick_gravel_road_v1.png", -28.0, PLAT_H + 0.008,
		Vector2(4.8, 1.55))
	_add_decal("transitions/gtx_brick_gravel_road_v2.png", 28.0, PLAT_H + 0.008,
		Vector2(4.8, 1.55))
	# 台肩镶边：中段石条 / 两侧土条（方形截面，高=深=台面高）
	_kerb_run(-28.0, 28.0, "band_kerb_stone")
	_kerb_run(-104.0, -28.0, "band_kerb_earth")
	_kerb_run(28.0, 104.0, "band_kerb_earth")


## 原天空贴图剪影板：复用 2D 游戏的 assets/sky/*（SkyDecor 同源），两张不透明
## 剪影 quad（billboard 相机基）立在末层背景之后、底衬远端之前——基线落在地面内，
## 不露"3D 天空直连地面"的缝，楼群缝隙里透出远山/树线。
func _add_sky_backdrop() -> void:
	# 原天空贴图剪影板：复用 2D 游戏的 assets/sky/*（SkyDecor 同源）。剪影 PNG 带
	# alpha——必须开透明混合（否则透明区渲成黑带）；高度/饱和度按空气透视压低压淡，
	# 立在末层背景之后、底衬远端之前（基线落在地面内，不露"3D 天空直连地面"的缝）。
	var far_z: float = float(_bg_base_z.get(2, SKYLINE_Z - BG_LAYER_GAP * 2.0))
	var layers := [
		{"tex": "bg_mountain_far.png", "dz": 2.0, "h": 8.0, "tint": Color(0.74, 0.79, 0.88)},
		{"tex": "bg_trees_far.png", "dz": 5.0, "h": 5.5, "tint": Color(0.64, 0.70, 0.64)},
	]
	for L in layers:
		var tex := _tex_abs(_root + "assets/sky/" + str(L["tex"]))
		if tex == null:
			print("[hd2d] 缺天空贴图，跳过: " + str(L["tex"]))
			continue
		var h: float = float(L["h"])
		var aspect: float = tex.get_width() / float(tex.get_height())
		# 沿街长平铺（相机横移后单张会露边）；层间错半张防接缝对齐
		var span: float = h * aspect
		var sx := -106.0 - float(L["dz"])
		while sx < 106.0:
			var pm := QuadMesh.new()
			pm.size = Vector2(span, h)
			var mi := MeshInstance3D.new()
			mi.mesh = pm
			var gm := StandardMaterial3D.new()
			gm.albedo_texture = tex
			gm.albedo_color = L["tint"]
			gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mi.material_override = gm
			mi.basis = _cam_basis()
			mi.position = Vector3(sx + span * 0.5,
				h * 0.5 * cos(deg_to_rad(TILT_DEG)) + 0.3, far_z - float(L["dz"]))
			mi.name = "SkyBackdrop_" + str(L["tex"]).get_basename()
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_ground_root.add_child(mi)
			sx += span


## 贴地 decal：单张 PNG 平铺一个 PlaneMesh（贴图原比例由调用者给世界尺寸）。
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
	var t := _tex_abs(_temp + GROUND_DIR + "src/" + tex_base + "_alb.png")
	if t == null:
		t = _tex_abs(_temp + GROUND_DIR + tex_base + "_128.png")
	var nt := _tex_abs(_temp + GROUND_DIR + "src/" + tex_base + "_nrm.png")
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
	var t := _tex_abs(_temp + GROUND_DIR + "src/" + base + "_alb.png")
	if t == null:
		t = _tex_abs(_temp + GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
	# 法线（深度）：src/<key>_nrm.png
	var nt := _tex_abs(_temp + GROUND_DIR + "src/" + base + "_nrm.png")
	if nt == null:
		nt = _tex_abs(_temp + GROUND_DIR + "src/" + base + "_nrm_512.png")
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
	var t := _tex_abs(_temp + GROUND_DIR + "src/" + base + "_alb.png")
	if t == null:
		t = _tex_abs(_temp + GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
	# 法线（深度）：src/<key>_nrm.png
	var nt := _tex_abs(_temp + GROUND_DIR + "src/" + base + "_nrm.png")
	if nt == null:
		nt = _tex_abs(_temp + GROUND_DIR + "src/" + base + "_nrm_512.png")
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
	# far 48 + 过渡 20：临街卡(41~45.5) 完全在 48 以内 → 100% 锐利；远景 66 →
	# (66-48)/20 = 90% 满档模糊 —— 轮廓仍读得出、细节糊掉。
	_cam_attrs.dof_blur_near_enabled = false
	_cam_attrs.dof_blur_far_enabled = hd and not bool(_opts["flat"])
	_cam_attrs.dof_blur_near_distance = 24.0
	_cam_attrs.dof_blur_near_transition = 10.0
	_cam_attrs.dof_blur_far_distance = 48.0
	_cam_attrs.dof_blur_far_transition = 20.0
	# amount 0.20：远景剪影层（深度 66）达到"轮廓读得出、细节糊掉"的观感。
	# 0.08 那种量级在这种"已带细节的卡"上几乎看不出模糊。
	_cam_attrs.dof_blur_amount = 0.20


# ------------------------------------------------------------------ 出图

func _settle(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(name: String) -> String:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_temp + "proto_hd2d")
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
				# 沿街四机位横移（set_cam_x），各出一张白天最终观感图
				_apply_light("day")
				_apply_stage("c")
				for cam_x: float in [-40.0, -12.0, 20.0, 50.0]:
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
