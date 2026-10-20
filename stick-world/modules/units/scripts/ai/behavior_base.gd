class_name BehaviorBase
extends Node
## AI 行为基类 -- 所有行为状态的最小单元。
##
## 详见 docs/技术/架构/场景与战斗/场景与战斗架构.md §7.2。
## 每个行为定义 enter / update / exit 三个回调，由 BehaviorStateMachine 调度。
## 行为本身不决策"下一步做什么"，只负责执行当前逻辑，
## 完成后调用 finish() 通知状态机，由 AIController 决策切换。

# ─────────────────────────────── 运行时 ────────────────────────────────
## 行为名称（唯一标识，用于状态机 travel，子类 _ready 中赋值）
var behavior_name: String = ""
## 所属实体引用（由 AIController 注入）
var entity: CharacterBody2D = null
## 是否已完成（到达目标 / 闲置时间到），由 finish() 设置
var _finished: bool = false
## 是否已激活（enter 后 true，exit 后 false）
var _active: bool = false
## 压制锁步态标记（上一拍是否被压——解除沿用它做一次性收盾）
var _suppression_pinned: bool = false


# ─────────────────────────────── 生命周期回调 ────────────────────────────────

## 进入此行为时调用。previous 为上一个行为名（可能为空），params 为 travel 传入的参数。
func enter(_previous: String, _params: Dictionary) -> void:
	_finished = false
	_active = true


## 每物理帧更新（由 BehaviorStateMachine.physics_update 转发）。
func update(_delta: float) -> void:
	pass


## 退出此行为时调用。next 为下一个行为名。
func exit(_next: String) -> void:
	_active = false


# ─────────────────────────────── 公共方法 ────────────────────────────────

## 标记此行为已完成，通知 AIController 决策下一步。
func finish() -> void:
	_finished = true


## 此行为是否已完成。
func is_finished() -> bool:
	return _finished


## 此行为是否处于激活状态。
func is_active() -> bool:
	return _active


# ─────────────────────── 压制锁步（02 二-A.5，CoH pinned 直译）───────────────────────

## 压制锁步消费段：被压 → 停滞 + 蜷缩举盾姿态（block_crouch 待命变体）——
## 不追不打不挪窝不后撤，站桩吃伤害（根除避战裁决：无任何逃离通道），姿态是
## 唯一反馈。盾单位举盾照常参与格挡判定（既有战斗真值），无盾单位纯姿态零数值。
## 各行为 update 首段调用（attack 压制段同源）；压制结束在下一次调用时**一次性
## 收盾**（防姿态粘死：如压制中目标死亡，attack 无目标路径不会再跑
## _update_arrow_threat_block；attack 侧威胁/攻后举盾窗口下拍重算会自然再举）。
## ai_stop/set_blocking 幂等重申无副作用。duck：组件缺失（测试桩）= 未被压，
## 零回归。
func pinned_by_suppression() -> bool:
	if entity == null or not is_instance_valid(entity) \
			or not entity.has_method("get_status_effects"):
		return false
	var se: Node = entity.get_status_effects()
	var pinned: bool = se != null and is_instance_valid(se) \
			and se.has_method("has_suppressed") and bool(se.has_suppressed())
	if not pinned:
		if _suppression_pinned:
			_suppression_pinned = false
			var w0: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
			if w0 != null and is_instance_valid(w0) and w0.has_method("set_blocking"):
				w0.set_blocking(false)
		return false
	_suppression_pinned = true
	if entity.has_method("ai_stop"):
		entity.ai_stop()
	var w: Node = entity.get_weapon() if entity.has_method("get_weapon") else null
	if w != null and is_instance_valid(w) and w.has_method("set_blocking"):
		w.set_blocking(true)
	return true


# ─────────────────────────────── 统一面向（SWL Ai.Face 直译）────────────────────────────────

## AI 统一面向入口（SWL Ai.Face(Unit u) 直译）：所有"面向目标/单位"的切换
## 收敛到此（底层走实体 face_towards 横向翻转）——散落各行为的 open fire 前
## 回头、走位后侧身统一处理，防"反向拉弓/背身挥刀"回归。
func face_target(target: Node) -> void:
	if entity == null or not is_instance_valid(entity) \
			or target == null or not is_instance_valid(target):
		return
	if entity.has_method("face_towards"):
		entity.face_towards(target.global_position)


## 面向指定点（SWL FaceDirection 语义近亲：按点定朝向而非 ±1 枚举）。
func face_position(pos: Vector2) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if entity.has_method("face_towards"):
		entity.face_towards(pos)


## 战线朝向收口（批5 战线，SWL Team.direction 语义）：站定在战线槽位上的
## 单位面向敌阵。移动朝向是"最后一步"的残影——倒退/横移归位的单位不收口
## 就会背对战线站桩（创始人点正「有人不面对战线」）。查战线面向（无战线
## 回落班战斗锚面向；都没有 = 0 不干预）；战斗朝向锁活跃时 try_set_facing
## 自会拒绝，无需此处判断。
func face_battle_dir() -> void:
	if entity == null or not is_instance_valid(entity) \
			or not entity.has_method("get_formation_system"):
		return
	var fs: Node = entity.get_formation_system()
	if fs == null or not is_instance_valid(fs) or not fs.has_method("get_unit_face_dir"):
		return
	var dir: int = fs.get_unit_face_dir(entity)
	if dir != 0 and entity.has_method("get_facing") and entity.has_method("try_set_facing") \
			and entity.get_facing() != dir:
		entity.try_set_facing(dir)


# ─────────────────────────── 城墙门洞引导（gate_router 协议）──────────────────────────

## 直线 steering 遇城墙时的门洞引导（HD-2D 主街等带墙图）：向所在图的
## gate_router（MapBase 侧 gate_steer_point）要一个门洞口引导点，先绕到门口
## 再直穿。无路由器/不跨墙线/跨越点已落在门洞带内时原样返回 target。
func gate_steered_target(target: Vector2) -> Vector2:
	if entity == null or not is_instance_valid(entity) or entity.get_tree() == null:
		return target
	var router: Node = entity.get_tree().get_first_node_in_group("gate_router")
	if router == null or not router.has_method("gate_steer_point"):
		return target
	var wp: Vector2 = router.gate_steer_point(entity.global_position, target)
	return target if wp == Vector2.ZERO else wp
