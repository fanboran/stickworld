@tool
class_name StickmanRig
extends Skeleton2D
## 火柴人渲染骨架（主控制器）
##
## 基于 Skeleton2D + Bone2D，在编辑器中只能旋转骨骼关节（不能拖动位置），
## K 帧体验自然。协调骨骼、纹理、动画、武器子系统。
## Inspector 可调参数：厚度、颜色、缩放、武器。

const Skeleton := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")
const Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")
const Weapon := preload("res://modules/units/scripts/weapons/stickman_weapon.gd")
const OverlayScript := preload("res://modules/units/scripts/rig/procedural_overlay.gd")

# ===== 动画状态名（公共 API 用） =====
const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_RUN := "run"
const ANIM_ATTACK := "attack"
const ANIM_DEAD := "dead"
const ANIM_HIT := "hit"
const ANIM_HIT_FRONT := "hit_front"
const ANIM_HIT_BACK := "hit_back"

# ===== 武器类型枚举（待扩展） =====
enum WeaponType { SWORD, SPEAR, BOW, SHIELD, UNARMED }

# ===== Inspector 可调参数 =====
@export var stick_scale: float = 1.0:
	set(v):
		stick_scale = v
		_rebuild_pending = true
@export var thickness_scale: float = 1.0:
	set(v):
		thickness_scale = v
		_rebuild_pending = true
@export var body_color: Color = Skeleton.DEFAULT_BODY:
	set(v):
		body_color = v
		_rebuild_pending = true
@export var weapon_color: Color = Skeleton.DEFAULT_WEAPON:
	set(v):
		weapon_color = v
		_rebuild_pending = true
@export var guard_color: Color = Skeleton.DEFAULT_GUARD:
	set(v):
		guard_color = v
		_rebuild_pending = true
@export var outline_color: Color = Skeleton.DEFAULT_OUTLINE:
	set(v):
		outline_color = v
		_rebuild_pending = true
@export var weapon_scene: PackedScene:
	set(v):
		weapon_scene = v
		_refresh_weapon(Skeleton.WEAPON_ATTACH_R)
@export var offhand_scene: PackedScene:
	set(v):
		offhand_scene = v
		_refresh_weapon(Skeleton.WEAPON_ATTACH_L)

# ===== 运行时引用 =====
var _bones: Dictionary = {}
var _sprites: Dictionary = {}
var _anim_player: AnimationPlayer
var _anim_tree: AnimationTree
var _state_machine: AnimationNodeStateMachinePlayback
var _current_anim: String = ANIM_IDLE
var _weapon_r: Node2D
var _weapon_l: Node2D
var _rebuild_pending: bool = false
## 受击插播计时（>0 表示正在受击动画，倒计时结束后回切到 _hit_return_to）
var _hit_timer: float = -1.0
## 受击前状态（动画播完后回切）
var _hit_return_to: String = ANIM_IDLE
## 已发送 animation_finished 的 state（防重复触发；离开该 state 后重置）
var _finished_sent_state: String = ""
## 动画事件派发状态：当前跟踪的动画名
var _event_anim: String = ""
## 动画事件派发状态：上一帧播放位置（用于检测重播/循环回绕）
var _event_last_pos: float = -1.0
## 动画事件派发状态：本轮已发射的事件键集合（"事件名@时间"）
var _fired_events: Dictionary = {}

## 动画播放结束信号（反编译参考实装 C）：LOOP_NONE 动画播完时发射（对应传奇 UpdateFinishAnimation）。
## 供攻击播完回切、受击播完回切、未来动作节奏（如 build 敲击）等使用。
signal animation_finished(anim_name: String)

## 动画内嵌事件信号（复刻 Spine animations[].events[] / 传奇 AnimationSpec.Events[]）。
## 播放位置越过事件时间点时发射一次；切状态或播放位置回退（重播/循环）后重新计数。
## 事件由 tools/baking/spine_import.gd 从解包 Spine JSON 导出为动画元数据：
##   Hit（命中帧）/ Sound（音效，value=音效名）/ Drawn（弓拉满）/ Mine（矿工敲击）。
## 消费方（WeaponMount）一律读真值，禁止再写"命中帧 = 动画进度 × 拍脑袋比例"。
signal animation_event(anim_name: String, event_name: String, value: String)


