class_name ArrowProjectile
extends Area2D
## 箭矢投影物 -- 弓（WeaponType.BOW）远程攻击发射。
##
## 复刻 SWL Arrow 类特性：
## - **抛物线弹道**（SWL Arrow.launchY/AimAngle）：固定重力积分，近距离平射、
##   远距高弧越顶——弓手站后排抛射不被友军前排挡箭
## - **单体碰撞命中**（SWL OnTriggerEnter2D，无范围伤害字段——见
##   docs/技术/参考/SWL-单位行为完整翻译.md §7）：箭碰谁谁中，一箭一人。
##   本作纵深轴压缩（视觉近≠逻辑近）用**加宽 y 容差**等效原作"擦到就中"
##   的观感，命中仍是纯单体碰撞语义，不引入范围伤害
## - 爆头判定 causesHeadShotAnimation：命中点在目标上部 1/4 → 爆头（管线加值+爆头死亡动画）
## - 插身 doesStickIn：命中后箭钉在受击者身上，随其移动，停留一段时间后淡出
##   （宿主死亡即脱离冻结，见 _freeze_stuck_arrow——死亡动画抖动不再甩箭）
## - 对雕像减伤 0.3 / 对巨人减伤 0.66（DamagePipeline 内处理）
## - 伤害走 DamagePipeline 单入口（复刻 Unit.Damage 语义）
## - 拉弓力度 drawPower 决定伤害（WeaponMount 传入）

# ─────────────────────────────── 常量 ────────────────────────────────
## 命中判定半径（px）：箭到目标碰撞体中心的横向（x）容差
const HIT_RADIUS: float = 25.5
## 纵深压缩系数：HD-2D 俯角投影把画布域地面纵深压进视觉域，压缩率
## k = sin(俯角)（hd2d_projection.gd：TILT_DEG=26.0 → squash_k ≈ 0.4384，
## FxLibrary.remap_pos → Hd2dMapBase.remap_fx_pos 的同一地面线协议）。
## 视觉近 ≠ 逻辑近——屏幕上 1px 纵深差对应画布域 1/k ≈ 2.28px（"约 2.3 倍
## 俯角压带"）。命中判定在画布域进行，y 容差按 k 的倒数放宽。
const DEPTH_SQUASH_K: float = 0.4384
## 命中判定纵向（y）容差 = HIT_RADIUS ÷ k ≈ 58.2px：视觉上与横向 25.5px
## 同宽的"擦到就中"判定带。SWL 原作没有范围命中（§7 实装要点对照表），
## 此容差是纵深轴换算的等效实现，不是 AOE。
const HIT_Y_TOLERANCE: float = HIT_RADIUS / DEPTH_SQUASH_K
## 击退力度系数（与近战一致：伤害 × KNOCKBACK_PER_DAMAGE）
const KNOCKBACK_PER_DAMAGE: float = 12.0
## 爆头判定：命中点相对目标碰撞体中心向上超过此比例 × 身高 → 爆头
const HEADSHOT_Y_RATIO := 0.22
## 箭插地留存时间（s），之后淡出（复刻 fadeOutOver）
const STUCK_LIFETIME: float = 4.0
## 爆头判定身高（目标碰撞体典型高度，px）
const BODY_HEIGHT := 97.5
## 落地判定：下落段相对出射点下降超过此值 → 插地（SWL InGroundArrows）
const GROUND_DROP: float = 375.0
## 兜底寿命（s）：超时强制插地（防极端弹道永生）
const MAX_FLIGHT_TIME: float = 6.0
## 近失半径查询的碰撞掩码（= 单位根节点层，镜像 arrow.tscn 的 collision_mask：
## 物理空间直查落点附近单位，仅终态调用一次，无逐帧成本）
const NEAR_MISS_QUERY_MASK: int = 2

## 兵种行为档案（压制键族；同模块 preload，与 status_effects/ai_controller 同款消费口径）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

