extends Node2D
class_name SettlementRenderer
## L1 动态聚落建筑群渲染器
##
## 详见 docs/技术/架构/战略图架构.md §4.6 动态聚落建筑群表示
##
## 核心特性：
##   - 聚落不是静态图标，是运行时根据 level + population_score 生成的建筑群
##   - 玩家建设改变 population_score → 地图上聚落大小实时变化
##   - 确定性：同一聚落每次渲染都一样（用 settlement_id 作种子）
##   - 产业差异化：采矿聚落有矿坑图标，贸易聚落有市场图标

## 建筑素材库（按级别和产业分类的 Sprite2D 场景）
## 结构：{level: {industry: Array[PackedScene]}}
@export var building_sprites: Dictionary = {}

## 城墙素材（T3+ 聚落用）
@export var wall_scene: PackedScene = null

## 地标建筑素材（T4+ 或特殊产业用）
@export var landmark_scenes: Dictionary = {}

## 当前已渲染的聚落节点缓存
## {settlement_id: Node2D}
var _rendered_settlements: Dictionary = {}


## 渲染单个聚落（返回建筑群 Node2D）
func render_settlement(settlement: SettlementRef) -> Node2D:
	# TODO: P1 实现（SM-3 阶段先用静态图标占位）
	#
	# 完整实现逻辑：
	# 1. var group = Node2D.new()
	# 2. var base_count = settlement.get_building_count()
	# 3. var base_radius = settlement.get_footprint_radius()
	# 4. 按 industry 选择建筑 sprite 子集
	# 5. 在 base_radius 范围内用 settlement.layout_seed 作种子的 RNG 放置建筑
	# 6. T3+ 加城墙环
	# 7. T4+ 或军事产业加地标建筑
	# 8. 缓存到 _rendered_settlements[settlement.settlement_id]
	# 9. return group
	var group = Node2D.new()
	group.name = "Settlement_%s" % settlement.settlement_id
	return group


## 刷新单个聚落（规模变化时重新生成）
func refresh(settlement_id: String) -> void:
	# TODO: P1 实现
	# 1. 移除旧的 _rendered_settlements[settlement_id]
	# 2. 从 data 查找最新的 SettlementRef
	# 3. render_settlement() 重新生成
	# 4. 加入场景树
	pass


## 清除所有已渲染的聚落（粒度切换时调用）
func clear_all() -> void:
	for id in _rendered_settlements:
		var node: Node = _rendered_settlements[id]
		if node != null and is_instance_valid(node):
			node.queue_free()
	_rendered_settlements.clear()


## 获取聚落建筑群节点（已渲染的）
func get_rendered_node(settlement_id: String) -> Node2D:
	return _rendered_settlements.get(settlement_id, null)


## 渲染地块内所有聚落（L1 粒度进入时调用）
func render_all_in_tile(tile: MapTileData) -> void:
	clear_all()
	for settlement in tile.settlements:
		if settlement == null:
			continue
		var node: Node2D = render_settlement(settlement)
		if node != null:
			add_child(node)
			_rendered_settlements[settlement.settlement_id] = node
