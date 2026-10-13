extends RefCounted
## 火柴人运动助手 —— 从 stickman_entity 拆出的移动/分离逻辑（§7.1）。
##
## 职责：
## - 地形/持盾移速倍率查询（_terrain_speed_mult / _blocking_speed_mult）
## - 加速/减速与移动动画公式（_handle_acceleration / _handle_deceleration）
## - AI 驱动移动与群体分离（_handle_ai_input / _apply_separation / _apply_static_separation）
## - 群体让路（9k，RTS 式：友军挡路给横向绕行分量，_sim_ally_yield / _ally_yield_lateral）
## - 统一移动处理（_apply_movement：方向 → 朝向/加速/奔跑 → velocity，sim 分支逐行保留）
##
## 速度/朝向/AI 意图状态字段（_current_speed/_is_running/_facing/_ai_move_dir/
## _ai_running）与公共 ai_move/ai_stop/get_armor_factor 留实体，本类只承载方法体。
## tests/dev/bench_units_main.gd 经实体 _handle_ai_input 壳直呼（契约壳留实体侧）。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null
## 让路绕行缓存（9k，sim 链）：与 AI 决策同拍重算、帧间持有——免逐帧邻居查询
## 分配，且偏航方向帧间稳定不抖；移动意图归零即清（重开会重算）
var _yield_cache: Vector2 = Vector2.ZERO


func _init(entity: Node) -> void:
	_entity = entity


# ─────────────────────────────── 运动常量 ────────────────────────────────
## walk 动画基准速率（速度=WALK_ANIM_BASE 时 anim_speed=1.0）。滑步/倍速治理
## 2026-10-06：基准必须=满走速 WALK_SPEED(160)——旧值 75 是 32→24px 换轨遗留，
## 配 ×1.4 倍率后满走播速 2.99×、满跑 2.87×，全员 locomotion 约三倍速播放
## ＝"画面像开倍速+滑步"的总根
const WALK_ANIM_BASE: float = 160.0
## run 动画基准速率（跑速=RUN_ANIM_BASE 时 anim_speed=1.0）＝RUN_SPEED(320)，
## 动画速率随跑速联动——跑得越快步频越快，防滑步
const RUN_ANIM_BASE: float = 320.0
## 动画整体播放倍率（1.0=原作步频直出；历史值 1.4 是无设计档出处的遗留加速，
## 2026-10-06 创始人验收"画面跟开了倍速一样"后复位）
const ANIM_SPEED_MULT: float = 1.0
## 切到 idle 的速度阈值（减速停止判定；原实体常量随减速公式迁入）
const IDLE_THRESHOLD: float = 5.0
## 分离检测半径（px）：与友军/任何单位过近时互相推开。数值与不变式（体宽 <
## 半径 < 编队间距）唯一维护在 formation 模块 formation_spacing.gd——历史上本处
## 与实体壳/批模拟各持一份副本，换轨漏改导致分离力对抗槽位、阵型挤散
const SEPARATION_RADIUS: float = preload("res://modules/formation/api.gd").SEPARATION_RADIUS
## 椭圆分离双轴（纵半径 = 前排间距量级——创始人 2026-10-11 裁决：垂直碰撞
## 箱设成前排那么大，接战战团靠碰撞自然展开，不需要阵型算法管接战期间距；
## 单一真相源 formation_spacing，消费方判定已全部改椭圆口径）
const _FormationAPI := preload("res://modules/formation/api.gd")
const SEPARATION_RADIUS_X: float = _FormationAPI.SEPARATION_RADIUS_X
const SEPARATION_RADIUS_Y: float = _FormationAPI.SEPARATION_RADIUS_Y
## 椭圆外接圆扫描半径（=max 两轴）：邻域查询用圆盒不漏人，逐对判定再走椭圆
const SEPARATION_SCAN_RADIUS: float = maxf(SEPARATION_RADIUS_X, SEPARATION_RADIUS_Y)
## 聚拢转向混入系数（班内一次性归队方向向量的混入权重；待实测校准）
const COHESION_STEER_FORCE: float = 0.8
## 分离推力系数（叠加到 AI 移动方向）
const SEPARATION_FORCE: float = 1.6
## 静态分离单帧位置修正上限（px）：N 路推力累加后仍 ≤ 此值，防瞬移（审计 P0-3）
const MAX_SEPARATION_CORRECTION: float = 3.0
## 驻株权重（battle_sim.SEPARATION_PLANTED_FACTOR 同语义同值）：站定单位
##（无移动意图且近静止）只吃小份静态分离修正——被移动方顶上时基本原地不动
const SEPARATION_PLANTED_FACTOR: float = 0.25
## 让路触发门槛：友军相对移动意图方向的前向点积 ≥ 此值才算"挡在去路上"（9k）。
## 身旁/身后的友军走常规分离不算挡路；收拢末段友军偏出锥面，绕行权重随点积衰减归零
const YIELD_AHEAD_DOT: float = 0.35
## 让路横向绕行强度上限（叠加进移动方向的垂直分量权重；0.9 ≈ 最大偏航约 42°）
const YIELD_LATERAL_FORCE: float = 0.9


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


