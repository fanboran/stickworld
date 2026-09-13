extends Node3D
## proto_25d.gd —— 2.5D 纸片风可行性原型（引擎侧验证，dev 层，不进 CI）
##
## 回答一个问题：现有 2D 侧视卷轴游戏能否改造成「3D 场景 + 烘焙建筑 sprite +
## 真 3D 光照，相机正交侧视、观感仍是 2D」。
##
## 固定跑法（可反复运行，产物落 stick-world/temp/）::
##
##   "F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
##     --path stick-world res://tests/dev/proto_25d/proto_25d.tscn -- --shots=all
##
##   # 只看性能（200 张建筑卡 + 20 个点光源），出图 proto25d_perf.png
##   ... -- --perf=200,20
##
##   # 只看 glb 低模路线（跳过纸片卡），便于对比
##   ... -- --no-cards
##
## 依赖（先跑一次 Blender 半场生成）::
##   blender -b --factory-startup -P stick-world/tests/dev/proto_25d/blender_proto.py
##   -> stick-world/temp/proto25d/{cards/*.png, cards.json, proto25d_buildings.glb}
##
## 坐标约定：Godot 单位 = 1 格 = 32px（Blender 世界 px / 32）。
##   Blender (x, y, z) -> Godot (x, z, -y) / 32；相机正交、yaw=0°、俯角 20°
##   （对齐交接档 §0.3「纯正面 + 20° 微俯视、禁水平偏航」）。

const S := 1.0 / 32.0                    # Blender 世界 px -> Godot 单位（格）
const TILT_DEG := 20.0                   # 俯角（硬约束）
const CARD_SHADER := preload("res://tests/dev/proto_25d/card.gdshader")

## Blender 侧烘焙卡清单（cards.json）
const CARDS_JSON := "proto25d/cards.json"
const GLB_REL := "proto25d/proto25d_buildings.glb"

## 前排行（纸片卡 / glb 低模交替配对：同一栋建筑两种做法直接对比）
const PAIRS: Array = [
	{"card": "house_w8", "glb": "house_w8"},
	{"card": "smithy1_w8", "glb": "smithy1_w8"},
	{"card": "cottage_w6", "glb": "cottage_w6"},
]
## 后排（更高体量，撑天际线 + 验证层次/雾）
const BACK_CARDS: Array = ["tavern_w12", "townhouse_w12", "cathedral_w16"]

const FRONT_Z := 0.0
const BACK_Z := -26.0
const GAP := 1.6                         # 建筑之间的净距（格）
const CAM_W := 74.0                      # 正交视宽（格）-> 1920 宽下 26 px/格
const CAM_CY := 15.5                     # 相机视线轴的世界高度
const CAM_DIST := 40.0                   # 正交相机离场距离（只影响裁切/雾深度）

## glb 低模的材质名 -> 近似纯色（glb 不带纹理，见 build_report.json 的诚实清单）
const GLB_COLORS := {
	"brick": Color(0.52, 0.27, 0.19), "plaster": Color(0.84, 0.80, 0.70),
	"plaster_old": Color(0.74, 0.71, 0.63), "timber": Color(0.24, 0.16, 0.11),
	"wood": Color(0.40, 0.29, 0.19), "wood_dark": Color(0.26, 0.19, 0.12),
	"wood_light": Color(0.55, 0.42, 0.27), "wood_door": Color(0.32, 0.29, 0.26),
	"wood_roof": Color(0.38, 0.28, 0.19), "stone": Color(0.60, 0.58, 0.54),
	"stone_dark": Color(0.42, 0.41, 0.39), "white_stone": Color(0.78, 0.77, 0.73),
	"slate": Color(0.34, 0.35, 0.38), "tile": Color(0.58, 0.27, 0.19),
	"iron": Color(0.20, 0.20, 0.22), "thatch": Color(0.60, 0.49, 0.23),
	"thatch_old": Color(0.48, 0.40, 0.21), "straw": Color(0.62, 0.50, 0.22),
	"cavity": Color(0.03, 0.03, 0.03), "cloth_red": Color(0.48, 0.14, 0.14),
	# 接地阴影/炉火在 buildings.py 里走的是**纯色回退**材质（materials.py 不接管），
	# 所以 glb 里叫 flat_*；这里给回原值，否则接触阴影会渲染成浅灰。
	"shadow_near": Color(0.20, 0.185, 0.165), "shadow_mid": Color(0.30, 0.28, 0.25),
	"shadow_far": Color(0.44, 0.415, 0.37), "shadow_ao": Color(0.10, 0.10, 0.10),
	"flat_shadow_near": Color(0.20, 0.185, 0.165),
	"flat_shadow_mid": Color(0.30, 0.28, 0.25),
	"flat_shadow_far": Color(0.44, 0.415, 0.37),
	"flat_shadow_ao": Color(0.10, 0.10, 0.10),
	"fire": Color(0.90, 0.35, 0.08), "flat_fire": Color(0.90, 0.35, 0.08),
	"ember": Color(0.85, 0.24, 0.05), "flat_ember": Color(0.85, 0.24, 0.05),
}
const GLB_GLASS := ["glass", "stained_glass", "glass_lead"]

