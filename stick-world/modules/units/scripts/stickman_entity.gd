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
##   └── CollisionShape2D

# ─────────────────────────────── 常量 ────────────────────────────────
## 基础行走速度（px/s）—— ×1.6 加速后
const WALK_SPEED: float = 160.0
## 奔跑速度—— ×1.6 加速后
const RUN_SPEED: float = 208.0
## walk 动画基准速率（速度=WALK_ANIM_BASE 时 anim_speed=1.0 * ANIM_SPEED_MULT）
const WALK_ANIM_BASE: float = 100.0
## 动画整体播放倍率（×1.4 加速）
const ANIM_SPEED_MULT: float = 1.4
## walk 动画最低播放速率
const MIN_ANIM_SCALE: float = 0.2
## 切到 idle 的速度阈值
const IDLE_THRESHOLD: float = 5.0
## 火柴人渲染缩放（对齐 stickman_test.BASE_SCALE * 1.5，适配 DESIGN_HEIGHT=1080）
const BASE_SCALE: float = 0.5

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
## 地图引用（供通行障碍查询，由 VillageMap.spawn_entity 注入）
var _map_ref: Node2D = null
## 上一帧有效位置（未碰撞障碍时的位置，用于回退）
var _last_valid_position: Vector2 = Vector2.ZERO

# ─────────────────────────────── AI 移动（§7.1 / §7.2）────────────────────────────────
## AI 控制器引用（_ready 时自动获取子节点）
var _ai_controller: Node = null
## AI 设定的移动方向（归一化），由 ai_move() 设置
var _ai_move_dir: Vector2 = Vector2.ZERO
## AI 是否要求奔跑
var _ai_running: bool = false
## Construction 模块引用（由 GameRoot spawn 时注入，供 AIController 查询派工；可能为 null）
var _construction_manager: Node = null

# ─────────────────────────────── 战斗（§7.1 / §8）────────────────────────────────
## 阵营 ID（0=未参战，1/2=敌对双方，由 BattleInstance 分配）
var faction_id: int = 0
## 所属战斗实例引用（null=未参战）
var _battle_instance: Node = null

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
## 开场 IK workaround（前 0.25s 模拟向右移动触发 IK 解算）
var _startup_fix_time: float = 0.25
var _startup_fix_elapsed: float = 0.0
var _startup_done: bool = false
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


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _enter_tree() -> void:
	# 禁用 RigHost 上的 stickman_test.gd 脚本，阻止其 _ready/_process/_input 运行
	# 必须在 _ready 之前完成
	var rig_host := get_node_or_null("RigHost")
	if rig_host != null and rig_host.get_script() != null:
		rig_host.set_script(null)


## 玩家按 Alt 切换散步/奔跑模式（仅附身时生效）
## 鼠标左键攻击（仅附身时生效，§7.5）
func _input(event: InputEvent) -> void:
	if not possessed:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ALT:
		_walk_only = not _walk_only
		if _walk_only and _is_running:
			_is_running = false
			_current_speed = WALK_SPEED
			_play_anim("walk")
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_player_attack()


func _ready() -> void:
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
	_play_anim("idle")
	# 初始化上一帧有效位置
	_last_valid_position = global_position
	# 战斗组件：死亡信号连接
	if health_component != null:
		health_component.died.connect(_on_died)


## 外部设置上一帧有效位置（修复 add_child 时序：_ready 时 global_position 还是被默认值 (0,0)）
func set_last_valid_position(pos: Vector2) -> void:
	_last_valid_position = pos


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
	print("[StickmanEntity] foot_offset = ", offset, " (root_y=", root_y, " outfoot_y=", outfoot_y, " scale=", BASE_SCALE, ")")
	return offset


