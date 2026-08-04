class_name StickmanEntity
extends CharacterBody2D
## 火柴人实体 —— 物理+碰撞外壳。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1。
## 在已有 StickmanRig（纯渲染骨架）外包一层 CharacterBody2D，
## 承担物理移动、碰撞、附身接口。
##
## P0 阶段：
##   - 玩家附身时 WASD 控制移动
##   - 未附身时静止 idle（AI 留到阶段 0.3）
##
## 子节点结构：
##   StickmanEntity (CharacterBody2D)
##   ├── RigHost (Node2D, 实例化 stickman_test.tscn，禁用其脚本)
##   │   ├── StickmanRig (Skeleton2D)
##   │   └── Node2D (IK markers parent)
##   ├── VisualController (Node, visual_controller.gd —— 动画播放/头顶进度条)
##   ├── InteractionController (Node, interaction_controller.gd —— 按E交互/提示弹窗)
##   └── CollisionShape2D

# ─────────────────────────────── 常量 ────────────────────────────────
## 基础行走速度（px/s）—— ×1.6 加速后
const WALK_SPEED: float = 160.0
## 奔跑速度—— ×1.6 加速后
const RUN_SPEED: float = 208.0
## walk 动画基准速率（速度=WALK_ANIM_BASE 时 anim_speed=1.0 * ANIM_SPEED_MULT）
const WALK_ANIM_BASE: float = 100.0
## 动画整体播放倍率（×1.4 加速，与 visual_controller.gd 一致）
const ANIM_SPEED_MULT: float = 1.4
## 切到 idle 的速度阈值
const IDLE_THRESHOLD: float = 5.0
## 火柴人渲染缩放（对齐 stickman_test.BASE_SCALE * 1.5，适配 DESIGN_HEIGHT=1080）
const BASE_SCALE: float = 0.5

## 视觉控制器组件脚本（动画播放/头顶进度条）
const _VisualControllerScript: GDScript = preload("res://modules/units/scripts/entity/visual_controller.gd")
## 交互控制器组件脚本（按E交互/提示弹窗）
const _InteractionControllerScript: GDScript = preload("res://modules/units/scripts/entity/interaction_controller.gd")
## 头顶血条组件脚本（受击后显示 HP，满血隐藏）
const _HealthBarScript: GDScript = preload("res://modules/units/scripts/entity/health_bar_indicator.gd")

# ─────────────────────────────── @export ────────────────────────────────
## 是否被玩家附身（true=玩家控制，false=AI 控制）
@export var possessed: bool = false:
	set(v):
		possessed = v
		_on_possession_changed(v)

## 移动加速度（px/s²）
@export var accel: float = 600.0
## 减速度（px/s²）
@export var decel: float = 800.0

# ─────────────────────────────── 地面约束（§7.1.1）────────────────────────────────
## 地面线 Y（由 MapInstance.spawn_entity 注入，火柴人可走区域顶部）
var ground_y: float = 450.0
## 地面底部 Y（火柴人可走区域底部，= ground_y + DESIGN_HEIGHT * ground_ratio）
var ground_bottom: float = 882.0
## X 活动范围左边界（由 MapInstance 注入）
var map_left: float = 0.0
## X 活动范围右边界（由 MapInstance 注入）
var map_right: float = 8192.0
## 脚部到节点原点的 Y 偏移（由 _ready 从模型 marker 动态计算，正值=脚在下方）
var foot_offset: float = 45.0

# ─────────────────────────────── 通行障碍（§7.1.2）────────────────────────────────
## 地图引用（供地形倍率/交互/脱困查询，由 VillageMap.spawn_entity 注入）
var _map_ref: Node2D = null

# ─────────────────────────────── AI 移动（§7.1 / §7.2）────────────────────────────────
## AI 控制器引用（_ready 时自动获取子节点）
var _ai_controller: Node = null
## AI 设定的移动方向（归一化），由 ai_move() 设置
var _ai_move_dir: Vector2 = Vector2.ZERO
## AI 是否要求奔跑
var _ai_running: bool = false
## Construction 模块 API 引用（由 GameRoot spawn 时注入的是 ConstructionApi 实例，供 AIController 查询派工；可能为 null）
var _construction_manager: Node = null

# ─────────────────────────────── 战斗（§7.1 / §8）────────────────────────────────
## 阵营 ID（0=未参战，1/2=敌对双方，由 BattleInstance 分配）
var faction_id: int = 0
## 所属战斗实例引用（null=未参战）
var _battle_instance: Node = null