var _root := ""
var _temp := ""
var _cards: Dictionary = {}              # card 名 -> 元数据
var _tex_cache: Dictionary = {}

var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _ground: MeshInstance3D
var _card_root: Node3D
var _model_root: Node3D
var _lamp_root: Node3D
var _extra_root: Node3D
var _cam: Camera3D

var _card_mats: Array[ShaderMaterial] = []   # 运行时统一调 glow_energy
var _glass_mats: Array[StandardMaterial3D] = []
var _lamps: Array[OmniLight3D] = []

# 帧采样
var _measuring := false
var _samples: PackedFloat32Array = PackedFloat32Array()
var _draw_samples: PackedInt32Array = PackedInt32Array()
var _phase := ""
var _phase_rows: Array[String] = []

var _opts := {"shots": "all", "perf": "", "cards": true, "models": true, "tag": ""}
var _t0 := 0


func _ready() -> void:
	_root = ProjectSettings.globalize_path("res://")
	_temp = _root + "temp/"
	_parse_args()
	print("[proto25d] 工程根=", _root)
	print("[proto25d] 跑法: godot --path stick-world res://tests/dev/proto_25d/proto_25d.tscn -- --shots=all")
	_load_cards()
	_build_world()
	if str(_opts["perf"]) != "":
		await _run_perf(str(_opts["perf"]))
	else:
		await _run_shots(str(_opts["shots"]))
	print("[proto25d] DONE")
	# 出图/测完先静置两帧再退，否则 200 个对象一次性析构会在 Godot 退出时刷
	# "Unreferenced static string / RID leaked" 噪声（引擎级关停顺序问题，非本次改动）
	await _settle(1.0)
	get_tree().quit(0)


# ------------------------------------------------------------------ 参数

func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--shots="):
			_opts["shots"] = s.get_slice("=", 1)
		elif s.begins_with("--perf="):
			_opts["perf"] = s.get_slice("=", 1)
		elif s.begins_with("--tag="):
			_opts["tag"] = s.get_slice("=", 1)
		elif s == "--no-cards":
			_opts["cards"] = false
		elif s == "--no-models":
			_opts["models"] = false


# ------------------------------------------------------------------ 资源

func _load_cards() -> void:
	var p := _temp + CARDS_JSON
	if not FileAccess.file_exists(p):
		push_error("[proto25d] 缺 cards.json，先跑 Blender 半场: " + p)
		return
	var f := FileAccess.open(p, FileAccess.READ)
	var arr: Variant = JSON.parse_string(f.get_as_text())
	if arr is Array:
		for c in arr:
			_cards[str(c["card"])] = c
	print("[proto25d] 烘焙卡 %d 张" % _cards.size())


func _tex_abs(p: String) -> Texture2D:
	if _tex_cache.has(p):
		return _tex_cache[p]
	if not FileAccess.file_exists(p):
		push_error("[proto25d] 纹理缺失: " + p)
		return null
	var img := Image.new()
	if img.load(p) != OK:
		return null
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_tex_cache[p] = t
	return t


