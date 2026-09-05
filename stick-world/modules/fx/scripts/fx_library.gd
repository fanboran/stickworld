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
const MAGIC_BLAST := "magic_blast"    ## 法术爆炸（Magikill 施法命中点，紫白星芒环形爆发）
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
		MAGIC_BLAST:
			_config_magic_blast(p)
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


## ── 配置：法术爆炸（Magikill 命中点：紫白星芒大范围环形爆发，急阻尼定住成形）──
static func _config_magic_blast(p: GPUParticles2D) -> void:
	p.amount = 30
	p.lifetime = 0.55
	p.explosiveness = 1.0
	p.texture = _star4(26)
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, -1, 0)
	m.spread = 180.0
	m.initial_velocity_min = 160.0
	m.initial_velocity_max = 340.0
	m.gravity = Vector3(0, 120, 0)
	m.damping_min = 300.0
	m.damping_max = 520.0
	m.scale_min = 1.0
	m.scale_max = 2.2
	m.color = Color(0.78, 0.62, 1.0, 1.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1.0))
	grad.set_color(0.4, Color(0.85, 0.7, 1.0, 0.9))
	grad.set_color(1, Color(0.5, 0.3, 0.8, 0.0))
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


# ─────────────────────────────── 伤害飘字（Demo 打磨包）────────────────────────────────

## 飘字复用池（战斗性能优化：混战每秒几十次 Label.new+Tween 创建销毁，
## 池化后 Label 只建一次反复改文本/位置重飘；场景切换后失效引用自动丢弃）
static var _damage_text_pool: Array = []

## 在目标头顶飘伤害数字（白=普通 / 金=暴击·爆头）；出生弹性回落 + 恒定屏上尺寸
## （字号/偏移按相机 zoom 反向放大并钳制，拉远观战大军时数字不缩成蚂蚁）；
## 0.7s 上浮淡出后回池。combat 管线（DamagePipeline.apply）结算后调用；fx 挂目标宿主层，不进战斗逻辑。
static func spawn_damage_text(tree: SceneTree, pos: Vector2, amount: float, crit: bool) -> void:
	if tree == null or tree.current_scene == null:
		return
	var label: Label = null
	if not _damage_text_pool.is_empty():
		label = _damage_text_pool.pop_back()
		if not is_instance_valid(label):
			label = null
	if label == null:
		label = Label.new()
		label.z_index = 90
		# deferred：伤害结算发生在物理帧内，同帧改树会挤掉其他节点的帧处理（血条时序交扰）
		tree.current_scene.add_child.call_deferred(label)
	# 恒定屏上尺寸：基准字号除以相机 zoom 再钳制；inv_zoom 同比例缩放偏移量
	var cam := tree.root.get_viewport().get_camera_2d()
	var zoom: float = clampf(cam.zoom.x if cam != null else 1.0, 0.35, 3.0)
	var base_px: float = 34.0 if crit else 24.0
	var font_px: int = int(round(clampf(base_px / zoom, 22.0, 56.0)))
	var inv_zoom: float = float(font_px) / base_px
	label.visible = true
	label.text = str(int(round(amount)))
	label.add_theme_font_size_override("font_size", font_px)
	label.add_theme_constant_override("outline_size", clampi(font_px / 4, 4, 12))
	if crit:
		label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.35))
		label.add_theme_color_override("font_outline_color", Color(0.45, 0.2, 0.0, 0.9))
	else:
		label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	# current_scene 在原点，local==global；随机水平偏移防数字完全重叠
	label.position = pos + Vector2(randf_range(-16.0, 16.0) * inv_zoom, -62.0 * inv_zoom)
	label.modulate.a = 1.0
	label.rotation = 0.0
	# 出生弹性：放大起手回落带轻微回弹（TRANS_BACK 过冲）；暴击冲击更强并带一点歪斜回正
	label.reset_size()
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2.ONE * (1.55 if crit else 1.3)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "scale", Vector2.ONE, 0.18 if crit else 0.13) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	if crit:
		label.rotation = randf_range(-0.09, 0.09)
		tween.tween_property(label, "rotation", 0.0, 0.22).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "position:y", label.position.y - 52.0 * inv_zoom, 0.7).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.45).set_delay(0.25)
	tween.chain().tween_callback(func() -> void:
		if is_instance_valid(label):
			label.visible = false
		_damage_text_pool.append(label))