## 移速倍率链（地形×档案×减速态×持盾×护甲）——加速/减速/换档斜坡共用，
## 单点维护防漂移（原减速路径漏 slow_mult 一项，斜坡化后两路同源）
func _speed_mult_chain() -> float:
	var se: Node = _entity.get_status_effects()
	if not _entity._se_checked:
		_entity._se_checked = true
		_entity._se_has_stun = se != null and se.has_method("has_stun")
		_entity._se_has_speed_mult = se != null and se.has_method("get_speed_mult")
	# slow_mult：SLOW 状态减速倍率（无组件/无方法 = 1.0；存在性走缓存布尔）
	var slow_mult: float = 1.0
	if se != null and _entity._se_has_speed_mult:
		slow_mult = se.get_speed_mult()
	return _terrain_speed_mult() * _entity.move_speed_mult * slow_mult \
			* _blocking_speed_mult() * _entity.armor_speed_factor


func _handle_acceleration(delta: float, allow_run: bool = true) -> void:
	var mult: float = _speed_mult_chain()
	var walk_cap: float = _entity.WALK_SPEED * mult
	var run_cap: float = _entity.RUN_SPEED * mult
	# 攻击动画期间不切移动动画（SWL 攻击与移动解耦：走 A 边跑边拉弓，
	# 动画播完由 rig animation_finished 回切；否则 run/walk 每帧覆盖拉弓动画）
	var attacking: bool = _entity._current_anim.begins_with("attack")
	if _entity._is_running:
		# 换档斜坡（批3）：跑档速度不瞬设——加速度限幅逼近跑速（SWL walkPower/Run
		# 力模型的连续速度观感等价物；walk→run 瞬跳 160→320 是速度硬跳观感源）；
		# 步频随爬升速度联动（攻击期间不动动画速率）
		_entity._current_speed = move_toward(_entity._current_speed, run_cap, _entity.accel * delta)
		if not attacking:
			_entity._visual.set_anim_speed(_entity._current_speed / RUN_ANIM_BASE * ANIM_SPEED_MULT)
		return
	_entity._current_speed += _entity.accel * delta
	if allow_run and _entity._current_speed >= walk_cap:
		# 进跑档只翻档位不跳速度——速度由跑档分支斜坡爬升
		_entity._is_running = true
		if not attacking:
			_entity._visual.play("run")
	else:
		# 不允许跑时，速度封顶在 walk_cap（受地形影响）
		_entity._current_speed = minf(_entity._current_speed, walk_cap)
		if not attacking and _entity._current_anim != "walk" and _entity._current_anim != "run":
			_entity._visual.play("walk")
		if _entity._current_anim == "walk" and not _entity._is_running:
			_entity._visual.set_anim_speed(_entity._current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT)