func _card_material(card: String) -> ShaderMaterial:
	var meta: Dictionary = _cards.get(card, {})
	var base := _temp + "proto25d/cards/"
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


## 纸片卡 quad：quad 平面与相机像平面平行（法线正对相机，观感即烘焙结果）
func _spawn_card(card: String, center: Vector3, parent: Node3D,
		own_mat: bool = false) -> MeshInstance3D:
	var meta: Dictionary = _cards.get(card, {})
	if meta.is_empty():
		push_warning("[proto25d] 无此卡: " + card)
		return null
	var units: Array = meta["units"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * S, float(units[1]) * S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.position = center
	mi.basis = _cam_basis()
	mi.material_override = _card_material(card)
	if own_mat:
		mi.material_override = mi.material_override.duplicate()
		_card_mats.append(mi.material_override)
	parent.add_child(mi)
	return mi


## 与相机同基（X 右 / Y 上 / Z 朝相机）：纸片卡永远正对相机
func _cam_basis() -> Basis:
	var t := deg_to_rad(TILT_DEG)
	return Basis(Vector3(1, 0, 0),
		Vector3(0, cos(t), -sin(t)), Vector3(0, sin(t), cos(t)))


# ------------------------------------------------------------------ 世界

func _build_world() -> void:
	# --- 环境（天空 + 环境光 + 雾 + 辉光）---
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# 线性色调映射：卡是**已经带光照的烘焙图**，任何 filmic/aces 都会把它压灰，
	# 观感就"不是 2D 那张图"了。2.5D 的第一原则是卡的像素别被二次改造。
	_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_env.tonemap_exposure = 1.0
	_env.tonemap_white = 1.0
	_env.glow_enabled = true
	_env.glow_intensity = 0.8
	_env.glow_bloom = 0.10
	_env.glow_hdr_threshold = 1.1
	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_depth_begin = 60.0
	_env.fog_depth_end = 420.0
	_env.fog_density = 1.0
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

	# --- 太阳 ---
	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 120.0
	add_child(_sun)

	# --- 地面（有限条带：远边落在画内，露出天空）---
	var pm := PlaneMesh.new()
	pm.size = Vector2(600.0, 95.0)
	_ground = MeshInstance3D.new()
	_ground.mesh = pm
	_ground.position = Vector3(0, 0, -7.5)
	var gm := StandardMaterial3D.new()
	gm.albedo_texture = _tex_abs(_temp + "ground_tiles/cobble_large_128.png")
	gm.albedo_color = Color(1, 1, 1)
	gm.roughness = 0.95
	gm.uv1_scale = Vector3(600.0 / 4.0, 95.0 / 4.0, 1.0)
	_ground.material_override = gm
	add_child(_ground)

	# --- 建筑：前排行 = 纸片卡 / glb 交替配对；后排 = 更高体量的纸片卡 ---
	_card_root = Node3D.new()
	_card_root.name = "Cards"
	add_child(_card_root)
	_model_root = Node3D.new()
	_model_root.name = "Models"
	add_child(_model_root)
	_lamp_root = Node3D.new()
	_lamp_root.name = "Lamps"
	add_child(_lamp_root)
	_extra_root = Node3D.new()
	_extra_root.name = "Extra"
	add_child(_extra_root)

	var cursor := 0.0
	var slots: Array = []
	for pr in PAIRS:
		if bool(_opts["cards"]):
			slots.append({"kind": "card", "id": str(pr["card"])})
		if bool(_opts["models"]):
			slots.append({"kind": "glb", "id": str(pr["glb"])})
	var total := 0.0
	for s in slots:
		total += _slot_width(s) + GAP
	total -= GAP
	cursor = -total / 2.0
	for s in slots:
		var w: float = _slot_width(s)
		if s["kind"] == "card":
			_spawn_card(str(s["id"]), Vector3(cursor + w / 2.0, 0, FRONT_Z), _card_root)
		else:
			_spawn_model(str(s["id"]), cursor + w / 2.0, FRONT_Z)
		cursor += w + GAP

	# 火柴人 standee（比例尺参照：130px = 4.06 格；同时验证"2D 剪影卡可直接平移"）
	for sx in [-26.0, -3.0, 22.0]:
		_spawn_stickman_standee(sx, FRONT_Z + 1.2)

	# 后排纸片卡
	var back_w := 0.0
	for c in BACK_CARDS:
		back_w += float(_cards[c]["units"][0]) * S + GAP
	back_w -= GAP
	var bx := -back_w / 2.0
	for c in BACK_CARDS:
		var w2 := float(_cards[c]["units"][0]) * S
		_spawn_card(c, Vector3(bx + w2 / 2.0, 0, BACK_Z), _card_root)
		bx += w2 + GAP

	# --- 灯笼点光源（暖光；glb 排与纸片排都吃这套真 3D 光）---
	var lamp_xs: Array = [-30.0, -22.0, -14.0, -6.0, 2.0, 10.0, 18.0, 26.0]
	for i in lamp_xs.size():
		var l := OmniLight3D.new()
		l.position = Vector3(float(lamp_xs[i]), 2.4, FRONT_Z + 2.6)
		l.light_color = Color(1.0, 0.63, 0.30)
		l.light_energy = 1.6
		l.omni_range = 9.5
		l.shadow_enabled = i % 2 == 0
		l.light_specular = 0.2
		_lamp_root.add_child(l)
		_lamps.append(l)

	# --- 相机：正交、纯正面 + 20° 微俯视（对齐 §0.3）---
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_WIDTH
	_cam.size = CAM_W
	_cam.near = 0.05
	_cam.far = 600.0
	_cam.rotation = Vector3(deg_to_rad(-TILT_DEG), 0, 0)
	var t := deg_to_rad(TILT_DEG)
	_cam.position = Vector3(0, CAM_CY + sin(t) * CAM_DIST, cos(t) * CAM_DIST)
	add_child(_cam)
	_cam.current = true


func _slot_width(s: Dictionary) -> float:
	if s["kind"] == "card":
		var m: Dictionary = _cards.get(str(s["id"]), {})
		return float(m.get("units", [12, 12])[0]) * S + 0.6
	# glb：按格宽（4/8/12/16）+ 出檐粗估
	var wc := float(str(s["id"]).get_slice("_w", 1))
	return wc * 1.2


## 程序化画一个 130px 火柴人剪影（32px = 1 格），贴成一张 standee 卡。
## 目的有二：① 比例尺（火柴人 4.06 格 vs 建筑 10~24 格）；② 证明 2D 剪影
## 可以零成本平移进 3D —— 但**动画/IK/武器挂点/受击表现全都要重做**（见汇报）。
func _stickman_tex() -> Texture2D:
	if _tex_cache.has("__stick__"):
		return _tex_cache["__stick__"]
	var W := 48
	var H := 148
	var base := 138          # 脚底所在行（含 10 行接地余量）
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var col := Color(0.07, 0.06, 0.06, 1.0)
	var cx := W / 2
	_head(img, cx, 5 + 14, 14, col)                       # 头（直径 28px）
	_line(img, cx, 33, cx, 84, 9, col)                    # 躯干
	_line(img, cx, 42, cx - 15, 74, 7, col)               # 左臂
	_line(img, cx, 42, cx + 15, 74, 7, col)               # 右臂
	_line(img, cx, 84, cx - 12, base, 8, col)             # 左腿
	_line(img, cx, 84, cx + 12, base, 8, col)             # 右腿
	var t := ImageTexture.create_from_image(img)
	_tex_cache["__stick__"] = t
	return t


func _head(img: Image, cx: int, cy: int, r: int, col: Color) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r:
				img.set_pixel(x, y, col)


func _line(img: Image, x0: int, y0: int, x1: int, y1: int, w: int, col: Color) -> void:
	var n := int(max(abs(x1 - x0), abs(y1 - y0))) + 1
	var hw := w / 2
	for i in n:
		var t := float(i) / float(max(1, n - 1))
		var x := int(round(lerp(float(x0), float(x1), t)))
		var y := int(round(lerp(float(y0), float(y1), t)))
		for dy in range(-hw, hw + 1):
			for dx in range(-hw, hw + 1):
				var px := x + dx
				var py := y + dy
				if px >= 0 and px < img.get_width() and py >= 0 and py < img.get_height():
					img.set_pixel(px, py, col)


func _spawn_stickman_standee(x: float, z: float) -> void:
	var W := 48.0
	var H := 148.0
	var base_row := 138.0
	var q := QuadMesh.new()
	q.size = Vector2(W / 32.0, H / 32.0)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	# 脚底(base_row)落在世界 y=0：quad 中心=图像中心，中心比脚底高 (base_row - H/2)
	mi.position = Vector3(x, (base_row - H / 2.0) / 32.0, z)
	mi.basis = _cam_basis()
	var m := StandardMaterial3D.new()
	m.albedo_texture = _stickman_tex()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mi.material_override = m
	_extra_root.add_child(mi)


func _spawn_model(name: String, x: float, z: float) -> void:
	var glb := _temp + GLB_REL
	if not FileAccess.file_exists(glb):
		push_warning("[proto25d] 缺 glb: " + glb)
		return
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(glb, st) != OK:
		push_error("[proto25d] glb 解析失败")
		return
	var scene: Node = doc.generate_scene(st)
	if scene == null:
		return
	# 只留目标那栋（Blender 侧每栋一个 mesh 节点，名 = <asm>_w<N>；
	# 导出的 node.translation.x 还是 Blender px（scale 只烘进网格数据），
	# 所以位置一律在 Godot 侧重设，不信任 glb 的 translation）
	var keep: Node3D = null
	for c in scene.get_children():
		if c is Node3D and str(c.name) == name:
			keep = c
			break
	if keep == null:
		var pre := name.get_slice("_w", 0)
		for c in scene.get_children():
			if c is Node3D and str(c.name).begins_with(pre):
				keep = c
				break
	_model_root.add_child(scene)
	for c in scene.get_children():
		if c != keep:
			c.queue_free()
	if keep != null:
		keep.position = Vector3(x, 0.0, z)
		_recolor(keep, true)
	else:
		push_warning("[proto25d] glb 内找不到 %s" % name)


func _recolor(n: Node, top: bool = false) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var src := mi.get_active_material(i)
				var nm := ""
				if src != null:
					nm = src.resource_name
					if nm == "":
						nm = src.resource_path.get_file().get_basename()
				var m := StandardMaterial3D.new()
				var col: Color = GLB_COLORS.get(nm, Color(0.72, 0.70, 0.66))
				m.albedo_color = col
				m.roughness = 0.9
				if nm in GLB_GLASS:
					m.albedo_color = Color(0.16, 0.20, 0.24)
					m.emission_enabled = true
					m.emission = Color(1.0, 0.72, 0.36)
					m.emission_energy_multiplier = 0.0
					m.cull_mode = BaseMaterial3D.CULL_DISABLED
					_glass_mats.append(m)
				mi.set_surface_override_material(i, m)
	for c in n.get_children():
		_recolor(c, false)


# ------------------------------------------------------------------ 三段光照

func _apply_mode(mode: String) -> void:
	# 每段先复位再按档覆盖（幂等，可反复调用）
	_sky_mat.sky_top_color = Color(0.30, 0.42, 0.68)
	_sky_mat.sky_horizon_color = Color(0.72, 0.78, 0.86)
	_sky_mat.ground_horizon_color = Color(0.72, 0.78, 0.86)
	_sky_mat.ground_bottom_color = Color(0.34, 0.36, 0.38)
	_sky_mat.energy_multiplier = 1.0
	# 关键纪律：卡的烘焙图里已经含了它的白天光照。环境光+太阳的**总和**必须 ≈1.0，
	# 否则就是把光照算两遍（实测 1.0+1.5 直接过曝成灰白）。
	_env.ambient_light_color = Color(0.62, 0.70, 0.82)
	_env.ambient_light_energy = 0.45
	_env.glow_intensity = 0.9
	_env.fog_light_color = Color(0.72, 0.78, 0.86)
	_env.fog_depth_begin = 60.0
	_env.fog_depth_end = 420.0
	_sun.light_color = Color(1.0, 0.95, 0.86)
	_sun.light_energy = 0.70
	_sun.rotation = Vector3(deg_to_rad(-42.0), deg_to_rad(-32.0), 0)
	var glow := 0.0
	var lamp := 0.0
	var glass := 0.0
	match mode:
		"dusk":
			_sky_mat.sky_top_color = Color(0.16, 0.22, 0.42)
			_sky_mat.sky_horizon_color = Color(0.95, 0.55, 0.30)
			_sky_mat.ground_horizon_color = Color(0.70, 0.45, 0.32)
			_sky_mat.ground_bottom_color = Color(0.16, 0.15, 0.18)
			_env.ambient_light_color = Color(0.42, 0.40, 0.52)
			_env.ambient_light_energy = 0.26
			_sun.light_color = Color(1.0, 0.58, 0.28)
			_sun.light_energy = 0.42
			_sun.rotation = Vector3(deg_to_rad(-9.0), deg_to_rad(-78.0), 0)
			_env.fog_light_color = Color(0.86, 0.56, 0.40)
			_env.fog_depth_begin = 60.0
			_env.fog_depth_end = 380.0
			glow = 0.45
			lamp = 0.8
			glass = 0.7
		"night":
			_sky_mat.sky_top_color = Color(0.015, 0.025, 0.07)
			_sky_mat.sky_horizon_color = Color(0.06, 0.08, 0.16)
			_sky_mat.ground_horizon_color = Color(0.05, 0.06, 0.11)
			_sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.04)
			_env.ambient_light_color = Color(0.14, 0.19, 0.34)
			_env.ambient_light_energy = 0.10
			_env.glow_intensity = 1.0
			_env.glow_bloom = 0.10
			_sun.light_color = Color(0.55, 0.68, 1.0)
			_sun.light_energy = 0.05
			_sun.rotation = Vector3(deg_to_rad(-62.0), deg_to_rad(140.0), 0)
			_env.fog_light_color = Color(0.05, 0.07, 0.14)
			_env.fog_depth_begin = 60.0
			_env.fog_depth_end = 340.0
			glow = 1.15
			lamp = 1.5
			glass = 1.3
		_:
			pass  # day
	for m in _card_mats:
		m.set_shader_parameter("glow_energy", glow)
	for m in _glass_mats:
		m.emission_energy_multiplier = glass
	for l in _lamps:
		l.visible = lamp > 0.0
		l.light_energy = lamp
	print("[proto25d] 光照档=%s glow=%.1f lamp=%.1f" % [mode, glow, lamp])


