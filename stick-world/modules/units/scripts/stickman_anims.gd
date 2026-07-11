class_name StickmanAnims
extends RefCounted
## 火柴人动画系统：加载 .tres 资源 + AnimationTree StateMachine

const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_RUN := "run"
const ANIM_ATTACK := "attack"
const ANIM_DEAD := "dead"

const ANIM_DIR := "res://modules/units/animations/"


# ============================================================
#  AnimationPlayer 初始化
# ============================================================

## 确保 AnimationPlayer 有动画库，从 .tres 文件加载动画
static func setup_player(player: AnimationPlayer) -> void:
	if player == null:
		return
	if not player.has_animation_library(""):
		player.add_animation_library("", AnimationLibrary.new())
	var lib := player.get_animation_library("")
	if lib.get_animation_list().is_empty():
		_load_anim(lib, ANIM_IDLE)
		_load_anim(lib, ANIM_WALK)
		_load_anim(lib, ANIM_RUN)
		_load_anim(lib, ANIM_ATTACK)
		_load_anim(lib, ANIM_DEAD)


# ============================================================
#  AnimationTree StateMachine
# ============================================================

## 构建 StateMachine 并关联 AnimationPlayer
static func setup_tree(tree: AnimationTree, player: AnimationPlayer) -> AnimationNodeStateMachinePlayback:
	if tree == null or player == null:
		return null
	var sm := AnimationNodeStateMachine.new()
	_add_state(sm, ANIM_IDLE)
	_add_state(sm, ANIM_WALK)
	_add_state(sm, ANIM_RUN)
	_add_state(sm, ANIM_ATTACK)
	_add_state(sm, ANIM_DEAD)
	# 过渡
	sm.add_transition(ANIM_IDLE, ANIM_WALK, _smt(0.2))
	sm.add_transition(ANIM_WALK, ANIM_IDLE, _smt(0.2))
	sm.add_transition(ANIM_WALK, ANIM_RUN, _smt(0.15))
	sm.add_transition(ANIM_RUN, ANIM_WALK, _smt(0.15))
	sm.add_transition(ANIM_RUN, ANIM_IDLE, _smt(0.3))
	sm.add_transition(ANIM_IDLE, ANIM_ATTACK, _smt(0.1))
	sm.add_transition(ANIM_WALK, ANIM_ATTACK, _smt(0.1))
	sm.add_transition(ANIM_ATTACK, ANIM_IDLE, _smt(0.3))
	sm.add_transition(ANIM_IDLE, ANIM_DEAD, _smt(0.3))
	sm.add_transition(ANIM_WALK, ANIM_DEAD, _smt(0.3))
	sm.add_transition(ANIM_ATTACK, ANIM_DEAD, _smt(0.3))
	sm.add_transition("Start", ANIM_IDLE, _smt(0.0))
	# 先关联 player，再设 tree_root，最后激活
	tree.anim_player = player.get_path()
	tree.tree_root = sm
	# 编辑器模式下不激活 AnimationTree，避免触发虚拟 AnimationPlayer 警告
	if not Engine.is_editor_hint():
		tree.active = true
	return tree.get("parameters/playback")


# ============================================================
#  内部辅助
# ============================================================

static func _load_anim(lib: AnimationLibrary, name: String) -> void:
	var path := ANIM_DIR + name + ".tres"
	if ResourceLoader.exists(path):
		var anim := load(path) as Animation
		if anim != null:
			lib.add_animation(name, anim)
			return
	push_warning("StickmanAnims: 动画资源不存在 %s，请运行 tools/bake_anims.tscn 生成" % path)


static func _add_state(sm: AnimationNodeStateMachine, anim_name: String) -> void:
	var node := AnimationNodeAnimation.new()
	node.animation = anim_name
	sm.add_node(anim_name, node)


static func _smt(xfade: float) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
	t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC
	t.xfade_time = xfade
	return t
