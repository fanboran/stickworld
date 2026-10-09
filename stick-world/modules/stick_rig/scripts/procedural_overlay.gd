extends Node2D
## 程序化叠加层（Stick Fight 关节物理/程序化动画风格，纯算法原创）
##
## 在动画之上叠加程序化动作，让火柴人更有"关节弹性 + 惯性"的活感：
##   - 待机呼吸：hip 微起伏（正弦）
##   - 移动惯性：按实体速度，躯干反向倾斜（加速前倾、减速后仰）
##   - 挥剑回弹：攻击挥出后 IK 手目标 spring 衰减振荡（overshoot）
##   - 受击抖动：受击时躯干弹性抖动 + 手弹开
##   - 随机微抖：torso 低幅噪声（火柴人真动感）
##
## 设计：
##   - 只叠加"不参与 IK 的骨骼"（hip/lower_torso）与"IK 手目标位置"
##     （outhand/innerhand），不直接改 IK 骨骼 rotation，避免破坏 IK 解算。
##   - 绝对设置（base + overlay）而非累积：这些骨骼/标记不被动画每帧重置，
##     `+=` 会累积漂移（实测单调漂 70°）。
##   - 不碰 head 骨：head 由动画轨道驱动（拉弓仰角等）；旧实现每帧以启动基准
##     覆写 head.rotation，把动画值踩掉（当时 head 旋转视觉死码未暴露）。
##   - 挂载：由 StickmanRig._ready 动态创建为骨架子节点，连接 process_frame
##     （动画应用后叠加，下一帧动画覆盖后再叠加 → 等效"动画 + 叠加"持续生效）。

const TAU := 6.2831853

## 全局总开关（渲染对比诊断用：验证叠加层是否在渲染上生效/是否产生重影）
static var ENABLED := true

# 幅度常量（度）
const BREATH_HIP_DEG := 1.2
const LEAN_MAX_DEG := 5.0
const LEAN_GAIN := 0.025
const JITTER_TORSO_DEG := 0.1
# 手 IK 目标叠加幅度（像素）
const ARM_SPRING_AMP := 6.0
const ARM_SPRING_FREQ := 4.0
const HIT_SPRING_AMP := 7.0
const HIT_SPRING_FREQ := 9.0
const ARM_BREATHE_AMP := 2.5

var _skeleton: Skeleton2D
var _rig: Node2D
var _markers: Node2D
var _outhand: Marker2D
var _innerhand: Marker2D
var _hip: Bone2D
var _torso: Bone2D
var _entity: Node2D

# 基准（动画不驱动这些骨骼/标记，叠加以基准 + 偏移绝对设置，防累积漂移）
var _hip_base: float = 0.0
var _torso_base: float = 0.0
var _outhand_base := Vector2.ZERO
var _innerhand_base := Vector2.ZERO

var _time: float = 0.0
var _arm_spring: float = 0.0
var _hit_spring: float = 0.0
var _last_anim: String = ""
var _last_pos := Vector2.INF

## rig.get_current_anim 的 Callable 缓存（setup 后不变）：_on_frame 每渲染帧都要读
## 当前动画名，原先每帧 has_method 字符串反射 + duck 查找，大群单位下是稳定浪费
var _get_anim: Callable = Callable()

# 速度平滑：实体位置只在物理帧更新，渲染帧率(如 144Hz) > 物理帧率(60Hz) 时，
# 按渲染帧差分会得到 0/全速交替的振荡值（实测躯干 lean 每帧跳 4~8° → 抖动/重影）。
# 改为物理帧差分 + 指数平滑，渲染帧直接读平滑值。
var _phys_vx: float = 0.0
var _smooth_vx: float = 0.0

# 低频微抖噪声（替代每帧 randf 白噪声：白噪声 = 高频抖动，违背"低频小幅"注释本意）
var _noise := FastNoiseLite.new()

