extends RefCounted
## 火柴人运动助手 —— 从 stickman_entity 拆出的移动/分离逻辑（§7.1）。
##
## 职责：
## - 地形/持盾移速倍率查询（_terrain_speed_mult / _blocking_speed_mult）
## - 加速/减速与移动动画公式（_handle_acceleration / _handle_deceleration）
## - AI 驱动移动与群体分离（_handle_ai_input / _apply_separation / _apply_static_separation）
## - 统一移动处理（_apply_movement：方向 → 朝向/加速/奔跑 → velocity，sim 分支逐行保留）
##
## 速度/朝向/AI 意图状态字段（_current_speed/_is_running/_facing/_ai_move_dir/
## _ai_running）与公共 ai_move/ai_stop/get_armor_factor 留实体，本类只承载方法体。
## tests/dev/bench_units_main.gd 经实体 _handle_ai_input 壳直呼（契约壳留实体侧）。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null


func _init(entity: Node) -> void:
	_entity = entity


# ─────────────────────────────── 运动常量 ────────────────────────────────
## walk 动画基准速率（速度=WALK_ANIM_BASE 时 anim_speed=1.0 * ANIM_SPEED_MULT）
const WALK_ANIM_BASE: float = 75.0   # 24px 换轨（旧 100；格/秒口径不变 → 动画相位不变）
## 动画整体播放倍率（×1.4 加速，与 visual_controller.gd 一致）
const ANIM_SPEED_MULT: float = 1.4
## 切到 idle 的速度阈值（减速停止判定；原实体常量随减速公式迁入）
const IDLE_THRESHOLD: float = 5.0
## 分离检测半径（px）：与友军/任何单位过近时互相推开——
## 必须略大于碰撞体宽（≈52），否则中心距 42 时身体已深度重叠
## （实体侧留同值 const 壳供 bench 直读，真身在此）
const SEPARATION_RADIUS: float = 54.0
## 分离推力系数（叠加到 AI 移动方向）
const SEPARATION_FORCE: float = 1.6
## 静态分离单帧位置修正上限（px）：N 路推力累加后仍 ≤ 此值，防瞬移（审计 P0-3）
const MAX_SEPARATION_CORRECTION: float = 3.0


## 获取当前脚下地形的移动速度倍率（土路=1.0，非土路=0.8）。
func _terrain_speed_mult() -> float:
	# _map_has_terrain_mult：set_map_reference 时缓存的方法存在性（免每帧字符串反射）
	if _entity._map_ref != null and is_instance_valid(_entity._map_ref) and _entity._map_has_terrain_mult:
		return _entity._map_ref.get_move_speed_mult_at_x(_entity.global_position.x)
	return 1.0


## 持盾移速倍率（盾姿态分层，计划 5）：举盾时读 WeaponMount 上的档案
## block_move_mult（SPEAR 0.8），未举盾/无字段 = 1.0。
func _blocking_speed_mult() -> float:
	var weapon_mount: Node2D = _entity.weapon_mount
	if weapon_mount == null or not is_instance_valid(weapon_mount):
		return 1.0
	# is_blocking 方法/block_move_mult 字段存在性不变 → 首次查一次记布尔（每帧反射免了）
	if not _entity._wm_checked:
		_entity._wm_checked = true
		_entity._wm_has_blocking = weapon_mount.has_method("is_blocking")
		_entity._wm_has_block_move_mult = "block_move_mult" in weapon_mount
	if not _entity._wm_has_blocking or not weapon_mount.is_blocking():
		return 1.0
	if _entity._wm_has_block_move_mult:
		return float(weapon_mount.block_move_mult)
	return 1.0