# ─────────────────────────────── 运行时 ────────────────────────────────
## 飞行速度矢量（px/s；vel.y 每帧 += gravity×delta = 抛物线）
var _vel: Vector2 = Vector2.RIGHT * 640.0
## 重力（px/s²；0 = 直线弹道，兼容旧调用）
var _gravity: float = 0.0
var _damage: float = 10.0
var _shooter: Node = null
var _target: Node = null
## 已飞行距离（保留给调试/可能的射程判定）
var _traveled: float = 0.0
## 出射高度（落地判定基准）
var _launch_y: float = 0.0
## 出弓点脚线（画布域 y，0 = 未捕获）：视觉域偏移的地面分量起点。
## _ready 时节点尚未定位，故在首帧 _apply_visual_offset 里惰性捕获（见该函数）。
var _launch_ground_y: float = 0.0
## 已飞行时间（s；抛物线解算模式下与 _solve_time 比较判落地）
var _flight_time: float = 0.0
## 解算飞行时间（s，>0 = 抛物线解算模式）：飞满后继续沿弹道下落到瞄准点地面线
## （_solve_ground_y）才插地——落点≈目标脚下，散布 miss 自然越过插在敌阵里；
## 0 = 未传（旧调用），退回 GROUND_DROP 深度判定
var _solve_time: float = 0.0
## 瞄准点地面线（y；solve_time 模式下插地判定线）
var _solve_ground_y: float = 0.0
## 拉弓力度 0~1（SWL drawPower：满弓伤害更高）
var _draw_power: float = 1.0
## 已插地/插身（停止飞行，等待淡出）
var _stuck: bool = false
## 插地淡出计时
var _stuck_timer: float = 0.0
## 命中后是否插在受击者身上（原版 Arrow.doesStickIn 字段：插身上的箭 ≠
## InGroundArrows 插地的箭，两条路径）。true = 命中后钉在目标身上随其移动。
@export var does_stick_in: bool = true
## 在飞伤害登记目标（11d MissingArrowsTolerance 估计口径）：发射时锁定，
## 箭矢终态（命中任意敌人/插地）扣减其 incoming_arrow_damage
var _registered_target: Node = null
## 近失压制开关/半径/射手阵营快照（setup 时从射手兵种档案解析一次，射手阵亡后
## 仍生效；开关默认关 = 零回归；判定与施加见 try_near_miss_suppression）
var _near_miss_enabled: bool = false
var _near_miss_radius: float = 0.0
var _near_miss_shooter_faction: int = 0
## 近失候选注入出口（单测确定性断言用；空数组 = 按落点做物理半径查询）
var near_miss_candidates_override: Array = []
## 目标 Collider 引用缓存（setup 时解析一次）：箭雨场景每物理帧数百次
## 目标身体位置查询免 get_node 路径解析；引用失效时回落实时查找
var _target_collider: Node2D = null
## 本箭碰撞形状节点（_ready 缓存）：Area2D 判定带的形状真相源（见 _ready）
var _collision_shape: CollisionShape2D = null
## 插身宿主（_stick_into_deferred 换父后记录）：宿主死亡时箭脱离冻结（修乱飞）
var _stuck_host: Node = null
## 插身地面线基线差（画布域 y）：命中瞬间的弹道地面线 − 宿主脚线。插身态的
## 地面线 = 宿主当前脚线 + 该差——插身瞬间与飞行线连续（零跳变），此后随宿主
## 脚线逐帧刷新（与宿主 billboard 视觉锚同源同压缩，游移归零）
var _stuck_line_offset: float = 0.0


