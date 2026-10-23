extends RefCounted
## hd2d_sky_celestial.gd —— HD-2D 天幕天体域组件（hd2d_world 职责拆分）。
##
## 职责：贴图天幕 quad（相机子节点，无穷远语义）与日月天体弧线（复刻 2D
## SkyStars 公式：线性横穿 + 抛物线高度 + 晨昏放大；太阳=屏幕后处理炫光、
## 月亮=实心小盘）、天幕/清屏色昼夜统一写（_set_sky_look，光照档出口调用）、
## 漂移云牌装配口（_place_clouds，云本体在 clouds/ 组件）。
## 天幕色档 SKY_BLUE/SKY_NIGHT 留在门面（门面 _build_world 与光照域共用），
## 经 w 读取。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

var w: Node3D = null   # 门面回引（_ready 注入；禁循环 preload 故不标门面类型）

## 漂移云牌组件（_place_clouds 装配；节点即 Clouds 容器）
const Hd2dClouds := preload("res://modules/hd2d/scripts/clouds/hd2d_clouds.gd")

## 月亮半径（格）：2D SkyStars 月亮 r=26px ÷ 32px/格（2D 月亮本就是实心白盘）
const MOON_DISC_R: float = 26.0 / 32.0
## 弧线参数（SkyStars Terraria Main.DrawSunAndMoon 直译，屏幕比例口径）：
## 横穿 0.65 视宽（1250/1920）、正午高 0.685 半视高（(540-170)/540）、
## 晨昏下沉 0.463 半视高（250/540）、晨昏放大 scale=1.2-0.4p
const CELESTIAL_SPAN_FRAC: float = 0.65
const CELESTIAL_NOON_FRAC: float = 370.0 / 540.0
const CELESTIAL_DROP_FRAC: float = 250.0 / 540.0
const SUN_HOUR_START: float = 5.0
const SUN_HOUR_END: float = 21.0
const MOON_HOUR_START: float = 19.0
const MOON_HOUR_END: float = 29.0   # 跨午夜 = 次日 5 时（SkyStars 同窗）

## 天幕与天体的私有节点/材质（门面与其他组件不消费）
var _sky_quad: MeshInstance3D      # 贴图天幕（相机子 quad，见 _build_sky）
var _sky_quad_mat: StandardMaterial3D
var _moon_disc: MeshInstance3D     # 月亮小盘（2D 同款实心白盘，弧线运行）
var _moon_disc_mat: StandardMaterial3D


## 贴图天幕 + 屏幕后处理太阳/月亮盘（创始人 2026-09-16：程序化天空 → 贴图天空）。
## 天幕 = 相机子 quad：正交视锥截面恒定（zoom 0.25..8 最大约 240×135 格），
## 340×220 全缩放档覆盖；深度 120 在地面远端/楼群（≈52~57）之后——地平线
## 分界由深度测试天然压出，quad 不随镜头平移（无穷远语义）。太阳不摆场景
## 贴片，弧线位置驱动屏幕后处理炫光（_publish_sun_uv），复刻 2D SkyStars
## 弧线公式（线性横穿+抛物线高度+晨昏放大），主光方向仍按档位固定（渲染确定性）。
func _build_sky() -> void:
	_sky_quad = MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(340.0, 220.0)
	_sky_quad.mesh = qm
	_sky_quad_mat = StandardMaterial3D.new()
	_sky_quad_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sky_quad_mat.albedo_color = w.SKY_BLUE
	# 天幕在雾程之外，不吃雾（否则 build 期默认雾档会把天幕整个洗成雾色）
	_sky_quad_mat.disable_fog = true
	_sky_quad.material_override = _sky_quad_mat
	_sky_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sky_quad.name = "SkyBackdrop"
	_sky_quad.position = Vector3(0.0, 0.0, -120.0)
	w._cam.add_child(_sky_quad)
	# 太阳 = 屏幕后处理炫光（创始人 2026-09-16：就是 PostProcessLayer 那颗
	# 屏幕太阳，要它沿弧线到处移动）——场景里不摆任何太阳贴片，弧线位置
	# 每帧经 _publish_sun_uv 写进后处理层 sun_uv；夜间由月盘接管（见下）
	# 月亮 = 实心小盘（2D SkyStars 月亮本就是实心白盘；月相环面暂不做——
	# 盘面过小读不出，创始人要再加）
	_moon_disc = MeshInstance3D.new()
	var sd := SphereMesh.new()
	sd.radius = MOON_DISC_R
	sd.height = MOON_DISC_R * 2.0
	_moon_disc.mesh = sd
	_moon_disc_mat = StandardMaterial3D.new()
	_moon_disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_moon_disc_mat.albedo_color = Color(0.95, 0.97, 1.0)
	_moon_disc_mat.emission_enabled = true
	_moon_disc_mat.emission = Color(0.85, 0.9, 1.0)
	_moon_disc_mat.emission_energy_multiplier = 1.6
	_moon_disc_mat.disable_fog = true
	_moon_disc.material_override = _moon_disc_mat
	_moon_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon_disc.name = "MoonDisc"
	_moon_disc.visible = false
	_sky_quad.add_child(_moon_disc)
	_update_celestial()


