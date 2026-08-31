class_name StickmanAnims
extends RefCounted
## 火柴人动画系统：加载 .tres 资源 + AnimationTree StateMachine
##
## 变体池（反编译参考实装 B）：
##   - stand 变体（idle / idle_v2）防全员同帧，对应遗产 StandAnimations[] + RandomAnimation
##   - 受击插播 hit（front/back 方向），经 AnimationNodeOneShot 触发，对应遗产 SelectHitAnimation
##   - .tres 数据化（animation_set.tres）推迟：当前所有火柴人共用统一骨架、无兵种差异动画

const ANIM_IDLE := "idle"
const ANIM_IDLE_V2 := "idle_v2"
const ANIM_IDLE_SPEAR := "idle_spear"
const ANIM_IDLE_BOW := "idle_bow"
const ANIM_IDLE_PICKAXE := "idle_pickaxe"
const ANIM_IDLE_STAFF := "idle_staff"
const ANIM_WALK := "walk"
const ANIM_RUN := "run"
const ANIM_ATTACK := "attack"
## 各武器专属攻击动画（转译自解包 Spine 数据，见 tools/baking/spine_import.gd）
const ANIM_ATTACK_SPEAR := "attack_spear"
const ANIM_ATTACK_PICKAXE := "attack_pickaxe"
const ANIM_ATTACK_STAFF := "attack_staff"
const ANIM_ATTACK_BOW := "attack_bow"
const ANIM_BLOCK := "block"
const ANIM_DEAD := "dead"
## 爆头死亡（转译自解包 Death-Headshot）：爆头致死时替代 dead 播放（原版
## Kill(isHeadShot) 参数分家——普通死亡与爆头死亡是两条动画）。
const ANIM_DEAD_HEADSHOT := "dead_headshot"
const ANIM_WALK_CARRY := "walk_carry"
const ANIM_BUILD := "build"
const ANIM_HIT := "hit"
const ANIM_HIT_FRONT := "hit_front"
const ANIM_HIT_BACK := "hit_back"
const ANIM_ARRIVE := "arrive"

# ── 死亡/受击变体池（2026-08-31 全量直译 legacy 受击死亡体系）──────────
## Death 组 ×10（普通死 2 + 爆头死 8：前扑/矛捅/矛兵形态等变体）
const ANIM_DEAD_V2 := "dead_v2"
const ANIM_DEAD_HEADSHOT_V2 := "dead_headshot_v2"
const ANIM_DEAD_HS_FWD := "dead_headshot_fwd"
const ANIM_DEAD_HS_FWD_SPEAR := "dead_headshot_fwd_spear"
const ANIM_DEAD_HS_SPEAR := "dead_headshot_spear"
const ANIM_DEAD_HS_SPEARTON := "dead_headshot_spearton"
const ANIM_DEAD_HS_SPEARTON_SPEAR := "dead_headshot_spearton_spear"
const ANIM_DEAD_HS2_SPEAR := "dead_headshot2_spear"
## Hit 组 ×12（部位 Head/Mid × 方向 Front/Back × 强度 Big/Small + 盾格被击）
const ANIM_HIT_MID_FRONT_BIG := "hit_mid_front_big"
const ANIM_HIT_MID_BACK_BIG := "hit_mid_back_big"
const ANIM_HIT_HEAD_FRONT_SMALL := "hit_head_front_small"
const ANIM_HIT_HEAD_FRONT_SMALL2 := "hit_head_front_small2"
const ANIM_HIT_HEAD_BACK_BIG := "hit_head_back_big"
const ANIM_HIT_HEAD_BACK_SMALL := "hit_head_back_small"
const ANIM_HIT_HEAD_BUTT := "hit_head_butt"
const ANIM_HIT_HEAD_BUTT2 := "hit_head_butt2"
const ANIM_HIT_BLOCK_1 := "hit_block_1"
const ANIM_HIT_BLOCK_2 := "hit_block_2"

