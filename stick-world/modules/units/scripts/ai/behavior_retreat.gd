class_name BehaviorRetreat
extends BehaviorBase
## 撤退行为 -- 向远离最近敌人的方向移动，拉开距离或恢复士气后 finish。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## 撤退中士气缓慢恢复；士气恢复到安全水平或拉开足够距离后 finish（回 attack）。
##
## 战役撤离模式（C3 敌将撤仗，出征与领地架构 §4.2）：params 带 evacuate=true 时
## 方向固定为己方出生侧地图边缘，不因士气恢复/安全距离/超时收束（战役级撤退不回头）；
## 抵达边缘带登记 entity.departed（BattleInstance._count_alive 计非存活）后收束。
##
## 9i+ 增强（P6 批次 7c，design §2.1.3.6 #2/#3，档案开关默认关 = 零回归）：
##   - 保持招架（retreat_keep_block）：持盾兵种撤退全程举盾，finish/死亡/战斗结束还原
##   - 垂直位游走（rout_strafe_enabled）：撤退叠加垂直于敌我连线的横向分量，消除贴边零位移
##
## params 可选字段：
##   - battle: BattleInstance（不传则从 entity.get_battle_instance() 取）
##   - evacuate: true 战役撤离（见上；TeamAi ROUT 姿态经 RETREAT 号令传入）
##   - retreat_mode: "withdraw" 撤退（回己方锚点/集结点，A3 · C6）；缺省/其余值 =
##     "fallback" 后撤（战术后退：远离最近敌拉开距离重整，既有语义原样）。
##     双档为 CoH fallback_*/retreat_* 同构：后撤=个人战况恶化的低烈度脱离
##     （保留再战），撤退=战线崩坏的整体回撤（回集结点重整）。evacuate 优先于
##     withdraw；锚点查询不可用时 withdraw 降级 fallback。

const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

# ─────────────────────────────── 常量 ────────────────────────────────
## 撤退最长持续时间（秒）
const RETREAT_DURATION: float = 4.0
## 安全距离（拉开此距离后可停止撤退）
const SAFE_DISTANCE: float = 320.0
## 撤退中士气恢复速度（每秒）
const MORALE_RECOVER_PER_SEC: float = 8.0
## 士气恢复到此比例后停止撤退
const SAFE_MORALE_RATIO: float = 0.6
## 战役撤离：判定抵达边缘带的内收余量（px；阵营锚点 margin 260，正常布阵不误触）
const DEPART_EDGE_EPSILON: float = 50.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 所属战斗实例
var _battle: Node = null
## 撤退计时器
var _timer: float = 0.0
## 撤退方向（归一化）
var _retreat_dir: Vector2 = Vector2.LEFT
## 兵种行为档案（enter 时按武器类型解析）
var _profile: Dictionary = {}
## 9i+ 保持招架：enter 时举盾标记，finish/exit 时还原（先例 behavior_seek_cover._set_blocking）
var _keep_block_active: bool = false
## 战役撤离模式（C3）：固定方向撤至己方侧边缘，不提前收束
var _evacuate: bool = false
## A3 撤退档（withdraw）：回己方锚点/集结点（方向固定锚点，抵达带或超时收束）
var _withdraw: bool = false
## withdraw 撤退目标锚点（enter 时经 BattleInstance.get_faction_side_anchor 解析）
var _withdraw_anchor: Vector2 = Vector2.ZERO
## withdraw 撤退计时（上限 = 档案 retreat_mod_withdraw_max_time）
var _withdraw_timer: float = 0.0


