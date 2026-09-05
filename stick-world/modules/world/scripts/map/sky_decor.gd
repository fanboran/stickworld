class_name SkyDecor
extends Node2D
## 天空装饰层 —— Terraria/ Kingdom 式多层视差背景（Demo 精品感主升级）。
##
## 层次（远→近；factor = 内容相对相机的扫动速率，1.0=钉死世界（同前景）/
## 0.0=钉死屏幕（无限远），层位移 = cam_x × (1 - factor)）：
##   星野+月亮(0.08，夜现) → 飞鸟群(0.35，昼现) → 远山(0.55) → 远树线(0.7)
##   → 雾带(0.7) → 近树线(0.88) → 云(0.55/0.42+自漂移) → 游戏世界(1.0)
## 贴图均 tools/ai/gen_sky_decor.py 程序化生成；星野/飞鸟为程序绘制零贴图；
## 由 VillageMap/road_map._ready 挂载。

const SkyStarsScript := preload("res://modules/world/scripts/map/sky_stars.gd")
const SkyBirdsScript := preload("res://modules/world/scripts/map/sky_birds.gd")
const TEX_MOUNTAINS := "res://assets/sky/mountains.png"
const TEX_TREELINE_FAR := "res://assets/sky/treeline_far.png"
const TEX_TREELINE_NEAR := "res://assets/sky/treeline_near.png"
const TEX_FOG := "res://assets/sky/fog_band.png"
const CLOUD_TEXS: Array = [
	"res://assets/sky/cloud_a.png",
	"res://assets/sky/cloud_b.png",
	"res://assets/sky/cloud_c.png",
]

## 地平线 y（与地图 ground_y 一致，山/树底贴地平线）
var horizon_y: float = 810.0
## 地图横向范围
var map_left: float = 0.0
var map_right: float = 8192.0

## 视差层注册表 [{node, factor, y_offset, tex_h}]
var _layers: Array = []
## Terraria 式云池（Cloud.cs 逆向）：尺寸=深度（scale 分档视差）、全局风驱动、
## Alpha 渐入渐出软生灭、极慢摇摆、云色继承天空光照色（夜里云自动变暗）
var _clouds: Array = []
## 全局风（缓慢起伏；Terraria windSpeedCurrent 的简化版）
var _wind: float = 0.9
var _wind_t: float = 0.0
## 上一帧相机 x（云按各自视差被相机回拉，Cloud.cs:321 同构）
var _last_cam_x: float = 0.0
## 环境系统（云色随昼夜）
var _env: Node = null
var _rng := RandomNumberGenerator.new()
var _cam: Camera2D = null
var _cam_ready: bool = false

## 云池规模（Terraria 200 槽 rand(200) 数量；我们屏幅小，12 朵足够密度）
const CLOUD_POOL: int = 12
## 云出生带（相对地平线向上；远云更高——小云再上移）
const CLOUD_Y_TOP: float = 190.0
const CLOUD_Y_BOTTOM: float = 640.0


func _ready() -> void:
	z_index = -6
	_build_stars()
	_build_birds()
	_build_layer(TEX_MOUNTAINS, 0.55, 0.0, Color(1, 1, 1))
	_build_layer(TEX_TREELINE_FAR, 0.70, 0.0, Color(1, 1, 1))
	_build_fog()
	_build_layer(TEX_TREELINE_NEAR, 0.88, 0.0, Color(1, 1, 1))
	_build_clouds()
	# 相机引用惰性获取（GameRoot.CameraRig）
	call_deferred("_find_camera")


## 星野+月亮（最底层、无限远；夜间淡入，见 sky_stars.gd）
func _build_stars() -> void:
	var stars: Node2D = SkyStarsScript.new()
	stars.name = "Stars"
	add_child(stars)
	_layers.append({"node": stars, "factor": SkyStarsScript.FACTOR})


## 远空飞鸟群（星野之上山层之下，会被山脊遮挡出纵深；昼间活动，见 sky_birds.gd）
func _build_birds() -> void:
	var birds: Node2D = SkyBirdsScript.new()
	birds.name = "Birds"
	add_child(birds)
	_layers.append({"node": birds, "factor": SkyBirdsScript.FACTOR})


## 构建一个视差层：region 平铺超宽（两端冗余覆盖视差位移），底边贴地平线
func _build_layer(tex_path: String, factor: float, y_extra: float, tint: Color) -> void:
	if not ResourceLoader.exists(tex_path):
		return
	var spr := Sprite2D.new()
	spr.texture = load(tex_path)
	var tex_h: float = spr.texture.get_height()
	spr.centered = false
	spr.position = Vector2(0, horizon_y - tex_h + y_extra)
	spr.modulate = tint
	# 平铺宽度 = 地图宽 + 两端视差冗余（factor 越小位移越大）
	var slack: float = (1.0 - factor) * 4000.0 + 400.0
	spr.region_enabled = true
	spr.region_rect = Rect2(map_left - slack, 0, (map_right - map_left) + slack * 2.0, tex_h)
	add_child(spr)
	_layers.append({"node": spr, "factor": factor})


## 雾带：压在远树线与近树线之间（大气透视），随 0.7 层视差
func _build_fog() -> void:
	if not ResourceLoader.exists(TEX_FOG):
		return
	var spr := Sprite2D.new()
	spr.texture = load(TEX_FOG)
	var tex_h: float = spr.texture.get_height()
	spr.centered = false
	spr.position = Vector2(0, horizon_y - tex_h + 6.0)
	spr.modulate = Color(1, 1, 1, 0.75)
	var slack: float = 2000.0
	spr.region_enabled = true
	spr.region_rect = Rect2(map_left - slack, 0, (map_right - map_left) + slack * 2.0, tex_h)
	add_child(spr)
	_layers.append({"node": spr, "factor": 0.70})


