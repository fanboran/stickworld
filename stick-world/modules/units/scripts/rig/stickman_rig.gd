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
const BatchRig := preload("res://modules/units/scripts/rig/stickman_batch_rig.gd")

# ===== 动画状态名（公共 API 用） =====
const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_RUN := "run"
const ANIM_ATTACK := "attack"
const ANIM_DEAD := "dead"
const ANIM_DEAD_HEADSHOT := "dead_headshot"
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
## 批渲染层（MultiMesh 桶；null = 旧矢量部件路径——编辑器/A-B 对照/回滚）
var _batch: RefCounted = null
var _anim_player: AnimationPlayer
var _anim_tree: AnimationTree
var _state_machine: AnimationNodeStateMachinePlayback
var _current_anim: String = ANIM_IDLE
var _weapon_r: Node2D
var _weapon_l: Node2D
var _rebuild_pending: bool = false
## 受击插播计时（>0 表示正在受击动画，倒计时结束后回切到 _hit_return_to）
var _hit_timer: float = -1.0
## 死亡终态（2026-08-31 观察场审计）：dead/dead_headshot 播出后置位，
## rig 层拒绝一切后续动画请求（受击插播/硬直回切/攻击都不会再覆盖死亡动画）。
## 场景：单位在受击硬直中被补刀打死——_on_died 播 dead，但 _hit_timer 仍在
## 倒计时，计时到 0 travel(_hit_return_to) 会把死亡动画覆盖回站立（"尸体站起来"）。
var _dead: bool = false
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

## ── LOD 动画节流（战斗级，UnitLodDirector 驱动；未接入时零变化）──
## 程序化叠加层引用（_init_procedural_overlay 时缓存，hz 变化时同步转发）
var _overlay: Node2D = null
## 驱动模式：true = AnimationTree 自动处理已停用（active=false），由本节点
## 按节流频率手动 advance 推进。一旦进入就不再回退自动处理（见 set_anim_update_hz）。
var _anim_driven: bool = false
## 当前动画更新频率（Hz；<=0 完全暂停，>=60 全速每帧推进）
var _adv_hz: float = 0.0
## 节流档累积器（真实渲染帧 delta 累积，达到 1/hz 批量 advance）
var _adv_accum: float = 0.0
## 显式暂停闸门（set_anim_paused 置位）：暂停优先于 LOD 档，冻结累积推进
var _pause_gate: bool = false
##
## 骨架解算频率（Hz）：修改栈（4×TwoBoneIK）解算的 LOD 限频档，由
## set_anim_update_hz 联动设定 = min(动画 hz, 30)（T0 密度档 20Hz 动画 → 解算
## 也 20Hz：解算只在推进帧后有输入变化，高于推进频率纯浪费；60Hz 动画 → 30Hz）。
##
## 机制（Godot 4.7 实测，worktree 实验：temp/mech/ 顺序探针 + 姿态/成本对照）：
## 解算跑在 Skeleton2D 的内部处理里，且没有等价的"手动解一次"API——
## Skeleton2D.execute_modifications 脱离内部处理调用会直接把 IK 结果写进骨骼
## 节点变换，肢体向 IK 目标塌折（与原生渲染姿态完全不符），不可用。故用
## set_process_internal 逐帧开关：推进帧置 true → 下一帧帧首内部处理恰好解算
## 一次 → 下一个推进节拍再按需开关（内部处理阶段先于脚本 _process、父节点先于
## 子节点，均实测；解算先于动画推进、读上一推进帧的骨骼姿态，与原生每帧时序
## 同构，仅频率降档）。未接 LOD（本变量保持 0 且 _anim_driven=false）时内部
## 处理保持原生开启，行为零变化。
var _solve_hz: float = 0.0
## 解算节拍累积器（累加动画推进 delta；仅在推进帧后解算才有输入变化）
var _solve_accum: float = 0.0

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


## 通知路由：
## - VISIBILITY_CHANGED：重新可见时补一次批渲染 pose 写入（不可见期 flush 跳过并
##   保留脏标记，此通知兜底"LOD FAR 档隐藏 → 回到近档"的首帧；旧矢量路径无此需求）。
## - INTERNAL_PROCESS：骨架解算落地帧恰是内部处理开启帧（set_process_internal
##   逐帧开关，机制见 _solve_hz 注），解算刚改写骨骼 → 批渲染标脏，本帧尾部
##   flush 捕获解算后姿态。未接 LOD 时内部处理原生常开、通知逐帧触发 = 与旧路径
##   "渲染即最新姿态"同频；接 LOD 后仅解算节拍帧触发，随档位降频。
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if _batch != null and is_visible_in_tree():
			_batch.mark_dirty()
	elif what == NOTIFICATION_INTERNAL_PROCESS:
		if _batch != null:
			_batch.mark_dirty()