func _ready() -> void:
	behavior_name = "retreat"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_battle = params.get("battle", null)
	if _battle == null and entity != null and entity.has_method("get_battle_instance"):
		_battle = entity.get_battle_instance()
	_timer = RETREAT_DURATION
	_evacuate = bool(params.get("evacuate", false))
	# A3 双档语义：withdraw = 撤退回锚点（方向固定锚点）；缺省 = fallback 后撤
	# （既有语义）。evacuate 优先；锚点解析失败降级 fallback。
	_withdraw = false
	_withdraw_timer = 0.0
	if not _evacuate and str(params.get("retreat_mode", "fallback")) == "withdraw":
		if _resolve_withdraw_anchor():
			_withdraw = true
	# 兵种档案解析（按主手武器类型；取不到回落空档案 = 全基线）
	_profile = {}
	if entity != null and is_instance_valid(entity) and entity.has_method("get_weapon"):
		var w: Node = entity.get_weapon()
		if w != null and is_instance_valid(w) and "weapon_type" in w:
			_profile = ScriptBehaviorProfiles.get_profile(int(w.get("weapon_type")))
	_compute_retreat_dir()
	if _evacuate:
		_retreat_dir = _evac_dir()
	elif _withdraw:
		var to_anchor: Vector2 = _withdraw_anchor - entity.global_position
		_retreat_dir = to_anchor.normalized() if to_anchor.length() > 0.1 else Vector2.LEFT
	# 9i+ 保持招架：持盾兵种（profile 有 block_walk_anim）且开关开 → 撤退全程举盾
	_keep_block_active = false
	if bool(_profile.get("retreat_keep_block", false)) and not String(_profile.get("block_walk_anim", "")).is_empty():
		_set_blocking(true)
		_keep_block_active = true


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	if entity.has_method("is_dead") and entity.is_dead():
		_finish_with_block_restore()
		return
	if _battle == null or not is_instance_valid(_battle) or not _battle.has_method("is_active") or not _battle.is_active():
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_finish_with_block_restore()
		return

	# 战役撤离：独立通道（不查敌、不因士气/距离/超时收束）
	if _evacuate:
		_update_evacuate()
		return

	# A3 撤退（withdraw）：回锚点独立通道（方向固定锚点，不因士气/安全距离提前
	# 收束；抵达锚点带或超时收束；不登记 departed——自主撤退是战术行为，非战役离场）
	if _withdraw:
		_update_withdraw(delta)
		return

	_timer -= delta

	# 撤退中士气恢复
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null and health.has_method("restore_morale"):
		health.restore_morale(MORALE_RECOVER_PER_SEC * delta)
		# 士气恢复到安全水平 -> 停止撤退
		if health.has_method("get_morale_ratio") and health.get_morale_ratio() >= SAFE_MORALE_RATIO:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			_finish_with_block_restore()
			return

	# 检查安全距离
	var enemy: Node = _battle.get_nearest_enemy(entity) if _battle.has_method("get_nearest_enemy") else null
	if enemy != null and is_instance_valid(enemy):
		var dist: float = entity.global_position.distance_to(enemy.global_position)
		if dist > SAFE_DISTANCE:
			if entity.has_method("ai_stop"):
				entity.ai_stop()
			_finish_with_block_restore()
			return
		# 重新计算撤退方向（远离敌人）
		var away: Vector2 = entity.global_position - enemy.global_position
		if away.length() > 0.1:
			_retreat_dir = away.normalized()

	# 撤退贴边 = 战役离场（C3 撤离判定覆盖溃逃：RETREAT 状态行至地图边缘即记 departed，
	# BattleInstance 计非存活；登记后停步收束，实体保留溃兵视觉）
	if _at_retreat_edge():
		_register_departed()
		return

	# 撤退移动（奔跑）：方向夹紧可走带——被逼到地图边缘时不再朝带外逃
	# （贴墙站死观感根因，2026-09-01 观察场反馈），x/y 双向都被夹死 → finish 回决策
	var move_dir := _retreat_dir
	# 9i+ 垂直位游走：叠加垂直于敌我连线的横向分量（指向可走带中心侧），消除贴边零位移
	if bool(_profile.get("rout_strafe_enabled", false)) and enemy != null and is_instance_valid(enemy):
		move_dir = _apply_strafe(move_dir, enemy)
	var gy: float = float(entity.get("ground_y")) if "ground_y" in entity else 0.0
	var gb: float = float(entity.get("ground_bottom")) if "ground_bottom" in entity else 0.0
	if gb > gy:
		var pos: Vector2 = entity.global_position
		if move_dir.y < 0.0 and pos.y <= gy + 20.0:
			move_dir.y = 0.0
		elif move_dir.y > 0.0 and pos.y >= gb - 20.0:
			move_dir.y = 0.0
		move_dir = move_dir.normalized() if move_dir.length_squared() > 0.0001 else Vector2.ZERO
	if move_dir == Vector2.ZERO:
		# 无路可退（贴边）：停止撤退，交还决策（脱火士气恢复后自然再接敌）
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_finish_with_block_restore()
		return
	if entity.has_method("ai_move"):
		entity.ai_move(move_dir, true)

	if _timer <= 0.0:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_finish_with_block_restore()
		return