func _handle_deceleration(delta: float) -> void:
	if _entity._is_running:
		# 换档斜坡（批3）：退档不瞬降（原 run→walk 为 320→160 瞬跳+立即换 walk）——
		# 速度保留由下方减速段统一下坡；跑速带内维持跑步步态（步频随速度联动，
		# 不提前换 walk——高速播 walk=快走滑步），掉进走速带自然换档
		_entity._is_running = false
	# 攻击动画期间不切移动动画（同 _handle_acceleration：走 A 保护）
	var attacking: bool = _entity._current_anim.begins_with("attack")
	if _entity._current_speed > 0:
		_entity._current_speed -= _entity.decel * delta
		if _entity._current_speed <= IDLE_THRESHOLD:
			_entity._current_speed = 0.0
			if not attacking:
				_entity._visual.play("idle")
		elif _entity._current_speed > _entity.WALK_SPEED * _speed_mult_chain():
			# 跑速带内减速：跑步步态+步频联动
			if not attacking:
				if _entity._current_anim != "run":
					_entity._visual.play("run")
				_entity._visual.set_anim_speed(_entity._current_speed / RUN_ANIM_BASE * ANIM_SPEED_MULT)
		else:
			if not attacking and _entity._current_anim == "idle":
				_entity._visual.play("walk")
			if _entity._current_anim == "walk" and not attacking:
				_entity._visual.set_anim_speed(_entity._current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT)


# ─────────────────────────────── AI 输入处理 ────────────────────────────────

## AI 驱动移动：根据 _ai_move_dir 处理加速/减速/动画，复用与玩家输入相同的物理逻辑。
## 移动方向叠加群体分离（防叠人/1字长蛇，行业 soft-body separation 简化版）
## 与友军让路绕行（9k）。意图归零时清让路缓存（接近槽位/到位后绕行分量归零）。
func _handle_ai_input(delta: float) -> void:
	var dir: Vector2 = _entity._ai_move_dir
	if dir != Vector2.ZERO:
		dir = _apply_separation(dir)
	elif _yield_cache != Vector2.ZERO:
		_yield_cache = Vector2.ZERO
	dir = _apply_cohesion(dir)
	_apply_movement(delta, dir, _entity._ai_running, false)


## 椭圆分离归一距离（1.0=椭圆边界，<1 过近）：横向/纵深双轴口径——
## 与旧圆形 (1-dist/r) 权重语义同构，直接替换比较基准
func _sep_ellipse_d(offset: Vector2) -> float:
	var ex: float = offset.x / SEPARATION_RADIUS_X
	var ey: float = offset.y / SEPARATION_RADIUS_Y
	return sqrt(ex * ex + ey * ey)


## 分离不反转意图（批3 治"分离推挤换边"）：SWL PushApart 推的是刚体位置、
## 从不反转移动意图——归一混合下逆意图分量一旦压过意图本身，单位就会倒着走
## （朝向翻转/热锅蚂蚁源头之一）。反向推力压过走力 = **零速顶住**（SWL 走力
## 对抗推力的失速观感；velocity=0 自动落进卡死看门狗的无意图豁免，压阵单位
## 不再被误判卡死吃随机推力）；否则按横向分量偏航全速前进。前向/顶住二值，
## 硬重叠交给静态分离的位置修正。
static func _sep_no_reverse(mixed: Vector2, dir_n: Vector2) -> Vector2:
	if mixed.dot(dir_n) < 0.0:
		return Vector2.ZERO
	return mixed.normalized()


## 班内一次性归队（SWL 滞回+节流直译；内核 formation/squad_cohesion——
## JOIN/SETTLE 滞回进/出判定、0.4s 触发节流、接战/避战战斗优先全在内核门控）。
## 非归队态内核返回 ZERO（零施力：不打扰任务执行——站桩不拉、行军不扰、
## 接战不吸）；归队态返回指向锚点的方向向量，此处归一混入移动意图
## （掉队站桩单位由此获得一次归队移动，落定后回原任务）。
func _apply_cohesion(dir: Vector2) -> Vector2:
	var host: Node = _FormationAPI.get_active_host()
	if host == null or not is_instance_valid(host):
		return dir
	var steer: Vector2 = host.get_unit_cohesion_steer(_entity)
	if steer == Vector2.ZERO:
		return dir
	return (dir + steer.normalized() * COHESION_STEER_FORCE).normalized()


