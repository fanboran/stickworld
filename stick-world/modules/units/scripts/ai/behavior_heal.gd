class_name BehaviorHeal
extends BehaviorBase
## 治疗行为 -- MericAi 3 函数直译宿主（P7 批次 7b）。
##
## 详见 .codeartsdoer/specs/meric_priest/design.md §2.1.3.2 映射表。
## dump MericAi.Update/CanAttack/UpdateTarget 均无方法体真值，
## 本文件为语义推断直译（结构对齐签名语义，数值待实测校准）。
##
## 主循环编排（MericAi.Update 直译）：
##   死亡/battle失效/受击硬直 → finish
##   自保撤离（kite_range > 0 ∧ 最近敌 < kite_range → 背向撤而不打）
##   update_target（扫视周期节流 → find_weakest_ally + sticky）
##   无目标 → ai_stop 后排待机（不 finish，防 travel→idle 抖动）
##   有目标 ∧ can_attack → can_cast_heal → cast_heal / 停移等待
##   有目标 ∧ ¬can_attack（射程外）→ ai_move 跟随走位
##
## params: battle（缺省取 entity.get_battle_instance()）

# 显式 preload（§七.3 headless 防御性路径）
const ScriptTargetFinder := preload("res://modules/combat/scripts/target_finder.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 当前治疗目标（友军）
var _heal_target: Node = null
## 目标扫视计时器
var _scan_timer: float = 0.0
## 兵种行为档案（enter 时按武器类型解析）
var _profile: Dictionary = {}


func _ready() -> void:
	behavior_name = "heal"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	_profile = {}
	if entity != null and is_instance_valid(entity) and entity.has_method("get_weapon"):
		var w: Node = entity.get_weapon()
		if w != null and "weapon_type" in w:
			_profile = ScriptBehaviorProfiles.get_profile(int(w.weapon_type))
	_heal_target = null
	_scan_timer = 0.0


## MericAi.Update 直译：主循环编排（AIController 决策挂载、帧驱动）。
## dump 无方法体真值，语义推断（待实测校准）。
func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if entity.has_method("is_dead") and entity.is_dead():
		finish()
		return
	# 受击硬直：被打瞬间短暂停滞
	if entity.has_method("is_in_hit_stun") and entity.is_in_hit_stun():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return
	if _battle == null or not is_instance_valid(_battle) \
			or not _battle.has_method("is_active") or not _battle.is_active():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		finish()
		return

	# 自保撤离（档案 kite_range > 0 ∧ 最近存活敌 < kite_range → 背向撤而不打）
	var kite_range: float = _p("kite_range", 0.0)
	if kite_range > 0.0:
		var nearest_enemy: Node = ScriptTargetFinder.find_target(entity, { "battle": _battle })
		if nearest_enemy != null:
			var enemy_dist: float = entity.global_position.distance_to(nearest_enemy.global_position)
			if enemy_dist < kite_range:
				var away: Vector2 = (entity.global_position - nearest_enemy.global_position).normalized()
				if entity.has_method("ai_move"):
					entity.ai_move(away, _p("kite_run", 0.0) > 0.5)
				# 撤离中冷却满且目标射程内仍放行施法（自保优先调和序，design §2.1.3.3）
				if _heal_target != null and is_instance_valid(_heal_target) \
						and not (_heal_target.has_method("is_dead") and _heal_target.is_dead()) \
						and can_attack(_heal_target):
					var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
					if weapon != null and weapon.has_method("can_cast_heal") \
							and weapon.can_cast_heal():
						if entity.has_method("ai_stop"):
							entity.ai_stop()
						weapon.cast_heal(_heal_target)
				return

	# 目标扫视周期节流（MericAi.UpdateTarget 直译）
	_scan_timer -= delta
	if _heal_target == null or not is_instance_valid(_heal_target) \
			or (_heal_target.has_method("is_dead") and _heal_target.is_dead()) \
			or _is_target_full_hp(_heal_target) or _scan_timer <= 0.0:
		update_target()
		_scan_timer = _p("heal_scan_interval", 0.5)

	# 无目标 → ai_stop 后排待机（保持行为激活不 finish，防 travel→idle 抖动）
	if _heal_target == null:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return

	# 有目标：资格判定 → 施放 / 走位
	if can_attack(_heal_target):
		var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
		if weapon != null and weapon.has_method("can_cast_heal") \
				and weapon.can_cast_heal():
			# 施法停移（决策点 5 初值）+ 施放
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			weapon.cast_heal(_heal_target)
		else:
			# 冷却/施法中 → 停移等待（Stand 观感）
			if entity.has_method("ai_stop"):
				entity.ai_stop()
	else:
		# 射程外 → ai_move 向目标跟随走位（无"穿人"追踪）
		var dir: Vector2 = (_heal_target.global_position - entity.global_position).normalized()
		if entity.has_method("ai_move"):
			entity.ai_move(dir, false)


## MericAi.CanAttack 直译（语义推断：治疗资格）。
## 目标为本阵营存活友军 ∧ 血量未满（hp_ratio < 1.0）∧ 在档案 heal_range 内 → 真。
## 对敌恒假（无攻击动画资产级真值）。dump 无方法体真值（待实测校准）。
## 签名差异声明：原版双参 (target, unit) 中 unit 为宿主上下文，
## GDScript 行为类持 entity 成员等价，单参化符合既有 behavior_* 族签名惯例。
func can_attack(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target.has_method("is_dead") and target.is_dead():
		return false
	# 血量未满
	if target.has_method("get_health"):
		var health: Node = target.get_health()
		if health != null and health.has_method("get_hp_ratio"):
			if health.get_hp_ratio() >= 1.0:
				return false
		else:
			return false
	else:
		return false
	# 在档案 heal_range 内
	var heal_range: float = _p("heal_range", 0.0)
	if heal_range > 0.0:
		var dist: float = entity.global_position.distance_to(target.global_position)
		if dist > heal_range:
			return false
	return true


## MericAi.UpdateTarget 直译：扫视周期刷新治疗目标。
## 按 heal_scan_interval 周期调 TargetFinder.find_weakest_ally；
## sticky 保持（目标存活且未满血不重选）；目标死亡/满血即清空重扫。
## dump 无方法体真值，执行计划指定血量最低（待实测校准）。
func update_target() -> void:
	# sticky：当前目标仍有效且未满血则保留
	if _heal_target != null and is_instance_valid(_heal_target) \
			and not (_heal_target.has_method("is_dead") and _heal_target.is_dead()) \
			and not _is_target_full_hp(_heal_target):
		return
	# 重扫：find_weakest_ally（本阵营存活 ∧ 未满血，含祭司自身——决策点 3）
	var heal_range: float = _p("heal_range", 0.0)
	var opts: Dictionary = { "battle": _battle }
	if heal_range > 0.0:
		opts["range"] = heal_range
	_heal_target = ScriptTargetFinder.find_weakest_ally(entity, opts)


# ─────────────────────────────── 内部 ────────────────────────────────

## 读取兵种档案参数（缺省回落 fallback——对齐 behavior_attack.gd:587 惯例）
func _p(key: String, fallback: float) -> float:
	return float(_profile.get(key, fallback))


## 目标是否满血（无 health 组件视为满血）
func _is_target_full_hp(target: Node) -> bool:
	if not target.has_method("get_health"):
		return true
	var health: Node = target.get_health()
	if health == null or not health.has_method("get_hp_ratio"):
		return true
	return health.get_hp_ratio() >= 1.0