## 死亡变体池（普通死：原版 Death1/Death2 随机）
const DEAD_VARIANTS: Array[String] = [ANIM_DEAD, ANIM_DEAD_V2]
## 爆头死亡变体池（原版 Death-Headshot 系 8 变体随机——含矛捅/前扑/矛兵形态）
const DEAD_HEADSHOT_VARIANTS: Array[String] = [
	ANIM_DEAD_HEADSHOT, ANIM_DEAD_HEADSHOT_V2, ANIM_DEAD_HS_FWD, ANIM_DEAD_HS_FWD_SPEAR,
	ANIM_DEAD_HS_SPEAR, ANIM_DEAD_HS_SPEARTON, ANIM_DEAD_HS_SPEARTON_SPEAR, ANIM_DEAD_HS2_SPEAR,
]
## 受击池（SelectHitAnimation 直译：部位×方向，强度=Big/Small）
const HIT_MID_FRONTS: Array[String] = [ANIM_HIT_FRONT, ANIM_HIT_MID_FRONT_BIG]
const HIT_MID_BACKS: Array[String] = [ANIM_HIT_BACK, ANIM_HIT_MID_BACK_BIG]
const HIT_HEAD_FRONTS: Array[String] = [ANIM_HIT_HEAD_FRONT_SMALL, ANIM_HIT_HEAD_FRONT_SMALL2, ANIM_HIT_HEAD_BUTT, ANIM_HIT_HEAD_BUTT2]
const HIT_HEAD_BACKS: Array[String] = [ANIM_HIT_HEAD_BACK_BIG, ANIM_HIT_HEAD_BACK_SMALL]
## 举盾中被击池（Hit-Spearton-Block：招架系统的配套受击反馈）
const HIT_BLOCK_VARIANTS: Array[String] = [ANIM_HIT_BLOCK_1, ANIM_HIT_BLOCK_2]
## 受击强度阈值（伤害 ≥ 此值播 Big 组，否则 Small；SWL Hit 强度分级近似）
const HIT_BIG_DAMAGE_THRESHOLD: float = 12.0

## 选受击动画（SWL SelectHitAnimation 直译）：部位(Head/Mid)×方向(Front/Back)×
## 强度(Big/Small)，举盾被击走 Block 池。head=true 部位在头（爆头未致死/头顶对撞）。
## 注意：类型化数组常量经三元表达式会退化为 untyped Array（运行时报
## "Trying to assign array of type Array to Array[String]"），一律 if/else 直返。
static func pick_hit_anim(from_front: bool, big: bool, head: bool, blocking: bool = false) -> String:
	if blocking:
		return HIT_BLOCK_VARIANTS[randi() % HIT_BLOCK_VARIANTS.size()]
	if head:
		if from_front:
			return HIT_HEAD_FRONTS[randi() % HIT_HEAD_FRONTS.size()]
		return HIT_HEAD_BACKS[randi() % HIT_HEAD_BACKS.size()]
	if from_front:
		return HIT_MID_FRONTS[1] if big else HIT_MID_FRONTS[0]
	return HIT_MID_BACKS[1] if big else HIT_MID_BACKS[0]


## 选死亡动画（原版死亡变体随机）：普通死 Death1/2，爆头死 Headshot 系 8 变体
static func pick_dead_anim(headshot: bool) -> String:
	var pool: Array[String] = DEAD_HEADSHOT_VARIANTS if headshot else DEAD_VARIANTS
	return pool[randi() % pool.size()]

const ANIM_DIR := "res://modules/units/animations/"

## 全部攻击动画（通用剑攻 + 各武器专属：矛刺/镐挥/法杖/拉弓）
const ATTACK_ANIMS: Array[String] = [
	ANIM_ATTACK, ANIM_ATTACK_SPEAR, ANIM_ATTACK_PICKAXE,
	ANIM_ATTACK_STAFF, ANIM_ATTACK_BOW,
]

## 武器类型 -> 攻击动画名。键序对齐 WeaponMount.WeaponType
## （0=SWORD 1=SPEAR 2=BOW 3=PICKAXE 4=STAFF）。
## 单一真相源：实体播放攻击动画（stickman_entity.play_attack）与武器挂载
## 订阅命中帧事件（weapon_mount）必须查同一张表，否则会出现"播矛刺动画、
## 却按剑的命中帧结算"的错配。
const WEAPON_ATTACK_ANIM: Dictionary = {
	0: ANIM_ATTACK,          # SWORD：剑挥砍（Swordwrath-Attack1）
	1: ANIM_ATTACK_SPEAR,    # SPEAR：矛刺（Spearton-Attack1）
	2: ANIM_ATTACK_BOW,      # BOW：拉弓（Archidon-Draw）
	3: ANIM_ATTACK_PICKAXE,  # PICKAXE：镐挥（Miner-Attack1）
	4: ANIM_ATTACK_STAFF,    # STAFF：法杖施法（Magikill-Spell1）
}