# ─────────────────────────────── 编队角色（编制预设派生）────────────────────────────────
## 角色类型（fighter/builder/worker，由编队预设写入，仅展示/标记；
## 行为限制由所属编队的职责范围决定，见 FormationSystem.is_work_allowed）
var role: String = ""
## FormationSystem 引用（由 GameRoot spawn 时注入，供 AIController 查询队伍职责；可能为 null）
var _formation_system: Node = null

# ─────────────────────────────── 运行时 ────────────────────────────────
## StickmanRig 引用（渲染骨架）
var rig: Node2D = null
## IK markers 父节点引用
var _markers_parent: Node2D = null
## 当前速度（标量，px/s）
var _current_speed: float = 0.0
## 是否在奔跑
var _is_running: bool = false
## 是否处于搬运状态（搬运工持物，walk 切换为 walk_carry 动画）
var _carrying: bool = false
## 动作动画锁定（如 build 敲击），锁定时 _play_anim 不切换动画
var _action_locked: bool = false
## 玩家按E建造的动画计时器（>0 表示正在播放 build 动画）
var _player_build_timer: float = 0.0
## 朝向（1=右，-1=左）
var _facing: int = 1
## 当前动画名
var _current_anim: String = "idle"
## 散步模式（true=只走不跑，按 Alt 切换）
var _walk_only: bool = false

# ─────────────────────────────── 受击反馈（近战打击感）────────────────────────────────
## 击退冲量速度（受击时注入，随帧衰减）
var _knockback_velocity: Vector2 = Vector2.ZERO
## 击退衰减（px/s²）
const KNOCKBACK_DECAY: float = 700.0
## 受击红闪 Tween（中断旧闪烁）
var _hurt_tween: Tween = null

# ─────────────────────────────── 群体分离（防叠人/1字长蛇）────────────────────────────────
## 分离检测半径（px）：与友军/任何单位过近时互相推开
const SEPARATION_RADIUS: float = 42.0
## 分离推力系数（叠加到 AI 移动方向）
const SEPARATION_FORCE: float = 1.6
## 头顶血条组件引用（_mount_components 装配）
var _health_bar: Node = null
## Collider 原始尺寸（_ready 时保存，_apply_scale 时乘以 BASE_SCALE）
var _collider_base_size: Vector2 = Vector2.ZERO
## Range 原始尺寸（悬停检测范围，与 Collider 同步缩放）
var _range_base_size: Vector2 = Vector2.ZERO
## Collider 原始 X 偏移（缩放后，朝右时基准；_apply_scale 时乘以 _facing 镜像）
var _collider_base_x: float = 0.0
## Range 原始 X 偏移（缩放后，朝右时基准；_apply_scale 时乘以 _facing 镜像）
var _range_base_x: float = 0.0
## Hitbox 子 CollisionShape2D 原始尺寸（受击判定，与 Collider 同步缩放）
var _hitbox_base_size: Vector2 = Vector2.ZERO
## Hitbox 子 CollisionShape2D 原始 X 偏移（缩放后，朝右时基准；_apply_scale 时乘以 _facing 镜像）
var _hitbox_base_x: float = 0.0

# ─────────────────────────────── 战斗组件引用（§7.1）────────────────────────────────
@onready var health_component: Node = get_node_or_null("HealthComponent")
@onready var hitbox: Area2D = get_node_or_null("Hitbox")
@onready var weapon_mount: Node2D = get_node_or_null("WeaponMount")

# ─────────────────────────────── 子组件引用 ────────────────────────────────
## 视觉控制器（动画播放/头顶进度条，_ready 装配）
var _visual: Node = null
## 交互控制器（按E交互/提示弹窗，_ready 装配）
var _interaction: Node = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _enter_tree() -> void:
	# 禁用 RigHost 上的 stickman_test.gd 脚本，阻止其 _ready/_process/_input 运行
	# 必须在 _ready 之前完成
	var rig_host := get_node_or_null("RigHost")
	if rig_host != null and rig_host.get_script() != null:
		rig_host.set_script(null)


## 玩家按 Alt 切换散步/奔跑模式（仅附身时生效）
## 鼠标左键攻击（仅附身时生效，§7.5）
## Q 键切换建造/战斗模式（仅附身时生效）
func _input(event: InputEvent) -> void:
	if not possessed:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ALT:
		_walk_only = not _walk_only
		if _walk_only and _is_running:
			_is_running = false
			_current_speed = WALK_SPEED
			_visual.play("walk")
	elif event is InputEventKey and event.pressed and event.keycode == KEY_Q:
		_toggle_combat_mode()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# 玩家点击：挥砍攻击（仅当鼠标不在 UI 控件上——编制按钮/建造菜单等优先）
		if _is_mouse_over_ui():
			return
		_player_attack()
		if get_viewport() != null:
			get_viewport().set_input_as_handled()


