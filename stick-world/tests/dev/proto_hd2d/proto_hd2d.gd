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
const TILT_DEG := 20.0                   # 俯角（§0.3 硬约束）
const CARD_SHADER := preload("res://tests/dev/proto_hd2d/card.gdshader")
const CHAR_HOST := preload("res://tests/dev/proto_hd2d/char_sprite_3d.gd")
const POST_SHADER := preload("res://tests/dev/proto_hd2d/post_hd2d.gdshader")
const BACKDROP_SHADER := preload("res://tests/dev/proto_hd2d/backdrop.gdshader")

const CARDS_JSON := "proto25d/cards.json"
const CARD_DIR := "proto25d/cards/"
const PROPS_JSON := "proto_hd2d/props.json"
const PROP_DIR := "proto_hd2d/props/"
const GROUND_DIR := "ground_tiles/"

const CAM_W := 100.0                     # 正交视宽（格）-> 1920 宽下 19.2 px/格，垂直可见 56 格
const CAM_CY := 11.0                     # 相机视线轴的世界高度
const CAM_DIST := 40.0

## ── 场景垂直分层（严格按文档口径，别乱改）────────────────────────────
## `场景宿主架构.md` §2.4.3：ground_ratio 0.33~0.4 —— **地面带只占屏幕下方约 1/3**，
## 其余是天空 + 建筑本体区。本原型相机 CAM_CY=11 时，世界 z 的屏幕落点是
##   screen_pct(z) = 74.86 + 0.822 * z   （y=0 的地面点）
## 据此反解三条基准线：
##   地平线（地面带顶线）  z=-17  -> 60.9%   → 地面带 = 39.1% ≈ ground_ratio 0.39 ✓
##   建筑基线（地平线+96px）z=-6.2 -> 69.8%   → 96px = 8.9% ✓（建筑与定居点 §4.3）
##   道路             z=-6.2 .. +46 -> 69.8% ~ 画外（占屏 30%）
const HORIZON_Z := -10.5
const MAIN_BASE_Z := 4.2
const ROAD_NEAR_Z := 72.0
## 角色在道路上活动（比建筑基线更靠近相机）
const WALK_Z := Vector2(14.0, 26.0)

## 临街**一排**（混排 1/2/3 层 + 茅草/陶瓦/石板/木板屋顶）。
## `gap` = 该栋左邻的净距（格）：以 0~1 格连续为主，偶有 1.8~4.2 格空当放道具。
const STREET: Array = [
	{"card": "cottage_w6", "gap": 0.0},
	{"card": "shop_w8", "gap": 1.4},
	{"card": "bakery_w8", "gap": 2.2},
	{"card": "townhouse_w12", "gap": 5.0},  # 大空当：市集摊
	{"card": "cottage_w6", "gap": 1.2},
	{"card": "house_w8", "gap": 3.0},       # 空当：木桶/麻袋
	{"card": "smithy1_w8", "gap": 0.0},     # 偶有相邻
	{"card": "tavern_w12", "gap": 4.2},     # 空当：推车/酒桶
	{"card": "house_w8", "gap": 1.6},
	{"card": "cottage_w6", "gap": 2.4},
]
## 后景 **三层稀疏封底**（各层零散几栋、不密集排），三层叠加把地平线盖死；
## 模糊**逐层递增**（bg1 轻 → bg2 中 → 城墙/塔楼 重），再往后是远山树线剪影。
const BG1_ROW: Array = [
	{"card": "house_w8", "x": -30.0},
	{"card": "townhouse_w12", "x": -6.0},
	{"card": "tavern_w12", "x": 22.0},
	{"card": "rowhouse_w12", "x": 42.0},
]
const BG2_ROW: Array = [
	{"card": "cathedral_w16", "x": -18.0},
	{"card": "guildhall_w12", "x": 8.0},
	{"card": "tower_w6", "x": 34.0},
]
const BG_Z := -11.5
const BG2_Z := -20.0
const BG1_BLUR := 1.6
const BG2_BLUR := 4.0
## 第三层：城墙段 + 塔楼（稀疏，重糊）
const WALL_ROW: Array = [
	{"card": "tower_w6", "x": -44.0},
	{"card": "tower_w6", "x": -14.0},
	{"card": "cathedral_w16", "x": 12.0},
	{"card": "tower_w6", "x": 38.0},
]
const WALL_Z := -30.0

