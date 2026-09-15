extends RefCounted
## 火柴人附身输入助手 —— 从 stickman_entity 拆出的玩家控制逻辑（§7.5）。
##
## 职责：
## - 玩家移动输入（WASD/方向键，_handle_player_input）
## - 玩家攻击/空挥（_player_attack / _player_swing，鼠标左键 / G 键）
## - 战斗/探索模式切换（_toggle_combat_mode，Q 键）
## - 副手盾格挡（_set_player_blocking，右键按住/松开）
## - 输入辅助（_find_input_dispatcher / _find_nearest_enemy_in_range /
##   _is_ranged_weapon / _is_mouse_over_ui）
##
## 引擎回调 _input/_unhandled_input 留实体薄壳；tests/integration 直呼的
## _toggle_combat_mode / _player_attack / _find_nearest_enemy_in_range
## 在实体侧留委托壳（契约不变）。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null


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
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	_entity._apply_movement(delta, dir, false, not _entity._walk_only)


## 主手是否远程武器（弓/杖）：远程主控攻击不锁移动（走 A）。
func _is_ranged_weapon() -> bool:
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not is_instance_valid(weapon_mount) \
			or not "weapon_type" in weapon_mount:
		return false
	return int(weapon_mount.weapon_type) == 2 or int(weapon_mount.weapon_type) == 4


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
## 由 Q 键触发（仅附身时）。BATTLE 模式下玩家保持附身（ExploreHandler 不释放），
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


## 玩家附身时鼠标左键攻击：找最近敌人InRange并执行攻击。
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


## 鼠标是否悬停在 UI 控件上（悬停时玩家左键不攻击，保证按钮可点）。
func _is_mouse_over_ui() -> bool:
	var vp := _entity.get_viewport()
	if vp == null:
		return false
	if vp.has_method("gui_get_hovered_control"):
		return vp.gui_get_hovered_control() != null
	return false