# ------------------------------------------------------------------ 出图

func _settle(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(name: String) -> String:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var tag := str(_opts["tag"])
	var p := _temp + "proto25d_%s%s.png" % [tag, name]
	var err := img.save_png(p)
	if err != OK:
		push_error("[proto25d] 截图失败 %s (err=%d)" % [p, err])
	else:
		print("[proto25d] shot -> %s  %dx%d" % [p, img.get_width(), img.get_height()])
	return p


func _run_shots(which: String) -> void:
	var modes: Array = ["day", "dusk", "night"]
	if which != "all" and which != "":
		modes = [which]
	for m in modes:
		_apply_mode(m)
		await _settle(1.2)
		await _shot(m)
		print("[proto25d] %s 档帧时=%.2f ms (draws=%d)" % [
			m, _last_frame_ms(),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])


func _last_frame_ms() -> float:
	return 1000.0 / max(1.0, Performance.get_monitor(Performance.TIME_FPS))


# ------------------------------------------------------------------ 性能

func _run_perf(spec: String) -> void:
	print("[proto25d] === 性能档 ===")
	# 本机事实：`DisplayServer.window_set_vsync_mode(VSYNC_DISABLED)` 在 D3D12 下**不生效**
	# （实测 0 卡基线也恰好 6.90ms/145fps —— 被 144Hz 刷新率钉死），所以"200 卡"这一档
	# 量不出本征成本。改用**加档压到 vsync 上限之上**再读：只有超过 6.9ms 的档才有信息量。
	_card_root.queue_free()
	_lamp_root.queue_free()
	_model_root.queue_free()
	_extra_root.queue_free()
	await _settle(0.4)
	_card_root = Node3D.new()
	_lamp_root = Node3D.new()
	add_child(_card_root)
	add_child(_lamp_root)
	_card_mats.clear()
	_glass_mats.clear()
	_lamps.clear()
	# 关垂直同步 + 关帧率上限：不关的话一切档位都被刷新率钉在同一个数（实测 10.00ms/100fps）。
	# 注意 config_manager autoload 会按配置设 VSYNC_ENABLED，所以这里必须**在**它之后再关。
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("[proto25d] vsync_mode=%d（2=disabled）" % DisplayServer.window_get_vsync_mode())
	if spec != "":
		var parts := spec.split(",")
		var n0 := int(parts[0])
		var l0 := int(parts[1]) if parts.size() > 1 else 20
		await _perf_level(n0, l0, 5.0)
		await _shot("perf")
		await _perf_level(n0 * 4, l0 * 4, 5.0)
		await _perf_level(n0 * 10, l0 * 10, 5.0)
		await _perf_level(0, 0, 3.0)
	print("[proto25d] === 性能档结束 ===")


func _perf_level(n: int, nl: int, seconds: float) -> void:
	for c in _card_root.get_children():
		c.queue_free()
	for l in _lamp_root.get_children():
		l.queue_free()
	await _settle(0.4)
	var keys: Array = _cards.keys()
	var cols := 20
	var pitch := 13.0
	for i in n:
		var k: String = str(keys[i % keys.size()])
		var x := float(i % cols) * pitch - float(cols) * pitch * 0.5
		var z := -6.0 - float(i / cols) * 24.0
		_spawn_card(k, Vector3(x, 0, z), _card_root, true)
	for i in nl:
		var l := OmniLight3D.new()
		l.position = Vector3(float(i % 12) * 12.0 - 72.0, 3.0, 4.0)
		l.light_color = Color(1.0, 0.62, 0.30)
		l.light_energy = 1.8
		l.omni_range = 16.0
		l.shadow_enabled = i % 5 == 0
		_lamp_root.add_child(l)
	for m in _card_mats:
		m.set_shader_parameter("glow_energy", 1.15)
	# 覆盖整个阵列的取景
	_cam.size = maxf(240.0, float(cols) * pitch + 40.0)
	var rows := int(ceil(float(maxi(n, 1)) / float(cols)))
	var depth := float(rows) * 24.0
	_cam.size = maxf(_cam.size, depth * 1.6)
	await _settle(3.0)                     # 热身（编译/上传/显存分配）
	_samples = PackedFloat32Array()
	_draw_samples = PackedInt32Array()
	_measuring = true
	var t0 := Time.get_ticks_usec()
	await _settle(seconds)
	var el := float(Time.get_ticks_usec() - t0) / 1000000.0
	_measuring = false
	var arr := Array(_samples)
	arr.sort()
	if arr.is_empty():
		return
	var fps := float(arr.size()) / maxf(0.001, el)
	var draws := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	var row := "[perf] %4d 卡 + %4d 点光：帧时=%.2f ms (%.0f fps)  med=%.2f p95=%.2f max=%.2f  draws=%d prims=%d" % [
		n, nl, 1000.0 / maxf(0.01, fps), fps, float(arr[arr.size() / 2]),
		float(arr[mini(arr.size() - 1, int(arr.size() * 0.95))]), float(arr[arr.size() - 1]),
		draws, prims]
	print(row)
	_phase_rows.append(row)


func _process(delta: float) -> void:
	if _measuring:
		_samples.append(delta * 1000.0)
		_draw_samples.append(int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