func _handle_acceleration(delta: float, allow_run: bool = true) -> void:
	var se: Node = _entity.get_status_effects()
	if not _entity._se_checked:
		_entity._se_checked = true
		_entity._se_has_stun = se != null and se.has_method("has_stun")
		_entity._se_has_speed_mult = se != null and se.has_method("get_speed_mult")
	# slow_mult：SLOW 状态减速倍率（无组件/无方法 = 1.0；存在性走缓存布尔）
	var slow_mult: float = 1.0
	if se != null and _entity._se_has_speed_mult:
		slow_mult = se.get_speed_mult()
	# 持盾移速惩罚（盾姿态分层，计划 5）：举盾行军更沉稳（档案 block_move_mult）
	var block_mult: float = _blocking_speed_mult()
	var mult: float = _terrain_speed_mult() * _entity.move_speed_mult * slow_mult * block_mult * _entity.armor_speed_factor
	var walk_cap: float = _entity.WALK_SPEED * mult
	var run_cap: float = _entity.RUN_SPEED * mult
	# 攻击动画期间不切移动动画（SWL 攻击与移动解耦：走 A 边跑边拉弓，
	# 动画播完由 rig animation_finished 回切；否则 run/walk 每帧覆盖拉弓动画）
	var attacking: bool = _entity._current_anim.begins_with("attack")
	if _entity._is_running:
		_entity._current_speed = run_cap
		return
	_entity._current_speed += _entity.accel * delta
	if allow_run and _entity._current_speed >= walk_cap:
		_entity._is_running = true
		_entity._current_speed = run_cap
		if not attacking:
			_entity._visual.play("run")
			_entity._visual.set_anim_speed(1.0 * ANIM_SPEED_MULT)
	else:
		# 不允许跑时，速度封顶在 walk_cap（受地形影响）
		_entity._current_speed = minf(_entity._current_speed, walk_cap)
		if not attacking and _entity._current_anim != "walk" and _entity._current_anim != "run":
			_entity._visual.play("walk")
		if _entity._current_anim == "walk" and not _entity._is_running:
			_entity._visual.set_anim_speed(_entity._current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT)


func _handle_deceleration(delta: float) -> void:
	if _entity._is_running:
		_entity._is_running = false
		_entity._current_speed = _entity.WALK_SPEED * _terrain_speed_mult() * _entity.move_speed_mult * _blocking_speed_mult() * _entity.armor_speed_factor
		_entity._visual.play("walk")
	# 攻击动画期间不切移动动画（同 _handle_acceleration：走 A 保护）
	var attacking: bool = _entity._current_anim.begins_with("attack")
	if _entity._current_speed > 0:
		_entity._current_speed -= _entity.decel * delta
		if _entity._current_speed <= IDLE_THRESHOLD:
			_entity._current_speed = 0.0
			if not attacking:
				_entity._visual.play("idle")
		else:
			if not attacking and _entity._current_anim == "idle":
				_entity._visual.play("walk")
			if _entity._current_anim == "walk" and not attacking:
				_entity._visual.set_anim_speed(_entity._current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT)


# ─────────────────────────────── AI 输入处理 ────────────────────────────────

## AI 驱动移动：根据 _ai_move_dir 处理加速/减速/动画，复用与玩家输入相同的物理逻辑。
## 移动方向叠加群体分离（防叠人/1字长蛇，行业 soft-body separation 简化版）。
func _handle_ai_input(delta: float) -> void:
	var dir: Vector2 = _entity._ai_move_dir
	if dir != Vector2.ZERO:
		dir = _apply_separation(dir)
	_apply_movement(delta, dir, _entity._ai_running, false)


## 群体分离：扫描附近过近的单位（地图空间网格邻域查询），
## 距离越近推力越强，叠加到移动方向（RTS 单位移动标准做法，参考
## StickmanEntity 的 soft-body separation：位置推开 + 速度修正）。
func _apply_separation(dir: Vector2) -> Vector2:
	# sim 模式：走 sim 网格快照的内联推力查询（无逐邻居 Node 遍历）
	if _entity._sim_active():
		var push_sim: Vector2 = _entity._sim.separation_push(_entity._sim_sid, SEPARATION_RADIUS)
		if push_sim == Vector2.ZERO:
			return dir
		return (dir + push_sim * SEPARATION_FORCE).normalized()
	var map_ref: Node2D = _entity._map_ref
	if map_ref == null or not is_instance_valid(map_ref) or not _entity._map_has_query:
		return dir
	# 帧率优化：分离扫描隔物理帧跑（与静态分离共用帧计数）
	if _entity._sep_frame_counter % _entity._sep_rate_div != 0:
		return dir
	var push := Vector2.ZERO
	for e in map_ref.query_neighbors(_entity.global_position, SEPARATION_RADIUS):
		if e == _entity or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var offset: Vector2 = _entity.global_position - e.global_position
		var dist: float = offset.length()
		if dist >= SEPARATION_RADIUS or dist <= 0.001:
			continue
		# 越近推力越大（1 - dist/radius 线性权重）
		push += offset.normalized() * (1.0 - dist / SEPARATION_RADIUS)
	if push == Vector2.ZERO:
		return dir
	return (dir + push * SEPARATION_FORCE).normalized()