## 程序化叠加层改写骨骼/IK 标记后的通知（叠加层 _on_frame 每次实际叠加后调用；
## 批渲染 pose 缓冲随之标脏，旧矢量路径无操作——节点树直接渲染无需快照）
func notify_pose_dirty() -> void:
	if _batch != null:
		_batch.mark_dirty()


## 隔帧计数（战斗性能优化）：动画结束/事件检测为"越过时间点"语义，
## 30Hz 采样不漏事件（最多晚 1 帧触发），196 单位混战省一半逐帧检测开销
var _tick_frame_counter: int = 0


func _process(delta: float) -> void:
	if _state_machine == null and _anim_tree != null:
		_state_machine = _anim_tree.get("parameters/playback")
	if _rebuild_pending:
		_rebuild_pending = false
		_do_rebuild()
	# 批渲染 pose 脏标记（自动驱动模式）：AnimationTree 自主推进，无法感知姿态
	# 变化帧，保守每帧标脏（无动画树则姿态恒定，跳过）
	if _batch != null and not _anim_driven and _anim_tree != null:
		_batch.mark_dirty()
	# LOD 驱动模式推进：自动处理已停用，按节流频率手动 advance（先于事件轮询，
	# 保证 _check_animation_finished/_check_animation_events 读到最新播放位置）
	if _anim_driven and _anim_tree != null and not _pause_gate:
		var adv := 0.0
		if _adv_hz >= 60.0:
			adv = delta
		else:
			_adv_accum += delta
			if _adv_accum >= 1.0 / _adv_hz:
				adv = _adv_accum
				_adv_accum = 0.0
		if adv > 0.0:
			_anim_tree.advance(adv)
			# 批渲染：本帧推进改写姿态 → 标脏（flush 在 _process 尾部消费）
			if _batch != null:
				_batch.mark_dirty()
			# 骨架解算随推进帧联动（机制见 _solve_hz 注）：本帧 _process 置 true，
			# 下一帧帧首内部处理解算一次；非解算节拍关闭内部处理停掉解算。
			# 批渲染的解算后标脏走 _notification 的 INTERNAL_PROCESS 分支
			#（解算落地帧 = 内部处理开启帧，精确挂钩），此处无需再记脏
			if _solve_hz > 0.0:
				_solve_accum += adv
				if _solve_accum >= 1.0 / _solve_hz:
					_solve_accum = 0.0
					set_process_internal(true)
				else:
					set_process_internal(false)
	# 受击插播倒计时：动画播完回切到受击前状态（反编译参考实装 B）
	if _hit_timer > 0.0:
		_hit_timer -= delta
		if _hit_timer <= 0.0 and _state_machine != null and not _dead:
			_state_machine.travel(_hit_return_to)
			_current_anim = _hit_return_to
	# 批渲染 pose 快照：此处骨骼 = 本帧最终合成姿态（推进 + 解算 + 程序化叠加）
	if _batch != null:
		_batch.flush()
	_tick_frame_counter += 1
	if _tick_frame_counter % 2 != 0:
		return
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
	# OverlayScript 非 @tool：编辑器里本节点是 placeholder 实例，setup 不可调用。
	# overlay 是纯运行时动态效果（速度惯性/攻击回弹/受击抖动），编辑器内无需接线；
	# 未接线的 overlay 有 _skeleton 空值守卫，_physics_process 会静默返回。
	if not Engine.is_editor_hint():
		overlay.call("setup", self, self)
	_overlay = overlay


