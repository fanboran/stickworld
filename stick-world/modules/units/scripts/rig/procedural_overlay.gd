extends Node2D
## 程序化叠加层（Stick Fight 关节物理/程序化动画风格，纯算法原创）
##
## 在动画之上叠加程序化动作，让火柴人更有"关节弹性 + 惯性"的活感：
##   - 待机呼吸：hip 微起伏 + 头微摆（正弦）
##   - 移动惯性：按实体速度，躯干/头反向倾斜（加速前倾、减速后仰）
##   - 随机微抖：head/torso 低幅噪声（火柴人真动感）
##
## 设计：
##   - 只叠加躯干轴上的三根骨（hip / minertorso1 / bone3），不碰肢体链，
##     避免与动画/骨架姿态互相踩踏。
##   - **先撤上帧叠加、再叠本帧**（`rot = rot - last + new`）：批次 B 换真骨架后
##     每根骨都被动画逐帧写绝对值，绝对设置（base + overlay）会把动画整段抹掉；
##     纯 `+=` 又会在"该动画没有这根骨的轨道"时累积漂移。先撤后加两种情形都对。
##   - 挂载：由 StickmanRig._ready 动态创建为骨架子节点，连接 process_frame
##     （动画应用后叠加，下一帧动画覆盖后再叠加 → 等效"动画 + 叠加"持续生效）。
##   - 历史上的"IK 手目标抖动"随 IK 装置一并移除：IK 修改器栈实测从不解算
##     （见 docs/设计/系统/火柴人逆向重建与覆盖率方案.md §三），手目标无消费者。

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

## 叠加目标骨（Spine 骨名）+ 路径（批次 B：骨骼字典键 = Spine 骨名）
const HIP_PATH := "RigRoot/root/bone"
const TORSO_PATH := "RigRoot/root/bone/minertorso1"
const HEAD_PATH := "RigRoot/root/bone/minertorso1/bone2/bone3"

var _skeleton: Skeleton2D
var _rig: Node2D
var _hip: Bone2D
var _torso: Bone2D
var _head: Bone2D
var _entity: Node2D

# 上一帧已叠加的偏移（本帧先撤销再加新值：兼容"动画写了绝对值"与"无该轨道"）
var _hip_applied: float = 0.0
var _torso_applied: float = 0.0
var _head_applied: float = 0.0

var _time: float = 0.0
var _last_anim: String = ""

# 速度平滑：实体位置只在物理帧更新，渲染帧率(如 144Hz) > 物理帧率(60Hz) 时，
# 按渲染帧差分会得到 0/全速交替的振荡值（实测 head lean 每帧跳 4~8° → 抖动/重影）。
# 改为物理帧差分 + 指数平滑，渲染帧直接读平滑值。
var _phys_vx: float = 0.0
var _smooth_vx: float = 0.0
var _last_pos := Vector2.INF

# 低频微抖噪声（替代每帧 randf 白噪声：白噪声 = 高频抖动，违背"低频小幅"注释本意）
var _noise := FastNoiseLite.new()


func setup(skeleton: Skeleton2D, rig: Node2D) -> void:
	_skeleton = skeleton
	_rig = rig
	# 叠加目标骨骼（躯干轴三根：髋 / 下躯干 / 颈等价骨）
	_hip = skeleton.get_node_or_null(HIP_PATH)
	_torso = skeleton.get_node_or_null(TORSO_PATH)
	_head = skeleton.get_node_or_null(HEAD_PATH)
	# 每帧帧末叠加（动画应用之后）
	get_tree().process_frame.connect(_on_frame)
	# 速度在物理帧计算（位置只在物理帧更新，渲染帧差分会振荡）
	_noise.seed = 1337
	_noise.frequency = 0.5


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

	# 当前动画跟踪（从 rig 读状态名；供呼吸/惯性判断）
	if _rig != null and _rig.get("_current_anim") != null:
		_last_anim = str(_rig.get("_current_anim"))

	# ---- 叠加角累计 ----
	var hip_off := 0.0
	var torso_off := 0.0
	var head_off := 0.0

	# 1. 待机呼吸（idle/idle_v2 及各兵种待机变体都算待机）
	var is_idle: bool = _last_anim.begins_with("idle") or _last_anim == "stand"
	if is_idle:
		var breath := sin(_time * TAU * 0.35)
		hip_off += breath * BREATH_HIP_DEG
		head_off += -breath * BREATH_HEAD_DEG

	# 2. 移动惯性倾斜（速度用物理帧平滑值，渲染帧差分会振荡导致抖动）
	var is_moving: bool = _last_anim == "walk" or _last_anim == "run"
	if is_moving:
		var lean := clampf(_smooth_vx * LEAN_GAIN, -LEAN_MAX_DEG, LEAN_MAX_DEG)
		torso_off += lean
		head_off += lean * 0.8

	# 3. 低频微抖（轻微活感；用平滑噪声而非每帧 randf 白噪声——
	#    白噪声是高频抖动，在骨骼上是肉眼可见的持续颤/拖影）
	head_off += _noise.get_noise_1d(_time * 2.0) * JITTER_HEAD_DEG
	torso_off += _noise.get_noise_1d(_time * 2.0 + 100.0) * JITTER_TORSO_DEG

	# ---- 应用（先撤上帧叠加、再叠本帧：动画逐帧写绝对值也不会被抹掉） ----
	_hip_applied = _apply_offset(_hip, deg_to_rad(hip_off), _hip_applied)
	_torso_applied = _apply_offset(_torso, deg_to_rad(torso_off), _torso_applied)
	_head_applied = _apply_offset(_head, deg_to_rad(head_off), _head_applied)


## 撤上帧偏移 + 叠本帧偏移，返回本帧偏移（供下帧撤销）
func _apply_offset(bone: Bone2D, offset: float, applied: float) -> float:
	if bone == null:
		return 0.0
	bone.rotation = bone.rotation - applied + offset
	return offset
