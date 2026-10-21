extends RefCounted
## 火柴人 User Control 输入助手 —— 从 stickman_entity 拆出的玩家控制逻辑（§7.5）。
##
## 职责：
## - 玩家移动输入（WASD/方向键，_handle_player_input，InputMap action）
## - 玩家攻击/空挥（_player_attack_press/_release 按武器分流 / _player_swing）
## - 武器蓄力状态机（弓拉弓 / 矛蓄力投掷 / 杖指向施法；轻点走旧点击路径）
## - 战斗/探索模式切换（_toggle_combat_mode，Q 键）
## - 副手盾格挡（_set_player_blocking，右键按住/松开）
## - 输入辅助（_find_input_dispatcher / _find_nearest_enemy_in_range /
##   _is_ranged_weapon / _aim_dir / _mouse_world）
##
## 引擎回调 _input/_unhandled_input 留实体薄壳；tests/integration 直呼的
## _toggle_combat_mode / _player_attack / _find_nearest_enemy_in_range
## 在实体侧留委托壳（契约不变）。
##
## 蓄力交互设计（SWL ArcherControls 逆向实锤的 PC 翻译，09 文档 §二）：
## 原版触屏=向后拖拽定方向与力度；PC 翻译=鼠标指向定方向（朝向+弹道），
## 按住左键时长定力度（真实毫秒计时）。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null

# ─────────────────────────────── 蓄力状态机 ────────────────────────────────
## 满蓄力真实毫秒（Time.get_ticks_msec 口径，不受 time_scale 影响）。
## 1000ms 行业惯例（MC 满蓄 1s）。
const CHARGE_FULL_MS: float = 1000.0
## 蓄力下限（原版 ArrowSpeedMinPower 语义：轻点也是一支软箭，不是哑火）
const CHARGE_MIN_POWER: float = 0.2
## 矛轻点阈值（ms）：按住短于此时长=近战戳刺（旧路径），否则=蓄力投掷
const SPEAR_TAP_MS: float = 180.0

## 蓄力态（弓/矛/杖按下中）：active + 起始毫秒
var _charge_active: bool = false
var _charge_start_ms: int = 0


func _init(entity: Node) -> void:
	_entity = entity


func _handle_player_input(delta: float) -> void:
	# 敲击建造动作锁定：1.8s 内禁止移动
	if _entity._player_build_timer > 0.0:
		_entity._apply_movement(delta, Vector2.ZERO, false, false)
		return
	# 攻击动作锁定（仅近战）：出招站定，动画播完恢复移动——否则按住方向键时
	# run/walk 每帧覆盖攻击动画，F 空挥/左键攻击看起来"没反应"。
	# **远程（弓/杖）不锁**：SWL 原版主控可边撤退边走 A（dump Unit 真值
	# USER_CONTROLLED_ATTACK_SPEED=1.3 只加攻速不停步），攻击动画与移动解耦，
	# 移动侧不覆盖攻击动画（见 _handle_acceleration/_handle_deceleration 攻击保护）
	if _entity._current_anim.begins_with("attack") and not _is_ranged_weapon():
		_entity._apply_movement(delta, Vector2.ZERO, false, false)
		return
	# 蓄力瞄准：朝向跟随鼠标（原版 PullBackTargetDirection 的 PC 对应物——
	# 拖拽定方向 → 鼠标指向定方向），轨迹预览同步刷新
	if _charge_active:
		_update_aim()
	var dir := Vector2.ZERO
	if Input.is_action_pressed("user_control/move_left"):
		dir.x -= 1.0
	if Input.is_action_pressed("user_control/move_right"):
		dir.x += 1.0
	if Input.is_action_pressed("user_control/move_up"):
		dir.y -= 1.0
	if Input.is_action_pressed("user_control/move_down"):
		dir.y += 1.0
	_entity._apply_movement(delta, dir, false, not _entity._walk_only)


## 蓄力中每帧瞄准更新：实体朝向翻向鼠标侧（SWL ArcherControls 拖拽方向 →
## PC 鼠标指向）；仰角不转实体（箭矢自身 rotation 跟随弹道速度）。
func _update_aim() -> void:
	var mouse: Vector2 = _mouse_world()
	if _entity.has_method("face_towards"):
		_entity.face_towards(mouse)
	if _entity.has_method("update_charge_preview"):
		_entity.update_charge_preview(_aim_origin(), _preview_velocity())