const TREELINE_Z := -60.0
const CLOUD_Z := -80.0

## 地面分带（格）。路肩不再是一条通铺带 —— 见 `_add_aprons()`：
## 只在**有建筑的面宽**内贴基座画一块有机边缘的石板场，空地一律草皮/杂土。
const APRON_DEPTH := 1.5
const BAND_ROAD := Vector2(MAIN_BASE_Z, ROAD_NEAR_Z)

## 道具（Blender 从 props.py 库烘的卡，见 bake_props.py）：填主排空当
const PROPS: Array = [
	{"card": "market_stall", "x": -21.3, "z": 0.8},
	{"card": "market_table", "x": -19.0, "z": 2.6},
	{"card": "barrel", "x": -0.4, "z": 0.5},
	{"card": "sack_stack", "x": -0.4, "z": 1.4},
	{"card": "crate", "x": 18.2, "z": 0.6},
	{"card": "cart", "x": 18.2, "z": 2.6},
	{"card": "well", "x": -28.6, "z": 1.1},
	{"card": "signboard", "x": 10.0, "z": 1.7},
	{"card": "barrel_stand", "x": 31.0, "z": 0.9},
	{"card": "basket", "x": -6.2, "z": 0.7},
	{"card": "lantern", "x": -2.2, "z": 1.1},
	{"card": "bench", "x": -33.5, "z": 1.5},
	{"card": "pot", "x": 36.6, "z": 1.1},
	{"card": "grindstone", "x": 14.6, "z": 1.0},
	{"card": "log_pile", "x": 40.0, "z": 1.3},
]
## 角色站位（3 个，全部正对相机）：都在道路上，z 越大越靠近相机
const CHARS: Array = [
	{"x": -27.0, "z": 23.0, "flip": true},
	{"x": -9.0, "z": 18.0, "flip": false},
	{"x": 14.0, "z": 13.5, "flip": true},
]
## 遮挡验证：两个角色、同 x、只差 z。判读方式：
##   x=-11 的那个正对 house_w8 的墙心（会被房子挡住）；
##   x=-30.5 的那个在街排空隙（左边没房子，任何 z 都该看得见）—— 它是**对照组**，
##   证明"z=-3 这一层的角色确实被渲染了"，从而把 x=-11 那个的消失归因于遮挡
##   而不是"没画出来"。
## OCC_X := 被墙挡的那个的 x；OCC_CTRL_X := 对照组 x
## 遮挡验证站位：主排建筑基线 MAIN_BASE_Z=-6.2，卡面 z≈-7.7
##   FRONT 取 +6（在道路上、明显更近）；BEHIND 取 -13（退到卡面之后、仍在地面带内）
const OCC_X := -4.15
const OCC_CTRL_X := -35.0
const OCC_FRONT_Z := 12.0
const OCC_BEHIND_Z := -5.0

var _root := ""
var _temp := ""
var _cards: Dictionary = {}
var _props: Dictionary = {}
var _tex_cache: Dictionary = {}

var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _ground_root: Node3D
var _card_root: Node3D
var _apron_root: Node3D
var _prop_root: Node3D
var _backdrop_root: Node3D
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

var _opts := {
	"shots": "all", "perf": false, "res": "", "sv": "always",
	"char": "blend", "tag": "", "svscale": "2",
}

# 帧采样
var _measuring := false
var _samples: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	_root = ProjectSettings.globalize_path("res://")
	_temp = _root + "temp/"
	_parse_args()
	print("[hd2d] 工程根=", _root)
	print("[hd2d] 跑法: godot --path stick-world res://tests/dev/proto_hd2d/proto_hd2d.tscn -- --shots=all")
	_load_cards()
	_build_world()
	if bool(_opts["perf"]):
		await _run_perf()
	else:
		await _run_shots(str(_opts["shots"]))
	print("[hd2d] DONE")
	await _settle(1.0)
	get_tree().quit(0)