func _physics_process(delta: float) -> void:
	# 开场 IK workaround
	if not _startup_done:
		_startup_fix_elapsed += delta
		if _startup_fix_elapsed < _startup_fix_time:
			if rig != null:
				rig.position += Vector2.RIGHT * 30 * delta
				_sync_markers_transform()
				if _current_anim == "idle":
					_play_anim("walk")
			return
		else:
			_startup_done = true
			if rig != null:
				rig.position = Vector2.ZERO
				_sync_markers_transform()
			_play_anim("idle")
			_current_speed = 0.0
			velocity = Vector2.ZERO

	# 仅在被附身时处理玩家输入
	if possessed:
		_handle_player_input(delta)
	else:
		# AI 控制：先让 AIController 决策（设置 _ai_move_dir），再处理移动
		if _ai_controller != null and _ai_controller.has_method("physics_update"):
			_ai_controller.physics_update(delta)
		_handle_ai_input(delta)

	# 火柴人可在地面范围内上下左右移动（详见 §7.1.1）
	move_and_slide()
	# Y 范围约束：脚部保持在 [ground_y, ground_bottom] 内
	var y_min: float = ground_y - foot_offset
	var y_max: float = ground_bottom - foot_offset
	global_position.y = clampf(global_position.y, y_min, y_max)
	# X 边界约束
	global_position.x = clampf(global_position.x, map_left, map_right)
	# 通行障碍检测：若进入 WalkBarrier / PassageBarrier 区域，回退到上一帧位置（§7.1.2）
	if _is_in_passage_barrier():
		global_position = _last_valid_position
		velocity = Vector2.ZERO
	else:
		_last_valid_position = global_position
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
	_update_interact_hint()


# ─────────────────────────────── 玩家交互（按E）────────────────────────────────

## 玩家附身时按E：在仓库附近取材料，在工地附近交付/建造。
func _unhandled_input(event: InputEvent) -> void:
	if not possessed:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_E:
		_try_player_interact()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_H:
		_escape_stuck()


func _try_player_interact() -> void:
	if _construction_manager == null:
		return
	var info: Dictionary = _find_interact_target()
	if info.is_empty():
		return
	var target = info.get("target", null)
	if target == null:
		return
	# 工地交互
	if target is RefCounted:
		var project: RefCounted = target as RefCounted
		if _carrying:
			project.deliver_material()
			set_carrying(false)
		elif not project.needs_material():
			# 敲击一次：推进建造进度 + 播放 build 动画
			var per_hit: float = project.total_work / 8.0
			project.add_build_progress(per_hit)
			set_action_anim("build")
			_player_build_timer = 1.8
	# 仓库交互
	elif target is Node2D:
		if _carrying:
			# 扔回材料到仓库
			set_carrying(false)
		else:
			set_carrying(true)


# ─────────────────────────────── 交互目标检测 ────────────────────────────────

## 从建筑 PassageBarrier CollisionShape2D 读取真实世界边界。
## 返回 {left, right, center} 或回退到 width*32 估算。
func _get_building_barrier_bounds(building: Node2D) -> Dictionary:
	var pb: Node = building.get_node_or_null("PassageBarrier") if building.has_method("get_node_or_null") else null
	if pb != null:
		for child in pb.get_children():
			if child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
				var cs: CollisionShape2D = child as CollisionShape2D
				var s: RectangleShape2D = (cs.shape as RectangleShape2D)
				var cx: float = cs.global_position.x
				return {"left": cx - s.size.x * 0.5, "right": cx + s.size.x * 0.5, "center": cx}
	# 回退：用 width 属性估算
	var w: int = int(building.get("width")) if "width" in building else 2
	var left_x: float = building.global_position.x
	return {"left": left_x, "right": left_x + float(w) * 32.0, "center": left_x + float(w) * 16.0}

## 检测玩家 X 是否在工地建筑范围外延 margin 内。
func _is_near_project(project: RefCounted, margin: float = 80.0) -> bool:
	var left_x: float = float(project.cell_x) * 32.0
	var right_x: float = left_x + float(project.width) * 32.0
	return global_position.x >= left_x - margin and global_position.x <= right_x + margin

## 检测玩家 X 是否在建筑 PassageBarrier 范围外延 margin 内。
func _is_near_building(building: Node2D, margin: float = 80.0) -> bool:
	var bounds: Dictionary = _get_building_barrier_bounds(building)
	return global_position.x >= float(bounds.left) - margin and global_position.x <= float(bounds.right) + margin