## 鼠标是否悬停在 UI 控件上（悬停时玩家左键不攻击，保证按钮可点）。
func _is_mouse_over_ui() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	if vp.has_method("gui_get_hovered_control"):
		return vp.gui_get_hovered_control() != null
	return false


func _ready() -> void:
	# 装配子组件（VisualController / InteractionController）
	_mount_components()
	# 拿到 StickmanRig 和 IK markers 引用
	var rig_host := get_node_or_null("RigHost")
	if rig_host != null:
		rig = rig_host.get_node_or_null("OutlineGroup/StickmanRig")
		_markers_parent = rig_host.get_node_or_null("OutlineGroup/Node2D")
	# 获取 AIController 子节点（§7.1）
	_ai_controller = get_node_or_null("AIController")
	# 从模型 marker 动态计算 foot_offset（适配不同参考系）
	foot_offset = _calculate_foot_offset()
	# 碰撞体移到脚部位置（保留原始 X 偏移并缩放，不硬编码为 0）
	var col := get_node_or_null("Collider") as CollisionShape2D
	if col != null:
		var col_orig_x: float = col.position.x
		_collider_base_x = col_orig_x * BASE_SCALE
		col.position = Vector2(_collider_base_x, foot_offset)
		# duplicate shape 避免多实例共享同一资源导致 _apply_scale 互相覆盖
		if col.shape is RectangleShape2D:
			col.shape = (col.shape as RectangleShape2D).duplicate()
			_collider_base_size = (col.shape as RectangleShape2D).size
	# Range 节点也 duplicate shape 并保存原始尺寸
	var rng := get_node_or_null("Range") as CollisionShape2D
	if rng != null and rng.shape is RectangleShape2D:
		rng.shape = (rng.shape as RectangleShape2D).duplicate()
		_range_base_size = (rng.shape as RectangleShape2D).size
		# Range position 也需要缩放（编辑器中的值基于原始大小，运行时需乘以 BASE_SCALE）
		_range_base_x = rng.position.x * BASE_SCALE
		rng.position *= BASE_SCALE
	# Hitbox 子 CollisionShape2D 同步缩放并保存原始尺寸/偏移
	if hitbox != null:
		var hb_shape := hitbox.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if hb_shape != null and hb_shape.shape is RectangleShape2D:
			hb_shape.shape = (hb_shape.shape as RectangleShape2D).duplicate()
			_hitbox_base_size = (hb_shape.shape as RectangleShape2D).size
			_hitbox_base_x = hb_shape.position.x * BASE_SCALE
			hb_shape.position *= BASE_SCALE
	# 应用初始缩放
	_apply_scale()
	# 播放 idle
	_visual.play("idle")
	# 战斗组件：死亡信号连接
	if health_component != null:
		health_component.died.connect(_on_died)


## 实例化并挂载子组件（VisualController / InteractionController / HealthBar）。
## 组件通过 setup(entity) 拿到本实体引用。
func _mount_components() -> void:
	_visual = Node.new()
	_visual.set_script(_VisualControllerScript)
	_visual.name = "VisualController"
	add_child(_visual)
	if _visual.has_method("setup"):
		_visual.setup(self)

	_interaction = Node.new()
	_interaction.set_script(_InteractionControllerScript)
	_interaction.name = "InteractionController"
	add_child(_interaction)
	if _interaction.has_method("setup"):
		_interaction.setup(self)

	# 头顶血条（受击后显示，满血隐藏）
	_health_bar = Node2D.new()
	_health_bar.set_script(_HealthBarScript)
	_health_bar.name = "HealthBar"
	add_child(_health_bar)
	if _health_bar.has_method("setup"):
		_health_bar.setup(get_node_or_null("HealthComponent"))


## 从 RigHost 的 outfoot marker 位置计算脚部 Y 偏移。
## 公式：foot_offset = root_y + outfoot_local_y * BASE_SCALE
## 这样无论模型参考系怎么改，脚部位置都能正确对齐地面。
func _calculate_foot_offset() -> float:
	var rig_host := get_node_or_null("RigHost")
	if rig_host == null:
		return 45.0
	var root_y: float = (rig_host as Node2D).position.y
	var outfoot := rig_host.get_node_or_null("OutlineGroup/Node2D/outfoot") as Node2D
	if outfoot == null:
		return 45.0
	var outfoot_y: float = outfoot.position.y
	var offset: float = root_y + outfoot_y * BASE_SCALE
	return offset