## 天体弧线逐帧更新（宿主 _process 驱动；时刻源 WorldState.game_time，缺失按正午）。
## 太阳（5..21 时）与月亮（19..29 时）共用弧线：屏幕后处理炫光太阳全程跟随，
## 夜间月盘接管天体读法
func _update_celestial() -> void:
	if w._cam == null:
		return
	var hour: float = 12.0
	if WorldState != null and WorldState.game_time > 0.0:
		hour = WorldState.game_time
	var vp: Vector2 = w._cam.get_viewport().get_visible_rect().size
	var half_w: float = w._cam.size * 0.5
	var half_h: float = half_w * vp.y / maxf(vp.x, 1.0)
	var lum: float = EnvironmentAPI.sample_sky_bg_color(hour).get_luminance()
	_moon_disc.visible = false
	var t: float = _celestial_traverse(hour, SUN_HOUR_START, SUN_HOUR_END)
	var sun_alpha: float = clampf((lum - 0.25) / 0.30, 0.0, 1.0) if t >= 0.0 else 0.0
	if t >= 0.0 and sun_alpha > 0.02:
		_publish_sun_uv(_celestial_uv(half_w, half_h, t))
		return
	# 月亮：白盘冷光，夜天越黑越显（SkyStars _sky_gate 同式）；炫光太阳跟随月位
	var mt: float = _celestial_traverse(hour, MOON_HOUR_START, MOON_HOUR_END)
	var gate: float = clampf((0.55 - lum) * 4.0, 0.0, 1.0)
	if mt >= 0.0 and gate > 0.02:
		_moon_disc_style(half_w, half_h, mt, gate)
		_publish_sun_uv(_celestial_uv(half_w, half_h, mt))


## 天体弧线屏幕位（UV）：x = (t−0.5)×0.65 视宽、y = 抛物线高度，换算 0~1 屏幕坐标
func _celestial_uv(half_w: float, half_h: float, t: float) -> Vector2:
	var p := pow(absf(t * 2.0 - 1.0), 2.0)
	var x := (t - 0.5) * CELESTIAL_SPAN_FRAC * half_w * 2.0
	var y := (CELESTIAL_NOON_FRAC - p * CELESTIAL_DROP_FRAC) * half_h
	return Vector2(0.5 + x / (half_w * 2.0), 0.5 - y / (half_h * 2.0))


## 屏幕后处理太阳（PostProcessLayer 的 glow+streak+ghost）钉到弧线位置——
## 正式链路由 SystemSetup 装配该层，这里只驱动位置；独立渲染（shots）没有
## SystemSetup，自建一层保证验收图与正式是同一颗屏幕太阳
func _publish_sun_uv(uv: Vector2) -> void:
	var layer: Node = w.get_tree().get_first_node_in_group("post_process_layer")
	if layer == null:
		layer = PostProcessLayer.new()
		layer.name = "PostProcessLayer"
		w.add_child(layer)
	if layer.has_method("set_sun_uv"):
		layer.set_sun_uv(uv)


## 月亮盘摆位（小盘冷白；实心白盘是 2D SkyStars 月亮同款语义，月相环面暂不做）
func _moon_disc_style(half_w: float, half_h: float, t: float, gate: float) -> void:
	var p := pow(absf(t * 2.0 - 1.0), 2.0)
	_moon_disc.visible = true
	_moon_disc.position = Vector3(
			(t - 0.5) * CELESTIAL_SPAN_FRAC * half_w * 2.0,
			(CELESTIAL_NOON_FRAC - p * CELESTIAL_DROP_FRAC) * half_h, 1.0)
	_moon_disc.scale = Vector3.ONE * (1.2 - 0.4 * p)
	_moon_disc_mat.emission_energy_multiplier = 1.6 * gate


## 天体横穿进度（0..1；不在时段 -1；跨午夜窗见 SkyStars._traverse 同式直译——
## 跨模块只许引 api.gd，12 行公式就地复制）
static func _celestial_traverse(hour: float, start_h: float, end_h: float) -> float:
	if hour >= start_h and hour <= end_h:
		return (hour - start_h) / (end_h - start_h)
	if end_h > 24.0 and hour < end_h - 24.0:
		return (hour + 24.0 - start_h) / (end_h - start_h)
	return -1.0


## 天幕/清屏色按昼夜档统一写（光照域 _apply_light 出口）
func _set_sky_look(c: Color) -> void:
	if _sky_quad_mat != null and is_instance_valid(_sky_quad_mat):
		_sky_quad_mat.albedo_color = c
	w._env.background_color = c


## 漂移云牌：装配与漂移随云组件（hd2d_clouds.gd，节点即 Clouds 容器——
## 小地图烘焙按容器整体归排除层）。首次调用创建组件并触发云池异步烘焙
##（headless 下 frame_post_draw 永不发射，协程悬置于首朵——与拆分前同口径）。
func _place_clouds() -> void:
	if w._cloud_root == null or not is_instance_valid(w._cloud_root):
		w._cloud_root = Hd2dClouds.new()
		w._cloud_root.name = w.CLOUD_ROOT_NAME
		w.add_child(w._cloud_root)
	w._cloud_root.place(w)
