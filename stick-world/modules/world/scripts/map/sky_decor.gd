class_name SkyDecor
extends Node2D
## 天空装饰层 —— Terraria 原版贴图多层视差背景（Demo 资产政策：机制+贴图皆源自反编译）。
##
## 贴图：Terraria Content/Images XNB 提取（Background_7/8 远山、9/10/11 森林三层、
## Cloud_0-3 云，tools/ai/extract_terraria_sky.py；已登记 docs/项目/素材替换清单.md）。
## 公式：Terraria 反编译源码（Main.cs DrawSurfaceBG / Cloud.cs，见
## docs/技术/参考逆向/天空与水体逆向笔记.md §三/§五）。
##
## 层次（远→近，绘制序；factor=视差扫动速率）：
##   星野(0.08) → 飞鸟(0.35) → 云·远档(scale<1.0) → 远山(0.15) → 近山(0.2)
##   → 云·中档(1.0~1.15) → 树线远(0.4) → 云·近档(≥1.15) → 树线中(0.43) → 树线近(0.49)
## 平铺：modulo 回绕（Main.cs :53724 同构）——任意相机位置无缝、无超宽贴图冗余。
## Staging：层顶/底按天空高度比例（Terraria 近层顶更低、远层从近层上方探出）。
## 由 VillageMap._ready 挂载。

const SkyStarsScript := preload("res://modules/world/scripts/map/sky_stars.gd")
const SkyBirdsScript := preload("res://modules/world/scripts/map/sky_birds.gd")
## 手绘云渲染器（选型对比期：四风格混排上天，用户选定后收敛单风格）
const SketchCloudScript := preload("res://modules/ui_global/scripts/sketch/sketch_cloud.gd")

## 地形背景组 —— Terraria 每种地形一套独立贴图（WorldGen.SetForestBGSet /
## SetDesertBGSet 等按地形分发），本项目按地图 sky_biome 选组：
##   mountains：远山×2（村落/战场/道路等开阔地——无树线）
##   forest：远山×2 + 森林树线×3（森林图专用，进入树林才有树）
## 层定义数值为 Terraria Main.cs DrawSurfaceBG 反编译直译：
## bgScale 为原版层缩放；top 为"层顶距地平线高度"（原版 bgTopY 公式在
## 地表取景 magic=-0.85、地平线在屏中 540px 时的值：bgTopY=magic*coef_a+coef_b+30）。
## 运行时整体再乘 sky_ratio（我方天空高/540），让构图比例与原版一致地适配任意地图。
const BIOME_SETS: Dictionary = {
	"mountains": [
		{"tex": "res://assets/sky/bg_mountain_far.png", "parallax": 0.15, "top": 525.0, "bg_scale": 1.00},
		{"tex": "res://assets/sky/bg_mountain_near.png", "parallax": 0.20, "top": 440.0, "bg_scale": 1.15},
	],
	"forest": [
		{"tex": "res://assets/sky/bg_mountain_far.png", "parallax": 0.15, "top": 525.0, "bg_scale": 1.00},
		{"tex": "res://assets/sky/bg_mountain_near.png", "parallax": 0.20, "top": 440.0, "bg_scale": 1.15},
		{"tex": "res://assets/sky/bg_trees_far.png", "parallax": 0.40, "top": 540.0, "bg_scale": 1.25},
		{"tex": "res://assets/sky/bg_trees_mid.png", "parallax": 0.43, "top": 417.0, "bg_scale": 1.31},
		{"tex": "res://assets/sky/bg_trees_near.png", "parallax": 0.49, "top": 295.0, "bg_scale": 1.34},
	],
}
## 当前地形背景组（由 VillageMap/road_map 按地图 sky_biome 注入）
var biome: String = "mountains"
## 原版地表取景的地平线屏高（bgTopY 公式的基准；我方按 sky_h/该值 等比适配）
const TERRARIA_HORIZON_PX: float = 540.0
## 云贴图（Terraria Cloud_0-3 四变体）
const TEX_CLOUDS: Array[String] = [
	"res://assets/sky/cloud_a.png",
	"res://assets/sky/cloud_b.png",
	"res://assets/sky/cloud_c.png",
	"res://assets/sky/cloud_d.png",
]