# ------------------------------------------------------------------ 参数

func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
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


# ------------------------------------------------------------------ 资源

func _load_cards() -> void:
	var p := _temp + CARDS_JSON
	if not FileAccess.file_exists(p):
		push_error("[hd2d] 缺 cards.json，先跑 proto_25d 的 Blender 半场: " + p)
		return
	var f := FileAccess.open(p, FileAccess.READ)
	var arr: Variant = JSON.parse_string(f.get_as_text())
	if arr is Array:
		for c in arr:
			_cards[str(c["card"])] = c
	print("[hd2d] 烘焙卡 %d 张" % _cards.size())
	var pp := _temp + PROPS_JSON
	if FileAccess.file_exists(pp):
		var pf := FileAccess.open(pp, FileAccess.READ)
		var parr: Variant = JSON.parse_string(pf.get_as_text())
		if parr is Array:
			for c in parr:
				_props[str(c["card"])] = c
		print("[hd2d] 道具卡 %d 张" % _props.size())
	else:
		push_warning("[hd2d] 缺 props.json（先跑 bake_props.py）：" + pp)


func _tex_abs(p: String) -> Texture2D:
	if _tex_cache.has(p):
		return _tex_cache[p]
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
## 屏幕落点（%）公式：CAM_CY=11 / CAM_W=100 时的实测反解
##   pct(y, z) = 68.36 - 1.6706 * y + 0.6080 * z
## 用于把"基座落在哪个屏幕高度"翻译成 quad 的世界 y（背景封底层靠它保证
## 地平线被完全盖住，是**可验证的数值**而不是靠调参碰）。
static func _pct(y: float, z: float) -> float:
	return 68.36 - 1.6706 * y + 0.6080 * z


static func _y_for_pct(pct: float, z: float) -> float:
	return (68.36 + 0.6080 * z - pct) / 1.6706


func _card_cells(card: String) -> float:
	var m: Dictionary = _cards.get(card, {})
	return float(m.get("cells", 8))


