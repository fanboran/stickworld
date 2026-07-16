@tool
class_name StickmanRig
extends Skeleton2D
## 火柴人渲染骨架（主控制器）
##
## 基于 Skeleton2D + Bone2D，在编辑器中只能旋转骨骼关节（不能拖动位置），
## K 帧体验自然。协调骨骼、纹理、动画、武器子系统。
## Inspector 可调参数：厚度、颜色、缩放、武器。

const Skeleton := preload("res://modules/units/scripts/stickman_skeleton.gd")
const Anims := preload("res://modules/units/scripts/stickman_anims.gd")
const Weapon := preload("res://modules/units/scripts/stickman_weapon.gd")

# ===== 动画状态名（公共 API 用） =====
const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_RUN := "run"
const ANIM_ATTACK := "attack"
const ANIM_DEAD := "dead"

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


# ============================================================
#  生命周期
# ============================================================

func _ready() -> void:
	_init_bones()
	_init_ik()
	_init_animations()
	_init_weapons()


func _process(_delta: float) -> void:
	if _state_machine == null and _anim_tree != null:
		_state_machine = _anim_tree.get("parameters/playback")
	if _rebuild_pending:
		_rebuild_pending = false
		_do_rebuild()


# ============================================================
#  初始化
# ============================================================

func _init_bones() -> void:
	# 检查是否已有骨骼（通过 hip 节点判断）
	if get_node_or_null("hip") != null:
		var result := Skeleton.collect_nodes(self)
		_bones = result["bones"]
		_sprites = result["sprites"]
	else:
		# 首次打开：从零构建骨骼 + 精灵
		var colors := {
			"body": body_color,
			"weapon": weapon_color,
			"guard": guard_color,
		}
		var result := Skeleton.build_from_scratch(self, thickness_scale, colors)
		_bones = result["bones"]
		_sprites = result["sprites"]


func _init_ik() -> void:
	# 运行时通过遍历骨骼修正 bone_idx，避免 .tscn 中写死的索引和实际不匹配
	var stack := get_modification_stack()
	if stack == null:
		print("[IK] modification_stack 为 null，IK 不会执行")
		return
	# 强制每个实例拥有独立的 modification stack 副本，避免多实例共享同一资源导致 IK 冲突
	if not Engine.is_editor_hint():
		var unique_stack := stack.duplicate(true) as SkeletonModificationStack2D
		if unique_stack != null:
			set_modification_stack(unique_stack)
			stack = unique_stack
	print("[IK] stack.enabled = ", stack.enabled, ", modification_count = ", stack.modification_count)
	# 构建骨骼名->索引映射
	var bone_name_to_idx: Dictionary = {}
	for idx in range(get_bone_count()):
		var b := get_bone(idx)
		if b:
			bone_name_to_idx[b.name] = idx
	for i in range(stack.modification_count):
		var mod := stack.get_modification(i) as SkeletonModification2DTwoBoneIK
		if mod == null:
			print("[IK] modification ", i, " 不是 TwoBoneIK")
			continue
		# 通过 NodePath 找到 Bone2D 节点，再用名称查实际索引
		var bone1 := get_node_or_null(mod.joint_one_bone2d_node) as Bone2D
		var bone2 := get_node_or_null(mod.joint_two_bone2d_node) as Bone2D
		if bone1:
			var idx1: int = bone_name_to_idx.get(bone1.name, -1)
			print("[IK] mod ", i, ": bone1 = ", bone1.name, " actual_idx = ", idx1, " saved_idx = ", mod.joint_one_bone_idx)
			if idx1 >= 0:
				mod.joint_one_bone_idx = idx1
		else:
			print("[IK] mod ", i, ": bone1 NodePath 解析失败: ", mod.joint_one_bone2d_node)
		if bone2:
			var idx2: int = bone_name_to_idx.get(bone2.name, -1)
			print("[IK] mod ", i, ": bone2 = ", bone2.name, " actual_idx = ", idx2, " saved_idx = ", mod.joint_two_bone_idx)
			if idx2 >= 0:
				mod.joint_two_bone_idx = idx2
		else:
			print("[IK] mod ", i, ": bone2 NodePath 解析失败: ", mod.joint_two_bone2d_node)
		# 检查目标节点
		var target := get_node_or_null(mod.target_nodepath) as Node2D
		if target:
			print("[IK] mod ", i, ": target = ", target.name, " pos = ", target.global_position)
		else:
			print("[IK] mod ", i, ": target NodePath 解析失败: ", mod.target_nodepath)
		print("[IK] mod ", i, ": enabled = ", mod.enabled, ", flip_bend = ", mod.flip_bend_direction)


func _init_animations() -> void:
	_anim_player = get_node_or_null("AnimationPlayer") as AnimationPlayer
	_anim_tree = get_node_or_null("AnimationTree") as AnimationTree
	if _anim_player == null:
		return
	# 确保 root_node 正确
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
	# 挂载新武器
	var scene: PackedScene = weapon_scene if bone_id == Skeleton.WEAPON_ATTACH_R else offhand_scene
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
	var colors := {
		"body": body_color,
		"weapon": weapon_color,
		"guard": guard_color,
	}
	Skeleton.apply_colors(_sprites, colors)


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
	_state_machine.travel(anim_name)
	_current_anim = anim_name


## 设置动画播放速率（用于 walk 速度匹配，p_speed=1.0 为原始速率）
func set_anim_speed(p_speed: float) -> void:
	if _anim_player != null:
		_anim_player.speed_scale = clampf(p_speed, 0.0, 3.0)


func get_current_anim() -> String:
	return _current_anim


func get_bone_by_id(id: int) -> Node2D:
	return _bones.get(id, null)


func get_bone_ids() -> Array:
	return _bones.keys()