## 地平线 y（与地图 ground_y 一致，层 staging 以此为锚）
var horizon_y: float = 810.0
## 地图横向范围（不再用于平铺，仅元数据兼容）
var map_left: float = 0.0
var map_right: float = 8192.0

## 视差层注册表 [{node, factor}]（星野/飞鸟等 position.x = cam_x*(1-factor) 机制）
var _layers: Array = []
## 平铺背景层注册表（modulo 回绕机制，与 _layers 分开驱动）
var _tile_layers: Array = []
## Terraria 式云池（Cloud.cs 逆向）：尺寸=深度、全局风驱动、Alpha 软生灭、
## 三档深度 pass 穿插在背景层之间（远云在山后、近云在树前）
var _clouds: Array = []
var _cloud_passes: Dictionary = {}   # 档位 → Node2D 容器
var _wind: float = 0.9
var _wind_t: float = 0.0
var _last_cam_x: float = 0.0
var _env: Node = null
var _rng := RandomNumberGenerator.new()
var _cam: Camera2D = null
var _cam_ready: bool = false
## 雨强度（Weather 注入）：云 alpha 上限提高（Terraria 雨天云浓）
var _rainy: float = 0.0

## 云池规模（Terraria 原版 numClouds=rand(200) 世界随机、实际画面常见个位数到
## 十几朵；本项目 14 朵 → 视野带内 14、屏内约 9。曾 32 朵密得像挤早高峰）
const CLOUD_POOL: int = 14
## 云出生带（相对地平线向上，比例×天空高）。2026-09-06 用户指示：云只出现在
## 屏幕上 1/3——带压到天空顶部区（bot 0.25→0.62：带高从 0.83 天空压到 0.46，
## 靠近顶带）。远云更高——小云再上移同构。
const CLOUD_Y_TOP_R: float = 1.08
const CLOUD_Y_BOT_R: float = 0.62
var _cloud_texs: Array = []


func _ready() -> void:
	z_index = -6
	var set: Array = BIOME_SETS.get(biome, BIOME_SETS["mountains"])
	# 云三档穿插：远云在首层山后；中云在两山之间；近云在树线远层之后
	# （无树线的地形组则垫在最后一层之后）——Terraria DrawSurfaceBG 绘制序
	var closest_after: int = 2 if set.size() > 2 else set.size() - 1
	_build_stars()
	_build_birds()
	_build_cloud_pass("distant")
	for i in set.size():
		if i == closest_after + 1:
			_build_cloud_pass("closest")
		if i == 1:
			_build_cloud_pass("closer")
		_build_layer(set[i])
	if not _cloud_passes.has("closest"):
		_build_cloud_pass("closest")
	_build_clouds()
	_build_haze()
	# 相机引用惰性获取（GameRoot.CameraRig）
	call_deferred("_find_camera")


## 星野+月亮（最底层、无限远；夜间淡入，见 sky_stars.gd）
func _build_stars() -> void:
	var stars: Node2D = SkyStarsScript.new()
	stars.name = "Stars"
	add_child(stars)
	_layers.append({"node": stars, "factor": SkyStarsScript.FACTOR})


## 地平线雾带（大气透视层）——远山/树线脚与地面交界处的垂直渐变雾，
## 盖住背景层贴图底边与地平线的生硬切线。雾在"无穷远"（视差=0），只跟随相机；
## 颜色用固定暖灰白，昼氛围由 CanvasModulate 全局昼夜统一染色（夜雾自动转暗蓝）。
## 层序在 sky_decor 内最后（背景层之上），地平线以下由地面多边形（z=0）自然盖住。
const HAZE_HEIGHT: float = 210.0
const HAZE_ALPHA: float = 0.52
const HAZE_COLOR := Color(0.87, 0.86, 0.82)
var _haze: Sprite2D = null