func _spawn_card(card: String, x: float, z_off: float, mode: String = "main") -> MeshInstance3D:
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
	if mode != "main":
		# 背景层：① 不投真阴影（卡片按 alpha 剪影向地面投真影，会给背景排拖出斜影脏斑）；
		# ② 独立材质做距离染色，且**不注册进 _card_mats**（不参与夜景窗火自发光）；
		# ③ 越远越淡越冷 → 与 DOF 的远焦模糊共同构成"中景/远山"两层。
		m = m.duplicate()
		var blur_map: Dictionary = {"bg1": BG1_BLUR, "bg2": BG2_BLUR, "skyline": 9.0}
		m.set_shader_parameter("blur_radius", float(blur_map.get(mode, 0.0)))
		m.set_shader_parameter("tint",
			Color(0.82, 0.86, 0.94) if mode == "bg1"
			else (Color(0.78, 0.83, 0.93) if mode == "bg2" else Color(0.74, 0.79, 0.91)))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_card_mats.erase(m)
	mi.material_override = m
	mi.name = "Card_" + card
	_card_root.add_child(mi)
	return mi


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
	m.set_shader_parameter("blur_radius", 0.0)
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

	# --- 地面：只铺"地面带"（地平线以下）---
	# 结构（自上而下 = 自远而近）：
	#   z ∈ [HORIZON_Z, MAIN_BASE_Z]  = 建筑带/路肩带（草皮/杂土；建筑处叠加石板场）
	#   z ∈ [MAIN_BASE_Z, ROAD_NEAR_Z]= 道路（角色活动面）
	_ground_root = Node3D.new()
	_ground_root.name = "Ground"
	add_child(_ground_root)
	# 地面带 = **一整片可行走区**（屏幕下方约 1/3，土/草/路面连续铺）。
	# 没有建筑的地方全是可走地面；建筑只靠自带"落地裙边"挤占其中一块。
	# 按区混材质（补充规格 2）：街心 → 近侧 → 外缘，各换一档，读作一条有肌理的街。
	_walkable_ground(HORIZON_Z, ROAD_NEAR_Z)

	# --- 建筑：临街一排（按累计 gap 排布，街道越过画框两侧）+ 路肩石板场 ---
	_card_root = Node3D.new()
	_card_root.name = "Cards"
	add_child(_card_root)
	_apron_root = Node3D.new()
	_apron_root.name = "Aprons"
	add_child(_apron_root)
	_prop_root = Node3D.new()
	_prop_root.name = "Props"
	add_child(_prop_root)
	_backdrop_root = Node3D.new()
	_backdrop_root.name = "Backdrops"
	add_child(_backdrop_root)

	var total := 0.0
	for e in STREET:
		total += _card_cells(str(e["card"])) + float(e["gap"])
	var cursor := -total * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260914
	var idx := 0
	for e in STREET:
		cursor += float(e["gap"])
		var cells := _card_cells(str(e["card"]))
		var cx := cursor + cells * 0.5
		# **站位抖动**（补充规格 1）：约 1/3 回退 0.5~1.5 格、约 15% 凸前半格~1 格，
		# 其余贴线 —— 禁止一排完美直线。
		var r := rng.randf()
		var dz := 0.0
		if r < 0.33:
			dz = rng.randf_range(0.5, 1.5)
		elif r < 0.48:
			dz = -rng.randf_range(0.5, 1.0)
		_spawn_card(str(e["card"]), cx, MAIN_BASE_Z + dz)
		_add_apron(cx, cells, dz)
		if dz > 0.2:
			# 回退出来的那条短踩踏径：从建筑门前接到路肩外缘
			_add_door_path(cx, MAIN_BASE_Z + dz + APRON_DEPTH * 0.4,
				MAIN_BASE_Z + APRON_DEPTH + 1.6)
		cursor += cells
		idx += 1

	# --- 主排空当里的道具（道具卡由 bake_props.py 从 props.py 库烘出）---
	for e in PROPS:
		_spawn_prop(str(e["card"]), float(e["x"]), MAIN_BASE_Z + float(e["z"]))

	# --- 背景排：紧贴主排后方（9.7 格），低饱和偏冷，基座落在地平线上 ---
	for e in BG1_ROW:
		_spawn_card(str(e["card"]), float(e["x"]), BG_Z, "bg1")
	for e in BG2_ROW:
		_spawn_card(str(e["card"]), float(e["x"]), BG2_Z, "bg2")
	# --- 城墙段 + 塔楼：再退一层，基座在地平线之上（被前排/树线遮住）---
	for e in WALL_ROW:
		_spawn_card(str(e["card"]), float(e["x"]), WALL_Z, "skyline")
	# --- 树线/远山剪影（不透明，遮住地平线以上的多余地面）+ 云带 ---
	# 树线/远山：基座压在地平线**下方 1.5%**（重叠一点防缝），不透明剪影向上盖住
	# 地平线以上的全部区域 → "地面延伸到无穷远 + 地平线"这件事在画面里不存在。
	_add_backdrop("treeline", TREELINE_Z, _pct(0.0, HORIZON_Z) + 1.5, 20.0, 500.0,
		_treeline_tex(), Color(0.98, 1.0, 1.02), 1.0, 12.0)
	# 云带：贴在天空区（6%~34%），软 alpha
	var c_top := 6.0
	var c_bot := 34.0
	var cy := _y_for_pct(c_bot, CLOUD_Z)
	var ct := _y_for_pct(c_top, CLOUD_Z)
	_add_backdrop("cloud", CLOUD_Z, c_bot, ct - cy, 500.0,
		_cloud_tex(), Color(1.0, 1.0, 1.0), 0.9, 6.0)

	# --- 灯笼点光源（暖光；让"真 3D 光照"这条线可验证）---
	_lamp_root = Node3D.new()
	_lamp_root.name = "Lamps"
	add_child(_lamp_root)
	for i in 9:
		var l := OmniLight3D.new()
		l.position = Vector3(-34.0 + float(i) * 8.5, 2.6, MAIN_BASE_Z - 2.6)
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

	# --- 2D 角色宿主（SubViewport -> billboard）---
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

	# 应用 SubViewport 更新模式选项
	match str(_opts["sv"]):
		"once":
			_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		"disabled":
			_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_:
			_char_host.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