# ============================================================
#  生命周期
# ============================================================

func _ready() -> void:
	_init_bones()
	_init_ik()
	_init_animations()
	_init_weapons()
	# 程序化叠加层（Stick Fight 关节物理/惯性风格；纯算法，动画之上叠加）
	_init_procedural_overlay()

func _process(_delta: float) -> void:
	if _state_machine == null and _anim_tree != null:
		_state_machine = _anim_tree.get("parameters/playback")
	if _rebuild_pending:
		_rebuild_pending = false
		_do_rebuild()
	# 受击插播倒计时：动画播完回切到受击前状态（反编译参考实装 B）
	if _hit_timer > 0.0:
		_hit_timer -= _delta
		if _hit_timer <= 0.0 and _state_machine != null:
			_state_machine.travel(_hit_return_to)
			_current_anim = _hit_return_to
	# 动画结束检测（反编译参考实装 C）：LOOP_NONE 动画播完发射 animation_finished
	_check_animation_finished()
	# 动画内嵌事件派发（Spine events[] 复刻）：越过事件时间点时发射 animation_event
	_check_animation_events()


## LOOP_NONE 动画播完检测：当前 state 播放位置 >= 动画长度时发射 animation_finished（仅一次）。
## 对应传奇 AnimationSystem.UpdateFinishAnimation；供攻击/受击等单次动画结束驱动回切或后续逻辑。
func _check_animation_finished() -> void:
	if _state_machine == null:
		return
	var cur: String = _state_machine.get_current_node()
	if cur.is_empty() or cur == "Start" or cur == _finished_sent_state:
		return
	# 只对 LOOP_NONE 动画发结束信号（循环动画永不结束）
	var anim: Animation = null
	if _anim_player != null and _anim_player.has_animation(cur):
		anim = _anim_player.get_animation(cur)
	if anim == null or anim.loop_mode != Animation.LOOP_NONE:
		return
	var len: float = _state_machine.get_current_length()
	var pos: float = _state_machine.get_current_play_position()
	if len > 0.0 and pos >= len - 0.02:
		_finished_sent_state = cur
		animation_finished.emit(cur)


## 动画内嵌事件派发：当前动画播放位置越过 anim_events 中任一事件时间点 → 发射一次。
## 事件表来自动画资源元数据（spine_import 从 Spine JSON 导出；无元数据则静默跳过）。
## 重播判定：切换动画、或播放位置回退（LOOP 动画回绕 / 重新 travel）→ 清空已发集合。
func _check_animation_events() -> void:
	if _state_machine == null or _anim_player == null:
		return
	var cur: String = _state_machine.get_current_node()
	if cur.is_empty() or cur == "Start" or not _anim_player.has_animation(cur):
		return
	var anim: Animation = _anim_player.get_animation(cur)
	if anim == null or not anim.has_meta("anim_events"):
		return
	var events: Array = anim.get_meta("anim_events")
	if events.is_empty():
		return
	var pos: float = _state_machine.get_current_play_position()
	if cur != _event_anim or pos < _event_last_pos - 0.001:
		_event_anim = cur
		_fired_events = {}
	_event_last_pos = pos
	for e in events:
		var t: float = float(e["time"])
		if pos < t:
			continue
		# 同帧多事件（如 Sound + Hit 同时点）各发一次：键含时间以区分
		var key: String = "%s@%.4f" % [e["name"], t]
		if _fired_events.has(key):
			continue
		_fired_events[key] = true
		animation_event.emit(cur, str(e["name"]), str(e["string"]))


# ============================================================
#  初始化
# ============================================================

## 程序化叠加层：创建为骨架子节点，动画之上叠加惯性/呼吸/弹性（非 IK 骨骼 + IK 手目标）
func _init_procedural_overlay() -> void:
	if get_node_or_null("ProceduralOverlay") != null:
		return
	var overlay := Node2D.new()
	overlay.name = "ProceduralOverlay"
	overlay.set_script(OverlayScript)
	add_child(overlay)
	overlay.call("setup", self, self)