# ── LOD 节流（战斗级，StickmanRig.set_anim_update_hz 同步转发；未接入时零变化）──
## 更新频率（Hz）：>=60 每帧叠加（默认 = 现行全速行为）；<=0 完全不叠加；
## 否则按频率节流（累积真实 delta，达到 1/hz 执行一次）
var _update_hz: float = 60.0
## 节流累积器
var _hz_accum: float = 0.0
## ── 低帧率分桶（与 StickmanRig._process 推进分支同桶错峰）──
## fps << hz 时叠加层节流同样失效（每帧叠加 + notify_pose_dirty → 批渲染
## 每帧重写）。rig 按全局帧号分桶后把相位转发过来，跳过帧不叠加——但
## _hz_accum 照常累积真实 delta，下次叠加执行时 delta 取累计值，呼吸相位/
## spring 衰减幅度与真实时间一致（不慢动作）。
var _stagger_phase: int = 0
var _stagger_k: int = 1

# ── 拉弓瞄准俯仰（SWL Archer.Aim/_currentAim/UpdateAim 语义）──
## 目标俯仰角（rig 域弧度，负=仰头）：实体侧 behavior_attack 按弹道解算逐拍
## 推送，经 rig.set_aim_pitch 转发进来；应用层做两件事——
##   1) 渐进追踪（SWL UpdateAim：_currentAim 向 _targetAim 平滑逼近，不瞬跳）；
##   2) 弓族动画门控：仅 attack_bow* / walk_bow_hold 期间生效（其他动画归零）——
##      换箭/受击/死亡不做残留仰角。
## 应用点 = **持弓臂 upper_arm_inner**（臂+前臂+手+弓整组抬起）——SWL 实机
## 对照（创始人点正＋实机截图证）：拉弓时**躯干直立、腿站定，只有持弓臂
## 随射角抬起**，拉弓手保持在脸颊；反汇编 UpdateAim 的 FindBone 目标骨名
## 在 literal pool 静态不可解析，观感基准取实机画面。弓族动画全部带
## upper_arm_inner 连续轨道（每帧重写）→ 读-加-写不累积；暂停期动画停写，
## 叠加同步跳过（防暂停累积自旋）。角域钳 [−0.65, 0.15] rad（SWL AimAngle
## 抛物线解 v=15 实用射程 ~10°..45°）。
var _aim_pitch_target: float = 0.0
var _aim_pitch_applied: float = 0.0
## 追踪速率（1/s）：越大跟得越紧（0.5s 内约到 99%）
const AIM_PITCH_TRACK_RATE := 10.0
## 持弓臂骨（upper_arm_inner：weapon_hand=弓 的祖先臂）
var _bow_arm: Bone2D = null


## 设置叠加更新频率（LOD 分档；见 StickmanRig.set_anim_update_hz）。
## 叠加所用 delta 用真实累计值，保证呼吸相位/spring 衰减幅度与真实时间一致。
func set_update_hz(hz: float) -> void:
	_update_hz = hz
	_hz_accum = 0.0


## 拉弓瞄准俯仰目标角（rig.set_aim_pitch 转发入口；应用见 _on_frame）
func set_aim_pitch_target(rad: float) -> void:
	_aim_pitch_target = rad


## rig 低帧率分桶参数同步（桶相位/桶数；见 StickmanRig 低帧率分桶注）。
func set_stagger(seed: int, k: int) -> void:
	_stagger_phase = seed
	_stagger_k = k


func setup(skeleton: Skeleton2D, rig: Node2D) -> void:
	_skeleton = skeleton
	_rig = rig
	# 持弓臂俯仰绝对写须晚于 rig 的动画推进（_process 内 advance AnimationTree）：
	# 晚优先级 = SWL LateUpdate 的 Godot 等价（同帧内动画先应用、我后覆写）
	process_priority = 1000
	# 读当前动画的入口缓存成 Callable（方法存在性 setup 后不变，免每帧反射）
	if rig != null and rig.has_method("get_current_anim"):
		_get_anim = Callable(rig, "get_current_anim")
	# IK 目标父（OutlineGroup/Node2D）
	var outline := skeleton.get_parent()
	_markers = outline.get_node_or_null("Node2D") if outline != null else null
	if _markers != null:
		_outhand = _markers.get_node_or_null("outhand")
		_innerhand = _markers.get_node_or_null("innerhand")
	# 叠加目标骨骼（不参与 IK）；head 不叠加（动画轨道驱动，见文件头注）
	_hip = skeleton.get_node_or_null("hip")
	_torso = skeleton.get_node_or_null("hip/spine_root/lower_torso")
	_bow_arm = skeleton.get_node_or_null(
			"hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner") as Bone2D
	# 记录基准
	if _hip != null:
		_hip_base = _hip.rotation
	if _torso != null:
		_torso_base = _torso.rotation
	if _outhand != null:
		_outhand_base = _outhand.position
	if _innerhand != null:
		_innerhand_base = _innerhand.position
	# 每帧帧末叠加（动画应用之后）
	get_tree().process_frame.connect(_on_frame)
	# 速度在物理帧计算（位置只在物理帧更新，渲染帧差分会振荡）
	_noise.seed = 1337
	_noise.frequency = 0.5