## 查找当前可交互目标及提示文字。返回 {target, hint, center_x} 或空。
func _find_interact_target() -> Dictionary:
	if _construction_manager == null:
		return {}
	# 优先：工地
	var project: RefCounted = _construction_manager.get_nearest_project(global_position)
	if project != null and _is_near_project(project):
		var left_x: float = float(project.cell_x) * 32.0
		var right_x: float = left_x + float(project.width) * 32.0
		var cx: float = (left_x + right_x) * 0.5
		var hint: String = ""
		if _carrying:
			hint = "按E交付材料"
		elif project.needs_material():
			hint = "材料不足，等待搬运"
		else:
			hint = "按E敲击建造"
		return {"target": project, "hint": hint, "center_x": cx}
	# 仓库
	var warehouse: Node2D = _construction_manager.get_nearest_warehouse(global_position)
	if warehouse != null and _is_near_building(warehouse):
		var bounds: Dictionary = _get_building_barrier_bounds(warehouse)
		var hint: String = ""
		if _carrying:
			hint = "按E放回材料"
		else:
			hint = "按E拿起建材"
		return {"target": warehouse, "hint": hint, "center_x": float(bounds.center)}
	return {}


# ─────────────────────────────── 玩家输入 ────────────────────────────────

func _handle_player_input(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0

	if dir != Vector2.ZERO:
		if dir.length() > 1.0:
			dir = dir.normalized()
		if dir.x != 0:
			var new_facing := 1 if dir.x > 0 else -1
			if new_facing != _facing:
				_facing = new_facing
				_apply_scale()
		_handle_acceleration(delta, not _walk_only)
		velocity = dir * _current_speed
	else:
		_handle_deceleration(delta)
		if _current_speed > 0:
			# 保留方向但减速
			var v_dir := velocity.normalized() if velocity.length() > 0.001 else Vector2.ZERO
			velocity = v_dir * _current_speed
		else:
			velocity = Vector2.ZERO


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
		_play_anim("run")
		if rig != null:
			rig.set_anim_speed(1.0 * ANIM_SPEED_MULT)
	else:
		# 不允许跑时，速度封顶在 walk_cap（受地形影响）
		_current_speed = minf(_current_speed, walk_cap)
		if _current_anim != "walk" and _current_anim != "run":
			_play_anim("walk")
		if _current_anim == "walk" and not _is_running:
			var s := _current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT
			if rig != null:
				rig.set_anim_speed(maxf(s, MIN_ANIM_SCALE))


func _handle_deceleration(delta: float) -> void:
	if _is_running:
		_is_running = false
		_current_speed = WALK_SPEED * _terrain_speed_mult()
		_play_anim("walk")
	if _current_speed > 0:
		_current_speed -= decel * delta
		if _current_speed <= IDLE_THRESHOLD:
			_current_speed = 0.0
			_play_anim("idle")
		else:
			if _current_anim == "idle":
				_play_anim("walk")
			var s := _current_speed / WALK_ANIM_BASE * ANIM_SPEED_MULT
			if rig != null:
				rig.set_anim_speed(maxf(s, MIN_ANIM_SCALE))


# ─────────────────────────────── AI 输入处理 ────────────────────────────────

## AI 驱动移动：根据 _ai_move_dir 处理加速/减速/动画，复用与玩家输入相同的物理逻辑。
func _handle_ai_input(delta: float) -> void:
	if _ai_move_dir != Vector2.ZERO:
		# 有移动方向：加速 + 设速度
		var dir: Vector2 = _ai_move_dir
		if dir.length() > 1.0:
			dir = dir.normalized()
		if dir.x != 0:
			var new_facing := 1 if dir.x > 0 else -1
			if new_facing != _facing:
				_facing = new_facing
				_apply_scale()
		if _ai_running:
			_is_running = true
			_current_speed = RUN_SPEED * _terrain_speed_mult()
			_play_anim("run")
			if rig != null:
				rig.set_anim_speed(1.0 * ANIM_SPEED_MULT)
		else:
			# NPC 始终散步，不允许加速到奔跑
			_handle_acceleration(delta, false)
		velocity = dir * _current_speed
	else:
		# 无移动方向：减速到停
		_handle_deceleration(delta)
		if _current_speed > 0:
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


func _play_anim(anim_name: String) -> void:
	if rig == null:
		return
	# 动作锁定时保持当前动作动画（如 build），不切走
	if _action_locked:
		return
	# 搬运状态：walk/idle 映射为 walk_carry（手搬姿势）
	var play_name: String = anim_name
	if _carrying and (anim_name == "walk" or anim_name == "idle"):
		play_name = "walk_carry"
	rig.play(play_name)
	_current_anim = anim_name


## 设置搬运状态：搬运工持物时 walk 切换为 walk_carry 动画。
## 由 BehaviorHaul 在 enter/exit 时调用。
func set_carrying(v: bool) -> void:
	_carrying = v
	# 立即同步动画：搬运时切 walk_carry，否则按速度切 walk/idle
	if rig == null:
		return
	if v:
		rig.play("walk_carry")
	else:
		if _current_speed > IDLE_THRESHOLD:
			rig.play("walk")
		else:
			rig.play("idle")


## 锁定动作动画（如 build 敲击），锁定期间 _play_anim 不切换。
## 由 BehaviorWork 在工地播放建造动画时调用。
func set_action_anim(anim_name: String) -> void:
	_action_locked = true
	if rig != null:
		rig.play(anim_name)
	_current_anim = anim_name


## 解除动作锁定，恢复正常动画（根据当前速度切 walk/idle）。
func clear_action() -> void:
	_action_locked = false
	if _current_speed > IDLE_THRESHOLD:
		_play_anim("walk")
	else:
		_play_anim("idle")


# ─────────────────────────────── 头顶动作进度条 ────────────────────────────────

var _action_progress_indicator: Node2D = null

## 确保头顶进度条节点存在。
func _ensure_action_indicator() -> void:
	if _action_progress_indicator != null and is_instance_valid(_action_progress_indicator):
		return
	var cls := load("res://modules/units/scripts/action_progress_indicator.gd")
	_action_progress_indicator = cls.new()
	_action_progress_indicator.position = Vector2(0, -130.0)  # 头顶上方
	add_child(_action_progress_indicator)


## 设置头顶动作进度（0~1，>0 显示，0 隐藏）。由 BehaviorHaul/BehaviorWork/玩家调用。
func set_action_progress(ratio: float) -> void:
	_ensure_action_indicator()
	if _action_progress_indicator != null:
		_action_progress_indicator.set_progress(ratio)


## 隐藏头顶动作进度条。
func hide_action_progress() -> void:
	if _action_progress_indicator != null:
		_action_progress_indicator.hide_bar()


# ─────────────────────────────── 玩家交互提示 ────────────────────────────────

## 交互提示节点（Node2D 容器，挂到地图前景层，跟随目标建筑显示）
var _interact_hint_node: Node2D = null
var _interact_hint_label: Label = null

## 确保交互提示节点存在，挂到地图前景层（z_index=10，在建筑之上）。
func _ensure_interact_hint() -> void:
	if _interact_hint_node != null and is_instance_valid(_interact_hint_node):
		return
	if _map_ref == null:
		return
	_interact_hint_node = Node2D.new()
	_interact_hint_node.name = "InteractHint"
	_interact_hint_node.visible = false
	_interact_hint_node.z_index = 20
	# 挂到 foreground_layer（z_index=10），确保在建筑之上
	var layer: Node2D = _map_ref.get("foreground_layer") if "foreground_layer" in _map_ref else null
	if layer != null:
		layer.add_child(_interact_hint_node)
	else:
		_map_ref.add_child(_interact_hint_node)
	_interact_hint_label = Label.new()
	_interact_hint_label.add_theme_font_size_override("font_size", 14)
	_interact_hint_label.position = Vector2(-100, -20)
	_interact_hint_label.size = Vector2(200, 24)
	_interact_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interact_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 暗色圆角背景
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.8)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	style.border_width_bottom = 1
	style.border_width_top = 1
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_color = Color(1, 1, 1, 0.25)
	_interact_hint_label.add_theme_stylebox_override("normal", style)
	_interact_hint_node.add_child(_interact_hint_label)

