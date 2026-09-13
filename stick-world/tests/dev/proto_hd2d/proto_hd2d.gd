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
const GROUND_DIR := "ground_tiles/"

const CAM_W := 74.0                      # 正交视宽（格）-> 1920 宽下 25.9 px/格
const CAM_CY := 11.0                     # 相机视线轴的世界高度
const CAM_DIST := 40.0

## 街排：**只有临街一排**（创始人两次质疑"为什么好多层建筑"）。
## 背后只留一层极远的城墙/塔楼剪影（雾里）撑天际线，不算"第二排建筑"。
const FRONT_ROW: Array = [
	{"card": "cottage_w6", "x": -24.0},
	{"card": "house_w8", "x": -11.0},
	{"card": "smithy1_w8", "x": 2.5},
	{"card": "shop_w8", "x": 16.0},
	{"card": "stable_w12", "x": 32.0},
]
## 远处剪影层：**允许且要求**（创始人：加深景模糊的背景建筑层）。
## 低饱和、略偏冷、不投真阴影、不参与夜景窗火自发光 → 只靠"轮廓"说话，
## 再由 DOF 的远焦模糊把细节糊掉（模糊量取"轮廓仍读得出、细节糊掉"）。
const SKYLINE_ROW: Array = [
	{"card": "tower_w6", "x": -42.0},
	{"card": "townhouse_w12", "x": -30.0},
	{"card": "house_w8", "x": -19.5},
	{"card": "tower_w6", "x": -9.5},
	{"card": "shop_w8", "x": 3.0},
	{"card": "tower_w6", "x": 16.5},
	{"card": "smithy1_w8", "x": 28.5},
	{"card": "tower_w6", "x": 40.0},
]
const SKYLINE_Z := -9.5                  # 26° 俯角下基线正好落在 1/3 线（60.98%）——按投影公式解得

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
var _tex_cache: Dictionary = {}

var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _ground_root: Node3D
var _card_root: Node3D
var _front_occ: Array = []
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
		# ② 用一份独立材质做距离染色（偏冷偏亮）且**不注册进 _card_mats**（不参与夜景
		# 窗火自发光），让它彻底退到背景层。
		m = m.duplicate()
		# 低饱和 + 偏冷：把卡的颜色往灰蓝压，读作"远处的同一座城"
		m.set_shader_parameter("tint", Color(0.80, 0.84, 0.93))
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

	# --- 地面：底衬 + 三条分带（路肩 / 路缘 / 道路）---
	_ground_root = Node3D.new()
	_ground_root.name = "Ground"
	add_child(_ground_root)
	# 地表中远景用**低对比**贴图（rammed_earth std=0.034），别用 cobble（std=0.107）：
	# 20° 掠射下 128px 贴图被压 3 倍以上，用高对比纹理时 mip 会在中景糊出一片
	# "碎石噪声"，读作脏。路面同理，tile 放大到 10 减少 minification。
	# 真实地平线 = 末层背景根部：地面远端正好收到末层底边（不再往后多出裸地）
	var far_z: float = SKYLINE_Z - 6.0
	_add_ground_plane("rammed_earth_128.png", far_z, 0.0,
		0.0, 14.0, Color(1.16, 1.14, 1.10))
	_add_platform()                       # 人行道台面（垫高 + PBR 法线）+ 台肩一排长条石
	_add_width_guides()                   # 建筑宽度辅助线（每栋左右边界在地面上画线）
	_add_ground_plane("band_road_stone_128.png", BAND_ROAD.x, BAND_ROAD.y,
		0.02, 10.0, Color(0.86, 0.89, 0.96))    # 道路：偏冷深石（与台面拉开）

	# --- 建筑卡：临街一排 + 远处城墙剪影 ---
	_card_root = Node3D.new()
	_card_root.name = "Cards"
	add_child(_card_root)
	_shadow_root = Node3D.new()
	_shadow_root.name = "BuildingShadows"
	add_child(_shadow_root)
	_place_rows()   # 前排吸附整格 + 三层背景按缝隙算法后层插前层

	# --- 灯笼点光源（暖光；让"真 3D 光照"这条线可验证）---
	_lamp_root = Node3D.new()
	_lamp_root.name = "Lamps"
	add_child(_lamp_root)
	for i in 9:
		var l := OmniLight3D.new()
		l.position = Vector3(-32.0 + float(i) * 8.5, 2.5, 4.2)
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


