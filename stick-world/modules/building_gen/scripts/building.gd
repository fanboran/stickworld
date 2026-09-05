class_name Building
extends Node2D
## 建筑运行时实体 —— §4.3 建筑节点结构。
##
## 一栋建筑 = 外观 + 占地 + 工作位 + 通行障碍 + HP + 室内交互（§5）。
## 由 ConstructionProject 完工时实例化到地图的 BuildingHost 容器。
## 详见 docs/技术/架构/场景与战斗架构.md §4.3 / §4.5 / §5。
##
## 节点结构（应包含的子节点，缺失只警告不崩溃）：
##   Building (Node2D, 本脚本)
##   ├── Exterior (Node2D)             ← 外观容器（含 Roof + WallFront；兼容旧 Sprite2D）
##   │   ├── Roof (Sprite2D)            ← 🆕 屋顶（始终可见）
##   │   └── WallFront (CanvasItem)     ← 🆕 前墙（透明化时 alpha 渐变，Polygon2D 也可）
##   ├── Interior (Node2D)              ← 🆕 内部空间（默认 visible=false）
##   │   ├── Floor (Sprite2D)           ← 🆕 室内地面
##   │   ├── Props (Node2D)             ← 🆕 装饰
##   │   └── WorkSlots (Node2D)         ← 📌 工作位（兼容旧路径 Building/WorkSlots）
##   │       └── Marker2D[]
##   ├── InteractionZone (Area2D)       ← 🆕 透明化触发区
##   │   └── CollisionShape2D
##   ├── EnterTrigger (Area2D)          ← 🆕 传送触发区
##   │   └── CollisionShape2D
##   ├── PassageBarrier (Area2D)        ← 通行障碍（可选）
##   │   └── CollisionShape2D[]
##   └── HealthComponent (Node)         ←（后续阶段）
##
## 迁移记录：原位于 modules/old_buildings/scripts/building.gd，
## 2026-07 迁至 modules/building_gen/scripts/building.gd。

# ─────────────────────────────── 状态 ────────────────────────────────

## 建筑状态机
enum State {
	PLANNED,              ## 项目刚创建，未开工
	UNDER_CONSTRUCTION,   ## 建造中
	OPERATIONAL,          ## 完工，正常使用
	DAMAGED,              ## 受损
	DESTROYED,            ## 被拆除/销毁
}

# ─────────────────────────────── @export 元数据 ────────────────────────────────

## 建筑定义 ID（对应 config/buildings/ 下的 .tres）
@export var def_id: String = ""
## 条带坐标 X（地图网格坐标，由 PlacementSystem 注入）
@export var cell_x: int = 0
## 占地宽度（条带数，单位=PlacementGrid.CELL_SIZE）
@export var width: int = 1
## 是否地形建筑（不可拆除，§4.5.3）
@export var is_terrain: bool = false

# ─────────────────────────────── 运行时 ────────────────────────────────

## 当前状态
var state: State = State.PLANNED

## 升级等级（运行时累计，0=初始；upgrade_building 时 +1，外观差异化待 building_gen 阶段 B）
var upgrade_level: int = 0
## 当前血量
var health: float = 100.0
## 最大血量
var max_health: float = 100.0

# ─────────────────────────────── 子节点引用 ────────────────────────────────
## 子节点引用
## 外观节点（Sprite2D / Polygon2D / ColorRect 等 CanvasItem 子类，需有 modulate 属性）
var _exterior: CanvasItem = null
var _passage_barrier: StaticBody2D = null
var _work_slots_node: Node2D = null
var _work_slot_markers: Array = []  # Marker2D[] 缓存

# ─────────────────────────────── 室内相关（§5）───────────────────────────────
## 室内容器（默认不可见）
var _interior: Node2D = null
## 前墙 CanvasItem（透明化时 alpha 渐变，兼容 Sprite2D / Polygon2D）
var _wall_front: CanvasItem = null
## 透明化触发区
var _interaction_zone: Area2D = null
## 传送触发区
var _enter_trigger: Area2D = null
## 当前是否处于透明化状态
var _interior_is_transparent: bool = false
## 前墙半透明 alpha（默认 0.3，后续从数据表读取）
var _transparent_alpha: float = 0.3
## 透明化渐变时长（秒，默认 0.2）
var _fade_duration: float = 0.2
## 进行中的透明化 Tween（快速进出触发区时先 kill 旧渐变，避免双 Tween 争写 alpha 回闪）
var _fade_tween: Tween = null
## 室内模式枚举（默认 NONE，后续从数据表读取）
var _interior_mode: int = 0  # 0=NONE, 1=TRANSPARENT, 2=TELEPORT
## 大建筑内部地图 ID（仅 TELEPORT 模式，P0 硬编码）
var mega_interior_map_id: String = ""