func _init_bones() -> void:
	var colors := _make_colors()
	# 检查是否已有骨骼（通过 hip 节点判断）
	if get_node_or_null("hip") != null:
		Skeleton.reorder_render_order(self)
		_bones = Skeleton.collect_nodes(self)["bones"]
		# .tscn 骨骼 + 运行时矢量肢体（场景不再预置贴图精灵）
		_sprites = Skeleton.build_limbs(self, _bones, thickness_scale, colors)
	else:
		# 首次打开：从零构建骨骼 + 矢量肢体
		var result := Skeleton.build_from_scratch(self, thickness_scale, colors)
		_bones = result["bones"]
		_sprites = result["sprites"]


## 组装颜色表（矢量肢体直接消费）
func _make_colors() -> Dictionary:
	return {
		"body": body_color,
		"weapon": weapon_color,
		"guard": guard_color,
		"outline": outline_color,
	}



func _init_ik() -> void:
	# 运行时通过遍历骨骼修正 bone_idx，避免 .tscn 中写死的索引和实际不匹配
	var stack := get_modification_stack()
	if stack == null:
		push_warning("[IK] modification_stack 为 null，IK 不会执行")
		return
	# 强制每个实例拥有独立的 modification stack 副本，避免多实例共享同一资源导致 IK 冲突
	if not Engine.is_editor_hint():
		var unique_stack := stack.duplicate(true) as SkeletonModificationStack2D
		if unique_stack != null:
			set_modification_stack(unique_stack)
			stack = unique_stack
	# 构建骨骼名->索引映射
	var bone_name_to_idx: Dictionary = {}
	for idx in range(get_bone_count()):
		var b := get_bone(idx)
		if b:
			bone_name_to_idx[b.name] = idx
	for i in range(stack.modification_count):
		var mod := stack.get_modification(i) as SkeletonModification2DTwoBoneIK
		if mod == null:
			push_warning("[IK] modification ", i, " 不是 TwoBoneIK")
			continue
		# 通过 NodePath 找到 Bone2D 节点，再用名称查实际索引
		var bone1 := get_node_or_null(mod.joint_one_bone2d_node) as Bone2D
		var bone2 := get_node_or_null(mod.joint_two_bone2d_node) as Bone2D
		if bone1:
			var idx1: int = bone_name_to_idx.get(bone1.name, -1)
			if idx1 >= 0:
				mod.joint_one_bone_idx = idx1
		else:
			push_warning("[IK] mod ", i, ": bone1 NodePath 解析失败: ", mod.joint_one_bone2d_node)
		if bone2:
			var idx2: int = bone_name_to_idx.get(bone2.name, -1)
			if idx2 >= 0:
				mod.joint_two_bone_idx = idx2
		else:
			push_warning("[IK] mod ", i, ": bone2 NodePath 解析失败: ", mod.joint_two_bone2d_node)
		# 检查目标节点
		var target := get_node_or_null(mod.target_nodepath) as Node2D
		if target == null:
			push_warning("[IK] mod ", i, ": target NodePath 解析失败: ", mod.target_nodepath)
	# 延迟一帧启用 IK：Skeleton2D + IK 在 _ready 后首帧不保证解算，
	# 先禁用栈、等一个帧周期再启用，让解算自然完成（替代"前 0.25s 模拟移动"的 workaround）
	if not Engine.is_editor_hint():
		stack.enabled = false
		call_deferred("_enable_ik_stack", stack)


func _enable_ik_stack(stack: SkeletonModificationStack2D) -> void:
	if stack != null and is_instance_valid(stack):
		stack.enabled = true