## 隐藏交互提示。
func _hide_interact_hint() -> void:
	if _interact_hint_node != null and is_instance_valid(_interact_hint_node):
		_interact_hint_node.visible = false

## 更新交互提示（玩家附身时，靠近仓库/工地在建筑上方显示弹窗）。
func _update_interact_hint() -> void:
	if not possessed or _construction_manager == null or _map_ref == null:
		_hide_interact_hint()
		return
	_ensure_interact_hint()
	if _interact_hint_node == null:
		return
	var info: Dictionary = _find_interact_target()
	if info.is_empty():
		_hide_interact_hint()
		return
	# 弹窗显示在目标建筑上方
	var ground_y: float = _map_ref.get("ground_y") if "ground_y" in _map_ref else 810.0
	_interact_hint_node.global_position = Vector2(float(info.center_x), ground_y - 280.0)
	_interact_hint_label.text = String(info.hint)
	_interact_hint_node.visible = true


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
func _escape_stuck() -> void:
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


## 检测是否在通行障碍区域内（WalkBarrier / PassageBarrier，§7.1.2）
## 使用脚部碰撞箱检测，与物理碰撞箱一致
func _is_in_passage_barrier() -> bool:
	if _map_ref == null or not is_instance_valid(_map_ref):
		return false
	# 用脚部碰撞箱检测
	var feet_rect := _get_feet_rect()
	# 检查地图级 WalkBarrier
	if _map_ref.has_method("get_walk_barriers"):
		for area in _map_ref.get_walk_barriers():
			if _is_rect_in_area(feet_rect, area):
				return true
	# 检查建筑级 PassageBarrier
	if _map_ref.has_method("get_passage_barriers"):
		for area in _map_ref.get_passage_barriers():
			if _is_rect_in_area(feet_rect, area):
				return true
	return false


