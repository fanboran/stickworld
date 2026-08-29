class_name FxLibrary
extends RefCounted
## 粒子特效配置库 —— 效果 ID → GPUParticles2D 参数（纯代码构建，零外部资产）。
##
## ⚠️ PLACEHOLDER 素材（2026-08-22）：全部视觉参数为程序化占位实现，
## 替换清单见 docs/项目/待办事项.md「PLACEHOLDER 素材替换」——
## 后续替换方向：手绘粒子贴图（当前为运行时生成的软圆点）、逐效果调参、
## 必要时换成 .tscn 预制粒子场景。

## 一次性爆发生效 ID
const BUILD_DUST := "build_dust"      ## 建造完工尘土
const GATHER_DEBRIS := "gather_debris" ## 采集/收割飘屑
const HIT_SPARK := "hit_spark"        ## 战斗打击火花
## 环境闪光源 ID（AmbientSparkleSpawner 用，非 burst 语义）
const AMBIENT_SPARKLE := "ambient_sparkle"

## 软圆点贴图缓存：{直径: ImageTexture}
static var _dot_cache: Dictionary = {}


## 创建一次性爆发粒子节点（不进树；调用方负责 add_child + global_position）
static func create_burst(effect_id: String) -> GPUParticles2D:
	var p := GPUParticles2D.new()
	p.one_shot = true
	p.emitting = false
	p.local_coords = false
	p.z_index = WorldZ.OVERLAY_HINT
	match effect_id:
		BUILD_DUST:
			_config_dust(p)
		GATHER_DEBRIS:
			_config_debris(p)
		HIT_SPARK:
			_config_spark(p)
		AMBIENT_SPARKLE:
			_config_sparkle(p)
		_:
			push_warning("[Fx] 未知特效 ID: %s" % effect_id)
			return null
	return p


## ── 配置：建造尘土（灰褐蓬松，向外低抛后沉降）──
static func _config_dust(p: GPUParticles2D) -> void:
	p.amount = 24
	p.lifetime = 0.8
	p.explosiveness = 1.0
	p.texture = _dot(36)
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, -1, 0)
	m.spread = 85.0
	m.initial_velocity_min = 50.0
	m.initial_velocity_max = 110.0
	m.gravity = Vector3(0, 150, 0)
	m.scale_min = 0.8
	m.scale_max = 1.9
	m.color = Color(0.58, 0.52, 0.43, 0.9)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.9))
	grad.set_color(1, Color(1, 1, 1, 0.0))
	m.color_ramp = _ramp_tex(grad)
	p.process_material = m


## ── 配置：采集飘屑（绿屑上抛散落，带旋转）──
static func _config_debris(p: GPUParticles2D) -> void:
	p.amount = 18
	p.lifetime = 0.9
	p.explosiveness = 1.0
	p.texture = _dot(14)
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, -1, 0)
	m.spread = 55.0
	m.initial_velocity_min = 70.0
	m.initial_velocity_max = 140.0
	m.gravity = Vector3(0, 300, 0)
	m.angular_velocity_min = -360.0
	m.angular_velocity_max = 360.0
	m.scale_min = 0.9
	m.scale_max = 1.6
	m.color = Color(0.45, 0.68, 0.32, 0.95)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1.0))
	grad.set_color(1, Color(1, 1, 1, 0.0))
	m.color_ramp = _ramp_tex(grad)
	p.process_material = m


## ── 配置：环境闪光（四角星芒 twinkle，对齐《药剂工艺》CrystalSparks 视觉）──
static func _config_sparkle(p: GPUParticles2D) -> void:
	p.amount = 2
	p.lifetime = 0.55
	p.explosiveness = 0.9
	p.texture = _star4(24)
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, -1, 0)
	m.spread = 30.0
	m.initial_velocity_min = 8.0
	m.initial_velocity_max = 20.0
	m.gravity = Vector3(0, -6, 0)
	m.scale_min = 0.8
	m.scale_max = 1.4
	m.color = Color(1.0, 0.97, 0.88, 1.0)
	var grad := Gradient.new()
	# 星芒节奏：快速亮起 → 峰值 → 缓慢消隐到琥珀
	grad.set_color(0, Color(1, 1, 1, 0.0))
	grad.set_color(0.18, Color(1, 1, 1, 1.0))
	grad.set_color(0.55, Color(1, 0.95, 0.8, 0.85))
	grad.set_color(1, Color(1, 0.72, 0.3, 0.0))
	m.color_ramp = _ramp_tex(grad)
	p.process_material = m