func _physics_process(delta: float) -> void:
	# 仅在被附身时处理玩家输入
	if possessed:
		_handle_player_input(delta)
	else:
		# AI 控制：先让 AIController 决策（设置 _ai_move_dir），再处理移动
		if _ai_controller != null and _ai_controller.has_method("physics_update"):
			_ai_controller.physics_update(delta)
		_handle_ai_input(delta)
		# 静态分离：停住的单位也互相推开（移动方向修正只在移动时生效，
		# 双方都停在射程边缘时会黏住——soft-body 位置修正解决）
		_apply_static_separation()

	# 火柴人可在地面范围内上下左右移动（详见 §7.1.1）
	velocity += _knockback_velocity
	move_and_slide()
	# 击退冲量衰减
	if _knockback_velocity != Vector2.ZERO:
		var kb_len: float = _knockback_velocity.length()
		var dec: float = KNOCKBACK_DECAY * delta
		if kb_len <= dec:
			_knockback_velocity = Vector2.ZERO
		else:
			_knockback_velocity = _knockback_velocity.normalized() * (kb_len - dec)
	# Y 范围约束：脚部保持在 [ground_y, ground_bottom] 内
	var y_min: float = ground_y - foot_offset
	var y_max: float = ground_bottom - foot_offset
	global_position.y = clampf(global_position.y, y_min, y_max)
	# X 边界约束
	global_position.x = clampf(global_position.x, map_left, map_right)
	_sync_markers_transform()
	# 玩家建造动画计时（按E敲击后 1.8 秒解除动作锁定）
	if _player_build_timer > 0.0:
		_player_build_timer -= delta
		set_action_progress(1.0 - _player_build_timer / 1.8)
		if _player_build_timer <= 0.0:
			_player_build_timer = 0.0
			hide_action_progress()
			clear_action()
	# 玩家交互提示（靠近仓库/工地时显示）
	_interaction.update_hint()


# ─────────────────────────────── 玩家输入（按E / H 由交互控制器处理）────────────────────────────────

## 玩家附身时按E：交互（取放材料 / 敲击建造，实现见 InteractionController）。
## 按H：脱离卡死。
func _unhandled_input(event: InputEvent) -> void:
	if not possessed:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_E:
		_interaction.try_interact()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_H:
		escape_stuck()


# ─────────────────────────────── 玩家输入 ────────────────────────────────

func _handle_player_input(delta: float) -> void:
	# 敲击建造动作锁定：1.8s 内禁止移动
	if _player_build_timer > 0.0:
		_apply_movement(delta, Vector2.ZERO, false, false)
		return
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	_apply_movement(delta, dir, false, not _walk_only)


## 获取当前脚下地形的移动速度倍率（土路=1.0，非土路=0.8）。
func _terrain_speed_mult() -> float:
	if _map_ref != null and _map_ref.has_method("get_move_speed_mult_at_x"):
		return _map_ref.get_move_speed_mult_at_x(global_position.x)
	return 1.0


func _handle_acceleration(delta: float, allow_run: bool = true) -> void:
	var mult: float = _terrain_speed_mult()
	var walk_cap: float = WALK_SPEED * mult
	var run_cap: float = RUN_SPEED * mult
	if _is_running:
		_current_speed = run_cap
		return
	_current_speed += accel * delta
	if allow_run and _current_speed >= walk_cap:
		_is_running = true
		_current_speed = run_cap
		_visual.play("run")
		_visual.set_anim_speed(1.0 * ANIM_SPEED_MULT)
	else:
		# 不允许跑时，速度封顶在 walk_cap（受地形影响）
		_current_speed = minf(_current_speed, walk_cap)
		if _current_anim != "walk" and _current_anim != "run":
			_visual.play("walk")
		if _current_anim == "walk" and not _is_running:
			_visual.set_anim_speed(_current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT)


func _handle_deceleration(delta: float) -> void:
	if _is_running:
		_is_running = false
		_current_speed = WALK_SPEED * _terrain_speed_mult()
		_visual.play("walk")
	if _current_speed > 0:
		_current_speed -= decel * delta
		if _current_speed <= IDLE_THRESHOLD:
			_current_speed = 0.0
			_visual.play("idle")
		else:
			if _current_anim == "idle":
				_visual.play("walk")
			_visual.set_anim_speed(_current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT)


