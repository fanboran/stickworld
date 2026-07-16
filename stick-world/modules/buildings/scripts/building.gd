class_name Building
extends Node2D
## 建筑运行时实体 —— §4.3 建筑节点结构。
##
## 一栋建筑 = 外观 + 占地 + 工作位 + 通行障碍 + HP。
## 由 ConstructionProject 完工时实例化到地图的 BuildingHost 容器。
## 详见 docs/技术/架构/场景与战斗架构.md §4.3 / §4.5。
##
## 节点结构（应包含的子节点，缺失只警告不崩溃）：
##   Building (Node2D, 本脚本)
##   ├── Exterior (Sprite2D)           ← 外观贴图（可选；兼容直接叫 Sprite2D 的旧场景）
##   ├── PassageBarrier (Area2D)        ← 通行障碍（§7.1.3，可选）
##   │   └── CollisionShape2D[]
##   └── WorkSlots (Node2D)             ← 工作位容器
##       └── Marker2D[]                 ← 工作位（工人 AI 寻路目标）

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
## 当前血量
var health: float = 100.0
## 最大血量
var max_health: float = 100.0

# ─────────────────────────────── 子节点引用 ────────────────────────────────
## 外观节点（Sprite2D / Polygon2D / ColorRect 等 CanvasItem 子类，需有 modulate 属性）
var _exterior: CanvasItem = null
var _passage_barrier: Area2D = null
var _work_slots_node: Node2D = null
var _work_slot_markers: Array = []  # Marker2D[] 缓存

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
	_passage_barrier = get_node_or_null("PassageBarrier") as Area2D
	_work_slots_node = get_node_or_null("WorkSlots") as Node2D
	_work_slot_markers = _collect_work_slot_markers()
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
func demolish() -> void:
	if state == State.DESTROYED:
		return
	set_state(State.DESTROYED)
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


## 获取 PassageBarrier Area2D（供 VillageMap.get_passage_barriers 收集）
func get_passage_barrier() -> Area2D:
	return _passage_barrier
