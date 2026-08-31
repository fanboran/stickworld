class_name BehaviorAttack
extends BehaviorBase
## 攻击行为 -- 找最近敌人 -> 接近到射程内 -> 攻击（命中帧->伤害事件）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2 / §7.4 / §8。
## 包含概率钩子（§7.4 第一层）：擅自冲锋、犹豫。
##
## 完成条件（finish 后由 AIController 决策切换）：
##   - 无敌人 / 战斗结束
##   - 自身溃逃（士气低于阈值）-> AIController 切 retreat
##   - 自身重伤且附近有掩体 -> AIController 切 seek_cover
##
## params 可选字段：
##   - battle: BattleInstance（不传则从 entity.get_battle_instance() 取）

# 显式 preload，避免 headless 模式下 class_name 全局注册未触发（惯例见 ai_controller.gd:16）
# audit-exempt: headless 防御性路径 preload（经 api 转发会重新依赖 class_name 注册，
# 失去防御意义）；TargetFinder 为 combat 对外公共类型（combat/api.gd 已声明契约）
const ScriptTargetFinder := preload("res://modules/combat/scripts/target_finder.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 目标刷新间隔（秒）
const ACQUIRE_INTERVAL: float = 0.5
## 犹豫检查间隔（秒）
const HESITATE_CHECK_INTERVAL: float = 0.5
## 低士气阈值（低于此值触发撤退决策）
const LOW_MORALE_THRESHOLD: float = 0.3
## 低 HP 阈值（低于此值且附近有掩体触发找掩体）
const LOW_HP_THRESHOLD: float = 0.3
## 掩体查询范围（附近多少像素内有掩体算"附近"）
const COVER_NEARBY_RANGE: float = 200.0
## 追击范围倍数（行业最佳实践：目标超出攻击范围 × LEASH_MULT 则放弃追击，防追到天涯海角）
const LEASH_MULT: float = 4.0

# ─────────────────────────────── @export（概率钩子，§7.4）────────────────────────────────
## 擅自冲锋概率（每次接近时）
@export var prob_aggressive_push: float = 0.05
## 犹豫概率（每次检查时）
@export var prob_hesitate: float = 0.03
## 狂暴冲锋概率（反编译参考实装 E：狂暴时替代 prob_aggressive_push）
const RAGE_PUSH_PROB: float = 0.35

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 当前目标敌人
var _target: Node = null
## 目标刷新计时器
var _acquire_timer: float = 0.0
## 犹豫检查计时器
var _hesitate_check_timer: float = 0.0
## 犹豫持续计时器（>0 时停滞）
var _hesitate_timer: float = 0.0
## 狂暴标记（反编译参考实装 E）：低血狂暴/被围背墙时由 AIController 传入。
## 狂暴时跳过"低血找掩体"、冲锋概率提升、不因士气波动收手。
var _rage: bool = false


func _ready() -> void:
	behavior_name = "attack"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	_rage = params.get("rage", false)
	_target = null
	_acquire_timer = 0.0
	_hesitate_check_timer = 0.0
	_hesitate_timer = 0.0


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if entity.has_method("is_dead") and entity.is_dead():
		finish()
		return
	# 受击硬直（行业最佳实践 hit stun）：被打瞬间短暂停滞，不追不打
	if entity.has_method("is_in_hit_stun") and entity.is_in_hit_stun():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("is_active") or not _battle.is_active():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		finish()
		return

	# 刷新目标
	_acquire_timer -= delta
	if _target == null or not is_instance_valid(_target) or (_target.has_method("is_dead") and _target.is_dead()) or _is_beyond_leash() or _acquire_timer <= 0.0:
		# 队伍级共享目标（反编译参考实装 D-B）：排长决策 → 队员执行（集火）。
		# 所属小队有共享攻击目标时优先用它，否则回退各自寻敌。
		var squad_target: Node = _get_squad_target()
		if squad_target != null:
			# 队伍目标始终优先（排长换目标 = 全队换目标）
			_target = squad_target
		elif _target != null and is_instance_valid(_target) and not (_target.has_method("is_dead") and _target.is_dead()) and not _is_beyond_leash():
			# 目标切换滞后（行业最佳实践 sticky target）：当前目标仍有效且未超追击范围则锁定保留，
			# 不因刷新周期重选（避免频繁换目标导致攻击输出丢失）
			pass
		else:
			# 公共目标选择核心（反编译参考实装 A）：规则经 opts 扩展，见 ScriptTargetFinder。
			# ignore_current_attackers = 防集火重叠（battle 记录攻击者数，反编译参考实装 A 的 TODO）
			_target = ScriptTargetFinder.find_target(entity, { "battle": _battle, "ignore_current_attackers": true })
		_acquire_timer = ACQUIRE_INTERVAL
		if _target == null:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			finish()
			return

	# 自身状态检查：士气/HP 过低 -> finish 让 AIController 决策
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null:
		if health.has_method("is_routed") and health.is_routed():
			finish()
			return
		# 狂暴时放宽士气下限（低血狂暴不因士气波动收手；溃逃仍由 AIController 处理）
		if not _rage and health.has_method("get_morale_ratio") and health.get_morale_ratio() < LOW_MORALE_THRESHOLD:
			finish()
			return
		# 狂暴时跳过"低血找掩体"（反编译参考实装 E）：背水一战不撤退
		if not _rage and health.has_method("get_hp_ratio") and health.get_hp_ratio() < LOW_HP_THRESHOLD and _has_cover_nearby():
			finish()
			return

	# 犹豫概率钩子（§7.4 第一层）
	if _hesitate_timer > 0.0:
		_hesitate_timer -= delta
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	_hesitate_check_timer -= delta
	if _hesitate_check_timer <= 0.0:
		_hesitate_check_timer = HESITATE_CHECK_INTERVAL
		if randf() < prob_hesitate:
			_hesitate_timer = randf_range(0.3, 0.8)
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			return

	# 攻击 / 接近逻辑
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	var dist: float = entity.global_position.distance_to(_target.global_position)

	if dist <= attack_range:
		# 在射程内：停止移动并攻击
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		if weapon != null and weapon.has_method("can_attack") and weapon.can_attack():
			weapon.perform_attack(_target)
			# 攻击命中帧触发攻击动画（反编译参考实装 C）：播完由 rig.animation_finished 回切
			if entity.has_method("play_attack"):
				entity.play_attack()
	else:
		# 不在射程：朝"保角环绕点"移动——停在射程边缘并保持自身相对目标的方位，
		# 各单位从不同方向包围目标（防一字长蛇/叠人；参考 RTS 攻击槽位思想）。
		# 自身方位角保持：desired = 敌人 + 自身方向 * attack_radius，
		# 从同一侧接近的部队自然散布在目标周围弧线上，配合实体 separation 防叠。
		var attack_radius: float = maxf(attack_range * 0.85, 24.0)
		var to_target: Vector2 = _target.global_position - entity.global_position
		var desired_pos: Vector2 = _target.global_position + to_target.normalized() * attack_radius
		var dir: Vector2 = (desired_pos - entity.global_position).normalized()
		var run: bool = randf() < (RAGE_PUSH_PROB if _rage else prob_aggressive_push)
		if entity.has_method("ai_move"):
			entity.ai_move(dir, run)


# ─────────────────────────────── 内部 ────────────────────────────────

## 队伍级共享攻击目标（反编译参考实装 D-B）：本兵所属小队的排长决策目标。
## 无 formation / 无小队 / 无共享目标时返回 null（回退各自寻敌）。
func _get_squad_target() -> Node:
	if entity == null or not entity.has_method("get_formation_system"):
		return null
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("get_unit_squad"):
		return null
	var squad_id: String = fs.get_unit_squad(entity)
	if squad_id.is_empty() or not fs.has_method("get_squad_target"):
		return null
	return fs.get_squad_target(squad_id)

## 追击范围检查（行业最佳实践）：当前目标是否已超出攻击范围 × LEASH_MULT。
## 超范围视为"追丢了"，触发重新选目标（避免追杀单个敌人到天涯海角）。
func _is_beyond_leash() -> bool:
	if _target == null or not is_instance_valid(_target) or entity == null:
		return false
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	return entity.global_position.distance_to(_target.global_position) > attack_range * LEASH_MULT

## 检查附近是否有掩体（用于"重伤找掩体"决策）
func _has_cover_nearby() -> bool:
	if _battle == null or not _battle.has_method("get_cover"):
		return false
	var cover = _battle.get_cover()
	if cover == null or not cover.has_method("has_covers") or not cover.has_covers():
		return false
	if cover.has_method("is_in_cover") and cover.is_in_cover(entity.global_position):
		return true
	if cover.has_method("find_nearest_cover"):
		var nearest: Vector2 = cover.find_nearest_cover(entity.global_position)
		return entity.global_position.distance_to(nearest) < COVER_NEARBY_RANGE
	return false


## 获取当前目标（供测试/调试）
func get_target() -> Node:
	return _target
