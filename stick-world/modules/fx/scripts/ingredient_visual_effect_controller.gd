class_name IngredientVisualEffectController
extends Node2D
## 演员视觉特效执行器 —— 完整移植《药剂工艺》IngredientVisualEffectController.cs
##
## 行为对应原版（逐行）：
##   Update(): 生命周期终止→回池；速度受重力、衰减；旋转速度加速度；
##   淡出由 modulate.a 映射（原版 ShaderEffect().SetEffectValue() 等价）。
## 池化：静态 Queue 复用，Spawn 取池、超时回池（原版 effectsPool）。
## 默认由 FxPool 作为子节点预建（对应原版 Managers.Game.InitializeEffects）。

var sprite: Sprite2D = null

## 静止数据（IngredientVisualEffect 传入）
var effect_data: IngredientVisualEffect = null
var appear_type: int = 0  # 0=Common, 1=Explosion
var fade_out_after: float = 0.0
var fade_out_time: float = 0.0
var life_time: float = 0.0
var rotation_speed: float = 0.0
var rotation_acceleration: float = 0.0
var speed: Vector2 = Vector2.ZERO
var gravity_acceleration: float = 0.0
var speed_slowdown: float = 0.0

## 池（原版 Queue<IngredientVisualEffectController>）
var pool: Array[IngredientVisualEffectController] = []


static func _new_effect(effect: IngredientVisualEffect) -> IngredientVisualEffectController:
	var c := IngredientVisualEffectController.new()
	var spr := Sprite2D.new()
	spr.name = "Sprite"
	c.add_child(spr)
	c.sprite = spr
	c._apply(effect)
	return c


## 从池取一个控制器并激活（原版 Spawn）
static func spawn(pool_owner: Node, effect: IngredientVisualEffect, appear_type: int,
		position: Vector2, velocity: Vector2, z_index: int) -> void:
	if pool_owner == null or effect == null:
		return
	var c: IngredientVisualEffectController = null
	# 先找池里的空闲实例（通过 owner 的回池登记的数组）
	if "take_from_pool" in pool_owner:
		c = pool_owner.take_from_pool()
	if c == null:
		c = _new_effect(effect)
	# 应用参数
	c.effect_data = effect
	c.appear_type = appear_type
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# 原版：Random.Range(fadeOutAfter.x, fadeOutAfter.y)
	c.fade_out_after = rng.randf_range(effect.fade_out_after_min, effect.fade_out_after_max)
	c.fade_out_time = rng.randf_range(effect.fade_out_time_min, effect.fade_out_time_max)
	c.life_time = 0.0
	c.sprite.color = effect.color
	if effect.random_spawn_rotation:
		c.rotation = rng.randf_range(0.0, TAU)
	var dir := -1 if (effect.random_rotation_direction and rng.randf() < 0.5) else 1
	c.rotation_speed = dir * rng.randf_range(effect.rotation_speed_min, effect.rotation_speed_max)
	c.rotation_acceleration = dir * effect.rotation_acceleration
	c.sprite.flip_h = (effect.can_be_mirrored and rng.randf() < 0.5)
	# 出生位置与速度（原版 ApplyToEffectController switch）
	var radius: float = 0.0
	if appear_type == 0:
		radius = rng.randf_range(0.0, effect.spawn_area_radius_common)
		var f := rng.randf_range(0.0, TAU)
		c.position = position + Vector2(radius * cos(f), radius * sin(f))
		c.speed = Vector2(0, -3) + velocity
		c.speed_slowdown = effect.speed_slowdown
	else:
		radius = rng.randf_range(0.0, effect.spawn_area_radius_explosion)
		var f := rng.randf_range(0.0, TAU)
		c.position = position + Vector2(radius * cos(f), radius * sin(f))
		var speed_mag := 4.0
		c.speed = Vector2(speed_mag * cos(f), speed_mag * sin(f)) + velocity
		c.speed_slowdown = effect.speed_slowdown_explosion
	c.gravity_acceleration = effect.gravity_acceleration
	c.sprite.texture = effect.sprites[rng.randi_range(0, effect.sprites.size() - 1)] if effect.sprites.size() > 0 else null
	c.visible = true
	pool_owner.add_child(c)


func _apply(effect: IngredientVisualEffect) -> void:
	visible = false


func _process(delta: float) -> void:
	# 生命周期终止 → 回池
	if life_time >= fade_out_after + fade_out_time:
		_return_to_pool()
		return
	life_time += delta
	# 重力 + 衰减（原版 EffectUpdate）
	speed += gravity_acceleration * delta * Vector2.DOWN
	if absf(speed.length()) > 0.00001 and absf(speed_slowdown) > 0.001:
		speed = speed.move_toward(Vector2.ZERO, speed_slowdown * delta)
	# 旋转
	if effect_data.accelerate_rotation_speed_to_zero:
		rotation_speed -= signf(rotation_speed) * absf(rotation_acceleration) * delta
	else:
		rotation_speed += rotation_acceleration * delta
	rotation += rotation_speed * delta
	position += speed * delta
	# 淡出：原版 ShaderEffect().SetEffectValue() 等价——用 modulate.a 映射
	if life_time > fade_out_after:
		var t := clampf((life_time - fade_out_after) / maxf(fade_out_time, 0.0001), 0.0, 1.0)
		sprite.modulate.a = 1.0 - t
	else:
		sprite.modulate.a = 1.0


func _return_to_pool() -> void:
	visible = false
	life_time = 0.0
	var owner_node := get_parent()
	if owner_node != null and owner_node.has_method("_release_to_pool"):
		owner_node.call("_release_to_pool", self)