func _build_clouds() -> void:
	_rng.seed = 20260905
	for i in CLOUD_POOL:
		var tex_path: String = CLOUD_TEXS[i % CLOUD_TEXS.size()]
		if not ResourceLoader.exists(tex_path):
			continue
		var spr := Sprite2D.new()
		spr.texture = load(tex_path)
		var scale_f: float = _rng.randf_range(0.7, 1.3)
		spr.scale = Vector2(scale_f, scale_f)
		# 出生带：远云（小）更高——Terraria 小云再上移的同构；
		# 初始分布相机出生带（x≈0 一带），之后由风与相机回拉自然演进
		var y: float = _rng.randf_range(CLOUD_Y_TOP, CLOUD_Y_BOTTOM) \
				- (1.3 - scale_f) * 120.0
		spr.position = Vector2(_rng.randf_range(-1200.0, 1200.0), y)
		add_child(spr)
		_clouds.append({
			"node": spr,
			"p": _cloud_parallax(scale_f),   # Cloud.GetParallax 直译
			"rot": 0.0,
			"rot_spd": 0.0,
			"alpha": _rng.randf_range(0.35, 0.85),  # 首批直接半亮，后续渐入
			"dying": false,
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


func _process(delta: float) -> void:
	if _cam_ready and _cam != null and is_instance_valid(_cam):
		_apply_parallax()
	# 风：缓慢正弦起伏（周期 ~2 分钟，双向漂）
	_wind_t += delta
	_wind = sin(_wind_t * 0.05) * 1.1
	_update_clouds(delta)
	_tint_clouds()


## 视差：层 x = 相机 x × (1 - factor)（factor=0 屏幕钉死=无限远 / 1 世界钉死=前景）
func _apply_parallax() -> void:
	var cam_x: float = _cam.global_position.x
	for layer in _layers:
		var node: Node2D = layer["node"]
		if node == null or not is_instance_valid(node):
			continue
		var factor: float = float(layer["factor"])
		node.position.x = cam_x * (1.0 - factor)


## Terraria 云更新（Cloud.Update 直译；云是相机跟随带内的屏域实体，
## 出带 ±1400px 软退场——任意取景密度恒定，不随全图摊薄）
func _update_clouds(delta: float) -> void:
	var cam_x: float = _cam.global_position.x if _cam != null and is_instance_valid(_cam) else 0.0
	var cam_move: float = cam_x - _last_cam_x
	_last_cam_x = cam_x
	for c in _clouds:
		var spr: Sprite2D = c["node"]
		if spr == null or not is_instance_valid(spr):
			continue
		var p: float = c["p"]
		# 风驱动 ×9×视差（Cloud.cs:401）+ 相机横移按视差回拉（Cloud.cs:321）
		spr.position.x += _wind * 9.0 * p * delta * 60.0
		spr.position.x -= cam_move * p
		# 摇摆：rSpeed 随机游走 ±0.0002/帧，rotation 夹 ±0.02 rad
		c["rot_spd"] = clampf(float(c["rot_spd"]) + _rng.randf_range(-0.0002, 0.00022), -0.0002, 0.0002)
		c["rot"] = clampf(float(c["rot"]) + float(c["rot_spd"]) * delta * 60.0, -0.02, 0.02)
		spr.rotation = c["rot"]
		# 软生灭：出带渐隐 → 对侧重生渐显
		if c["dying"]:
			c["alpha"] = float(c["alpha"]) - 0.06 * delta
			if float(c["alpha"]) <= 0.0:
				_respawn_cloud(c, cam_x)
		else:
			c["alpha"] = minf(float(c["alpha"]) + 0.06 * delta, 0.92)
			if spr.position.x < cam_x - 1400.0 or spr.position.x > cam_x + 1400.0:
				c["dying"] = true


## 云重生：风向对侧入场，重掷尺度（视差档随之变化）与出生带
func _respawn_cloud(c: Dictionary, cam_x: float) -> void:
	var spr: Sprite2D = c["node"]
	var scale_f: float = _rng.randf_range(0.7, 1.3)
	var tex_path: String = CLOUD_TEXS[_rng.randi() % CLOUD_TEXS.size()]
	if ResourceLoader.exists(tex_path):
		spr.texture = load(tex_path)
	spr.scale = Vector2(scale_f, scale_f)
	var dir: float = signf(_wind) if absf(_wind) > 0.05 else 1.0
	spr.position.x = cam_x - dir * 1350.0
	spr.position.y = _rng.randf_range(CLOUD_Y_TOP, CLOUD_Y_BOTTOM) - (1.3 - scale_f) * 120.0
	c["p"] = _cloud_parallax(scale_f)
	c["alpha"] = 0.0
	c["dying"] = false
	c["rot"] = 0.0
	c["rot_spd"] = 0.0


## 云色继承天空光照（Cloud.cloudColor：bgColor×scale×alpha 同构——夜里云
## 自动变暗、黄昏自动染暖，零特判）
func _tint_clouds() -> void:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env()
		if _env == null:
			return
	if not _env.has_method("get_current_light_color"):
		return
	var light: Color = _env.get_current_light_color()
	for c in _clouds:
		var spr: Sprite2D = c["node"]
		if spr != null and is_instance_valid(spr):
			spr.modulate = Color(light.r, light.g, light.b, float(c["alpha"]))


func _find_env() -> Node:
	var env := get_tree().root.get_node_or_null("GameRoot/EnvironmentSystem")
	if env != null:
		return env
	var a := get_parent()
	while a != null:
		var e := a.get_node_or_null("EnvironmentSystem")
		if e != null:
			return e
		a = a.get_parent()
	return null