## 四角星芒贴图：中心亮点 + 横竖光臂（原版药剂工艺水晶闪光的核心视觉）
## ⚠️ PLACEHOLDER：程序化近似；替换项 P1 换手绘十字光斑（可加衍射芒线）
static func _star4(diameter: int) -> Texture2D:
	var img := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var c := float(diameter) * 0.5
	for y in diameter:
		for x in diameter:
			var dx := x - c + 0.5
			var dy := y - c + 0.5
			var r := sqrt(dx * dx + dy * dy) / c
			# 中心亮点（软核）
			var core: float = clampf(1.0 - r, 0.0, 1.0)
			# 横竖光臂：靠近轴的像素亮度随距离衰减
			var arm_x: float = clampf(1.0 - absf(dy) / maxf(c * 0.22, 1.0), 0.0, 1.0) * clampf(1.0 - r, 0.0, 1.0)
			var arm_y: float = clampf(1.0 - absf(dx) / maxf(c * 0.22, 1.0), 0.0, 1.0) * clampf(1.0 - r, 0.0, 1.0)
			var base: float = pow(core, 1.5) + pow(arm_x + arm_y, 1.8) * 1.4
			var a: float = clampf(base, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var tex := ImageTexture.create_from_image(img)
	return tex


# ─────────────────────────────── 演员特效配置（原版药剂工艺 IngredientVisualEffect 数据等价）────────────────────────────────

## 星芒帧集合缓存（多方向变体，对应原版 sprites List）
static var _star_frames: Array[Texture2D] = []

## 环境闪光数据脚本（原版 IngredientVisualEffect：帧集合+物理参数+淡出）
static var ambient_sparkle_effect: IngredientVisualEffect = null


## 初始化演员特效数据（内部，幂等）
static func _ensure_ingredient_effects() -> void:
	if ambient_sparkle_effect != null:
		return
	# 多方向星芒帧（水平/垂直/对角），4 帧
	_star_frames = [_star4(24), _star4(26), _star4(22), _star4(24)]
	ambient_sparkle_effect = IngredientVisualEffect.new()
	ambient_sparkle_effect.sprites = _star_frames
	ambient_sparkle_effect.color = Color(0.95, 0.93, 0.75, 0.95)
	ambient_sparkle_effect.fade_out_after_min = 0.0
	ambient_sparkle_effect.fade_out_after_max = 0.1
	ambient_sparkle_effect.fade_out_time_min = 0.35
	ambient_sparkle_effect.fade_out_time_max = 0.6
	ambient_sparkle_effect.can_be_mirrored = true
	ambient_sparkle_effect.random_spawn_rotation = false
	ambient_sparkle_effect.random_rotation_direction = false
	ambient_sparkle_effect.rotation_speed_min = 0.0
	ambient_sparkle_effect.rotation_speed_max = 0.0
	ambient_sparkle_effect.rotation_acceleration = 0.0
	ambient_sparkle_effect.gravity_acceleration = 0.0
	ambient_sparkle_effect.speed_slowdown = 2.0
	ambient_sparkle_effect.spawn_area_radius_common = 0.0


## 演员特效静态入口：FxLibrary.spawn_ingredient(burst_effect_id, pool_node, pos)
## 对应原版 IngredientVisualEffectController.Spawn(effect, appearType, position, velocity, layer)
static func spawn_ingredient(pool: Node, effect_id: String, position: Vector2, velocity: Vector2 = Vector2.ZERO) -> void:
	_ensure_ingredient_effects()
	if pool == null or not pool.has_method("spawn_ingredient_effect"):
		push_warning("[Fx] 池节点缺少 spawn_ingredient_effect: %s" % (pool.name if pool else "null"))
		return
	match effect_id:
		AMBIENT_SPARKLE:
			pool.call("spawn_ingredient_effect", ambient_sparkle_effect, 0, position, velocity)
		_:
			push_warning("[Fx] 无演员特效配置: %s" % effect_id)


## ── 配置：打击火花（白黄高速四射，急阻尼）──
static func _config_spark(p: GPUParticles2D) -> void:
	p.amount = 16
	p.lifetime = 0.38
	p.explosiveness = 1.0
	p.texture = _star4(18)
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, -1, 0)
	m.spread = 180.0
	m.initial_velocity_min = 140.0
	m.initial_velocity_max = 280.0
	m.gravity = Vector3(0, 240, 0)
	m.damping_min = 260.0
	m.damping_max = 440.0
	m.scale_min = 0.9
	m.scale_max = 1.7
	m.color = Color(1.0, 0.92, 0.55, 1.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 0.75, 0.3, 0.0))
	m.color_ramp = _ramp_tex(grad)
	p.process_material = m


## 运行时生成软圆点贴图（径向 alpha 衰减），按直径缓存
static func _dot(diameter: int) -> Texture2D:
	if _dot_cache.has(diameter):
		return _dot_cache[diameter]
	var img := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var c := float(diameter) * 0.5
	for y in diameter:
		for x in diameter:
			var d := Vector2(x - c + 0.5, y - c + 0.5).length() / c
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	var tex := ImageTexture.create_from_image(img)
	_dot_cache[diameter] = tex
	return tex


## Gradient → GradientTexture1D（Godot4 的 color_ramp 属性要求 Texture 而非 Gradient）
static func _ramp_tex(grad: Gradient) -> Texture2D:
	var tex := GradientTexture1D.new()
	tex.gradient = grad
	return tex