func _init_bones() -> void:
	var colors := _make_colors()
	# 批渲染开关（默认开；旧矢量部件路径原样保留做 A/B 对照与回滚，编辑器恒走旧路径）
	var batch_on: bool = not Engine.is_editor_hint() and BatchRig.is_enabled()
	var batch: RefCounted = BatchRig.new() if batch_on else null
	if get_node_or_null("hip") != null:
		Skeleton.reorder_render_order(self)
		_bones = Skeleton.collect_nodes(self)["bones"]
		# .tscn 骨骼 + 运行时矢量肢体（场景不再预置贴图精灵）
		if not batch_on:
			_sprites = Skeleton.build_limbs(self, _bones, thickness_scale, colors)
	else:
		# 首次打开：从零构建骨骼 + 矢量肢体（批渲染路径只建骨骼，部件归 MultiMesh 桶）
		var result := Skeleton.build_from_scratch(self, thickness_scale, colors, not batch_on)
		_bones = result["bones"]
		_sprites = result["sprites"]
	if batch != null:
		if batch.setup(self, _bones, thickness_scale, colors):
			_batch = batch
		else:
			# 批渲染构建失败（骨骼缺失等）：回退旧矢量路径，行为与旧版完全一致
			_sprites = Skeleton.build_limbs(self, _bones, thickness_scale, colors)


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
	# NodePath 解析失败的修改器必须整条移除（收集后倒序删，避免中途移位）。
	# 约束：TwoBoneIK 的 joint idx 在 tscn 里是"写死的历史值"，只有 NodePath 解析
	# 成功时才会被 _init_ik 按骨名校正。解析失败却保留修改器 = 残留 idx 继续生效，
	# 会误驱动别的骨骼——08-30"独立场景全身横躺 ~90°"事故根因：骨链重排后
	# 腿 IK NodePath 失配，残留 idx (0,1)=新链的 (hip,spine_root)，腿 IK 把
	# 根骨 hip 拽向脚部目标 → 全身横躺（详见 tools/baking/render_weapon_check.gd 头注释）。
	var _dead_mods: PackedInt64Array = []
	for i in range(stack.modification_count):
		var mod := stack.get_modification(i) as SkeletonModification2DTwoBoneIK
		if mod == null:
			push_warning("[IK] modification ", i, " 不是 TwoBoneIK")
			continue
		# 通过 NodePath 找到 Bone2D 节点，再用名称查实际索引
		var bone1 := get_node_or_null(mod.joint_one_bone2d_node) as Bone2D
		var bone2 := get_node_or_null(mod.joint_two_bone2d_node) as Bone2D
		if bone1 == null or bone2 == null:
			push_warning("[IK] mod ", i, " 关节骨 NodePath 解析失败（bone1=",
					mod.joint_one_bone2d_node, " bone2=", mod.joint_two_bone2d_node,
					"），已移除该修改器，防止残留 joint idx 误驱动其他骨骼")
			_dead_mods.append(i)
			continue
		var idx1: int = bone_name_to_idx.get(bone1.name, -1)
		if idx1 >= 0:
			mod.joint_one_bone_idx = idx1
		var idx2: int = bone_name_to_idx.get(bone2.name, -1)
		if idx2 >= 0:
			mod.joint_two_bone_idx = idx2
		# 检查目标节点
		var target := get_node_or_null(mod.target_nodepath) as Node2D
		if target == null:
			push_warning("[IK] mod ", i, ": target NodePath 解析失败: ", mod.target_nodepath)
	for j in range(_dead_mods.size() - 1, -1, -1):
		stack.delete_modification(_dead_mods[j])
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
	if _batch != null:
		# 批渲染路径：重烘桶实例的局部变换与颜色（不重建节点）
		_batch.reconfigure(thickness_scale, _make_colors())
		return
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
	# 死亡终态：dead 前缀动画（含变体池 dead_v2/dead_headshot_* 等）置位后
	# 拒绝一切其他动画请求（见 _dead 注释）。变体名动态换入 dead/dead_headshot
	# 状态节点后 travel 标准状态（不增状态节点，set_state_animation 同款机制）。
	if anim_name.begins_with("dead"):
		_dead = true
		_hit_timer = -1.0
		if anim_name != ANIM_DEAD and anim_name != ANIM_DEAD_HEADSHOT and _anim_tree != null:
			var sm: AnimationNodeStateMachine = _anim_tree.tree_root as AnimationNodeStateMachine
			var base: String = ANIM_DEAD_HEADSHOT if anim_name.begins_with("dead_headshot") else ANIM_DEAD
			Anims.set_state_animation(sm, base, anim_name)
			anim_name = base
	elif _dead:
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
		# 重播 = 新一轮播放周期：清除"已发结束信号"标记，否则第二刀播完
		# _check_animation_finished 判 cur == _finished_sent_state 直接跳过，
		# animation_finished 不发射 → 攻击播完不回切（移动锁下表现为卡死）
		_finished_sent_state = ""
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


## 动态换主状态节点的动画资源（盾姿态分层，计划 5）：
## walk↔block_walk、idle↔block_crouch、attack_spear↔block_attack_N——不增状态节点，
## 机制同死亡变体池。事件/完成信号按 state 名派发（animation_event/finished 发
## "attack_spear" 等状态名），换动画不影响 weapon_mount 命中帧订阅。
## 返回是否成功（动画未入库/状态不存在时 false，调用方自行回退）。
func set_state_anim(state_name: String, anim_name: String) -> bool:
	if _anim_tree == null or _anim_player == null:
		return false
	if not _anim_player.has_animation(anim_name):
		return false
	var sm: AnimationNodeStateMachine = _anim_tree.tree_root as AnimationNodeStateMachine
	if sm == null or not sm.has_node(state_name):
		return false
	Anims.set_state_animation(sm, state_name, anim_name)
	return true


