class_name BehaviorMove
extends BehaviorBase
## 移动行为 -- 向目标点直线移动，到达后完成。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.2。
## P0 阶段为简单直线移动，不做 A* 寻路（障碍由 entity 的通行障碍检测处理）。
## params 必填字段：
##   - target: Vector2  目标位置（世界坐标）
## 可选字段：
##   - run: bool  是否奔跑（默认 false）
##   - engage_in_range: bool  接敌即战（敌人进入武器射程即打断移动转战斗）
##   - hold_on_arrive: bool  到位驻留（编队动态跟队锚定用）：到达后行为不完成，
##     站桩待命压制 AI 战斗决策"擅自冲锋"，敌人进射程（engage_in_range）仍打断
##   - catching_up: bool  追赶队形（编队跟队/列阵下发，SWL UpdateCatchingUpToFormation）：
##     落后槽位过远的归位跑——收盾疾跑，落定后恢复行军盾

## 兵种行为档案（formation_block：盾兵行军盾不放下）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

## 到达目标的距离阈值（像素）
const ARRIVAL_THRESHOLD: float = 20.0
## 列阵到位滞留时长（秒；编队成员到达时播 arrive 动画后停留，AI 完善批次 4）
const ARRIVE_HOLD_DURATION: float = 0.4
## 接敌检查节流间隔（秒）
const ENGAGE_CHECK_INTERVAL: float = 0.2

## 目标位置（世界坐标）
var _target: Vector2 = Vector2.ZERO
## 是否奔跑
var _running: bool = false
## 是否已到达目标（hold_on_arrive 驻留态标记）
var _arrived: bool = false
## 到位驻留（编队动态跟队锚定）：到达后不 finish，原地待命
var _hold_on_arrive: bool = false
## 列阵到位滞留倒计时（>0 表示已到达正在播 arrive）
var _arrive_hold: float = 0.0
## 接敌即战（号令 engage_in_range=true 时启用）：敌人进入武器射程即打断移动
var _engage_in_range: bool = false
## 接敌检查计时器
var _engage_check_timer: float = 0.0
## 行军举盾开关（档案 formation_block：SWL UpdateBlockWhenInFormation）
var _formation_blocking: bool = false
## 追赶队形（SWL UpdateCatchingUpToFormation 直译，11b）：归位跑收盾，落定恢复端盾
var _catching_up: bool = false


func _ready() -> void:
	behavior_name = "move"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	if params.has("target"):
		_target = params["target"]
	else:
		_target = entity.global_position if entity != null else Vector2.ZERO
	_running = params.get("run", false)
	_engage_in_range = params.get("engage_in_range", false)
	_hold_on_arrive = params.get("hold_on_arrive", false)
	_catching_up = params.get("catching_up", false)
	_arrived = false
	_engage_check_timer = 0.0
	_update_formation_block(true)


func exit(next: String) -> void:
	# 退出行军收盾：战斗行为会按姿态聚合重新决策举盾
	_update_formation_block(false)
	super.exit(next)


## 行军举盾（SWL UpdateBlockWhenInFormation 直译）：档案 formation_block=true 的
## 盾兵在行军/待命全程举盾（Spearton 端盾行军姿态），进战斗后由 attack 行为接管。
## 追赶归位跑不举盾（SWL UpdateBlockWhenInFormation(isCatchingUpToFormation)：
## 落后收盾疾跑），落定后由到达分支恢复端盾
func _update_formation_block(on: bool) -> void:
	if on == _formation_blocking:
		return
	if on and _catching_up:
		return  # 追赶中不端盾（落定后到达分支再开）
	var weapon: Node = entity.get_weapon() if entity != null and entity.has_method("get_weapon") else null
	if weapon == null or not weapon.has_method("set_blocking"):
		return
	var wt: int = int(weapon.weapon_type) if "weapon_type" in weapon else -1
	if on and bool(ScriptBehaviorProfiles.get_profile(wt).get("formation_block", false)):
		_formation_blocking = true
		weapon.set_blocking(true)
	else:
		_formation_blocking = false
		weapon.set_blocking(false)


func update(delta: float) -> void:
	if entity == null or not is_instance_valid(entity):
		finish()
		return

	# 接敌即战（2026-08-31 观察场审计）：推进/驻留途中敌人进入武器射程 → 打断移动，
	# finish 后 AIController 清除命令转入战斗决策——远程班停在射程边缘输出，
	# 近战班卡在攻击距离，不再被号令拽着冲过射程贴脸
	# （前置检查：锚定驻留态也要能被接敌打断，交还战斗行为）
	if _engage_in_range:
		_engage_check_timer -= delta
		if _engage_check_timer <= 0.0:
			_engage_check_timer = ENGAGE_CHECK_INTERVAL
			if _enemy_in_weapon_range():
				if entity.has_method("ai_stop"):
					entity.ai_stop()
				finish()
				return

	# 到达后的列阵到位滞留（AI 完善批次 4）：播 arrive 立正动画，播完再 finish；
	# hold_on_arrive（编队动态跟队）滞留结束不 finish，转入下方驻留分支
	if _arrive_hold > 0.0:
		_arrive_hold -= delta
		if _arrive_hold <= 0.0 and not _hold_on_arrive:
			finish()
			if entity.has_method("ai_stop"):
				entity.ai_stop()
		return

	# 到位驻留（hold_on_arrive，编队动态跟队）：站桩待命、行为不完成——
	# 号令持续占用决策（压制"无令时战斗决策擅自冲锋"），敌人进射程由上方接敌检查打断
	if _arrived:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		return

	var pos: Vector2 = entity.global_position
	var dist: float = pos.distance_to(_target)

	# 到达目标
	if dist <= ARRIVAL_THRESHOLD:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_arrived = true
		# 追赶落定（11b）：恢复行军端盾（SWL 落位后 UpdateBlockWhenInFormation 端盾）
		if _catching_up:
			_catching_up = false
			_update_formation_block(true)
		# 编队成员到达队形位 → 播列阵动画并短暂滞留（对应传奇 ArriveAtFormationAnimationSystem）
		if _is_squad_member():
			if entity.has_method("play_arrive"):
				entity.play_arrive()
			_arrive_hold = ARRIVE_HOLD_DURATION
		elif not _hold_on_arrive:
			finish()
		return

	# 计算移动方向并驱动 entity
	var dir: Vector2 = (_target - pos).normalized()
	if entity.has_method("ai_move"):
		entity.ai_move(dir, _running)


## 是否有活跃敌人进入主手武器射程（进入即停推进，交由战斗行为接管）
func _enemy_in_weapon_range() -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	if not entity.has_method("get_battle_instance"):
		return false
	var bi: Node = entity.get_battle_instance()
	if bi == null or not is_instance_valid(bi) \
			or not bi.has_method("is_active") or not bi.is_active():
		return false
	var faction: int = entity.get_faction() if entity.has_method("get_faction") else 0
	if faction == 0 or not bi.has_method("get_enemies_of"):
		return false
	var weapon: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	var attack_range: float = weapon.attack_range if weapon != null and "attack_range" in weapon else 100.0
	for e in bi.get_enemies_of(faction):
		if e == null or not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if entity.global_position.distance_to(e.global_position) <= attack_range:
			return true
	return false


## 是否编队成员（AI 完善批次 4）：有 formation 且属于某小队 → 到达时播列阵动画。
func _is_squad_member() -> bool:
	if entity == null or not entity.has_method("get_formation_system"):
		return false
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("get_unit_squad"):
		return false
	return not fs.get_unit_squad(entity).is_empty()