## 建/重建 2D 角色宿主（SubViewport -> billboard）。px_scale > 1 = SubViewport
## 以更高分辨率渲染同一个 2D 角色（世界占位不变），用于隔离它的渲染开销。
func _spawn_char_host(px_scale: float = 1.0) -> void:
	if _char_host != null:
		_char_host.queue_free()
	_char_host = CHAR_HOST.new()
	_char_host.name = "CharHost"
	add_child(_char_host)
	_char_host.set_px_scale(px_scale)
	_char_host.build(self, "walk")
	for e in CHARS:
		_char_host.add_char(float(e["x"]), float(e["z"]), bool(e["flip"]))
	_char_host.mark_regular()


## 建筑接地影：贴在路肩带**之上**（y=0.07，高过所有分带面）的程序化软影。
## 为什么必须补：卡片里烘的接触阴影在卡的深度面上（z≈-1.5），而路肩面（z∈[0,4]）
## 比它更靠近相机 → 深度测试判路肩赢，烘的接触阴影会被路肩**整片盖掉**，
## 建筑就"浮"在路肩上、基线读不准。补一张贴地的程序化软影，把建筑钉在路肩上。
## 路肩石板场：**只画在有建筑的面宽内**（纠偏 3）。
## 一栋 = 3~4 块抖过边的小石板拼一条，外缘参差（有机边缘），空地不画 ——
## 空地露出下面的草皮/杂土。**材质分区**（补充规格 2）：街心用石板、往两侧换砖铺、
## 再往外换夯土碎石，同一条街至少两种路肩材质。
func _apron_tex(cx: float) -> String:
	var ax := absf(cx)
	if ax < 16.0:
		return "flagstone_128.png" if ax < 7.0 else "band_shoulder_stone_128.png"
	if ax < 30.0:
		return "brick_pave_128.png"
	return "band_shoulder_earth_128.png"


func _add_apron(cx: float, cells: float, z_off: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cx * 97.0) + 517
	var tex := _apron_tex(cx)
	var n := 3 + int(cells / 4.0)
	var w := cells / float(n)
	var z0b := MAIN_BASE_Z + z_off
	for i in n:
		var z0 := z0b + rng.randf_range(-0.10, 0.14)
		var z1 := z0 + APRON_DEPTH + rng.randf_range(-0.30, 0.45)
		var half := cells * 0.5
		var x0 := cx - half + float(i) * w
		_add_ground_plane_at(tex, x0 + w * 0.5, w * 1.0, z0, z1, 0.035, 3.6,
			Color(0.72 + rng.randf_range(-0.08, 0.08),
				0.71 + rng.randf_range(-0.08, 0.08),
				0.68 + rng.randf_range(-0.08, 0.08)))


## 踩踏径：回退建筑（z_off>0）门前补一条 4~10px 的小短路接到路肩/道路。
## 这是"禁止一排完美直线"的关键细节 —— 没有它，回退的建筑会读作"浮在半空"。
func _add_door_path(cx: float, z_from: float, z_to: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cx * 31.0) + 7
	var n := 4
	for i in n:
		var z0 := lerpf(z_from, z_to, float(i) / float(n))
		var z1 := lerpf(z_from, z_to, float(i + 1) / float(n)) + 0.12
		_add_ground_plane_at("dirt_rut_128.png", cx + rng.randf_range(-0.5, 0.5),
			rng.randf_range(1.2, 2.3), z0, z1, 0.055, 2.0,
			Color(0.86, 0.82, 0.74))