## 鼠标世界坐标（CanvasItem.get_global_mouse_position，随相机缩放正确换算）
func _mouse_world() -> Vector2:
	return _entity.get_global_mouse_position()


## 瞄准起点（射手胸口，与手动放箭出射点同源）
func _aim_origin() -> Vector2:
	var mount: Node2D = _entity.weapon_mount
	if mount != null and is_instance_valid(mount) and mount.has_method("get_arrow_origin"):
		return mount.get_arrow_origin()
	return _entity.global_position


## 当前蓄力对应的预览初速（轨迹预览点用；与实际放箭同公式）
func _preview_velocity() -> Vector2:
	var mount: Node2D = _entity.weapon_mount
	if mount == null or not is_instance_valid(mount) or not mount.has_method("charge_launch_speed"):
		return Vector2.ZERO
	return _aim_dir() * mount.charge_launch_speed(_charge_power())


## 当前蓄力力度（0..1；未蓄力时为 0）
func _charge_power() -> float:
	if not _charge_active:
		return 0.0
	var held_ms: float = float(Time.get_ticks_msec() - _charge_start_ms)
	return clampf(held_ms / CHARGE_FULL_MS, 0.0, 1.0)


## 瞄准方向（鼠标方向单位向量，从射手胸口出发）
func _aim_dir() -> Vector2:
	var dir: Vector2 = _mouse_world() - _aim_origin()
	if dir.length() < 1.0:
		dir = Vector2(_entity.get_facing(), 0.0)
	return dir.normalized()


## 主手是否远程武器（弓/杖）：远程主控攻击不锁移动（走 A）。
func _is_ranged_weapon() -> bool:
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not is_instance_valid(weapon_mount) \
			or not "weapon_type" in weapon_mount:
		return false
	return int(weapon_mount.weapon_type) == 2 or int(weapon_mount.weapon_type) == 4


# ─────────────────────────────── 攻击按下/松开（按武器分流）────────────────

## 左键按下分流（InputMap user_control/attack）：
## - 弓/矛/杖：进入蓄力态（拉弓动画 + 朝向跟随），冷却门在此判；
## - 剑/镐等近战：保持"按下即攻击"（旧行为，零延迟）。
## 搬运材料时双手被占用（放下前不可攻击）。
func _player_attack_press() -> void:
	if _entity.is_carrying():
		return
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not weapon_mount.has_method("can_attack"):
		return
	var wt: int = int(weapon_mount.get("weapon_type"))
	if wt == 2 or wt == 1 or wt == 4:
		# BOW 拉弓 / SPEAR 蓄力投掷 / STAFF 指向施法——共用蓄力状态机
		if not weapon_mount.can_attack():
			return
		_begin_charge(weapon_mount)
	else:
		_player_attack()


## 左键松开分流：蓄力态收口（放箭/投矛/施法），轻点矛在阈值内回落近战戳刺。
## 非蓄力态（近战/按下被冷却拦下）静默——不补射。
func _player_attack_release() -> void:
	if not _charge_active:
		return
	_charge_active = false
	if _entity.has_method("hide_charge_preview"):
		_entity.hide_charge_preview()
	if _entity.is_carrying():
		return
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not is_instance_valid(weapon_mount):
		return
	var held_ms: float = float(Time.get_ticks_msec() - _charge_start_ms)
	var power: float = clampf(held_ms / CHARGE_FULL_MS, CHARGE_MIN_POWER, 1.0)
	match int(weapon_mount.get("weapon_type")):
		2:  # BOW：松手放箭（SWL AimReleased → UserControlledArrowReleased）
			weapon_mount.release_player_shot(_aim_dir(), power)
		1:  # SPEAR：轻点=近战戳刺（旧路径自动锁敌），按住=蓄力投掷
			if held_ms <= SPEAR_TAP_MS:
				_player_attack()
			else:
				weapon_mount.throw_spear_manual(_aim_dir(), power)
		4:  # STAFF：指向施法（落点=鼠标世界坐标）
			weapon_mount.cast_magic_at(_mouse_world())