# ─────────────────────────────── AI 输入处理 ────────────────────────────────

## AI 驱动移动：根据 _ai_move_dir 处理加速/减速/动画，复用与玩家输入相同的物理逻辑。
## 移动方向叠加群体分离（防叠人/1字长蛇，行业 soft-body separation 简化版）。
func _handle_ai_input(delta: float) -> void:
	var dir: Vector2 = _ai_move_dir
	if dir != Vector2.ZERO:
		dir = _apply_separation(dir)
	_apply_movement(delta, dir, _ai_running, false)


## 群体分离：扫描附近过近的单位（同图所有存活 CharacterBody2D），
## 距离越近推力越强，叠加到移动方向（RTS 单位移动标准做法，参考
## Stick War Legacy clone 的 soft-body separation：位置推开 + 速度修正）。
func _apply_separation(dir: Vector2) -> Vector2:
	if _map_ref == null or not is_instance_valid(_map_ref):
		return dir
	if not _map_ref.has_method("get_entities"):
		return dir
	var push := Vector2.ZERO
	for e in _map_ref.get_entities():
		if e == self or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var offset: Vector2 = global_position - e.global_position
		var dist: float = offset.length()
		if dist >= SEPARATION_RADIUS or dist <= 0.001:
			continue
		# 越近推力越大（1 - dist/radius 线性权重）
		push += offset.normalized() * (1.0 - dist / SEPARATION_RADIUS)
	if push == Vector2.ZERO:
		return dir
	return (dir + push * SEPARATION_FORCE).normalized()


## 静态分离（soft-body 位置修正）：对过近邻居直接推位置（重叠量各半，双向）。
## 与 _apply_separation 的区别：后者只在移动时生效；停住的单位（射程边缘
## 互停的敌我）靠本方法持续分开，解决"黏住"bug。参考 RtsGame.resolveSoftCollisions。
func _apply_static_separation() -> void:
	if _map_ref == null or not is_instance_valid(_map_ref):
		return
	if not _map_ref.has_method("get_entities"):
		return
	for e in _map_ref.get_entities():
		if e == self or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var offset: Vector2 = global_position - e.global_position
		var dist: float = offset.length()
		if dist >= SEPARATION_RADIUS:
			continue
		if dist <= 0.001:
			# 完全重叠：退化为固定方向（向上），否则无法计算推开方向
			offset = Vector2.UP
			dist = 0.001
		# 重叠量的一半推给自己（对方也在推自己，双向合计推开整个重叠量）
		var push_dist: float = (SEPARATION_RADIUS - dist) * 0.5
		global_position += offset.normalized() * push_dist


## 获取头顶血条组件（供测试/调试）
func get_health_bar() -> Node:
	return _health_bar


## 统一移动处理（玩家与 AI 共用）：方向 → 朝向/加速/奔跑 → velocity。
## run=true 强制奔跑；allow_run=false 时不会自动加速到奔跑（NPC 散步）。
func _apply_movement(delta: float, dir: Vector2, run: bool, allow_run: bool) -> void:
	if dir != Vector2.ZERO:
		if dir.length() > 1.0:
			dir = dir.normalized()
		if dir.x != 0:
			var new_facing := 1 if dir.x > 0 else -1
			if new_facing != _facing:
				_facing = new_facing
				_apply_scale()
		if run:
			_is_running = true
			_current_speed = RUN_SPEED * _terrain_speed_mult()
			_visual.play("run")
			_visual.set_anim_speed(1.0 * ANIM_SPEED_MULT)
		else:
			_handle_acceleration(delta, allow_run)
		velocity = dir * _current_speed
	else:
		_handle_deceleration(delta)
		if _current_speed > 0:
			# 保留方向但减速
			var v_dir := velocity.normalized() if velocity.length() > 0.001 else Vector2.ZERO
			velocity = v_dir * _current_speed
		else:
			velocity = Vector2.ZERO


# ─────────────────────────────── 渲染同步 ────────────────────────────────