## 获取脚部碰撞箱的世界坐标矩形
func _get_feet_rect() -> Rect2:
	var col := get_node_or_null("Collider") as CollisionShape2D
	if col != null and col.shape is RectangleShape2D:
		var shape := col.shape as RectangleShape2D
		var center: Vector2 = col.global_position
		var half_size: Vector2 = shape.size * 0.5
		return Rect2(center - half_size, shape.size)
	# 退化：用脚部点位置
	var feet_pos: Vector2 = Vector2(global_position.x, global_position.y + foot_offset)
	return Rect2(feet_pos - Vector2.ONE, Vector2(2, 2))


## 检查矩形是否与 Area2D 的 RectangleShape2D 重叠
func _is_rect_in_area(rect: Rect2, area: Area2D) -> bool:
	for child in area.get_children():
		if child is CollisionShape2D:
			var shape: Shape2D = (child as CollisionShape2D).shape
			if shape is RectangleShape2D:
				var rect_shape: RectangleShape2D = shape as RectangleShape2D
				var area_center: Vector2 = (child as CollisionShape2D).global_position
				var area_half: Vector2 = rect_shape.size * 0.5
				var area_rect := Rect2(area_center - area_half, rect_shape.size)
				return rect.intersects(area_rect)
	return false


## 切换附身状态
func set_possessed(p: bool) -> void:
	possessed = p


func is_possessed() -> bool:
	return possessed


## 获取朝向
func get_facing() -> int:
	return _facing


## 获取当前动画名
func get_current_anim() -> String:
	return _current_anim


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


## 由 GameRoot spawn 时注入 ConstructionManager 引用（供 AIController 查询派工）
func set_construction_manager(manager: Node) -> void:
	_construction_manager = manager
	# 把 NPC 注册为可派工工人
	if manager != null and manager.has_method("register_worker"):
		manager.register_worker(self)


## 获取 ConstructionManager 引用（可能为 null）
func get_construction_manager() -> Node:
	return _construction_manager


# ─────────────────────────────── 战斗 API（§8）────────────────────────────────

## 死亡处理：停止移动、播放死亡动画、禁用受击、通知战斗实例
func _on_died() -> void:
	ai_stop()
	velocity = Vector2.ZERO
	_play_anim("dead")
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