## 静态分离（soft-body 位置修正）：对过近邻居直接推位置（重叠量各半，双向）。
## 与 _apply_separation 的区别：后者只在移动时生效；停住的单位（射程边缘
## 互停的敌我）靠本方法持续分开，解决"黏住"bug。参考 RtsGame.resolveSoftCollisions。
## 2026-08-31 审计 P0-3：所有邻居的推力**先累加再限幅**——原实现对每路推力
## 直接写坐标线性叠加（被 N 人围住 = N 路叠加无上限，一帧几十上百 px = 肉眼瞬移），
## 现在单帧总修正 ≤ MAX_SEPARATION_CORRECTION。
func _apply_static_separation() -> void:
	var map_ref: Node2D = _entity._map_ref
	if map_ref == null or not is_instance_valid(map_ref) or not _entity._map_has_query:
		return
	var total_push := Vector2.ZERO
	# +8px 余量：网格位置是本帧重建时刻的快照，覆盖帧内已发生的位移
	for e in map_ref.query_neighbors(_entity.global_position, SEPARATION_RADIUS + 8.0):
		if e == _entity or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var offset: Vector2 = _entity.global_position - e.global_position
		var dist: float = offset.length()
		if dist >= SEPARATION_RADIUS:
			continue
		if dist <= 0.001:
			# 完全重叠：退化为固定方向（向上），否则无法计算推开方向
			offset = Vector2.UP
			dist = 0.001
		# 重叠量的一半推给自己（对方也在推自己，双向合计推开整个重叠量）
		total_push += offset.normalized() * ((SEPARATION_RADIUS - dist) * 0.5)
	if total_push == Vector2.ZERO:
		return
	if total_push.length() > MAX_SEPARATION_CORRECTION:
		total_push = total_push.normalized() * MAX_SEPARATION_CORRECTION
	_entity.global_position += total_push


## 统一移动处理（玩家与 AI 共用）：方向 → 朝向/加速/奔跑 → velocity。
## run=true 强制奔跑；allow_run=false 时不会自动加速到奔跑（NPC 散步）。
## sim 模式：velocity 照算（动画曲线/速度标量与旧链完全同源），
## 但不落 move_and_slide——末尾写入 sim 意图，由批循环积分。
func _apply_movement(delta: float, dir: Vector2, run: bool, allow_run: bool) -> void:
	if dir != Vector2.ZERO:
		if dir.length() > 1.0:
			dir = dir.normalized()
		if dir.x != 0:
			var new_facing := 1 if dir.x > 0 else -1
			if new_facing != _entity._facing:
				_entity._facing = new_facing
				_entity._apply_scale()
		if run:
			_entity._is_running = true
			_entity._current_speed = _entity.RUN_SPEED * _terrain_speed_mult() * _entity.move_speed_mult
			_entity._visual.play("run")
			_entity._visual.set_anim_speed(1.0 * ANIM_SPEED_MULT)
		else:
			_handle_acceleration(delta, allow_run)
		_entity.velocity = dir * _entity._current_speed
	else:
		_handle_deceleration(delta)
		if _entity._current_speed > 0:
			# 保留方向但减速
			var v_dir = _entity.velocity.normalized() if _entity.velocity.length() > 0.001 else Vector2.ZERO
			_entity.velocity = v_dir * _entity._current_speed
		else:
			_entity.velocity = Vector2.ZERO
	if _entity._sim_active():
		_entity._sim.set_intent(_entity._sim_sid, _entity.velocity)