## 发射参数：初速度矢量、伤害、射手、目标、拉弓力度（0~1）、重力（缺省 0=直线，兼容旧调用）、
## 解算飞行时间（>0 = 抛物线解算模式）、瞄准点地面线（solve_time 模式下插地判定线，
## 0 = 飞满 solve_time 即插）。
## 抛物线模式下 vel 含竖直初速（WeaponMount 按目标距离解算）。
func setup(vel: Vector2, dmg: float, shooter: Node, target: Node = null, draw_power: float = 1.0, gravity: float = 0.0, solve_time: float = 0.0, solve_ground_y: float = 0.0) -> void:
	_vel = vel
	_gravity = gravity
	_damage = dmg
	_shooter = shooter
	_target = target
	_draw_power = clampf(draw_power, 0.0, 1.0)
	_solve_time = maxf(0.0, solve_time)
	_solve_ground_y = solve_ground_y
	rotation = _vel.angle()
	# 近失压制参数快照（发射瞬间的射手兵种档案；射手之后阵亡不影响本箭）
	_capture_near_miss_profile()
	# 11d 在飞伤害登记目标（终态扣减，见 _clear_incoming）
	if target != null and is_instance_valid(target) and "incoming_arrow_damage" in target:
		_registered_target = target
		# 目标 Collider 引用顺手缓存（_target_body_pos 每物理帧消费）
		_target_collider = target.get_node_or_null("Collider") as Node2D


func _ready() -> void:
	# 箭在空中飞行：挂绝对高层（高于 y 排序单位 z≈0~140），落点不被单位身体盖住
	z_as_relative = false
	z_index = 900
	body_entered.connect(_on_body_entered)
	_launch_y = global_position.y
	_wrap_visual_root()
	_setup_collision_shape()


## 碰撞形状真相源（脚本，场景 tscn 里的形状只是编辑器占位——箭/矛两个场景
## 共用本脚本，形状口径不允许各自漂移）：**竖直胶囊**（长轴沿世界 y），
## 半径 = HIT_RADIUS（x 容差）、半长 = HIT_Y_TOLERANCE（y 纵深容差），
## 与手动锁定路径的椭圆判定（x 25.5 / y 58.2）同口径。胶囊随根节点旋转会
## 跟着弹道歪斜，_physics_process 每帧反旋把它钉在世界系竖直方向——
## 纵深容差永远作用在纵深轴上。
func _setup_collision_shape() -> void:
	for ch in get_children():
		if ch is CollisionShape2D:
			_collision_shape = ch
			break
	if _collision_shape == null:
		_collision_shape = CollisionShape2D.new()
		add_child(_collision_shape)
	var cap := CapsuleShape2D.new()
	cap.radius = HIT_RADIUS
	cap.height = 2.0 * HIT_Y_TOLERANCE
	_collision_shape.shape = cap
	_collision_shape.rotation = -rotation


## ── HD-2D 视觉域偏移 ──────────────────────────────────────────────
## 绘制子节点收进 VisualRoot（碰撞形状留在根上，Area2D 判定不动），逐帧按图协议
## （`FxLibrary.remap_pos` → `remap_fx_pos`）把弹道地面线压进视觉域：箭的物理位置
## 在画布域（Area2D 判定/命中距离都在画布域算），直接照画会落在 billboard 部队
## 下方的草地上。**只压地面分量、弹道高度按原值保留**（身体纵向不压缩，
## MapBase 视觉域协议铁律 2）——按融合值直映射会把弧高当纵深，箭飞进天里。
## 2D 图 remap 恒等 → 偏移恒 0（零回归）。
var _visual_root: Node2D = null

func _wrap_visual_root() -> void:
	_visual_root = Node2D.new()
	_visual_root.name = "VisualRoot"
	for ch in get_children():
		if ch is CollisionShape2D or ch is CollisionPolygon2D:
			continue   # 碰撞形状必须是 Area2D 直接子级，留在根上
		remove_child(ch)
		_visual_root.add_child(ch)
	add_child(_visual_root)