## 暂停冻结动画（TimeManager 暂停门禁配套，修复"暂停只停位移肢体还动"）：
## AnimationPlayer 速率归零；恢复时回 1.0（walk 速率由移动代码下一帧重设）。
## LOD 驱动模式下同步置闸门：显式暂停优先于 LOD 档（冻结手动推进，
## 否则暂停期间被节流的单位动画仍会走——AnimationTree 不理会 AnimationPlayer 的
## speed_scale，闸门是驱动模式下暂停真正生效的通道），并停掉骨架解算
## （闸门跳过推进分支后不会再有开关指令，悬挂的 internal=true 会让解算每帧空跑）。
func set_anim_paused(paused: bool) -> void:
	_pause_gate = paused
	_adv_accum = 0.0
	if paused and _anim_driven:
		set_process_internal(false)
		_solve_accum = 0.0
	if _anim_player == null:
		return
	_anim_player.speed_scale = 0.0 if paused else 1.0


## 设置动画更新频率（Hz，战斗级 LOD 节流，UnitLodDirector 经实体转发调用）：
##   hz <= 0 ：完全暂停（停用自动处理，保留当前 pose，状态推进与骨架解算冻结）
##   0 < hz < 60 ：按该频率节流推进（累积真实 delta，达到 1/hz 批量 advance）
##   hz >= 60 ：全速（每帧 advance 真实 delta，与 IDLE 自动处理等价）
##
## 骨架解算联动：接入 LOD 即按 min(hz, 30) 限频修改栈解算（T0 封顶 30Hz /
## T1 15Hz / T2 5Hz；机制与时序详见 _solve_hz 注）。
##
## 实现说明（为什么不用 MANUAL 回调、也不把 active 置回 true）：实测 Godot 4.7，
## 运行时切换 process_callback 或重新 set_active(true) 后，AnimationTree 激活首帧
## 会向状态机发送 seek(0)，AnimationNodeStateMachinePlayback 被整体重置回 Start
## （源码 animation_node_state_machine.cpp "seek to 0 (means reset)" 分支）——
## 攻击/受击动画位置丢失、命中帧事件重发（重复伤害）。因此一旦进入驱动模式
## （active=false + 手动 advance）就不再回退自动处理；deactivate 不重置状态机，
## advance 是同步推进（状态机过渡/播放位置/事件检测照常），全速档与自动处理行为等价。
func set_anim_update_hz(hz: float) -> void:
	if _anim_tree == null:
		return
	_adv_hz = hz
	_adv_accum = 0.0
	_solve_accum = 0.0
	if hz <= 0.0:
		_anim_driven = false
		_solve_hz = 0.0
		if _anim_tree.active:
			_anim_tree.active = false
		# 完全暂停档：骨架解算一并冻结（接入过 LOD 才动内部处理，未接入保持原生）
		set_process_internal(false)
		_forward_overlay_hz(0.0)
		return
	_anim_driven = true
	_solve_hz = minf(hz, 30.0)
	if _anim_tree.active:
		_anim_tree.active = false
	# 批渲染：节拍节奏变化，补一次 pose 快照（防档位切换期漏帧）
	if _batch != null:
		_batch.mark_dirty()
	_forward_overlay_hz(hz)


## 叠加层频率同步：overlay 与动画同档节流（hz<=0 关闭叠加）。
func _forward_overlay_hz(hz: float) -> void:
	if _overlay != null and is_instance_valid(_overlay) and _overlay.has_method("set_update_hz"):
		_overlay.set_update_hz(hz)


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


## 受击插播（反编译参考实装 B）：打断任意动作插入受击动画，播完（计时器）
## 自动回切到受击前状态。变体池直译（SWL SelectHitAnimation：部位×方向×强度）——
## hit_front/hit_back 状态节点动画**动态替换**为池中变体（不增状态节点）。
## from_front=true 正面受击；big=true 强击（Mid Big 组）；head=true 部位在头；
## blocking=true 举盾中被击（Hit-Spearton-Block 池，招架配套反馈）。
func play_hit(from_front: bool, big: bool = false, head: bool = false, blocking: bool = false) -> void:
	if _dead:
		return
	if _state_machine == null:
		if _anim_tree != null:
			_state_machine = _anim_tree.get("parameters/playback")
	if _state_machine == null:
		return
	# 连续受击时保留最初的返回状态（不因 hit 中途又被打而回切到 hit）
	if _current_anim != ANIM_HIT_FRONT and _current_anim != ANIM_HIT_BACK:
		_hit_return_to = _current_anim
	var hit_state: String = ANIM_HIT_FRONT if from_front else ANIM_HIT_BACK
	var chosen: String = Anims.pick_hit_anim(from_front, big, head, blocking)
	# 动态替换 hit 状态节点的动画为选中变体（set_idle_variant 同款机制）
	if _anim_tree != null:
		var sm: AnimationNodeStateMachine = _anim_tree.tree_root as AnimationNodeStateMachine
		Anims.set_state_animation(sm, hit_state, chosen)
	_state_machine.travel(hit_state)
	_current_anim = hit_state
	_hit_timer = _anim_length(chosen)


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