func _apply_scale() -> void:
	if rig == null:
		return
	var s := BASE_SCALE
	rig.scale = Vector2(s * _facing, s)
	# 同步缩放 Collider shape（Collider 不在 rig 层级下，不受 rig.scale 影响）
	if _collider_base_size != Vector2.ZERO:
		var col := get_node_or_null("Collider") as CollisionShape2D
		if col != null and col.shape is RectangleShape2D:
			(col.shape as RectangleShape2D).size = _collider_base_size * s
			# X 偏移随朝向镜像（原点不在碰撞箱中心时，翻转需镜像偏移）
			col.position.x = _collider_base_x * _facing
	# 同步缩放 Range shape（悬停检测范围，与 Collider 同步缩放）
	if _range_base_size != Vector2.ZERO:
		var rng := get_node_or_null("Range") as CollisionShape2D
		if rng != null and rng.shape is RectangleShape2D:
			(rng.shape as RectangleShape2D).size = _range_base_size * s
			rng.position.x = _range_base_x * _facing
	# 同步缩放 Hitbox 子 shape（受击判定，与 Collider 同步缩放）
	if _hitbox_base_size != Vector2.ZERO and hitbox != null:
		var hb_shape := hitbox.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if hb_shape != null and hb_shape.shape is RectangleShape2D:
			(hb_shape.shape as RectangleShape2D).size = _hitbox_base_size * s
			hb_shape.position.x = _hitbox_base_x * _facing
	_sync_markers_transform()


func _sync_markers_transform() -> void:
	if _markers_parent == null or rig == null:
		return
	# IK markers 父节点必须与 StickmanRig 同 transform，否则 IK 不可达
	_markers_parent.global_transform = rig.global_transform


# ─────────────────────────────── 动画 API（转发到 VisualController）────────────────────────────────

## 设置搬运状态：搬运工持物时 walk 切换为 walk_carry 动画。
## 由 BehaviorHaul 在 enter/exit 时调用。
func set_carrying(v: bool) -> void:
	_visual.set_carrying(v)


## 是否处于搬运状态（供交互/UI 查询，2026-08 收敛：替代组件直读 _carrying 私有字段）
func is_carrying() -> bool:
	return _carrying


## 设置玩家建造敲击计时（交互控制器触发敲击时调用，替代组件直写私有字段）
func set_player_build_timer(v: float) -> void:
	_player_build_timer = v


## 锁定动作动画（如 build 敲击），锁定期间动画不切换。
## 由 BehaviorWork 在工地播放建造动画时调用。
func set_action_anim(anim_name: String) -> void:
	_visual.set_action_anim(anim_name)


## 解除动作锁定，恢复正常动画（根据当前速度切 walk/idle）。
func clear_action() -> void:
	_visual.clear_action()


## 设置头顶动作进度（0~1，>0 显示，0 隐藏）。由 BehaviorHaul/BehaviorWork/玩家调用。
func set_action_progress(ratio: float) -> void:
	_visual.set_progress(ratio)


## 隐藏头顶动作进度条。
func hide_action_progress() -> void:
	_visual.hide_progress()


## 获取当前动画名
func get_current_anim() -> String:
	return _current_anim


# ─────────────────────────────── 玩家战斗模式（Q 键切换）────────────────────────────────

## 切换建造/战斗模式：EXPLORE <-> BATTLE。
## 由 Q 键触发（仅附身时）。BATTLE 模式下玩家保持附身（ExploreHandler 不释放），
## 左键 = 挥砍攻击；EXPLORE 模式下左键用于交互/框选。
func _toggle_combat_mode() -> void:
	var dispatcher: Node = _find_input_dispatcher()
	if dispatcher == null or not dispatcher.has_method("get_mode"):
		return
	var new_mode: int = PlayerControlAPI.Mode.BATTLE
	if dispatcher.get_mode() == PlayerControlAPI.Mode.BATTLE:
		new_mode = PlayerControlAPI.Mode.EXPLORE
	if dispatcher.has_method("set_mode"):
		dispatcher.set_mode(new_mode)
	if EventBus != null and EventBus.has_signal("ui_notification"):
		var label: String = "战斗模式（左键挥砍，Q 切回）" if new_mode == PlayerControlAPI.Mode.BATTLE else "探索模式"
		EventBus.ui_notification.emit("模式", label, "info")


## 查找 InputDispatcher（通过 game_root group 获取；2026-08 审计收敛：替代父链遍历）。
## GameRoot 注册于 "game_root" group（见 game_root._ready）。
func _find_input_dispatcher() -> Node:
	if get_tree() == null:
		return null
	var game_root: Node = get_tree().get_first_node_in_group("game_root")
	if game_root == null:
		return null
	return game_root.get("input_dispatcher") as Node


## 获取所在地图引用（可能为 null，供 AI 行为查询玩家等）。
func get_map() -> Node2D:
	return _map_ref


# ─────────────────────────────── 玩家攻击（§7.5）────────────────────────────────