## 外部通知：挥剑（从 rig.play 检测 attack 触发）
func notify_attack() -> void:
	_arm_spring = 1.0


## 外部通知：受击（从 rig 播放 hit 触发）
func notify_hit() -> void:
	_hit_spring = 1.0


func _physics_process(delta: float) -> void:
	# 实体水平速度：只在物理帧做位置差分（实体位置在物理帧更新）。
	# 渲染帧率 > 物理帧率时按渲染帧差分会得到 0/全速交替的振荡值。
	var node: Node2D = _find_entity()
	if node == null or not is_instance_valid(node):
		return
	var pos: Vector2 = node.global_position
	if _last_pos != Vector2.INF:
		_phys_vx = (pos.x - _last_pos.x) / maxf(delta, 0.0001)
	_last_pos = pos
	# 指数平滑（低通）：消除移动加速/减速/碰撞引起的瞬时波动
	_smooth_vx = lerpf(_smooth_vx, _phys_vx, clampf(delta * 20.0, 0.0, 1.0))


## 向上查找实体（CharacterBody2D），缓存引用
func _find_entity() -> Node2D:
	if _entity == null or not is_instance_valid(_entity):
		var node: Node = _skeleton
		while node != null:
			if node is CharacterBody2D:
				_entity = node
				break
			node = node.get_parent()
	return _entity


## 持弓臂瞄准俯仰的绝对写（SWL LateUpdate 式，晚于 rig 的动画推进）：
## 基值 = 当前动画旋转轨道在播放时刻的插值（sample_bone_track_rotation，
## 次序无关、暂停/LOD 节流下幂等），再叠加平滑后的俯仰。写后标脏批渲染。
## process_priority 在 setup 里置晚（默认 0 = rig 的 AnimationTree advance 先跑）
func _process(_delta: float) -> void:
	if _bow_arm == null or is_zero_approx(_aim_pitch_applied):
		return
	if _rig == null or not is_instance_valid(_rig):
		return
	var anim: String = str(_get_anim.call()) if _get_anim.is_valid() else ""
	if not (anim.begins_with("attack_bow") or anim == "walk_bow_hold"):
		return
	var t: float = float(_rig.get_anim_time(anim)) if _rig.has_method("get_anim_time") else -1.0
	if t < 0.0:
		return
	var base: float = float(_rig.sample_bone_track_rotation(
			anim, NodePath("hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner:rotation"), t)) \
			if _rig.has_method("sample_bone_track_rotation") else NAN
	if is_nan(base):
		return
	_bow_arm.rotation = base + _aim_pitch_applied
	if _rig.has_method("notify_pose_dirty"):
		_rig.notify_pose_dirty()