## 挥砍剑光弧 —— 命中帧在攻击者朝向画一道渐隐弧光（白/金），0.16s 消散。
## angle_rad: 弧光朝向（世界角）；flip_v: 攻击者面朝左时镜像弧线。
static func spawn_slash_arc(tree: SceneTree, pos: Vector2, angle_rad: float, crit: bool = false) -> void:
	if tree == null or tree.current_scene == null:
		return
	var arc := Polygon2D.new()
	var seg: int = 20
	var r0: float = 14.0
	var r1: float = 44.0
	var spread: float = 2.2  # 弧张角（rad，约 126°）
	var pts := PackedVector2Array()
	var colors := PackedColorArray()
	var base := Color(1.0, 0.97, 0.85, 0.85) if crit else Color(0.95, 0.97, 1.0, 0.7)
	for i in seg + 1:
		var t: float = float(i) / float(seg)
		var a: float = angle_rad - spread * 0.5 + spread * t
		var dir := Vector2(cos(a), sin(a))
		pts.append(dir * r1)
		pts.append(dir * r0)
		# 外缘亮、内缘淡（顶点色渐变，成对推入：外/内）
		colors.append(Color(base.r, base.g, base.b, base.a))
		colors.append(Color(base.r, base.g, base.b, base.a * 0.15))
	arc.polygon = pts
	arc.vertex_colors = colors
	arc.position = pos
	arc.rotation = 0.0
	arc.z_index = 85
	tree.current_scene.add_child(arc)
	var tw := arc.create_tween()
	tw.set_parallel(true)
	tw.tween_property(arc, "scale", Vector2(1.25, 1.25), 0.16)
	tw.tween_property(arc, "modulate:a", 0.0, 0.16)
	tw.chain().tween_callback(arc.queue_free)


## 胜利彩带 —— 全屏顶部撒落彩色纸屑（胜利画面专用，3s 自然落尽后自毁）。
static func spawn_confetti(tree: SceneTree) -> void:
	if tree == null or tree.current_scene == null:
		return
	var host := Node2D.new()
	host.name = "Confetti"
	host.z_index = 95
	tree.current_scene.add_child(host)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(Time.get_ticks_msec())
	var palette: Array[Color] = [
		Color(1.0, 0.84, 0.4), Color(0.95, 0.5, 0.4), Color(0.5, 0.85, 0.6),
		Color(0.5, 0.75, 0.95), Color(0.85, 0.6, 0.95),
	]
	for i in 80:
		var rect := ColorRect.new()
		rect.color = palette[i % palette.size()]
		rect.size = Vector2(rng.randf_range(4, 8), rng.randf_range(8, 14))
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.position = Vector2(rng.randf_range(0, 1920), rng.randf_range(-560, -16))
		rect.rotation = rng.randf_range(0, TAU)
		host.add_child(rect)
		var fall: float = rng.randf_range(2.2, 3.4)
		var sway: float = rng.randf_range(30, 90)
		var spin: float = rng.randf_range(-3.0, 3.0)
		var tw := rect.create_tween()
		tw.set_parallel(true)
		tw.tween_property(rect, "position:y", 1120.0, fall).set_ease(Tween.EASE_IN)
		tw.tween_property(rect, "position:x", rect.position.x + sway, fall)
		tw.tween_property(rect, "rotation", rect.rotation + spin, fall)
	var sweep := host.create_tween()
	sweep.tween_interval(3.8)
	sweep.tween_callback(host.queue_free)