## 群体分离：扫描附近过近的单位（地图空间网格邻域查询），
## 距离越近推力越强，叠加到移动方向（RTS 单位移动标准做法，参考
## StickmanEntity 的 soft-body separation：位置推开 + 速度修正）。
## 9k 群体让路：友军挡在移动意图方向上时叠加横向绕行分量（_ally_yield_lateral），
## 纵队蛇形穿过友军密集区，而不是顶着分离力与人群对顶。
func _apply_separation(dir: Vector2) -> Vector2:
	var dir_n := dir.normalized()
	# sim 模式：走 sim 网格快照的内联推力查询（无逐邻居 Node 遍历）
	if _entity._sim_active():
		var result := dir
		var push_sim: Vector2 = _entity._sim.separation_push_ellipse(_entity._sim_sid)
		if push_sim != Vector2.ZERO:
			result = _sep_no_reverse(result + push_sim * SEPARATION_FORCE, dir_n)
		# 让路扫描与 AI 决策同拍（相位错峰，免逐帧邻居查询分配）；帧间持有缓存向量
		if _entity._ai_tick_counter % _entity._ai_rate_div == _entity._ai_phase % _entity._ai_rate_div:
			_yield_cache = _sim_ally_yield(dir_n)
		if _yield_cache != Vector2.ZERO:
			result = (result + _yield_cache).normalized()
		return result
	var map_ref: Node2D = _entity._map_ref
	if map_ref == null or not is_instance_valid(map_ref) or not _entity._map_has_query:
		return dir
	# 帧率优化：分离扫描隔物理帧跑（与静态分离共用帧计数）；
	# 相位按实例奇偶错开（批3 错峰）——全场不再同刻同拍扫描修正
	if _entity._sep_frame_counter % _entity._sep_rate_div != _entity._sep_phase:
		return dir
	var push := Vector2.ZERO
	var yield_side: float = 0.0
	var yield_mag: float = 0.0
	for e in map_ref.query_neighbors(_entity.global_position, SEPARATION_SCAN_RADIUS):
		if e == _entity or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var offset: Vector2 = _entity.global_position - e.global_position
		var dist: float = offset.length()
		var ed: float = _sep_ellipse_d(offset)
		if ed >= 1.0 or dist <= 0.001:
			continue
		# 越近推力越大（椭圆归一距离的 1-ed 线性权重）
		push += offset.normalized() * (1.0 - ed)
		# 9k 让路：仅友军计入"挡路"（同阵营 + 前向锥面内；权重随椭圆距离×前向点积衰减）
		if "faction_id" in e and e.faction_id == _entity.faction_id:
			var ahead: float = -offset.normalized().dot(dir_n)
			if ahead > YIELD_AHEAD_DOT:
				var w: float = (1.0 - ed) * ahead
				yield_mag += w
				# cross(意图方向, 挡路者相对位)：判挡路者偏意图向哪一侧（Godot 2D y 向下）
				yield_side += signf(dir_n.x * -offset.y - dir_n.y * -offset.x) * w
	if push == Vector2.ZERO and yield_mag <= 0.0:
		return dir
	var result := dir
	if push != Vector2.ZERO:
		result = _sep_no_reverse(result + push * SEPARATION_FORCE, dir_n)
	if yield_mag > 0.0:
		result = (result + _ally_yield_lateral(dir_n, yield_side, yield_mag)).normalized()
	return result


## sim 链让路扫描（9k）：BattleSim 批数据直读（query_neighbor_ids/get_pos/get_faction，
## 与 separation_push/set_intent 同一注入引用的既有公共面），免 Node 遍历。
## 返回横向绕行分量（无友军挡路 = 零向量）。
func _sim_ally_yield(dir_n: Vector2) -> Vector2:
	var sim = _entity._sim
	var my_pos: Vector2 = sim.get_pos(_entity._sim_sid)
	var my_faction: int = _entity.faction_id
	var side: float = 0.0
	var mag: float = 0.0
	for oid in sim.query_neighbor_ids(my_pos, SEPARATION_SCAN_RADIUS):
		if sim.get_faction(oid) != my_faction:
			continue
		var to: Vector2 = sim.get_pos(oid) - my_pos
		var dist: float = to.length()
		var ed: float = _sep_ellipse_d(to)
		if dist <= 0.001 or ed >= 1.0:
			continue
		var ahead: float = to.dot(dir_n) / dist
		if ahead <= YIELD_AHEAD_DOT:
			continue
		var w: float = (1.0 - ed) * ahead
		mag += w
		side += signf(dir_n.x * to.y - dir_n.y * to.x) * w
	if mag <= 0.0:
		return Vector2.ZERO
	return _ally_yield_lateral(dir_n, side, mag)