func _gaps(occ: Array) -> Array:
	# 已占用区间 [x0,x1] 的补集（在 [-40, 40] 内）——用于"后层插前层缝"
	var s := occ.duplicate()
	s.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out := []
	var cur := -40.0
	for iv in s:
		if float(iv[0]) > cur + 0.5:
			out.append([cur, float(iv[0])])
		cur = maxf(cur, float(iv[1]))
	if cur < 39.5:
		out.append([cur, 40.0])
	return out


func _place_rows() -> void:
	# 前排：吸附整格、**一格挨一格铺满整条可见街**（左右超出画框，不留空当）
	var occ_front := []
	var cur := -40.0
	var names := ["cottage_w6", "house_w8", "shop_w8", "bakery_w8", "townhouse_w12",
		"guildhall_w12", "smithy1_w8", "tavern_w12", "stable_w12"]
	var ni := 0
	while cur < 40.0:
		var card: String = names[ni % names.size()]
		ni += 1
		var w := _cw(card)
		if w < 1.0:
			w = 8.0
		var cx := cur + w * 0.5
		var mi := _spawn_card(card, cx, 0.85)
		mi.position.y += PLAT_H
		_spawn_building_shadow(card, cx, mi)
		occ_front.append([cur, cur + w])
		cur += w          # 一个格子挨着一个格子（0 缝）
	_front_occ = occ_front
	# 三层背景：**逐层把前层的缝隙塞满**（每段缝连续铺卡直到盖满），末层即"真实地平线"
	# 近小远大：近层小民居/塔；**远层也限宽 ≤12 格**（w16 大件悬在半空会读作悬浮板）
	var lists := [
		["house_w8", "tower_w6", "house_w8", "townhouse_w12"],
		["townhouse_w12", "house_w8", "tower_w6", "house_w8"],
		["house_w8", "tower_w6", "townhouse_w12", "house_w8"],
	]
	var layer := occ_front
	for li in lists.size():
		var lz: float = SKYLINE_Z - 3.0 * float(li)
		var list: Array = lists[li]
		var occ := []
		var ci2: int = li * 5
		for g in _gaps(layer):
			var g0: float = float(g[0])
			var g1: float = float(g[1])
			if g1 - g0 < 0.5:
				continue
			while g1 - g0 > 0.5:
				var card: String = str(list[ci2 % list.size()])
				ci2 += 1
				var w2: float = minf(_cw(card), g1 - g0)
				if w2 < 1.5:
					break
				var cx2: float = g0 + w2 * 0.5
				_spawn_card(card, cx2, lz, true)
				occ.append([g0, g0 + w2])
				g0 += w2
		layer = occ


func _add_width_guides() -> void:
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

	var x := -37.0
	while x <= 37.0:
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


func _add_platform() -> void:
	# 人行道台面：整面垫高（PLAT_H）+ PBR（albedo + 法线，石块凸起见深度）
	# 台肩 = 台面外缘**一排长条石**（现代人行道路缘那种），逐块长度抖动
	# 台面：从**地平线**（远处 z=-60 与拉远底衬同远端）一直铺到台肩（z=1.95）
	_add_ground_plane("band_shoulder_stone_128.png", -6.5, BAND_SIDEWALK.y,
		PLAT_H, 5.0, Color(1.04, 1.00, 0.93))   # 台面：偏暖亮的浅石（与道路明显区分）
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260917
	var t := _tex_abs(_temp + GROUND_DIR + "src/band_kerb_stone_alb.png")
	if t == null:
		t = _tex_abs(_temp + GROUND_DIR + "band_kerb_stone_128.png")
	var nt := _tex_abs(_temp + GROUND_DIR + "src/band_kerb_stone_nrm.png")
	var x := -40.0
	while x < 40.0:
		var w: float = minf(rng.randf_range(1.7, 2.6), 40.0 - x)
		var bm := BoxMesh.new()
		bm.size = Vector3(w * 0.96, PLAT_H, PLAT_H)   # 方形截面：高 = 深 = 台面高
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		# 顶面**压低一丝**（-0.01）避免与台面共面 z-fighting；沿台面前沿镶边
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
	# 深度坐标（相机视图空间，实测本机位）：角色 29~35 | 临街建筑卡 41~45.5 |
	# 中景地面 44~62 | 远景剪影层(z=-24) ≈ 66。
	# far 48 + 过渡 20：临街卡(41~45.5) 完全在 48 以内 → 100% 锐利；远景 66 →
	# (66-48)/20 = 90% 满档模糊 —— 轮廓仍读得出、细节糊掉。
	_cam_attrs.dof_blur_near_enabled = false
	_cam_attrs.dof_blur_far_enabled = hd
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