func exit(next: String) -> void:
	# 9i+ 保持招架还原兜底（finish 路径已调 _finish_with_block_restore，此处防异常切行为残留）
	if _keep_block_active:
		_set_blocking(false)
		_keep_block_active = false
	super.exit(next)


# ─────────────────────────────── 内部 ────────────────────────────────

## 战役撤离主循环（C3）：固定朝己方侧边缘行军，抵达边缘带登记 departed 后收束。
## 登记后实体保留（溃兵视觉），由 BattleInstance 侧计非存活触发战斗收束。
func _update_evacuate() -> void:
	if _at_retreat_edge():
		_register_departed()
		return
	var move_dir := _retreat_dir
	# y 夹紧可走带（与常规撤退同规）：撤离是水平行军，y 只防走出地带
	var gy: float = float(entity.get("ground_y")) if "ground_y" in entity else 0.0
	var gb: float = float(entity.get("ground_bottom")) if "ground_bottom" in entity else 0.0
	if gb > gy:
		var pos: Vector2 = entity.global_position
		if move_dir.y < 0.0 and pos.y <= gy + 20.0:
			move_dir.y = 0.0
		elif move_dir.y > 0.0 and pos.y >= gb - 20.0:
			move_dir.y = 0.0
		move_dir = move_dir.normalized() if move_dir.length_squared() > 0.0001 else Vector2.ZERO
	if move_dir != Vector2.ZERO and entity.has_method("ai_move"):
		entity.ai_move(move_dir, true)


## 撤退档主循环（A3 · C6 withdraw）：固定朝己方锚点/集结点行军，途中士气恢复
## （"重整"分量，不因士气收束）；抵达锚点带或超时（档案 retreat_mod_withdraw_*
## 参数）收束。方向不因敌人重算（脱离接触语义），不叠加游走，不登记 departed。
func _update_withdraw(delta: float) -> void:
	var health: Node = entity.get_health() if entity.has_method("get_health") else null
	if health != null and health.has_method("restore_morale"):
		health.restore_morale(MORALE_RECOVER_PER_SEC * delta)
	_withdraw_timer += delta
	var arrive: float = float(_profile.get("retreat_mod_withdraw_arrive", 80.0))
	var max_time: float = float(_profile.get("retreat_mod_withdraw_max_time", 12.0))
	var to_anchor: Vector2 = _withdraw_anchor - entity.global_position
	if to_anchor.length() <= arrive or _withdraw_timer >= max_time:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_finish_with_block_restore()
		return
	var move_dir := to_anchor.normalized()
	# y 夹紧可走带（与常规撤退同规）
	var gy: float = float(entity.get("ground_y")) if "ground_y" in entity else 0.0
	var gb: float = float(entity.get("ground_bottom")) if "ground_bottom" in entity else 0.0
	if gb > gy:
		var pos: Vector2 = entity.global_position
		if move_dir.y < 0.0 and pos.y <= gy + 20.0:
			move_dir.y = 0.0
		elif move_dir.y > 0.0 and pos.y >= gb - 20.0:
			move_dir.y = 0.0
		move_dir = move_dir.normalized() if move_dir.length_squared() > 0.0001 else Vector2.ZERO
	if move_dir == Vector2.ZERO:
		# 无路可走（贴边）：收束交还决策
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_finish_with_block_restore()
		return
	if entity.has_method("ai_move"):
		entity.ai_move(move_dir, true)