func _build_haze() -> void:
	var grad := Gradient.new()
	grad.set_color(0, Color(HAZE_COLOR.r, HAZE_COLOR.g, HAZE_COLOR.b, 0.0))
	grad.set_color(1, Color(HAZE_COLOR.r, HAZE_COLOR.g, HAZE_COLOR.b, HAZE_ALPHA))
	# 渐变主体压在靠下 1/3：远山大部分轮廓可见，只有山脚沉进雾里
	grad.add_point(0.42, Color(HAZE_COLOR.r, HAZE_COLOR.g, HAZE_COLOR.b, 0.0))
	grad.add_point(0.78, Color(HAZE_COLOR.r, HAZE_COLOR.g, HAZE_COLOR.b, HAZE_ALPHA * 0.55))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	# 垂直渐变：FILL_LINEAR + fill 向量自上而下（枚举无 VERTICAL 变体）
	tex.fill = GradientTexture2D.FILL_LINEAR
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	tex.width = 64
	tex.height = 256
	_haze = Sprite2D.new()
	_haze.name = "HorizonHaze"
	_haze.texture = tex
	_haze.centered = false
	add_child(_haze)


## 雾带对齐视野：宽覆盖视野 + 余量，底边锚在地平线（超出部分被地面盖住）
func _update_haze() -> void:
	if _haze == null or _cam == null or not is_instance_valid(_cam):
		return
	var view_w: float = get_viewport_rect().size.x / maxf(_cam.zoom.x, 0.05)
	_haze.scale = Vector2((view_w + 800.0) / 64.0, HAZE_HEIGHT / 256.0)
	_haze.position = Vector2(_cam.global_position.x - (view_w + 800.0) * 0.5,
			horizon_y - HAZE_HEIGHT)


## 远空飞鸟群（星野之上、山层之下，会被山脊遮挡出纵深；昼间活动，见 sky_birds.gd）
func _build_birds() -> void:
	var birds: Node2D = SkyBirdsScript.new()
	birds.name = "Birds"
	add_child(birds)
	_layers.append({"node": birds, "factor": SkyBirdsScript.FACTOR})


## 构建平铺背景层：Terraria 层缩放 × sky_ratio，层顶锚定地平线上方 top 像素；
## 纹理 repeat + 超宽 region（modulo 每帧驱动）
func _build_layer(def: Dictionary) -> void:
	if not ResourceLoader.exists(def["tex"]):
		push_warning("[SkyDecor] 背景贴图缺失: %s" % def["tex"])
		return
	var tex: Texture2D = load(def["tex"])
	var sky_ratio: float = horizon_y / TERRARIA_HORIZON_PX
	var scl: float = float(def["bg_scale"]) * sky_ratio
	var top_y: float = horizon_y - float(def["top"]) * sky_ratio
	var spr := Sprite2D.new()
	spr.name = String(def["tex"]).get_file().get_basename()
	spr.texture = tex
	spr.centered = false
	spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	spr.scale = Vector2(scl, scl)
	spr.position = Vector2(0.0, top_y)
	add_child(spr)
	_tile_layers.append({"node": spr, "parallax": float(def["parallax"]),
			"tile_w": float(tex.get_width()) * scl, "tex_h": float(tex.get_height())})


## 云深度 pass 容器（穿插在背景层之间制造前后遮挡）
func _build_cloud_pass(pass_name: String) -> void:
	var holder := Node2D.new()
	holder.name = "Clouds_" + pass_name
	add_child(holder)
	_cloud_passes[pass_name] = holder


