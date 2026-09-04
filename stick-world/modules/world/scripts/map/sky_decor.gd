class_name SkyDecor
extends Node2D
## 天空装饰层 —— 远山剪影（平铺）+ 两团缓移云（横向漂移回绕）。
##
## 由 VillageMap._ready 挂载到地图根（z_index 负值：永远在地面/建筑之后）。
## 贴图由 tools/ai/gen_sky_decor.py 程序化生成（低多边形山脊 + 大气透视渐变）。

const MOUNTAINS_TEX := "res://assets/sky/mountains.png"
const CLOUD_A_TEX := "res://assets/sky/cloud_a.png"
const CLOUD_B_TEX := "res://assets/sky/cloud_b.png"

## 地平线 y（与地图 ground_y 一致，山底贴地平线）
var horizon_y: float = 810.0
## 地图横向范围（平铺与云回绕用）
var map_left: float = 0.0
var map_right: float = 8192.0

var _cloud_a: Sprite2D = null
var _cloud_b: Sprite2D = null


func _ready() -> void:
	z_index = -6
	_build_mountains()
	_build_clouds()


## 远山：Sprite2D region 平铺整个地图宽，底边贴地平线
func _build_mountains() -> void:
	if not ResourceLoader.exists(MOUNTAINS_TEX):
		return
	var spr := Sprite2D.new()
	spr.name = "Mountains"
	spr.texture = load(MOUNTAINS_TEX)
	var tex_h: float = spr.texture.get_height()
	spr.centered = false
	spr.position = Vector2(map_left, horizon_y - tex_h)
	spr.region_enabled = true
	spr.region_rect = Rect2(0, 0, map_right - map_left, tex_h)
	add_child(spr)


func _build_clouds() -> void:
	_cloud_a = _make_cloud(CLOUD_A_TEX, Vector2(map_left + 1200.0, horizon_y - 560.0), 6.0)
	_cloud_b = _make_cloud(CLOUD_B_TEX, Vector2(map_left + 4200.0, horizon_y - 680.0), -4.0)


func _make_cloud(tex_path: String, pos: Vector2, speed: float) -> Sprite2D:
	if not ResourceLoader.exists(tex_path):
		return null
	var spr := Sprite2D.new()
	spr.texture = load(tex_path)
	spr.position = pos
	spr.set_meta("drift_speed", speed)
	add_child(spr)
	return spr


func _process(delta: float) -> void:
	# 云团缓慢漂移，出界从另一侧回绕
	for cloud in [_cloud_a, _cloud_b]:
		if cloud == null or not is_instance_valid(cloud):
			continue
		var spd: float = cloud.get_meta("drift_speed", 5.0)
		cloud.position.x += spd * delta
		var half_w: float = cloud.texture.get_width() * 0.5
		if cloud.position.x > map_right + half_w:
			cloud.position.x = map_left - half_w
		elif cloud.position.x < map_left - half_w:
			cloud.position.x = map_right + half_w
