class_name SkyDecor
extends Node2D
## 天空装饰层 —— Terraria/ Kingdom 式多层视差背景（Demo 精品感主升级）。
##
## 层次（远→近，视差因子 = 跟随相机的比例，1.0=钉死屏幕 / 0.0=钉死世界）：
##   天空渐变(1.0) → 云(0.12+自漂移) → 远山(0.55) → 远树线(0.7) → 雾带(0.7)
##   → 近树线(0.88) → 游戏世界(0.0)
## 贴图均 tools/ai/gen_sky_decor.py 程序化生成；由 VillageMap/road_map._ready 挂载。

const TEX_MOUNTAINS := "res://assets/sky/mountains.png"
const TEX_TREELINE_FAR := "res://assets/sky/treeline_far.png"
const TEX_TREELINE_NEAR := "res://assets/sky/treeline_near.png"
const TEX_FOG := "res://assets/sky/fog_band.png"
const TEX_CLOUD_A := "res://assets/sky/cloud_a.png"
const TEX_CLOUD_B := "res://assets/sky/cloud_b.png"

## 地平线 y（与地图 ground_y 一致，山/树底贴地平线）
var horizon_y: float = 810.0
## 地图横向范围
var map_left: float = 0.0
var map_right: float = 8192.0

## 视差层注册表 [{node, factor, y_offset, tex_h}]
var _layers: Array = []
var _cloud_a: Sprite2D = null
var _cloud_b: Sprite2D = null
var _cam: Camera2D = null
var _cam_ready: bool = false


func _ready() -> void:
	z_index = -6
	_build_layer(TEX_MOUNTAINS, 0.55, 0.0, Color(1, 1, 1))
	_build_layer(TEX_TREELINE_FAR, 0.70, 0.0, Color(1, 1, 1))
	_build_fog()
	_build_layer(TEX_TREELINE_NEAR, 0.88, 0.0, Color(1, 1, 1))
	_build_clouds()
	# 相机引用惰性获取（GameRoot.CameraRig）
	call_deferred("_find_camera")


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
	_cloud_a = _make_cloud(TEX_CLOUD_A, Vector2(map_left + 1200.0, horizon_y - 620.0), 6.0, 0.55)
	_cloud_b = _make_cloud(TEX_CLOUD_B, Vector2(map_left + 4200.0, horizon_y - 740.0), -4.0, 0.42)


func _make_cloud(tex_path: String, pos: Vector2, speed: float, factor: float) -> Sprite2D:
	if not ResourceLoader.exists(tex_path):
		return null
	var spr := Sprite2D.new()
	spr.texture = load(tex_path)
	spr.position = pos
	spr.set_meta("drift_speed", speed)
	add_child(spr)
	_layers.append({"node": spr, "factor": factor})
	return spr


func _find_camera() -> void:
	# 优先 GameRoot.CameraRig；任何环境兜底取当前激活相机（测试/特殊场景层级不定）
	var gr := get_tree().root.get_node_or_null("GameRoot")
	if gr != null:
		_cam = gr.get_node_or_null("CameraRig") as Camera2D
	if _cam == null:
		_cam = get_viewport().get_camera_2d()
	_cam_ready = true
	# 立即对齐一次视差，防首帧跳变
	if _cam != null:
		_apply_parallax()


func _process(delta: float) -> void:
	if _cam_ready and _cam != null and is_instance_valid(_cam):
		_apply_parallax()
	_update_clouds(delta)


## 视差：层 x = 相机 x × (1 - factor)（factor=0 世界钉死 / 1 屏幕钉死）
func _apply_parallax() -> void:
	var cam_x: float = _cam.global_position.x
	for layer in _layers:
		var node: Node2D = layer["node"]
		if node == null or not is_instance_valid(node):
			continue
		var factor: float = float(layer["factor"])
		node.position.x = cam_x * (1.0 - factor) + _cloud_base(layer)


## 云层额外保留自漂移的相对偏移（漂移写在 node.meta 累加，基础偏移由视差管）
func _cloud_base(_layer: Dictionary) -> float:
	return 0.0


func _update_clouds(delta: float) -> void:
	for cloud in [_cloud_a, _cloud_b]:
		if cloud == null or not is_instance_valid(cloud):
			continue
		var spd: float = cloud.get_meta("drift_speed", 5.0)
		cloud.position.x += spd * delta
		var half_w: float = cloud.texture.get_width() * 0.5
		var lo: float = map_left - half_w - 1000.0
		var hi: float = map_right + half_w + 1000.0
		if cloud.position.x > hi:
			cloud.position.x = lo
		elif cloud.position.x < lo:
			cloud.position.x = hi