## 道具卡：与建筑卡同一套 anchor 落位（基座落世界 y=0 的 z_off 平面）
func _spawn_prop(card: String, x: float, z_off: float) -> MeshInstance3D:
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
	mi.position = Vector3(x, float(anc[2]) * S, -float(anc[1]) * S + z_off)
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
	return mi


## 背景封底层（补充规格 3）：用 `base_pct` 直接指定基座屏幕高度，靠 `_y_for_pct`
## 反解世界 y —— "地平线被完全盖住"因此是**可验证的数值**而不是靠调参碰。
func _add_backdrop(kind: String, z: float, base_pct: float, height: float,
		width: float, tex: Texture2D, tint: Color, alpha_mul: float,
		blur: float = 0.0) -> void:
	var y_base := _y_for_pct(base_pct, z)
	var q := QuadMesh.new()
	q.size = Vector2(width, height)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.position = Vector3(0.0, y_base + height * 0.5, z)
	mi.basis = _cam_basis()
	var m := ShaderMaterial.new()
	m.shader = BACKDROP_SHADER
	m.set_shader_parameter("bd_tex", tex)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("alpha_mul", alpha_mul)
	m.set_shader_parameter("top_fade", 0.0)
	m.set_shader_parameter("blur_radius", blur)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Backdrop_" + kind
	_backdrop_root.add_child(mi)


## 程序化树线/远山：低频山形 + 高频树冠锯齿，剪影顶向上渐淡（空气透视）。
## 为什么程序化：素材库没有树线资产；这层唯一职责是"在正确高度遮住地平线以上、
## 并接上天空"，用几何形状表达即可，不需要贴图质量。
func _treeline_tex() -> Texture2D:
	var w := 1024
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for x in w:
		var u := float(x) / float(w)
		var hill := 0.34 + 0.10 * sin(u * 6.1 + 0.7) + 0.06 * sin(u * 13.7 + 2.1) \
			+ 0.04 * sin(u * 27.3 + 4.4)
		var trees := 0.035 * absf(sin(u * 151.0 + 1.3)) + 0.02 * absf(sin(u * 83.0))
		var y0 := int(clampf(hill + trees, 0.0, 1.0) * float(h))
		for y in range(y0, h):
			var t := float(y - y0) / maxf(1.0, float(h - y0))
			var haze := pow(1.0 - t, 0.7)
			var c := Color(0.32, 0.38, 0.35).lerp(Color(0.60, 0.66, 0.72), haze)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0 if y > y0 + 2 else 0.45))
	# 底线以下整片不透明（保证地平线被彻底盖住，不留"地面无限延伸"的缝）
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## 程序化云带：几个软高斯团 + 细噪声
func _cloud_tex() -> Texture2D:
	var w := 1024
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var blobs := [
		Vector3(0.14, 0.62, 0.20), Vector3(0.28, 0.44, 0.14),
		Vector3(0.44, 0.70, 0.24), Vector3(0.58, 0.40, 0.13),
		Vector3(0.72, 0.62, 0.19), Vector3(0.88, 0.48, 0.15),
		Vector3(0.36, 0.30, 0.10), Vector3(0.66, 0.78, 0.12),
	]
	for y in h:
		for x in w:
			var u := float(x) / float(w)
			var v := float(y) / float(h)
			var a := 0.0
			for b in blobs:
				var bb: Vector3 = b
				var dx: float = (u - bb.x) * 2.6
				var dy: float = v - bb.y
				a += bb.z * exp(-(dx * dx + dy * dy) * 9.0)
			a *= 0.75 + 0.25 * sin(u * 61.0 + v * 23.0)
			a = clampf(a, 0.0, 1.0) * 0.55
			if a > 0.004:
				img.set_pixel(x, y, Color(0.99, 0.99, 1.0, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)



func _make_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 6)
	_post_layer.add_child(l)
	return l