func _init_animations() -> void:
	_anim_player = get_node_or_null("AnimationPlayer") as AnimationPlayer
	_anim_tree = get_node_or_null("AnimationTree") as AnimationTree
	if _anim_player == null:
		return
	# AnimationPlayer 是骨架（StickmanRig）的子节点，root_node = ".." 指向骨架自身；
	# 动画 track 路径（如 "thigh_outer"、"hip/lower_torso/..."）相对骨架根解析。
	_anim_player.root_node = NodePath("..")
	# 编辑器模式下断开 AnimationTree 的 anim_player，避免 state machine
	# 把 idle pose 应用到骨骼，阻止 IK 实时调试。运行时由 setup_tree 重新关联。
	if Engine.is_editor_hint():
		if _anim_tree != null:
			_anim_tree.active = false
			_anim_tree.anim_player = NodePath()
		return
	Anims.setup_player(_anim_player)
	if _anim_tree != null:
		_state_machine = Anims.setup_tree(_anim_tree, _anim_player)


func _init_weapons() -> void:
	if Engine.is_editor_hint():
		return
	_refresh_weapon(Skeleton.WEAPON_ATTACH_R)
	_refresh_weapon(Skeleton.WEAPON_ATTACH_L)


# ============================================================
#  武器刷新
# ============================================================

func _refresh_weapon(bone_id: int) -> void:
	# 清除旧武器
	var old := _weapon_r if bone_id == Skeleton.WEAPON_ATTACH_R else _weapon_l
	if is_instance_valid(old):
		old.queue_free()
	if bone_id == Skeleton.WEAPON_ATTACH_R:
		_weapon_r = null
	else:
		_weapon_l = null
	# 未配置武器场景则跳过挂载：武器由实体 WeaponMount 统一管理（挂 hand 骨骼）
	var scene: PackedScene = weapon_scene if bone_id == Skeleton.WEAPON_ATTACH_R else offhand_scene
	if scene == null:
		return
	var instance := Weapon.attach(scene, bone_id, _bones)
	if instance != null:
		if bone_id == Skeleton.WEAPON_ATTACH_R:
			_weapon_r = instance
		else:
			_weapon_l = instance


# ============================================================
#  颜色/缩放重建
# ============================================================

func _do_rebuild() -> void:
	Skeleton.apply_colors(_sprites, _make_colors())


# ============================================================
#  公共 API
# ============================================================

func play(anim_name: String) -> void:
	if _state_machine == null:
		if _anim_tree != null:
			_state_machine = _anim_tree.get("parameters/playback")
	if _state_machine == null:
		return
	# 切换到非 walk 动画时重置播放速率
	if _anim_player != null and anim_name != ANIM_WALK:
		_anim_player.speed_scale = 1.0
	# 重播同一个一次性动画（连续攻击/连续受击）：travel 到**当前** state 是空操作，
	# 播放位置会停在片尾（LOOP_NONE 播完位置钳在 length）→ 动画不会重头播，
	# 内嵌 Hit 事件的时间一上来就被越过，第二次及以后的攻击会瞬间结算。
	# 用 start() 强制重新起播，保证每次挥剑都完整走一遍命中帧。
	if _state_machine.get_current_node() == anim_name and _is_oneshot(anim_name):
		_state_machine.start(anim_name)
		_current_anim = anim_name
		return
	_state_machine.travel(anim_name)
	_current_anim = anim_name


## 动画是否为一次性（LOOP_NONE，播完停在片尾）；找不到的动画按一次性处理。
func _is_oneshot(anim_name: String) -> bool:
	if _anim_player == null or not _anim_player.has_animation(anim_name):
		return true
	var anim: Animation = _anim_player.get_animation(anim_name)
	return anim != null and anim.loop_mode == Animation.LOOP_NONE


## 设置动画播放速率（用于 walk 速度匹配，p_speed=1.0 为原始速率）。
## 只对**循环动画**（walk/run 等移动动画）生效：一次性动画（攻击/受击/死亡/列阵/
## 格挡）一律按原始速率播放。否则单位站着不动时速率被压到 MIN_ANIM_SCALE(0.6)，
## 挥剑动画被拖慢 40%，动画内嵌的 Hit 事件（Swordwrath-Attack1 Hit@1.0s）
## 要到 1.6s+ 才走到——命中帧对齐就失去了意义。
func set_anim_speed(p_speed: float) -> void:
	if _anim_player == null:
		return
	if _is_oneshot(_current_anim):
		_anim_player.speed_scale = 1.0
		return
	_anim_player.speed_scale = clampf(p_speed, 0.0, 3.0)