## 取武器类型对应的攻击动画名（未知类型回落通用剑攻）
static func anim_for_weapon(weapon_type: int) -> String:
	return WEAPON_ATTACK_ANIM.get(weapon_type, ANIM_ATTACK)

## 武器类型 -> 持械站姿动画名（键序对齐 WeaponMount.WeaponType）。
## 原版各兵种 Stand 动画：剑士 Swordwrath-Stand1/2、矛兵 Spearton-Stand1、
## 弓手 Archidon-Stand1、矿工 Miner-Stand1、法师 Magikill-Stand1。
const WEAPON_IDLE_ANIM: Dictionary = {
	0: ANIM_IDLE,            # SWORD：持剑（变体池见 STAND_VARIANTS）
	1: ANIM_IDLE_SPEAR,      # SPEAR：持矛
	2: ANIM_IDLE_BOW,        # BOW：持弓
	3: ANIM_IDLE_PICKAXE,    # PICKAXE：持镐
	4: ANIM_IDLE_STAFF,      # STAFF：持杖
}

## 取武器类型对应的站姿动画名（未知类型回落持剑）
static func idle_for_weapon(weapon_type: int) -> String:
	return WEAPON_IDLE_ANIM.get(weapon_type, ANIM_IDLE)

## 待机变体池（stand 类别，防全员同帧）
const STAND_VARIANTS: Array[String] = [ANIM_IDLE, ANIM_IDLE_V2]


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
	# 强制加载/覆盖：场景预置的 AnimationLibrary 可能有草稿（如 walk_carry 单帧），
	# 用 .tres 文件覆盖以确保完整动画
	_load_anim(lib, ANIM_IDLE)
	_load_anim(lib, ANIM_IDLE_V2)
	_load_anim(lib, ANIM_IDLE_SPEAR)
	_load_anim(lib, ANIM_IDLE_BOW)
	_load_anim(lib, ANIM_IDLE_PICKAXE)
	_load_anim(lib, ANIM_IDLE_STAFF)
	_load_anim(lib, ANIM_WALK)
	_load_anim(lib, ANIM_RUN)
	_load_anim(lib, ANIM_ATTACK)
	_load_anim(lib, ANIM_ATTACK_SPEAR)
	_load_anim(lib, ANIM_ATTACK_PICKAXE)
	_load_anim(lib, ANIM_ATTACK_STAFF)
	_load_anim(lib, ANIM_ATTACK_BOW)
	_load_anim(lib, ANIM_BLOCK)
	_load_anim(lib, ANIM_DEAD)
	_load_anim(lib, ANIM_DEAD_HEADSHOT)
	_load_anim(lib, ANIM_WALK_CARRY)
	_load_anim(lib, ANIM_BUILD)
	_load_anim(lib, ANIM_HIT_FRONT)
	_load_anim(lib, ANIM_HIT_BACK)
	# 死亡/受击变体池（legacy Death ×10 / Hit ×12 全量入库，2026-08-31）
	for a in DEAD_VARIANTS:
		if a != ANIM_DEAD:
			_load_anim(lib, a)
	for a in DEAD_HEADSHOT_VARIANTS:
		if a != ANIM_DEAD_HEADSHOT:
			_load_anim(lib, a)
	for a in [ANIM_HIT_MID_FRONT_BIG, ANIM_HIT_MID_BACK_BIG,
			ANIM_HIT_HEAD_FRONT_SMALL, ANIM_HIT_HEAD_FRONT_SMALL2,
			ANIM_HIT_HEAD_BACK_BIG, ANIM_HIT_HEAD_BACK_SMALL,
			ANIM_HIT_HEAD_BUTT, ANIM_HIT_HEAD_BUTT2,
			ANIM_HIT_BLOCK_1, ANIM_HIT_BLOCK_2]:
		_load_anim(lib, a)
	_load_anim(lib, ANIM_ARRIVE)

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
	for a in ATTACK_ANIMS:
		_add_state(sm, a)
	_add_state(sm, ANIM_BLOCK)
	_add_state(sm, ANIM_DEAD)
	_add_state(sm, ANIM_DEAD_HEADSHOT)
	_add_state(sm, ANIM_WALK_CARRY)
	_add_state(sm, ANIM_BUILD)
	# 过渡（sync=false 即 AT_START：新动画从头播放）。
	# 关键：idle↔walk/run↔idle 必须 AT_START。SWITCH_MODE_SYNC 会让新动画从
	# 旧动画的当前进度映射过来（idle 2s / walk 0.8s 循环不等长），随机落在 walk
	# 步态循环的任意相位——若落在"支撑腿完全伸直"相位（t≈0.5s，膝≈0°），
	# 启动瞬间就是"四肢先伸直一下再滑步"。AT_START 让 walk 总从起步帧（膝弯曲）
	# 开始、停止总回站姿，消除伸直相位。walk↔run 步态同相，保留 SYNC 保连续。
	sm.add_transition(ANIM_IDLE, ANIM_WALK, _smt(0.06, false))
	sm.add_transition(ANIM_WALK, ANIM_IDLE, _smt(0.06, false))
	sm.add_transition(ANIM_WALK, ANIM_RUN, _smt(0.06))
	sm.add_transition(ANIM_RUN, ANIM_WALK, _smt(0.06))
	sm.add_transition(ANIM_RUN, ANIM_IDLE, _smt(0.1, false))
	# 一次性动画（attack*/block/dead/hit/arrive，均为 LOOP_NONE）**必须**用
	# AT_START（sync=false + reset=true）切入。
	# 用 SYNC 的话新动画会从旧动画的当前进度映射过来：idle 播到 2.5s 时切 attack，
	# attack 的播放位置一上来就是 1.x 秒——挥剑从半程开始播，动画内嵌的 Hit 事件
	# （Swordwrath-Attack1 Hit@1.0s）瞬间被越过 → 命中帧对齐形同虚设；
	# 切 dead 更严重：位置直接落在片尾，死亡动画几乎不播就发 animation_finished。
	# 攻击状态（各武器专属）：从 idle/walk/run 可切入，播完回 idle
	for a in ATTACK_ANIMS:
		for s in [ANIM_IDLE, ANIM_WALK, ANIM_RUN]:
			sm.add_transition(s, a, _smt(0.1, false))
		sm.add_transition(a, ANIM_IDLE, _smt(0.12))
	for s in [ANIM_IDLE, ANIM_WALK, ANIM_RUN]:
		sm.add_transition(s, ANIM_BLOCK, _smt(0.08, false))
	sm.add_transition(ANIM_BLOCK, ANIM_IDLE, _smt(0.08))
	sm.add_transition(ANIM_BLOCK, ANIM_DEAD, _smt(0.1, false))
	sm.add_transition(ANIM_IDLE, ANIM_DEAD, _smt(0.15, false))
	sm.add_transition(ANIM_WALK, ANIM_DEAD, _smt(0.15, false))
	for a in ATTACK_ANIMS:
		sm.add_transition(a, ANIM_DEAD, _smt(0.15, false))
	# 爆头死亡（Death-Headshot 转译）：与普通死亡同款切入（终态，不回 idle）
	for s in [ANIM_IDLE, ANIM_WALK, ANIM_RUN]:
		sm.add_transition(s, ANIM_DEAD_HEADSHOT, _smt(0.15, false))
	for a in ATTACK_ANIMS:
		sm.add_transition(a, ANIM_DEAD_HEADSHOT, _smt(0.15, false))
	# 搬运动画过渡（搬运工 set_carrying 切换时）
	sm.add_transition(ANIM_IDLE, ANIM_WALK_CARRY, _smt(0.08))
	sm.add_transition(ANIM_WALK_CARRY, ANIM_IDLE, _smt(0.08))
	sm.add_transition(ANIM_WALK, ANIM_WALK_CARRY, _smt(0.08))
	sm.add_transition(ANIM_WALK_CARRY, ANIM_WALK, _smt(0.08))
	sm.add_transition(ANIM_WALK_CARRY, ANIM_RUN, _smt(0.08))
	sm.add_transition(ANIM_RUN, ANIM_WALK_CARRY, _smt(0.08))
	# 建造动画过渡（建造工 set_action_anim 切换时）
	sm.add_transition(ANIM_IDLE, ANIM_BUILD, _smt(0.08))
	sm.add_transition(ANIM_BUILD, ANIM_IDLE, _smt(0.08))
	sm.add_transition(ANIM_WALK, ANIM_BUILD, _smt(0.08))
	sm.add_transition(ANIM_BUILD, ANIM_WALK, _smt(0.08))
	sm.add_transition("Start", ANIM_IDLE, _smt(0.0))
	# 受击状态（普通 state）：rig.play_hit 打断插入 hit_front/hit_back，
	# 播完由 rig._process 计时回切到受击前状态（对应遗产 SelectHitAnimation）。
	_add_state(sm, ANIM_HIT_FRONT)
	_add_state(sm, ANIM_HIT_BACK)
	var from_states: Array[String] = [ANIM_IDLE, ANIM_WALK, ANIM_RUN]
	from_states.append_array(ATTACK_ANIMS)
	for s in from_states:
		sm.add_transition(s, ANIM_HIT_FRONT, _smt(0.05, false))
		sm.add_transition(s, ANIM_HIT_BACK, _smt(0.05, false))
	sm.add_transition(ANIM_HIT_FRONT, ANIM_IDLE, _smt(0.08))
	sm.add_transition(ANIM_HIT_BACK, ANIM_IDLE, _smt(0.08))
	sm.add_transition(ANIM_HIT_FRONT, ANIM_DEAD, _smt(0.1, false))
	sm.add_transition(ANIM_HIT_BACK, ANIM_DEAD, _smt(0.1, false))
	sm.add_transition(ANIM_HIT_FRONT, ANIM_DEAD_HEADSHOT, _smt(0.1, false))
	sm.add_transition(ANIM_HIT_BACK, ANIM_DEAD_HEADSHOT, _smt(0.1, false))
	# 列阵到位动画（AI 完善批次 4，对应传奇 ArriveAtFormationAnimationSystem）：
	# 主状态可切入 arrive；播完由 rig.animation_finished 回 idle（VisualController 处理）
	_add_state(sm, ANIM_ARRIVE)
	for s in from_states:
		sm.add_transition(s, ANIM_ARRIVE, _smt(0.1, false))
	sm.add_transition(ANIM_ARRIVE, ANIM_IDLE, _smt(0.08))
	sm.add_transition(ANIM_ARRIVE, ANIM_DEAD, _smt(0.1, false))
	# 先关联 player，再设 tree_root，最后激活
	tree.anim_player = player.get_path()
	tree.tree_root = sm
	# 编辑器模式下不激活 AnimationTree，避免触发虚拟 AnimationPlayer 警告
	if not Engine.is_editor_hint():
		tree.active = true
	return tree.get("parameters/playback")