func _apply_visual_offset() -> void:
	if _visual_root == null:
		return
	# 出弓点脚线（首帧位置 = 出弓位）：_ready 时节点还没定位，不能在 _ready 取
	if _launch_ground_y == 0.0:
		_launch_ground_y = global_position.y + 70.0
	var ground := Vector2(global_position.x, _ground_line_y())
	# 偏移 = 地面线的投影压缩量：箭在视觉域的落点 = 视觉地面线 − 原值弧高
	# （弧高由 pos.y 与地面线的差隐含携带，此处不再单独减一次）
	_visual_root.position = (FxLibrary.remap_pos(get_tree(), ground) - ground).rotated(-rotation)


## 弹道地面线（画布域 y）：
## - 插身态：跟宿主当前脚线（每帧重取宿主位置）——此前沿用出弓瞬间冻结的
##   地面线做纵深换算（k=sin26°），宿主每在画布 y 移动 1px，箭视觉相对宿主
##   billboard 漂移 (1−k)≈0.56px（诊断实测游移均值 27px / p90 67px，即"插身
##   箭在身上乱飞"的主因）。基线差在 _stick_into 捕获，插身瞬间与飞行线连续。
## - 飞行态：出弓点脚线 → 瞄准点脚线按飞行进度插值。
##   出弓点 = 出弓位 + 70 回推脚线（weapon_ranged 的 from = 脚线 − 70）；
##   瞄准点脚线 = 传入的插地线（aim_point + 65，aim_point 即目标脚线）回退 65。
func _ground_line_y() -> float:
	if _stuck:
		if _stuck_host != null and is_instance_valid(_stuck_host) and _stuck_host is Node2D:
			return (_stuck_host as Node2D).global_position.y + _stuck_line_offset
		return _launch_ground_y  # 宿主已死脱离冻结：线收口在脱离瞬间的宿主位
	if _solve_time <= 0.0 or _solve_ground_y <= 0.0:
		return _launch_ground_y
	return lerpf(_launch_ground_y, _solve_ground_y - 65.0, _ground_progress())