## **整片可行走地面**（不是"路肩带 + 道路带"两截）：z 从地平线一直到画面外，
## 在 x 上按 街心/近侧/外缘 换材质，读作一条有肌理的街；建筑靠自带裙边挤占。
func _walkable_ground(z0: float, z1: float) -> void:
	var zones := [
		{"x0": -340.0, "x1": -48.0, "tex": "grass_sparse_128.png", "tint": Color(0.98, 1.0, 0.92)},
		{"x0": -48.0, "x1": -26.0, "tex": "dirt_rut_128.png", "tint": Color(1.0, 0.99, 0.96)},
		{"x0": -26.0, "x1": 26.0, "tex": "band_road_stone_128.png", "tint": Color(1.0, 1.0, 1.02)},
		{"x0": 26.0, "x1": 48.0, "tex": "dirt_rut_128.png", "tint": Color(1.0, 0.99, 0.96)},
		{"x0": 48.0, "x1": 340.0, "tex": "grass_sparse_128.png", "tint": Color(0.98, 1.0, 0.92)},
	]
	# 边界"啃"一下：在两条 土↔石 分界上零散贴几小块对侧材质，打断直线
	var rng := RandomNumberGenerator.new()
	rng.seed = 881
	for bx in [-26.0, 26.0]:
		for i in 9:
			var side: float = 1.0 if bx > 0.0 else -1.0
			var cx2: float = bx + side * rng.randf_range(-3.5, 3.5)
			var zd: float = rng.randf_range(-6.0, 40.0)
			_add_ground_plane_at("band_road_stone_128.png" if bx > 0.0 else "dirt_rut_128.png",
				cx2, rng.randf_range(1.5, 4.5), zd, zd + rng.randf_range(1.2, 3.4),
				0.03, 4.0, Color(0.98, 0.98, 1.0))
	for z in zones:
		var zz: Dictionary = z
		_add_ground_plane_at(str(zz["tex"]), (float(zz["x0"]) + float(zz["x1"])) * 0.5,
			float(zz["x1"]) - float(zz["x0"]), z0, z1, 0.02, 9.0, zz["tint"])


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
	var t := _tex_abs(_temp + GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
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
	var t := _tex_abs(_temp + GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
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
	_char_host.set_chars_visible(stage != "a")
	_post_rect.visible = stage == "c" or stage == "d" or stage == "e"
	_update_px_size()
	var hd := stage == "c" or stage == "d" or stage == "e"
	_env.glow_enabled = hd
	# 景深（CameraAttributesPractical；Godot 4 的 DOF 挂在相机属性上，不在 Environment）
	# **业界口径**：八方旅人初代的强移轴被广泛批评（"让玩家想关掉"），三角战略已把它
	# 改成可关设置。故本档口径 = 近焦**关**、主场景（临街一排 + 火柴人）**零模糊**，
	# 只让远背景层吃远焦模糊。
	# 深度坐标（相机视图空间，重新按新站位实算）：
	#   角色(z=7.5~15.5) 30~38 | 临街建筑卡(z≈-7.7) 48~50 | 背景排(z≈-18) 59
	#   | 城墙塔楼(z≈-32) 72 | 树线(z=-60) 95 | 云带(z=-80) 114
	# **Environment 的 DOF 关掉**：它只有"近/远两档"，做不出"第一层轻糊、第二层中糊、
	# 远山重糊"的逐层递增（创始人明确要求非线性/逐层）。改由卡片材质的 blur_radius
	# 逐层给：主排/角色 0（100% 锐利）→ bg1 1.6px → bg2 4.0px → 城墙 9px → 树线 12px。
	_cam_attrs.dof_blur_near_enabled = false
	_cam_attrs.dof_blur_far_enabled = false
	_cam_attrs.dof_blur_near_distance = 24.0
	_cam_attrs.dof_blur_near_transition = 10.0
	_cam_attrs.dof_blur_far_distance = 46.0
	_cam_attrs.dof_blur_far_transition = 24.0
	_cam_attrs.dof_blur_amount = 0.20


# ------------------------------------------------------------------ 出图

func _settle(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(name: String) -> String:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
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
	_hud.text = "FRONT  z=+12（两角色都在街上；x=-4.15 盖住建面）"
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
	_hud.text = "BEHIND  z=-5（对照角色仍在；x=-4.15 被墙吃掉）"
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