# ─────────────────────────────── 城墙相关（阶段 F §5.7.4）──────────────────────────────────
## 城墙等级（0=非城墙, 1/2/3=城墙 tier）
var wall_tier: int = 0
## 城墙顶部可站人
var can_stand_on: bool = false
## 城门（允许己方通行，可关闭拒敌）
var is_gate: bool = false
## 城墙顶部站立平台（tier>=2 时存在）
var _stand_platform: Area2D = null

# ─────────────────────────────── 信号 ────────────────────────────────

## 建筑被拆除。参数为自身引用，供外部释放 PlacementGrid 占用。
signal demolished(building: Building)
## 建筑状态变化
signal state_changed(old_state: State, new_state: State)
## 建筑完工
signal completed(building: Building)


func _ready() -> void:
	_lookup_children()
	_apply_state_visual()


# ─────────────────────────────── 数据驱动（D2）────────────────────────────────

## 从建筑定义 Dictionary 应用数据驱动字段
func apply_building_def(def: Dictionary) -> void:
	# buildings.tres 由 Excel 管线生成：空单元格导出为 null（key 在、值为 null），
	# 而 Variant 构造 String/int/bool/float 均不接受 null（Nonexistent constructor），
	# 一律走 null 安全取值（null = 未填 = 回退值）
	_interior_mode = _def_int(def, "interior_mode", 0)
	mega_interior_map_id = _def_string(def, "mega_interior_map_id", "")
	# 阶段 F：城墙字段
	wall_tier = _def_int(def, "wall_tier", 0)
	can_stand_on = _def_bool(def, "can_stand_on", false)
	is_gate = _def_bool(def, "is_gate", false)
	max_health = _def_float(def, "max_hp", 100.0)
	health = max_health


# ── null 安全取值（Excel 管线空单元格 = null；Variant 构造不接受 null）──

static func _def_string(def: Dictionary, key: String, fallback: String) -> String:
	var v: Variant = def.get(key, fallback)
	return String(v) if v != null else fallback


static func _def_int(def: Dictionary, key: String, fallback: int) -> int:
	var v: Variant = def.get(key, fallback)
	return int(v) if v != null else fallback


static func _def_bool(def: Dictionary, key: String, fallback: bool) -> bool:
	var v: Variant = def.get(key, fallback)
	return bool(v) if v != null else fallback