func _build_clouds() -> void:
	_rng.seed = 20260905
	for p in TEX_CLOUDS:
		if ResourceLoader.exists(p):
			_cloud_texs.append(load(p))
	for i in CLOUD_POOL:
		var cloud: Node2D = SketchCloudScript.new()
		var scale_f: float = _rng.randf_range(0.7, 1.3)
		# 手绘云四风格均匀混排（选型对比期）：F1/F2/F3/E2 = 枚举 5/5/5/4 的前三
		cloud.set("style", [5, 5, 5, 4][i % 4])
		# 尺寸=深度档（2026-09-06 用户指示减小 1/3：基准 300×125 → 200×83）
		cloud.set("cloud_size", Vector2(200.0, 83.0) * scale_f * 1.35)
		var pass_name: String = "distant" if scale_f < 1.0 else ("closer" if scale_f < 1.15 else "closest")
		(_cloud_passes[pass_name] as Node2D).add_child(cloud)
		# 出生带：远云（小）更高——Terraria 小云再上移的同构
		var sky_h: float = maxf(horizon_y, 320.0)
		var band_top: float = horizon_y - sky_h * CLOUD_Y_TOP_R
		var band_h: float = sky_h * (CLOUD_Y_TOP_R - CLOUD_Y_BOT_R)
		var y: float = _rng.randf_range(0.0, band_h) + band_top - (1.3 - scale_f) * 0.12 * sky_h
		cloud.position = Vector2(_rng.randf_range(-1700.0, 1700.0), y)
		_clouds.append({
			"node": cloud,
			"p": _cloud_parallax(scale_f),   # Cloud.GetParallax 直译
			"scale_f": scale_f,
			"alpha": _rng.randf_range(0.35, 0.85),  # 首批直接半亮，后续渐入
			"dying": false,
			"phase": _rng.randf() * TAU,     # 极慢摇摆的相位
		})


## Cloud.GetParallax 直译：scale 三档 → 0.07/0.19/0.23 系（小云远、慢）
static func _cloud_parallax(scale_f: float) -> float:
	var base: float
	var mod: float
	if scale_f < 1.0:
		base = 0.07
		mod = (scale_f + 0.15 + 1.0) * 0.5
	elif scale_f <= 1.15:
		base = 0.19
		mod = scale_f - 0.075
	else:
		base = 0.23
		mod = scale_f - 0.225
	mod *= mod
	return base * mod


func _find_camera() -> void:
	# 优先 GameRoot.CameraRig；任何环境兜底取当前激活相机（测试/特殊场景层级不定）
	var gr := get_tree().root.get_node_or_null("GameRoot")
	if gr != null:
		_cam = gr.get_node_or_null("CameraRig") as Camera2D
	if _cam == null:
		_cam = get_viewport().get_camera_2d()
	_cam_ready = true
	if _cam != null:
		_last_cam_x = _cam.global_position.x
		# 立即对齐一次视差，防首帧跳变
		_apply_parallax()
		_update_tile_layers()


func _process(delta: float) -> void:
	if _cam_ready and _cam != null and is_instance_valid(_cam):
		_apply_parallax()
		_update_tile_layers()
		_update_haze()
	# 风：缓慢正弦起伏（周期 ~2 分钟，双向漂；Terraria windSpeedCurrent 简化版）。
	# 幅度 0.6：原版常态风速偏小（峰值档最近云 ~86px/s，可察觉的舒缓漂移）；
	# 曾 1.1（最近云 158px/s、横穿一屏 12s——用户质疑「变化这么快」的来源）
	_wind_t += delta
	_wind = sin(_wind_t * 0.05) * 0.6
	_update_clouds(delta)


## 视差：星野/飞鸟等层 x = 相机 x × (1 - factor)
func _apply_parallax() -> void:
	var cam_x: float = _cam.global_position.x
	for layer in _layers:
		var node: Node2D = layer["node"]
		if node == null or not is_instance_valid(node):
			continue
		var factor: float = float(layer["factor"])
		node.position.x = cam_x * (1.0 - factor)


## 平铺背景层 modulo 回绕（Main.cs :53724 bgStartX 同构）：
## 相位 = cam_x×parallax 对 tile_w 取模，层 sprite 覆盖视野宽 + 2 tile 冗余
func _update_tile_layers() -> void:
	var view_w: float = get_viewport_rect().size.x / maxf(_cam.zoom.x, 0.05)
	var view_left: float = _cam.global_position.x - view_w * 0.5
	for tl in _tile_layers:
		var spr: Sprite2D = tl["node"]
		if spr == null or not is_instance_valid(spr):
			continue
		var w: float = float(tl["tile_w"])
		var phase: float = fmod(_cam.global_position.x * float(tl["parallax"]) - view_left, w)
		if phase < 0.0:
			phase += w
		spr.position.x = view_left - phase
		spr.region_enabled = true
		spr.region_rect = Rect2(0.0, 0.0, view_w + w * 2.0, float(tl["tex_h"]))