## 玩家附身时鼠标左键攻击：找最近敌人InRange并执行攻击
func _player_attack() -> void:
	if weapon_mount == null or not weapon_mount.has_method("can_attack"):
		return
	if not weapon_mount.can_attack():
		return
	var target: Node = _find_nearest_enemy_in_range()
	if target == null:
		return
	weapon_mount.perform_attack(target)


## 找最近敌人（不同阵营且存活）在武器射程内
func _find_nearest_enemy_in_range() -> Node:
	if _map_ref == null or not is_instance_valid(_map_ref):
		return null
	if not _map_ref.has_method("get_entities"):
		return null
	var attack_range: float = weapon_mount.attack_range if weapon_mount != null and weapon_mount.get("attack_range") != null else 140.0
	var nearest: Node = null
	var nearest_dist: float = attack_range
	for e in _map_ref.get_entities():
		if e == self or not is_instance_valid(e):
			continue
		if not (e is CharacterBody2D):
			continue
		# 跳过同阵营
		if e.has_method("get_faction") and e.get_faction() == faction_id:
			continue
		# 跳过死亡
		if e.has_method("is_dead") and e.is_dead():
			continue
		var dist: float = global_position.distance_to(e.global_position)
		if dist <= nearest_dist:
			nearest_dist = dist
			nearest = e
	return nearest


# ─────────────────────────────── 公共 API ────────────────────────────────

## 由 MapInstance.spawn_entity 调用，注入地面约束参数（§7.1.1）
func set_ground_constraints(p_ground_y: float, p_ground_bottom: float, p_map_left: float, p_map_right: float) -> void:
	ground_y = p_ground_y
	ground_bottom = p_ground_bottom
	map_left = p_map_left
	map_right = p_map_right


## 由 MapInstance.spawn_entity 调用，注入地图引用（供通行障碍查询，§7.1.2）
func set_map_reference(p_map: Node2D) -> void:
	_map_ref = p_map


## 物理查询：实体的 Collider 形状位于 pos 时是否与任何物理体（建筑/工地障碍/其他实体）碰撞。
## 排除自身（否则查询自己的位置永远命中自己）。用于脱困采样判定与测试。
func is_position_blocked(pos: Vector2) -> bool:
	var col := get_node_or_null("Collider") as CollisionShape2D
	if col == null or col.shape == null:
		return false
	var space := get_world_2d().direct_space_state
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = col.shape
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	query.transform = Transform2D(0.0, pos)
	return not space.intersect_shape(query, 1).is_empty()


## 脱离卡死（H 键 / HUD 脱困按钮）：随机传送到附近空旷地带。
## 以当前位置为中心，半径 200px 起随机采样（每圈 24 次），用物理查询
## 判定空旷（is_position_blocked）；逐级扩大到 3200px；仍找不到则沿左右
## 线性扫描最近空旷点；兜底回地图中心。只动 X（Y 由地面约束管理）。
func escape_stuck() -> void:
	if _map_ref == null or not is_instance_valid(_map_ref):
		return
	var map_left: float = float(_map_ref.map_left) if "map_left" in _map_ref else -100000.0
	var map_right: float = float(_map_ref.map_right) if "map_right" in _map_ref else 100000.0
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var radius: float = 200.0
	var found: bool = false
	while radius <= 3200.0 and not found:
		for attempt in range(24):
			var probe_x: float = global_position.x + rng.randf_range(-radius, radius)
			probe_x = clampf(probe_x, map_left + 50.0, map_right - 50.0)
			if not is_position_blocked(Vector2(probe_x, global_position.y)):
				global_position.x = probe_x
				found = true
				break
		radius *= 2.0
	# 随机采样未命中（密集建筑区）：沿左右线性扫描最近的空旷点
	if not found:
		for step in range(20, 4001, 20):
			for s in [-1.0, 1.0]:
				var probe_x: float = global_position.x + s * step
				probe_x = clampf(probe_x, map_left + 50.0, map_right - 50.0)
				if not is_position_blocked(Vector2(probe_x, global_position.y)):
					global_position.x = probe_x
					found = true
					break
			if found:
				break
	if not found:
		global_position.x = (map_left + map_right) * 0.5


## 切换附身状态
func set_possessed(p: bool) -> void:
	possessed = p


func is_possessed() -> bool:
	return possessed


## 获取朝向
func get_facing() -> int:
	return _facing


func _on_possession_changed(p: bool) -> void:
	# 附身切换时重置速度，避免残留
	if not p:
		_current_speed = 0.0
		_is_running = false
		velocity = Vector2.ZERO
	# 取消附身时也清除 AI 移动方向，避免残留
	_ai_move_dir = Vector2.ZERO
	_ai_running = false