# ============================================================
#  变体池公共 API（反编译参考实装 B）
# ============================================================

## 随机挑一个待机变体动画名（防全员同帧；进入待机时调用一次并保持）。
static func pick_stand_variant() -> String:
	return STAND_VARIANTS[randi() % STAND_VARIANTS.size()]


## 按武器类型随机挑站姿：剑士从 Stand1/2 变体池取，其余兵种单一站姿
## （原版数据每兵种只有 1 个 Stand；返回仍是"进入待机时调用一次并保持"语义）。
static func pick_stand_variant_for(weapon_type: int) -> String:
	var pool: Array[String] = [idle_for_weapon(weapon_type)]
	if weapon_type == 0:
		pool = STAND_VARIANTS
	return pool[randi() % pool.size()]


## 动态切换 state 节点的动画资源（如 idle 状态换待机变体）。
## 变体与 state 共用：改 idle state 的动画名即可，不必为每个变体建独立 state。
static func set_state_animation(sm: AnimationNodeStateMachine, state_name: String, anim_name: String) -> void:
	if sm == null or not sm.has_node(state_name):
		return
	var node: AnimationNode = sm.get_node(state_name)
	if node is AnimationNodeAnimation:
		node.animation = anim_name


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
	push_warning("StickmanAnims: 动画资源不存在 %s，请运行 tools/baking/bake_anims.tscn 生成" % path)


static func _add_state(sm: AnimationNodeStateMachine, anim_name: String) -> void:
	sm.add_node(anim_name, _anim_node(anim_name))


## 创建引用指定动画的 AnimationNodeAnimation
static func _anim_node(anim_name: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = anim_name
	return node


static func _smt(xfade: float, sync: bool = true) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
	# Godot 4.4+ 移除了 SWITCH_MODE_AT_START，改用 IMMEDIATE + reset 组合实现"从头播放"：
	#   sync=false（idle↔walk/run↔idle）：IMMEDIATE + reset=true → 新动画从初始帧开始，
	#     避免 SYNC 把 idle 的播放进度映射到 walk 步态循环的"支撑腿伸直"相位（膝≈0°，
	#     表现为启动瞬间"四肢先伸直一下再滑步"）。
	#   sync=true（walk↔run）：SYNC + reset=false → 保持动画进度，步态连续不跳变。
	t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC if sync \
			else AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	t.reset = not sync
	t.xfade_time = xfade
	return t