## 查询指定动画的播放进度（0~1）。仅当当前状态正在播放该动画时返回真实进度，
## 否则返回 1.0（未在播放 = 视为已结束）。供武器命中帧结算（Saga Strike 模式）。
func get_anim_progress(anim_name: String) -> float:
	if _state_machine == null:
		return 1.0
	var cur: String = _state_machine.get_current_node()
	if cur != anim_name:
		return 1.0
	var len: float = _state_machine.get_current_length()
	if len <= 0.0:
		return 1.0
	return clampf(_state_machine.get_current_play_position() / len, 0.0, 1.0)


## 查询指定动画的播放位置（秒）。仅当当前状态正在播放该动画时返回真实位置，
## 否则返回 -1（未在播放）。用于把命中帧对齐到动画内嵌事件的绝对时间
## （Spine Hit@1.0s 这类真值），而不是拍脑袋的进度比例。
func get_anim_time(anim_name: String) -> float:
	if _state_machine == null:
		return -1.0
	if _state_machine.get_current_node() != anim_name:
		return -1.0
	return _state_machine.get_current_play_position()


## 查询动画内嵌事件时间（秒）。返回首个匹配事件的绝对时间；无该事件/无元数据返回 -1。
## 供需要"提前知道命中时刻"的逻辑（如没有动画事件时的兜底、调试断言）使用；
## 常规命中帧结算应订阅 animation_event 信号而非轮询。
func get_anim_event_time(anim_name: String, event_name: String) -> float:
	if _anim_player == null or not _anim_player.has_animation(anim_name):
		return -1.0
	var anim: Animation = _anim_player.get_animation(anim_name)
	if anim == null or not anim.has_meta("anim_events"):
		return -1.0
	for e in anim.get_meta("anim_events"):
		if str(e["name"]) == event_name:
			return float(e["time"])
	return -1.0


## 查询动画时长（秒）；找不到返回 -1。与 get_anim_time 配合计算
## "命中后动画可打断点"（AnimationCancelFractionOfAnimationAfterAttackHit）。
func get_anim_length(anim_name: String) -> float:
	if _anim_player == null or not _anim_player.has_animation(anim_name):
		return -1.0
	var anim: Animation = _anim_player.get_animation(anim_name)
	return anim.length if anim != null else -1.0


## 受击插播（反编译参考实装 B）：打断任意动作插入 hit_front/hit_back，
## 动画播完（计时器）自动回切到受击前状态。from_front=true 正面受击（后仰）。
func play_hit(from_front: bool) -> void:
	if _state_machine == null:
		if _anim_tree != null:
			_state_machine = _anim_tree.get("parameters/playback")
	if _state_machine == null:
		return
	# 连续受击时保留最初的返回状态（不因 hit 中途又被打而回切到 hit）
	if _current_anim != ANIM_HIT_FRONT and _current_anim != ANIM_HIT_BACK:
		_hit_return_to = _current_anim
	var hit_name: String = ANIM_HIT_FRONT if from_front else ANIM_HIT_BACK
	_state_machine.travel(hit_name)
	_current_anim = hit_name
	_hit_timer = _anim_length(hit_name)


## 切换 idle 状态的待机变体动画（stand 变体池；进入待机时调用一次并保持）。
func set_idle_variant(anim_name: String) -> void:
	if _anim_tree == null:
		return
	var sm: AnimationNodeStateMachine = _anim_tree.tree_root as AnimationNodeStateMachine
	Anims.set_state_animation(sm, ANIM_IDLE, anim_name)


## 取动画时长（秒）；找不到返回 0.3 兜底（hit 动画设计时长）。
func _anim_length(anim_name: String) -> float:
	if _anim_player == null:
		return 0.3
	var anim: Animation = _anim_player.get_animation(anim_name)
	return anim.length if anim != null else 0.3


func get_current_anim() -> String:
	return _current_anim


func get_bone_by_id(id: int) -> Node2D:
	return _bones.get(id, null)


func get_bone_ids() -> Array:
	return _bones.keys()