## Terraria 云更新（Cloud.Update 直译；云是相机跟随带内的屏域实体，
## 出视野带 ±600px 软退场——任意取景密度恒定，不随全图摊薄）
func _update_clouds(delta: float) -> void:
	var cam_x: float = _cam.global_position.x if _cam != null and is_instance_valid(_cam) else 0.0
	var cam_move: float = cam_x - _last_cam_x
	_last_cam_x = cam_x
	var view_w: float = get_viewport_rect().size.x / maxf(_cam.zoom.x if _cam != null else 1.0, 0.05)
	var band_half: float = view_w * 0.5 + 600.0
	for c in _clouds:
		var cloud: Node2D = c["node"]
		if cloud == null or not is_instance_valid(cloud):
			continue
		var p: float = c["p"]
		# 风驱动 ×9×视差（Cloud.cs:401）+ 相机横移按视差回拉（Cloud.cs:321）
		cloud.position.x += _wind * 9.0 * p * delta * 60.0
		cloud.position.x -= cam_move * p
		# 软生灭：出带渐隐 → 对侧重生渐显（雨天云更浓：上限 0.92→1.0）
		if c["dying"]:
			c["alpha"] = float(c["alpha"]) - 0.06 * delta
			if float(c["alpha"]) <= 0.0:
				_respawn_cloud(c, cam_x, band_half)
		else:
			c["alpha"] = minf(float(c["alpha"]) + 0.06 * delta, 0.92 + 0.08 * _rainy)
			if cloud.position.x < cam_x - band_half or cloud.position.x > cam_x + band_half:
				c["dying"] = true
		# 云级 alpha：尺度越大越实（Cloud.cloudColor 的 scale×Alpha 同构；
		# 颜色不手动染色——CanvasModulate 全局昼夜染色已覆盖云与背景层）
		var opacity: float = float(c["alpha"]) * lerpf(0.72, 1.0, (float(c["scale_f"]) - 0.7) / 0.6)
		cloud.modulate = Color(1.0, 1.0, 1.0, opacity)
		# 极慢摇摆（Cloud 微幅摆动同构，±0.6°）
		cloud.rotation = sin(_wind_t * 0.11 + float(c["phase"])) * 0.01


## 云重生：风向对侧入场，重掷风格（四候选均匀）与尺度（视差档/深度 pass 随之变化）
func _respawn_cloud(c: Dictionary, cam_x: float, band_half: float) -> void:
	var cloud: Node2D = c["node"]
	var scale_f: float = _rng.randf_range(0.7, 1.3)
	cloud.set("cloud_size", Vector2(200.0, 83.0) * scale_f * 1.35)
	cloud.set("style", [5, 5, 5, 4][_rng.randi() % 4])
	# 尺度变档 → 换深度 pass（远/中/近云的遮挡关系随尺度联动）
	var pass_name: String = "distant" if scale_f < 1.0 else ("closer" if scale_f < 1.15 else "closest")
	var holder: Node2D = _cloud_passes[pass_name]
	if cloud.get_parent() != holder:
		cloud.get_parent().remove_child(cloud)
		holder.add_child(cloud)
	var dir: float = signf(_wind) if absf(_wind) > 0.05 else 1.0
	cloud.position.x = cam_x - dir * (band_half - 300.0)
	var sky_h: float = maxf(horizon_y, 320.0)
	var band_top: float = horizon_y - sky_h * CLOUD_Y_TOP_R
	var band_h: float = sky_h * (CLOUD_Y_TOP_R - CLOUD_Y_BOT_R)
	cloud.position.y = _rng.randf_range(0.0, band_h) + band_top - (1.3 - scale_f) * 0.12 * sky_h
	c["p"] = _cloud_parallax(scale_f)
	c["scale_f"] = scale_f
	c["alpha"] = 0.0
	c["dying"] = false


## 雨强度注入（Weather 调用）：云加浓
func set_rainy(t: float) -> void:
	_rainy = clampf(t, 0.0, 1.0)


## 当前雨强度（验证脚本用）
func get_rainy() -> float:
	return _rainy
