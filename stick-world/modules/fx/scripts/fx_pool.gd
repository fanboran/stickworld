class_name FxPool
extends Node
## 全局粒子特效池 —— 一次性爆发特效的复用与发射。
##
## 由 SystemSetup 挂到 GameRoot（group "fx_pool"）。业务方不持有本节点引用，
## 经 Fx.burst(tree, id, pos) 静态入口按组查找，保持模块解耦。
##
## 2026-08-22 增补：完全按《药剂工艺》IngredientVisualEffect 的实现方式复刻了
## 演员特效（Sprite2D 手写物理 + 池化），入口为 spawn_ingredient_effect。区别于
## GPUParticles2D 爆发，这才是原版"布灵布灵"的等效路径。
## ⚠️ PLACEHOLDER：效果配置见 fx_library.gd 头注释。

const POOL_PER_EFFECT := 6
## 超出上限后丢弃最旧（防止极端情况下无限增长）
const HARD_CAP_PER_EFFECT := 16

var _pools: Dictionary = {}  # effect_id -> Array[GPUParticles2D]

## 演员特效空闲池（对应原版 effectsPool：Queue<IngredientVisualEffectController>）
var _free_pool: Array[IngredientVisualEffectController] = []


func _ready() -> void:
	add_to_group("fx_pool")
	# 环境闪光生成器（《药剂工艺》式随机闪烁，2026-08-22）
	var spawner := AmbientSparkleSpawner.new()
	spawner.name = "AmbientSparkleSpawner"
	add_child(spawner)


## 演员特效入口（《药剂工艺》IngredientVisualEffect 的 spawn 路径）
## pool_owner 即本节点；effect 为配置资源；appear_type 0=Common 1=Explosion；
## z_index 按原版 sortingLayer 语义传入。
func spawn_ingredient_effect(effect: IngredientVisualEffect, appear_type: int,
		position: Vector2, velocity: Vector2, z_index: int = WorldZ.OVERLAY_HINT) -> void:
	IngredientVisualEffectController.spawn(self, effect, appear_type, position, velocity, z_index)


## 回池（由控制器调用）
func _release_to_pool(c: IngredientVisualEffectController) -> void:
	if c != null and is_instance_valid(c):
		c.get_parent().remove_child(c)
		c.visible = false
		_free_pool.append(c)


## 池取用（由控制器 spawn 流程调用）：弹出空闲实例，无则 null
func take_from_pool() -> IngredientVisualEffectController:
	if _free_pool.is_empty():
		return null
	return _free_pool.pop_back()


## 发射一次爆发特效（从池中取空闲实例；无空闲且未达硬上限时扩池）
func burst(effect_id: String, global_pos: Vector2) -> void:
	var nodes: Array = _pools.get(effect_id, [])
	var chosen: GPUParticles2D = null
	for p in nodes:
		if is_instance_valid(p) and not p.emitting:
			chosen = p
			break
	if chosen == null:
		if nodes.size() >= HARD_CAP_PER_EFFECT:
			chosen = nodes[0]  # 偷最旧的顶上
		else:
			chosen = FxLibrary.create_burst(effect_id)
			if chosen == null:
				return
			add_child(chosen)
			nodes.append(chosen)
			_pools[effect_id] = nodes
	chosen.global_position = global_pos
	chosen.restart()
	chosen.emitting = true


# ─────────────────────────────── 静态便捷入口 ────────────────────────────────

## 业务侧统一入口：FxPool.spawn_burst(get_tree(), FxLibrary.HIT_SPARK, global_position)。
## 场景中无 FxPool（如纯逻辑测试）时静默忽略；
## 但游戏内若 FxPool 缺席（主菜单/GameRoot 未装配）是异常路径——debug 构建下第一次
## 缺失时 push_warning + toast，帮助玩家/开发者快速定位"没效果"根因。
static func spawn_burst(tree: SceneTree, effect_id: String, global_pos: Vector2) -> void:
	if tree == null:
		return
	var pool := tree.get_first_node_in_group("fx_pool") as FxPool
	if pool == null:
		if OS.is_debug_build():
			push_warning("[FxPool] 场景中无 fx_pool 组节点（GameRoot 未装配？），特效未发射: %s" % effect_id)
		return
	pool.burst(effect_id, global_pos)