# ─────────────────────────────── AI 移动接口（供 AIController / behavior 调用）────────────────────────────────

## AI 设定移动方向。dir 应为归一化向量，run=true 强制奔跑。
func ai_move(dir: Vector2, run: bool = false) -> void:
	_ai_move_dir = dir
	_ai_running = run


## AI 停止移动。
func ai_stop() -> void:
	_ai_move_dir = Vector2.ZERO
	_ai_running = false


## 获取 AIController 引用（可能为 null）。
func get_ai_controller() -> Node:
	return _ai_controller


## 由 GameRoot spawn 时注入 ConstructionApi 引用（供 AIController 查询派工）
func set_construction_manager(manager: Node) -> void:
	_construction_manager = manager
	# 把 NPC 注册为可派工工人（api.gd 已转发 register_worker）
	if manager != null and manager.has_method("register_worker"):
		manager.register_worker(self)


## 获取 ConstructionApi 引用（可能为 null）
func get_construction_manager() -> Node:
	return _construction_manager


## 销毁时反注册派工池，防止悬垂引用（2026-08 收敛）
func _exit_tree() -> void:
	if _construction_manager != null and is_instance_valid(_construction_manager) \
			and _construction_manager.has_method("unregister_worker"):
		_construction_manager.unregister_worker(self)
	_construction_manager = null


## 由 GameRoot spawn 时注入 FormationSystem 引用（供 AIController 查询队伍职责）。
## 未注入（如测试直生实体）时视为"未编队"，不限制行为。
func set_formation_system(fs: Node) -> void:
	_formation_system = fs


## 获取 FormationSystem 引用（可能为 null）
func get_formation_system() -> Node:
	return _formation_system


## 设置角色类型（由 FormationSystem 编队时写入）。
func set_role(r: String) -> void:
	role = r


## 获取角色类型（空=未编队）。
func get_role() -> String:
	return role


# ─────────────────────────────── 战斗 API（§8）────────────────────────────────

## 死亡处理：停止移动、播放死亡动画、禁用受击、通知战斗实例
func _on_died() -> void:
	ai_stop()
	velocity = Vector2.ZERO
	_visual.play("dead")
	# 禁用 hitbox 避免继续被攻击
	if hitbox != null:
		hitbox.set_deferred("monitorable", false)
	# 通知战斗实例（由 BattleInstance 统计伤亡）
	if _battle_instance != null and is_instance_valid(_battle_instance):
		if _battle_instance.has_method("on_unit_died"):
			_battle_instance.on_unit_died(self)


## 设置阵营 ID（由 BattleInstance 分配）
func set_faction(fid: int) -> void:
	faction_id = fid


## 获取阵营 ID
func get_faction() -> int:
	return faction_id


## 设置所属战斗实例
func set_battle_instance(bi: Node) -> void:
	_battle_instance = bi


## 获取所属战斗实例（可能为 null）
func get_battle_instance() -> Node:
	return _battle_instance


## 获取 HealthComponent（可能为 null）
func get_health() -> Node:
	return health_component


## 获取 WeaponMount（可能为 null）
func get_weapon() -> Node2D:
	return weapon_mount


## 是否已死亡
func is_dead() -> bool:
	return health_component != null and health_component.is_dead()


## 是否溃逃（士气低于阈值且未死）
func is_routed() -> bool:
	return health_component != null and health_component.is_routed()


# ─────────────────────────────── 受击反馈（§7.5 近战打击感）────────────────────────────────

## 受击反馈：物理击退冲量 + 受击红闪。
## 由 WeaponMount.perform_attack 命中时调用（dir 为指向目标的方向）。
func apply_hit_reaction(dir: Vector2, force: float) -> void:
	if dir != Vector2.ZERO:
		_knockback_velocity = dir.normalized() * force
	_flash_hurt()


## 受击红闪：身体短暂变红后恢复（Stickman Burst 受击闪光方案）。
func _flash_hurt() -> void:
	if rig == null:
		return
	if _hurt_tween != null and _hurt_tween.is_valid():
		_hurt_tween.kill()
	_hurt_tween = create_tween()
	_hurt_tween.tween_property(rig, "modulate", Color(1.0, 0.25, 0.25), 0.06)
	_hurt_tween.tween_property(rig, "modulate", Color.WHITE, 0.18)


## 获取当前击退冲量（供测试/调试）
func get_knockback_velocity() -> Vector2:
	return _knockback_velocity