## 由挡路累计（强度 mag / 左右偏向 side）解出横向绕行分量（9k）。
## 不变式红线（formation_spacing.gd"分离力对抗槽位"教训）：本分量只在
## "有移动意图 + 挡路者是友军 + 友军在意图方向锥面内"时产生（调用方保证）；
## 方向取意图向的垂直向——与目标方向点乘恒 0，不减速不顶牛；权重随
## "距离 × 前向点积"衰减，友军偏到身侧即消失，到位后意图归零整体消失；
## 静止列阵单位无意图不进本路径，队形不会被推散。
## 绕行侧按挡路权重投票（挡路者多在垂直向哪侧就往反侧绕）；对称僵局
## （side≈0）按实例奇偶固定拆半——一半向左一半向右自然分流。
func _ally_yield_lateral(dir_n: Vector2, side: float, mag: float) -> Vector2:
	var s: float = signf(side)
	if s == 0.0:
		s = 1.0 if _entity.get_instance_id() % 2 == 0 else -1.0
	var perp := Vector2(-dir_n.y, dir_n.x)  # cross(dir,to)>0 的挡路者在此侧，往反侧绕
	if s > 0.0:
		perp = -perp
	return perp * (minf(mag, 1.0) * YIELD_LATERAL_FORCE)


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
	for e in map_ref.query_neighbors(_entity.global_position, SEPARATION_SCAN_RADIUS + 8.0):
		if e == _entity or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var offset: Vector2 = _entity.global_position - e.global_position
		var dist: float = offset.length()
		var ed: float = _sep_ellipse_d(offset)
		if ed >= 1.0:
			continue
		if dist <= 0.001:
			# 完全重叠：退化为固定方向（向上），否则无法计算推开方向
			offset = Vector2.UP
			ed = 0.0
		# 重叠量的一半推给自己（对方也在推自己，双向合计推开整个重叠量）；
		# 深度按椭圆归一折算（纵深轴为名义尺度）
		total_push += offset.normalized() * ((1.0 - ed) * SEPARATION_RADIUS_Y * 0.5)
	if total_push == Vector2.ZERO:
		return
	if total_push.length() > MAX_SEPARATION_CORRECTION:
		total_push = total_push.normalized() * MAX_SEPARATION_CORRECTION
	# 驻株权重（2026-10-12 创始人点正「跑动方把站立方顶飞」）：站定单位（无移动
	# 意图且近静止——站桩攻击/待命/守位）只吃小份修正——被移动方顶上时基本
	# 原地不动，重叠由移动方自己的修正解开（它被推回去＝在接触处刹停）；
	# 旧版对称半推＝站定者以移动方的推进速度被持续搬运。sim 链同语义
	#（battle_sim._tick_separation）
	var vx: float = _entity.velocity.x
	var vy: float = _entity.velocity.y
	var planted: bool = vx * vx + vy * vy < 400.0 \
			and _entity._ai_move_dir.length_squared() < 0.01
	if planted:
		total_push *= SEPARATION_PLANTED_FACTOR
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
			# facing 滞回（批3 源治热锅蚂蚁）+ 朝向节流走闸（SWL
			# DIRECTION_CHANGE_FREQUENCY=0.5 直译）：反向意图连续持续
			# FACING_PERSIST_SECS 才放行翻面请求——节流窗内保持原朝向
			# （人向新向走、脸缓半拍转——SWL 转身节奏），瞬时反号攒不满
			# 滞回窗根本翻不动；节流兜底低频翻转
			var side := 1 if dir.x > 0 else -1
			if _entity.note_move_facing(side, delta):
				_entity.try_set_facing(side)
		else:
			_entity.note_move_facing(0, delta)
		if run:
			_entity._is_running = true
			# 换档斜坡（批3）：强制跑同样不瞬跳——AI run/walk 意图切换即速度
			# 硬跳的主源；加速度限幅逼近跑速（步频随速度联动）
			var run_target: float = _entity.RUN_SPEED * _terrain_speed_mult() * _entity.move_speed_mult
			_entity._current_speed = move_toward(_entity._current_speed, run_target, _entity.accel * delta)
			_entity._visual.play("run")
			_entity._visual.set_anim_speed(_entity._current_speed / RUN_ANIM_BASE * ANIM_SPEED_MULT)
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