static func _def_float(def: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = def.get(key, fallback)
	return float(v) if v != null else fallback
## 配置字段安全读取：Excel 空单元格经管线导出为 null，null 强转构造会抛运行时错，
## 统一回落到默认值（泛型版，供审计侧通用路径调用）
static func _field(def: Dictionary, key: String, default: Variant) -> Variant:
	var v: Variant = def.get(key)
	return default if v == null else v




# ─────────────────────────────── 子节点查找 ────────────────────────────────

func _lookup_children() -> void:
	# 优先用 Exterior，缺失则兼容旧场景的 Sprite2D；接受任何 CanvasItem 子类（Sprite2D / Polygon2D / ColorRect 等）
	var ext := get_node_or_null("Exterior")
	if ext is CanvasItem:
		_exterior = ext as CanvasItem
	else:
		var sprite := get_node_or_null("Sprite2D")
		if sprite is CanvasItem:
			_exterior = sprite as CanvasItem
	_passage_barrier = get_node_or_null("PassageBarrier") as StaticBody2D

	# WorkSlots 兼容两种路径（§5.3 向后兼容）
	_work_slots_node = get_node_or_null("WorkSlots") as Node2D
	if _work_slots_node == null:
		var interior_node := get_node_or_null("Interior") as Node2D
		if interior_node != null:
			_work_slots_node = interior_node.get_node_or_null("WorkSlots") as Node2D
	_work_slot_markers = _collect_work_slot_markers()

	# ── 室内节点查找（§5.3）──
	# Interior 容器
	_interior = get_node_or_null("Interior") as Node2D
	if _interior != null:
		_interior.visible = false  # 默认不可见

	# WallFront：从 Exterior 容器或直接从 Building 子节点查找
	if ext is Node2D:
		_wall_front = ext.get_node_or_null("WallFront") as CanvasItem
	if _wall_front == null:
		_wall_front = get_node_or_null("WallFront") as CanvasItem

	# InteractionZone
	_interaction_zone = get_node_or_null("InteractionZone") as Area2D
	if _interaction_zone != null:
		if not _interaction_zone.body_entered.is_connected(_on_interaction_zone_body_entered):
			_interaction_zone.body_entered.connect(_on_interaction_zone_body_entered)
		if not _interaction_zone.body_exited.is_connected(_on_interaction_zone_body_exited):
			_interaction_zone.body_exited.connect(_on_interaction_zone_body_exited)

	# EnterTrigger
	_enter_trigger = get_node_or_null("EnterTrigger") as Area2D
	if _enter_trigger != null:
		if not _enter_trigger.body_entered.is_connected(_on_enter_trigger_body_entered):
			_enter_trigger.body_entered.connect(_on_enter_trigger_body_entered)

	# 阶段 F：城墙站立平台（tier>=2 城墙顶部）
	_stand_platform = get_node_or_null("StandPlatform") as Area2D

	if _exterior == null:
		push_warning("[Building] 缺少 Exterior/Sprite2D 子节点: %s" % name)
	if _work_slot_markers.is_empty():
		# 没有工作位不算错（地形建筑、装饰物通常没有）
		pass


func _collect_work_slot_markers() -> Array:
	var result: Array = []
	if _work_slots_node == null:
		return result
	for child in _work_slots_node.get_children():
		if child is Marker2D:
			result.append(child as Marker2D)
	return result


# ─────────────────────────────── 位置辅助 ────────────────────────────────

## 获取碰撞体下边界相对于建筑原点的 Y 偏移
## = CollisionShape2D.position.y + shape.size.y / 2
## 用于运行时建造时对齐草坪中线（与 building_snap.gd 编辑器吸附逻辑一致）
func get_collision_bottom_local() -> float:
	var pb := get_node_or_null("PassageBarrier")
	if pb == null:
		return 0.0
	for child in pb.get_children():
		if child is CollisionShape2D and (child as CollisionShape2D).shape is RectangleShape2D:
			return (child as CollisionShape2D).position.y + ((child as CollisionShape2D).shape as RectangleShape2D).size.y * 0.5
	return 0.0


# ─────────────────────────────── 工作位 ────────────────────────────────

## 获取所有工作位的世界坐标（供工人 AI 寻路）
func get_work_slot_positions() -> Array:
	var positions: Array = []
	for marker in _work_slot_markers:
		positions.append((marker as Marker2D).global_position)
	return positions


## 工作位数量
func get_work_slot_count() -> int:
	return _work_slot_markers.size()


## 获取指定索引的工作位 Marker（供外部读取引用）
func get_work_slot(index: int) -> Marker2D:
	if index < 0 or index >= _work_slot_markers.size():
		return null
	return _work_slot_markers[index] as Marker2D


# ─────────────────────────────── 状态管理 ────────────────────────────────

## 设置建筑状态
func set_state(new_state: State) -> void:
	if new_state == state:
		return
	var old := state
	state = new_state
	_apply_state_visual()
	state_changed.emit(old, new_state)
	if new_state == State.OPERATIONAL:
		completed.emit(self)


func _apply_state_visual() -> void:
	if _exterior == null:
		return
	match state:
		State.PLANNED:
			_exterior.modulate = Color(1.0, 1.0, 1.0, 0.3)
		State.UNDER_CONSTRUCTION:
			_exterior.modulate = Color(1.0, 1.0, 1.0, 0.6)
		State.OPERATIONAL:
			_exterior.modulate = Color.WHITE
		State.DAMAGED:
			_exterior.modulate = Color(1.0, 0.5, 0.5, 1.0)
		State.DESTROYED:
			visible = false


# ─────────────────────────────── 拆除/伤害 ────────────────────────────────

## 拆除：发射 demolished 信号，由外部 PlacementGrid 释放占用。
## 阶段 F：城墙被破坏时 PassageBarrier 消失（可通过）。
func demolish() -> void:
	if state == State.DESTROYED:
		return
	set_state(State.DESTROYED)
	# 城墙/城门被破坏时禁用 PassageBarrier 碰撞，单位可通过
	if _passage_barrier != null and wall_tier > 0:
		_passage_barrier.visible = false
		for child in _passage_barrier.get_children():
			if child is CollisionShape2D:
				(child as CollisionShape2D).set_deferred("disabled", true)
	demolished.emit(self)


## 受到伤害。P0 简化：扣血，归零拆除，半血以下进 DAMAGED。
func take_damage(amount: float) -> void:
	health = maxf(0.0, health - amount)
	if health <= 0.0:
		demolish()
	elif state == State.OPERATIONAL and health < max_health * 0.5:
		set_state(State.DAMAGED)


# ─────────────────────────────── 查询 ────────────────────────────────

## 是否已完工
func is_operational() -> bool:
	return state == State.OPERATIONAL


## 是否正在建造中
func is_under_construction() -> bool:
	return state == State.UNDER_CONSTRUCTION


## 阶段 F：是否城墙类建筑（wall_tier > 0）
func is_wall() -> bool:
	return wall_tier > 0


## 获取 PassageBarrier StaticBody2D（供 VillageMap.get_passage_barriers 收集）
func get_passage_barrier() -> StaticBody2D:
	return _passage_barrier


# ─────────────────────────────── 室内系统（§5）───────────────────────────────

## 所属地图引用（由 ConstructionManager 挂载建筑时注入，用于判定玩家实体）
var _map_ref: Node = null


## 注入所属地图（2026-08 审计收敛：替代向上遍历找 GameRoot）
func set_map_reference(map: Node) -> void:
	_map_ref = map


## 判定 body 是否为当前玩家实体（供 InteractionZone 触发过滤：NPC 不触发透明化）
func _is_player_entity(body: Node2D) -> bool:
	# 通过地图的 get_possessed_entity 获取当前附身实体（VillageMap/RoadMap 均实现）
	if _map_ref == null or not is_instance_valid(_map_ref):
		push_warning("[Building] 地图引用未注入，无法判定玩家实体: %s" % name)
		return false
	if not _map_ref.has_method("get_possessed_entity"):
		return false
	var possessed: Node2D = _map_ref.get_possessed_entity()
	if possessed == null or not is_instance_valid(possessed):
		return false
	return possessed == body


## 设置透明化状态（Tween 渐变 WallFront.alpha + Interior.visible）
func _set_transparent(on: bool) -> void:
	if on == _interior_is_transparent:
		return
	_interior_is_transparent = on
	if _wall_front != null:
		var target_alpha: float = _transparent_alpha if on else 1.0
		if _fade_tween != null and _fade_tween.is_valid():
			_fade_tween.kill()
		_fade_tween = create_tween()
		_fade_tween.tween_property(_wall_front, "modulate:a", target_alpha, _fade_duration)
	if _interior != null:
		_interior.visible = on


## InteractionZone body_entered 回调
func _on_interaction_zone_body_entered(body: Node2D) -> void:
	if not _is_player_entity(body):
		return  # 非玩家实体不触发
	if state != State.OPERATIONAL:
		return  # 建造中/被破坏不触发
	_set_transparent(true)
	# 发射 EventBus 信号（InputDispatcher 订阅后切入 INDOOR 模式，2026-08 审计收敛）
	if EventBus != null:
		EventBus.interior_entered.emit(get_instance_id())


## InteractionZone body_exited 回调
func _on_interaction_zone_body_exited(body: Node2D) -> void:
	if not _is_player_entity(body):
		return
	_set_transparent(false)
	# 发射 EventBus 信号（GameRoot 收到后做全局 _maybe_exit_indoor_mode 检查）
	if EventBus != null:
		EventBus.interior_exited.emit(get_instance_id())


## EnterTrigger body_entered 回调（传送切换，§5.6）
func _on_enter_trigger_body_entered(body: Node2D) -> void:
	if not _is_player_entity(body):
		return
	if _interior_mode != 2:  # 2 = TELEPORT
		return
	if mega_interior_map_id.is_empty():
		push_warning("[Building] TELEPORT 模式但 mega_interior_map_id 为空: %s" % name)
		return
	# 发射 EventBus 信号，交由 GameRoot 统一处理（校验 + 过场 + 旅行）
	if EventBus != null:
		EventBus.mega_interior_entered.emit(get_instance_id(), mega_interior_map_id)


## 玩家是否还在本建筑的 InteractionZone 内（供 GameRoot 全局检查）
func is_player_inside_interaction_zone() -> bool:
	if _interaction_zone == null:
		return false
	if _map_ref == null or not is_instance_valid(_map_ref) or not _map_ref.has_method("get_possessed_entity"):
		return false
	var player: Node2D = _map_ref.get_possessed_entity()
	if player == null or not is_instance_valid(player):
		return false
	var bodies: Array = _interaction_zone.get_overlapping_bodies()
	return bodies.has(player)