## 解析撤退目标锚点（A3 withdraw 档）：己方阵营侧锚点（BattleInstance.
## get_faction_side_anchor duck 调用，不跨模块 preload）。查询不可用返回
## false → 撤退降级后撤（fallback 原语义）。
func _resolve_withdraw_anchor() -> bool:
	if entity == null or not is_instance_valid(entity) or not entity.has_method("get_faction"):
		return false
	if _battle == null or not is_instance_valid(_battle) \
			or not _battle.has_method("get_faction_side_anchor"):
		return false
	_withdraw_anchor = _battle.get_faction_side_anchor(int(entity.get_faction()))
	return true


## 撤离方向：己方出生侧（faction 1 左攻方 → 左缘；faction 2 右守方 → 右缘）
func _evac_dir() -> Vector2:
	var f: int = int(entity.get("faction_id")) if entity != null and "faction_id" in entity else 0
	return Vector2.LEFT if f == 1 else Vector2.RIGHT


## 是否抵达撤退方向上的边缘带（entity.map_left/map_right 内收 DEPART_EDGE_EPSILON；
## evacuate 与常规溃逃共用——撤离判定按"RETREAT 状态行至边缘"，出征与领地架构 §4.2）
func _at_retreat_edge() -> bool:
	var x: float = entity.global_position.x
	if _retreat_dir.x < -0.5:
		var ml: float = float(entity.get("map_left")) if "map_left" in entity else 0.0
		return x <= ml + DEPART_EDGE_EPSILON
	if _retreat_dir.x > 0.5:
		var mr: float = float(entity.get("map_right")) if "map_right" in entity else 0.0
		return x >= mr - DEPART_EDGE_EPSILON
	return false


## 登记战役离场：departed 置位（BattleInstance._count_alive 计非存活），
## 停步收束（实体保留，溃兵视觉；战斗收束由 BattleInstance 侧清点触发）
func _register_departed() -> void:
	if "departed" in entity:
		entity.set("departed", true)
	if entity.has_method("ai_stop"):
		entity.ai_stop()
	_finish_with_block_restore()


## 计算初始撤退方向（远离最近敌人）
func _compute_retreat_dir() -> void:
	if _battle == null or entity == null:
		_retreat_dir = Vector2.LEFT
		return
	var enemy: Node = _battle.get_nearest_enemy(entity) if _battle.has_method("get_nearest_enemy") else null
	if enemy == null:
		_retreat_dir = Vector2.LEFT
		return
	var away: Vector2 = entity.global_position - enemy.global_position
	_retreat_dir = away.normalized() if away.length() > 0.1 else Vector2.LEFT


## 9i+ 垂直位游走：在撤退方向上叠加垂直于敌我连线的横向分量。
## 横向指向可走带中心侧（y 中点方向），消除贴边 >2s 零位移（design §2.1.3.6 #3）。
func _apply_strafe(retreat_dir: Vector2, enemy: Node) -> Vector2:
	var to_enemy: Vector2 = enemy.global_position - entity.global_position
	if to_enemy.length_squared() < 1.0:
		return retreat_dir
	# 垂直于敌我连线（两个候选方向，选指向可走带中心侧的）
	var perp := Vector2(-to_enemy.y, to_enemy.x).normalized()
	var gy: float = float(entity.get("ground_y")) if "ground_y" in entity else 0.0
	var gb: float = float(entity.get("ground_bottom")) if "ground_bottom" in entity else 0.0
	var mid_y: float = (gy + gb) * 0.5
	if (entity.global_position.y < mid_y and perp.y < 0.0) or (entity.global_position.y > mid_y and perp.y > 0.0):
		perp = -perp
	var strength: float = float(_profile.get("rout_strafe_strength", 0.35))
	return (retreat_dir + perp * strength).normalized()


## finish 并还原举盾态（9i+ 保持招架收尾）
func _finish_with_block_restore() -> void:
	if _keep_block_active:
		_set_blocking(false)
		_keep_block_active = false
	finish()


## 切换举盾姿态（委托实体 WeaponMount.set_blocking，先例 behavior_seek_cover）
func _set_blocking(v: bool) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if not entity.has_method("get_weapon"):
		return
	var weapon: Node = entity.get_weapon()
	if weapon != null and weapon.has_method("set_blocking"):
		weapon.set_blocking(v)


## 获取撤退方向（供测试/调试）
func get_retreat_dir() -> Vector2:
	return _retreat_dir
