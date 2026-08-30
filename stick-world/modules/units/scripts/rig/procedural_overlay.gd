extends Node2D
## 程序化叠加层（Stick Fight 关节物理/程序化动画风格，纯算法原创）
##
## 在动画之上叠加程序化动作，让火柴人更有"关节弹性 + 惯性"的活感：
##   - 待机呼吸：hip 微起伏 + 头微摆（正弦）
##   - 移动惯性：按实体速度，躯干/头反向倾斜（加速前倾、减速后仰）
##   - 挥剑回弹：攻击挥出后 IK 手目标 spring 衰减振荡（overshoot）
##   - 受击抖动：受击时躯干/头弹性抖动 + 手弹开
##   - 随机微抖：head/torso 低幅噪声（火柴人真动感）
##
## 设计：
##   - 只叠加"不参与 IK 的骨骼"（hip/lower_torso/neck）与"IK 手目标位置"
##     （outhand/innerhand），不直接改 IK 骨骼 rotation，避免破坏 IK 解算。
##   - 绝对设置（base + overlay）而非累积：这些骨骼/标记不被动画每帧重置，
##     `+=` 会累积漂移（实测 head 单调漂 70°）。
##   - 挂载：由 StickmanRig._ready 动态创建为骨架子节点，连接 process_frame
##     （动画应用后叠加，下一帧动画覆盖后再叠加 → 等效"动画 + 叠加"持续生效）。

const TAU := 6.2831853

## 全局总开关（渲染对比诊断用：验证叠加层是否在渲染上生效/是否产生重影）
static var ENABLED := true

# 幅度常量（度）
const BREATH_HIP_DEG := 1.2
const BREATH_HEAD_DEG := 1.0
const LEAN_MAX_DEG := 5.0
const LEAN_GAIN := 0.025
const JITTER_HEAD_DEG := 0.15
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
var _head: Bone2D
var _entity: Node2D

# 基准（动画不驱动这些骨骼/标记，叠加以基准 + 偏移绝对设置，防累积漂移）
var _hip_base: float = 0.0
var _torso_base: float = 0.0
var _head_base: float = 0.0
var _outhand_base := Vector2.ZERO
var _innerhand_base := Vector2.ZERO

var _time: float = 0.0
var _arm_spring: float = 0.0
var _hit_spring: float = 0.0
var _last_anim: String = ""
var _last_pos := Vector2.INF

# 速度平滑：实体位置只在物理帧更新，渲染帧率(如 144Hz) > 物理帧率(60Hz) 时，
# 按渲染帧差分会得到 0/全速交替的振荡值（实测 head lean 每帧跳 4~8° → 抖动/重影）。
# 改为物理帧差分 + 指数平滑，渲染帧直接读平滑值。
var _phys_vx: float = 0.0
var _smooth_vx: float = 0.0

# 低频微抖噪声（替代每帧 randf 白噪声：白噪声 = 高频抖动，违背"低频小幅"注释本意）
var _noise := FastNoiseLite.new()


func setup(skeleton: Skeleton2D, rig: Node2D) -> void:
	_skeleton = skeleton
	_rig = rig
	# IK 目标父（OutlineGroup/Node2D）
	var outline := skeleton.get_parent()
	_markers = outline.get_node_or_null("Node2D") if outline != null else null
	if _markers != null:
		_outhand = _markers.get_node_or_null("outhand")
		_innerhand = _markers.get_node_or_null("innerhand")
	# 叠加目标骨骼（不参与 IK）；head 骨骼可能不存在（部分骨架只有 neck），回退到 neck
	_hip = skeleton.get_node_or_null("hip")
	_torso = skeleton.get_node_or_null("hip/spine_root/lower_torso")
	_head = skeleton.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso/neck/head")
	if _head == null:
		_head = skeleton.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso/neck")
	# 记录基准
	if _hip != null:
		_hip_base = _hip.rotation
	if _torso != null:
		_torso_base = _torso.rotation
	if _head != null:
		_head_base = _head.rotation
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


func _on_frame() -> void:
	if not ENABLED:
		return
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	var delta: float = get_process_delta_time()
	_time += delta

	# 当前动画（从 rig 读取）
	var anim: String = ""
	if _rig != null and _rig.get("_current_anim") != null:
		anim = _rig.get("_current_anim")
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
	var head_off := 0.0
	var outhand_off := Vector2.ZERO
	var innerhand_off := Vector2.ZERO

	# 1. 待机呼吸
	var is_idle: bool = anim == "idle" or anim == "idle_v2"
	if is_idle:
		var breath := sin(_time * TAU * 0.35)
		hip_off += breath * BREATH_HIP_DEG
		head_off += -breath * BREATH_HEAD_DEG

	# 2. 移动惯性倾斜（速度用物理帧平滑值，渲染帧差分会振荡导致抖动）
	var is_moving: bool = anim == "walk" or anim == "run"
	if is_moving:
		var lean := clampf(_smooth_vx * LEAN_GAIN, -LEAN_MAX_DEG, LEAN_MAX_DEG)
		torso_off += lean
		head_off += lean * 0.8

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
		head_off += j * HIT_SPRING_AMP * 0.8
		hip_off += j * HIT_SPRING_AMP * 0.3
		outhand_off += Vector2(j * HIT_SPRING_AMP, j * HIT_SPRING_AMP * 0.5)
		innerhand_off += Vector2(-j * HIT_SPRING_AMP, -j * HIT_SPRING_AMP * 0.5)
	else:
		_hit_spring = 0.0

	# 5. 低频微抖（轻微活感；用平滑噪声而非每帧 randf 白噪声——
	#    白噪声是高频抖动，在骨骼上是肉眼可见的持续颤/拖影）
	head_off += _noise.get_noise_1d(_time * 2.0) * JITTER_HEAD_DEG
	torso_off += _noise.get_noise_1d(_time * 2.0 + 100.0) * JITTER_TORSO_DEG

	# ---- 应用（绝对设置 = 基准 + 叠加） ----
	if _head != null:
		_head.rotation = _head_base + deg_to_rad(head_off)
	if _torso != null:
		_torso.rotation = _torso_base + deg_to_rad(torso_off)
	if _hip != null:
		_hip.rotation = _hip_base + deg_to_rad(hip_off)
	if _outhand != null:
		_outhand.position = _outhand_base + outhand_off
	if _innerhand != null:
		_innerhand.position = _innerhand_base + innerhand_off