## 进入蓄力态：拉弓动画起播（不进冷却不登记结算）。
func _begin_charge(weapon_mount: Node2D) -> void:
	_charge_active = true
	_charge_start_ms = Time.get_ticks_msec()
	if weapon_mount.has_method("begin_player_draw"):
		weapon_mount.begin_player_draw()
	_update_aim()


## 玩家接管单位是否蓄力瞄准中（hitstop 互斥查询口；实体薄壳转发）
func is_aim_charging() -> bool:
	return _charge_active


## 强制收口（接管退出/死亡等异常路径）：只清状态，不出手。
func cancel_charge() -> void:
	if not _charge_active:
		return
	_charge_active = false
	if _entity.has_method("hide_charge_preview"):
		_entity.hide_charge_preview()


# ─────────────────────────────── 既有输入路径 ──────────────────────────────

## 玩家按住/松开右键：举盾格挡（副手盾；无盾实体设了姿态也挡不住，
## 见 WeaponMount.is_shield_blocking 三重判定）。搬运材料时双手被占不举盾。
func _set_player_blocking(v: bool) -> void:
	if v and _entity.is_carrying():
		return
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not is_instance_valid(weapon_mount):
		return
	if weapon_mount.has_method("set_blocking"):
		weapon_mount.set_blocking(v)


## 切换建造/战斗模式：EXPLORE <-> BATTLE。
## 由 Q 键触发（仅 User Control 时）。BATTLE 模式下玩家保持接管（ExploreHandler 不释放），
## 左键 = 挥砍攻击；EXPLORE 模式下左键用于交互/框选。
func _toggle_combat_mode() -> void:
	var dispatcher: Node = _find_input_dispatcher()
	if dispatcher == null or not dispatcher.has_method("get_mode"):
		return
	var new_mode: int = PlayerControlAPI.Mode.BATTLE
	if dispatcher.get_mode() == PlayerControlAPI.Mode.BATTLE:
		new_mode = PlayerControlAPI.Mode.EXPLORE
	if dispatcher.has_method("set_mode"):
		dispatcher.set_mode(new_mode)
	if EventBus != null and EventBus.has_signal("ui_notification"):
		var label: String = "战斗模式（左键挥砍，Q 切回）" if new_mode == PlayerControlAPI.Mode.BATTLE else "探索模式"
		EventBus.ui_notification.emit("模式", label, "info")


## 查找 InputDispatcher（经 PlayerControlAPI 注册表；GameRoot 装配时注册）。
func _find_input_dispatcher() -> Node:
	return PlayerControlAPI.get_input_dispatcher()


## 玩家 User Control 时近战/旧路径攻击：找最近敌人InRange并执行攻击。
## 搬运材料时双手被占用（放下前不可攻击）。
func _player_attack() -> void:
	if _entity.is_carrying():
		return
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not weapon_mount.has_method("can_attack"):
		return
	if not weapon_mount.can_attack():
		return
	var target: Node = _find_nearest_enemy_in_range()
	if target == null:
		return
	weapon_mount.perform_attack(target)


## 玩家空挥（G 键，复刻原版 User Control）：无目标出攻击动作，纯动作无伤害。
## 受冷却约束（can_attack），冷却中按 G 不响应；搬运中双手被占同样不响应。
func _player_swing() -> void:
	if _entity.is_carrying():
		return
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not weapon_mount.has_method("perform_swing"):
		return
	weapon_mount.perform_swing()


## 找最近敌人（不同阵营且存活）在武器射程内
func _find_nearest_enemy_in_range() -> Node:
	var map_ref: Node2D = _entity._map_ref
	if map_ref == null or not is_instance_valid(map_ref):
		return null
	if not map_ref.has_method("get_entities"):
		return null
	var weapon_mount: Node2D = _entity.weapon_mount
	var attack_range: float = weapon_mount.attack_range if weapon_mount != null and weapon_mount.get("attack_range") != null else 140.0
	var nearest: Node = null
	var nearest_dist: float = attack_range
	for e in map_ref.get_entities():
		if e == _entity or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		# 跳过同阵营
		if e.has_method("get_faction") and e.get_faction() == _entity.faction_id:
			continue
		# 跳过死亡
		if e.has_method("is_dead") and e.is_dead():
			continue
		var dist: float = _entity.global_position.distance_to(e.global_position)
		if dist <= nearest_dist:
			nearest_dist = dist
			nearest = e
	return nearest