## 飞行进度 [0,1]：按已飞距离 / 解算总程（抛物线模式下速度幅值近似恒定）
func _ground_progress() -> float:
	if _solve_time <= 0.0:
		return 0.0
	var total: float = _vel.length() * _solve_time
	if total <= 1.0:
		return 0.0
	return clampf(_traveled / total, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	# 暂停冻结由引擎总闸负责（本节点 PAUSABLE，暂停期箭矢悬停）；
	# 步长经 sim_delta 携带速度档（弹道积分随档位缩放）
	if TimeManager != null:
		delta = TimeManager.sim_delta(delta)
	_apply_visual_offset()
	if _stuck:
		# 宿主死亡冻结（修"乱飞"）：插身箭钉在宿主骨骼上随宿主走，宿主死亡
		# 动画（倒地/抖动）会带着箭乱甩——宿主一死立即脱离回场景根，就地
		# 冻结姿态沿用既有淡出计时（计时不清零，插身多久就淡出多久）
		if _stuck_host != null and is_instance_valid(_stuck_host) and _host_is_dead(_stuck_host):
			_freeze_stuck_arrow()
		# 插地淡出（SWL fadeOutOver）
		_stuck_timer += delta
		if _stuck_timer >= STUCK_LIFETIME:
			queue_free()
		elif _stuck_timer >= STUCK_LIFETIME - 1.0:
			modulate.a = (STUCK_LIFETIME - _stuck_timer) / 1.0
		return
	# 抛物线积分：vel.y += g·dt（重力 y 向下为正）
	_vel.y += _gravity * delta
	var step := _vel * delta
	position += step
	_traveled += step.length()
	_flight_time += delta
	rotation = _vel.angle()
	# 碰撞形状反旋钉世界系竖直（见 _setup_collision_shape 注释）：纵深容差
	# 只作用于纵深轴，不随弹道角歪斜
	if _collision_shape != null:
		_collision_shape.rotation = -rotation
	# 手动命中检测（近战同款：不依赖物理碰撞）：**椭圆容差**——x 半轴
	# HIT_RADIUS、y 半轴 HIT_Y_TOLERANCE（纵深轴按 1/k 加宽，见常量注释）。
	# _target 是发射时锁定的敌方目标，无需阵营复查
	if _target != null and is_instance_valid(_target):
		var d: Vector2 = global_position - _target_body_pos(_target)
		var nx: float = d.x / HIT_RADIUS
		var ny: float = d.y / HIT_Y_TOLERANCE
		if nx * nx + ny * ny <= 1.0:
			_hit(_target)
			return
	# 落地判定（两条路径）：
	# ① 抛物线解算模式（solve_time>0）：飞满解算时间后沿弹道继续下落，越过
	#    瞄准点地面线即插——落点≈目标脚下，miss 自然插在敌阵（修复"低于出射点
	#    500px 才插地=贴地小半圆插前线"观感 bug，2026-09-01 观察场反馈 9c）
	# ② 旧调用（solve_time=0）：下落段低于出射点 GROUND_DROP，或兜底寿命到
	var landed: bool = false
	if _solve_time > 0.0:
		landed = _flight_time >= _solve_time \
				and (_solve_ground_y <= 0.0 or global_position.y >= _solve_ground_y)
		if _solve_time > 0.0 and _flight_time >= _solve_time + MAX_FLIGHT_TIME:
			landed = true  # 解算模式兜底（防极端弹道永生）
	else:
		landed = (_vel.y > 0.0 and global_position.y >= _launch_y + GROUND_DROP) \
				or _flight_time >= MAX_FLIGHT_TIME
	if landed:
		_stick_ground()


## 目标身体（碰撞体）世界位置：Collider 节点优先，缺省回落 root + 典型偏移。
## Collider 引用 setup 缓存（箭雨每物理帧数百次查询免 get_node 路径解析），
## 缓存失效（未缓存/已释放）时回落实时查找并重新缓存。
## 仅服务锁定目标的命中路径（飞行命中/爆头判定）；近失压制逐候选走
## _candidate_body_pos 直查——缓存是单一目标的位置，跨候选复用即错位。
func _target_body_pos(target: Node) -> Vector2:
	var col: Node2D = _target_collider
	if (col == null or not is_instance_valid(col)) and target != null:
		col = _body_collider(target)
		_target_collider = col
	return _body_pos_from(col, target)


## 候选身体（碰撞体）世界位置：按候选自身实时直查 Collider，不读写
## _target_collider 缓存——近失压制语义 = "这一候选的身体位置距爆点是否
## 在半径内"，与箭的锁定目标无关；复用缓存会把首个候选/锁定目标的位置
## 误套给其余全部候选（半径判定整体失效）。
func _candidate_body_pos(body: Node) -> Vector2:
	return _body_pos_from(_body_collider(body), body)


func _body_collider(target: Node) -> Node2D:
	if target == null:
		return null
	return target.get_node_or_null("Collider") as Node2D


## 身体位置空间换算（命中/近失两路共用）：碰撞体存在取其全局位，
## 否则 root + 典型偏移
func _body_pos_from(col: Node2D, target: Node) -> Vector2:
	if col != null:
		return col.global_position
	return (target as Node2D).global_position + Vector2(8.5, 130)


func _on_body_entered(body: Node2D) -> void:
	if _stuck:
		return
	if body == _shooter:
		return
	# 阵营过滤（SWL Arrow 碰撞只检敌方）：友军不挡箭不被打——
	# 抛物线下落段穿过己方人群时，误伤前排背后是"攻击友军"观感的根因
	if not _is_enemy(body):
		return
	# 命中实体本体（CharacterBody2D）
	if body is CharacterBody2D:
		_hit(body)


## 命中阵营判定：同阵营必不命中；任一方未参战（0）或射手信息缺失时保持可命中
## （兼容无阵营的测试桩/中立目标）
func _is_enemy(body: Node) -> bool:
	if _shooter == null or not is_instance_valid(_shooter):
		return true
	if not body.has_method("get_faction") or not _shooter.has_method("get_faction"):
		return true
	var f_shooter: int = _shooter.get_faction()
	var f_body: int = body.get_faction()
	if f_shooter == 0 or f_body == 0:
		return true
	return f_shooter != f_body


## 爆头判定：命中点高于目标身体中心 HEADSHOT_Y_RATIO × BODY_HEIGHT。
## 命中 y 差先按 1/k 折回视觉域再比阈值（与 HIT_Y_TOLERANCE 同口径换算）：
## 命中判定带已按纵深轴 1/k 加宽（视觉 1px 纵深 = 画布 2.28px），爆头阈值带
## 若仍是画布口径，纵深偏移的命中会被误判成爆头。数值待实测校准。
func _is_headshot(target: Node, hit_pos: Vector2) -> bool:
	var body_pos := _target_body_pos(target)
	var dy_visual: float = (body_pos.y - hit_pos.y) / DEPTH_SQUASH_K
	return dy_visual > BODY_HEIGHT * HEADSHOT_Y_RATIO


func _hit(target: Node) -> void:
	# 箭矢终态：扣减在飞伤害估计（无论实际命中者是否登记目标——估计口径允许偏差）
	_clear_incoming()
	# ── 伤害走 DamagePipeline 单入口（SWL Unit.Damage 复刻）──
	# SWL 箭伤 = drawPower 一次算定，无飞行时间衰减（RWR kill_decay 私货已回退：
	# 命中即全额结算，远近同伤——射程内的每一箭都是等威胁的）
	var p := DamagePipeline.Params.new(_damage * (0.6 + 0.4 * _draw_power), _shooter)
	p.direction = _vel.normalized()
	p.type = DamagePipeline.DAMAGE_TYPE.RANGED
	# 爆头：箭命中点在目标上部（causesHeadShotAnimation 语义）
	p.is_head_shot = _is_headshot(target, global_position)
	# 爆头加值/暴击参数取自射手的武器配置（原版 Unit.headShotBonusDamage 等字段
	# 是**每单位**配置的，不在管线里写死）
	var wm: Node = _shooter.get_node_or_null("WeaponMount") if _shooter != null else null
	if wm != null:
		p.head_shot_bonus_damage = _num(wm, "head_shot_bonus_damage", p.head_shot_bonus_damage)
		p.crit_damage_multiplier = _num(wm, "crit_damage_multiplier", p.crit_damage_multiplier)
		p.crit_self_damage = _num(wm, "crit_bonus_damage_inflicted_to_self", p.crit_self_damage)
		if _num(wm, "crit_chance", 0.0) > 0.0 and randf() < _num(wm, "crit_chance", 0.0):
			p.is_crit = true
	var dealt: float = DamagePipeline.apply(target, p)
	# 登记攻击者（防集火；与近战一致）
	if _shooter != null and _shooter.has_method("get_battle_instance"):
		var battle: Node = _shooter.get_battle_instance()
		if battle != null and is_instance_valid(battle) and battle.has_method("register_attacker"):
			battle.register_attacker(target, _shooter)
	if dealt > 0.0 and target.has_method("apply_hit_reaction"):
		target.apply_hit_reaction(_vel.normalized(), dealt * KNOCKBACK_PER_DAMAGE)
	# doesStickIn：箭钉在受击者身上随其移动，停留后淡出；否则就地消失
	if does_stick_in and is_instance_valid(target):
		_stick_into(target)
	else:
		queue_free()


## 插在受击者身上：停用碰撞，换父到目标节点（保持世界位姿——箭钉在命中点，
## 跟随单位移动），复用插地淡出计时。目标被释放时箭随场景树一并消失。
## 调用链在物理回调内（_on_body_entered）：碰撞开关与换父必须 call_deferred，
## 否则报 "Removing a CollisionObject node during a physics callback"。
func _stick_into(target: Node) -> void:
	# 插身地面线基线差（先于 _stuck 置位取飞行线）：命中瞬间的弹道地面线与
	# 宿主脚线的差——此后地面线 = 宿主当前脚线 + 该差（见 _ground_line_y）
	var host_pos: Vector2 = (target as Node2D).global_position if target is Node2D \
			else global_position
	_stuck_line_offset = _ground_line_y() - host_pos.y
	_stuck = true
	_stuck_timer = 0.0
	set_deferred("monitoring", false)
	_stick_into_deferred.call_deferred(target)


func _stick_into_deferred(target: Node) -> void:
	if not is_instance_valid(target):
		queue_free()
		return
	var xf: Transform2D = global_transform
	var parent: Node = get_parent()
	if parent != null:
		parent.remove_child(self)
	target.add_child(self)
	global_transform = xf
	_stuck_host = target


## 宿主死亡判定：有 is_dead() 的实体按其真值；测试桩等无此方法的宿主
## 永不触发冻结（保持旧行为，兼容）
func _host_is_dead(host: Node) -> bool:
	return host.has_method("is_dead") and bool(host.is_dead())


## 宿主死亡冻结（修"落地后乱飞"）：插身箭 reparent 在宿主骨骼下，宿主死亡
## 动画（倒地/翻滚/消散抖动）会带着箭满屏甩——宿主一死立即脱离回场景根，
## 就地冻结插身瞬间的世界位姿，沿用既有淡出计时（_stuck_timer 不重置）。
## SWL 对照：原作箭挂受击者骨骼（UpdateStuckInArrow），尸体被 Remove 时箭
## 一并回收，不存在"钉在乱动尸体上"的观感；本作死亡动画期较长，脱离冻结
## 是等效语义。调用点在 _physics_process（非物理回调），可直接改树。
func _freeze_stuck_arrow() -> void:
	# 冻结线收口：把当前跟随宿主的地面线写回出弓线，再清宿主引用——脱离后
	# _ground_line_y 回落到该值，视觉偏移不因脱离宿主跳变
	_launch_ground_y = _ground_line_y()
	_stuck_host = null
	var xf: Transform2D = global_transform
	# 先取场景根再拔箭：remove_child 后本节点不在树上，get_tree() 会是 null
	var tree := get_tree()
	if tree == null:
		return
	var root: Node = tree.current_scene if tree.current_scene != null else tree.root
	var parent: Node = get_parent()
	if parent != null:
		parent.remove_child(self)
	root.add_child(self)
	global_transform = xf


## 读取节点上的数值属性（属性不存在或类型不符时返回缺省值）。
static func _num(node: Node, prop: String, fallback: float) -> float:
	if node == null or not prop in node:
		return fallback
	var v: Variant = node.get(prop)
	return float(v) if v != null else fallback


## 插地：箭停在原地并倾斜，等待淡出（复刻 SetSpriteRendererForInGround + fadeOutOver）
func _stick_ground() -> void:
	_stuck = true
	_stuck_timer = 0.0
	# 箭矢终态：扣减在飞伤害估计（这箭没打中任何人，登记作废）
	_clear_incoming()
	# 监测引用失效（目标死后箭还在飞 → 立即插地）
	if _target != null and not is_instance_valid(_target):
		_target = null
	# 视觉：插地角度微微下倾
	rotation = _vel.angle() + 0.15
	# A6 近失压制：插地 = 本箭的"打偏"终态，落点附近敌人被压制（命中路径走
	# _hit，不经此处——命中已另有受击门槛触发源，两条路径不重复）
	try_near_miss_suppression()


## 近失压制参数快照（A6 · C9 近失触发源，射手兵种档案解析一次）：
## 开关 = suppression_enabled（总门）∧ suppression_near_miss_enabled（近失门）；
## 射手缺失/无武器类型 → 保持关（零回归）。
func _capture_near_miss_profile() -> void:
	_near_miss_enabled = false
	_near_miss_radius = 0.0
	_near_miss_shooter_faction = 0
	if _shooter == null or not is_instance_valid(_shooter) or not _shooter.has_method("get_weapon"):
		return
	if _shooter.has_method("get_faction"):
		_near_miss_shooter_faction = int(_shooter.get_faction())
	var w: Node = _shooter.get_weapon()
	if w == null or not is_instance_valid(w) or not ("weapon_type" in w):
		return
	var p: Dictionary = ScriptBehaviorProfiles.get_profile(int(w.weapon_type))
	_near_miss_enabled = bool(p.get("suppression_enabled", false)) \
			and bool(p.get("suppression_near_miss_enabled", false))
	_near_miss_radius = maxf(0.0, float(p.get("suppression_near_miss_radius", 0.0)))


## 近失压制：落点半径内的敌方单位经 StatusEffects 通用入口施加 SUPPRESSED。
## "擦身而过/落在脚边"同样构成压制因果——不要求命中（命中走受击门槛路径）。
## candidates 缺省 = 按落点做物理半径查询（单位层）；显式传入 = 单测注入。
## 只施加压制，不产生伤害（不触碰 DamagePipeline）。
## 返回本次被近失压制的单位数。
func try_near_miss_suppression(candidates: Array = []) -> int:
	if not _near_miss_enabled or _near_miss_radius <= 0.0:
		return 0
	var pool: Array = near_miss_candidates_override if not near_miss_candidates_override.is_empty() \
			else candidates
	if pool.is_empty():
		pool = _query_bodies_in_radius(_near_miss_radius)
	var applied: int = 0
	for body in pool:
		if body == null or not is_instance_valid(body) or body == _shooter:
			continue
		if not (body is Node2D):
			continue
		if not _is_near_miss_enemy(body):
			continue  # 只压制敌方（不误伤友军）
		if global_position.distance_to(_candidate_body_pos(body)) > _near_miss_radius:
			continue  # 半径外不算近失（按候选自身碰撞体直算，不读锁定目标缓存）
		if not body.has_method("get_status_effects"):
			continue
		var se: Node = body.get_status_effects()
		if se == null or not is_instance_valid(se) or not se.has_method("apply_suppression"):
			continue
		if se.apply_suppression(_shooter):
			applied += 1
	return applied


## 近失敌方过滤：按发射瞬间锁定的射手阵营判定——射手随后阵亡不影响本箭，
## 也不退化成"射手没了就六亲不认"误压友军；任一方阵营未知（0）= 不判为敌。
func _is_near_miss_enemy(body: Node) -> bool:
	if _near_miss_shooter_faction == 0:
		return false
	if not body.has_method("get_faction"):
		return false
	return int(body.get_faction()) != _near_miss_shooter_faction


## 落点半径内的单位列表（物理空间直查，单位层；仅箭矢终态调用一次）
func _query_bodies_in_radius(radius: float) -> Array:
	if not is_inside_tree():
		return []
	var world: World2D = get_world_2d()
	if world == null:
		return []
	var shape := CircleShape2D.new()
	shape.radius = radius
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = Transform2D(0.0, global_position)
	params.collision_mask = NEAR_MISS_QUERY_MASK
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var out: Array = []
	for hit in world.direct_space_state.intersect_shape(params):
		var collider: Variant = hit.get("collider")
		if collider != null and collider is Node:
			out.append(collider)
	return out


## 扣减登记目标头上的在飞伤害估计（11d MissingArrowsTolerance 估计口径；
## 箭矢所有终态调用一次，幂等：_registered_target 置空防重复扣减）
func _clear_incoming() -> void:
	if _registered_target == null:
		return
	if is_instance_valid(_registered_target) and "incoming_arrow_damage" in _registered_target:
		_registered_target.incoming_arrow_damage = maxf(
				0.0, _registered_target.incoming_arrow_damage - _damage)
	_registered_target = null
