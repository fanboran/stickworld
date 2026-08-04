class_name ResourceNode
extends Node2D
## 城内有限资源点 -- 阶段 F §5.7.4.5
##
## 城内树木/石头/铁矿，储量有限，砍完彻底不再生。
## 建造时自动清场（砍树给木材）。

## 资源类型枚举
enum ResourceType {
	WOOD,    ## 树木 -> res_wood
	STONE,   ## 石头 -> res_stone
	METAL,   ## 铁矿 -> res_metal_ore
}

## 资源类型（对应 ResourceType 枚举）
@export var resource_type: int = ResourceType.WOOD
## 储量（剩余可采集量）
@export var amount: int = 100
## 占地大小（像素）
@export var node_size: float = 32.0

var _is_depleted: bool = false
var _debug_label: Label = null


func _ready() -> void:
	add_to_group("resource_node")
	_apply_visual()
	# 2026-08 修复依赖反转：经 EventBus 订阅调试可见性（生产代码不再依赖 debug_GUI autoload）
	if EventBus != null and EventBus.has_signal("debug_visibility_changed"):
		EventBus.debug_visibility_changed.connect(_update_debug_visibility)


func _update_debug_visibility(_v: bool = false) -> void:
	if _debug_label != null:
		_debug_label.visible = _v


func _apply_visual() -> void:
	# 简单色块表示资源点（P0 占位，正式版用贴图）
	var colors: Array[Color] = [
		Color(0.2, 0.5, 0.2),  # WOOD=绿
		Color(0.5, 0.5, 0.5),  # STONE=灰
		Color(0.6, 0.3, 0.2),  # METAL=棕
	]
	var color: Color = colors[resource_type] if resource_type < colors.size() else Color.WHITE
	var rect := ColorRect.new()
	rect.color = color
	rect.size = Vector2(node_size, node_size)
	rect.position = Vector2(-node_size * 0.5, -node_size * 0.5)
	add_child(rect)
	# 调试标签：显示资源类型名（F3 开关控制）
	_debug_label = Label.new()
	_debug_label.text = _get_type_name()
	_debug_label.add_theme_font_size_override("font_size", 10)
	_debug_label.position = Vector2(-node_size * 0.5, node_size * 0.5)
	add_child(_debug_label)
	_update_debug_visibility()


## 采集指定数量，返回实际采集量
func harvest(qty: int) -> int:
	if _is_depleted:
		return 0
	var actual: int = mini(qty, amount)
	amount -= actual
	if amount <= 0:
		_is_depleted = true
		queue_free()
	return actual


func is_depleted() -> bool:
	return _is_depleted


## 调试用：获取资源类型中文名
func _get_type_name() -> String:
	match resource_type:
		ResourceType.WOOD: return "木"
		ResourceType.STONE: return "石"
		ResourceType.METAL: return "铁"
	return "?"


## 获取对应的资源 ID
func get_resource_id() -> String:
	match resource_type:
		ResourceType.WOOD: return "res_wood"
		ResourceType.STONE: return "res_stone"
		ResourceType.METAL: return "res_metal_ore"
	return ""


## 获取资源点的 cell_x
func get_cell_x(grid: Node) -> int:
	if grid == null or not grid.has_method("world_to_cell"):
		return -1
	return grid.world_to_cell(global_position)