func _on_frame() -> void:
	if not ENABLED:
		return
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	var delta: float = get_process_delta_time()
	# LOD 频率闸门：<=0 不叠加；节流档累积到 1/hz 才执行一次（delta 换成累计值）
	if _update_hz <= 0.0:
		return
	# 低帧率分桶：跳过帧累积真实 delta 后直接返回（与 rig 推进同桶错峰，
	# 时间不丢失——下次叠加 delta 取累计值）
	if _stagger_k > 1 \
			and Engine.get_process_frames() % _stagger_k != _stagger_phase % _stagger_k:
		_hz_accum += delta
		return
	if _update_hz < 60.0:
		_hz_accum += delta
		if _hz_accum < 1.0 / _update_hz:
			return
		delta = _hz_accum
		_hz_accum = 0.0
	_time += delta

	# 当前动画（从 rig 读取；走缓存的 Callable，免每帧 has_method 反射查找）
	var anim: String = ""
	if _get_anim.is_valid():
		anim = _get_anim.call()
	if anim != _last_anim:
		# 动画切换事件
		if anim == "attack":
			notify_attack()
		elif anim == "hit_front" or anim == "hit_back":
			notify_hit()
		_last_anim = anim

	# ---- 叠加角累计 ----
	var hip_off := 0.0
	var torso_off := 0.0
	var outhand_off := Vector2.ZERO
	var innerhand_off := Vector2.ZERO

	# 1. 待机呼吸
	var is_idle: bool = anim == "idle" or anim == "idle_v2"
	if is_idle:
		var breath := sin(_time * TAU * 0.35)
		hip_off += breath * BREATH_HIP_DEG

	# 2. 移动惯性倾斜（速度用物理帧平滑值，渲染帧差分会振荡导致抖动）
	var is_moving: bool = anim == "walk" or anim == "run"
	if is_moving:
		var lean := clampf(_smooth_vx * LEAN_GAIN, -LEAN_MAX_DEG, LEAN_MAX_DEG)
		torso_off += lean

	# 3. 挥剑回弹（spring 衰减振荡）
	if _arm_spring > 0.001:
		_arm_spring *= exp(-6.0 * delta)
		var off := _arm_spring * sin(_time * TAU * ARM_SPRING_FREQ)
		outhand_off += Vector2(off * ARM_SPRING_AMP, -absf(off) * ARM_SPRING_AMP * 0.4)
		innerhand_off += Vector2(off * ARM_SPRING_AMP * 0.6, absf(off) * ARM_SPRING_AMP * 0.4)
	else:
		_arm_spring = 0.0

	# 4. 受击抖动
	if _hit_spring > 0.001:
		_hit_spring *= exp(-8.0 * delta)
		var j := _hit_spring * sin(_time * TAU * HIT_SPRING_FREQ)
		torso_off += j * HIT_SPRING_AMP * 0.5
		hip_off += j * HIT_SPRING_AMP * 0.3
		outhand_off += Vector2(j * HIT_SPRING_AMP, j * HIT_SPRING_AMP * 0.5)
		innerhand_off += Vector2(-j * HIT_SPRING_AMP, -j * HIT_SPRING_AMP * 0.5)
	else:
		_hit_spring = 0.0

	# 5. 低频微抖（轻微活感；用平滑噪声而非每帧 randf 白噪声——
	#    白噪声是高频抖动，在骨骼上是肉眼可见的持续颤/拖影）
	torso_off += _noise.get_noise_1d(_time * 2.0 + 100.0) * JITTER_TORSO_DEG

	# 6. 拉弓瞄准俯仰（SWL UpdateAim 渐进追踪）：弓族动画期间向目标角逼近，
	#    其他动画归零（受击/死亡/换弹无残留仰角）
	var pitch_goal: float = 0.0
	if anim.begins_with("attack_bow") or anim == "walk_bow_hold":
		pitch_goal = _aim_pitch_target
	_aim_pitch_applied = lerpf(_aim_pitch_applied, pitch_goal,
			clampf(delta * AIM_PITCH_TRACK_RATE, 0.0, 1.0))

	# ---- 应用（绝对设置 = 基准 + 叠加） ----
	# 瞄准俯仰**不在此处**写臂：process_frame 信号先于一切 _process（含 rig 的
	# AnimationTree advance），先写后必被轨道值覆盖（实锤：臂枢首版全帧被踩、
	# 战场读数平射）。臂的绝对写移到本叠加层 _process（process_priority 晚于
	# rig，SWL LateUpdate 等价），基值独立采样（见 _process）。
	if _torso != null:
		_torso.rotation = _torso_base + deg_to_rad(torso_off)
	if _hip != null:
		_hip.rotation = _hip_base + deg_to_rad(hip_off)
	if _outhand != null:
		_outhand.position = _outhand_base + outhand_off
	if _innerhand != null:
		_innerhand.position = _innerhand_base + innerhand_off
	# 批渲染层通知：叠加已改写骨骼/IK 标记，pose 实例缓冲需重写
	# （旧矢量路径无操作——部件节点直接从骨骼树取变换）
	if _rig != null and is_instance_valid(_rig) and _rig.has_method("notify_pose_dirty"):
		_rig.notify_pose_dirty()
