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
var _body_rect: ColorRect = null
var _body_sprite: Sprite2D = null
var _initial_amount: int = 0


func _ready() -> void:
	add_to_group("resource_node")
	_initial_amount = maxi(amount, 1)
	_apply_visual()
	# 2026-08 修复依赖反转：经 EventBus 订阅调试可见性（生产代码不再依赖 debug_gui autoload）
	if EventBus != null and EventBus.has_signal("debug_visibility_changed"):
		EventBus.debug_visibility_changed.connect(_update_debug_visibility)


func _update_debug_visibility(_v: bool = false) -> void:
	if _debug_label != null:
		_debug_label.visible = _v


## 手绘笔触贴图（程序参考图 + mona-3 逆向油画算法拟合，见 tools/ai/stroke_paint.py）
const _TEXTURE_PATHS: Dictionary = {
	ResourceType.WOOD: "res://assets/resources/tree_paint.png",
	ResourceType.STONE: "res://assets/resources/stone_paint.png",
}
## 贴图显示尺寸（px，宽高）
const _TEXTURE_SIZES: Dictionary = {
	ResourceType.WOOD: Vector2(108.0, 108.0),
	ResourceType.STONE: Vector2(76.0, 76.0),
}


func _apply_visual() -> void:
	var tex_path: String = String(_TEXTURE_PATHS.get(resource_type, ""))
	if not tex_path.is_empty() and ResourceLoader.exists(tex_path):
		# 笔触贴图分支：底边对齐节点底（地面接触线）
		var spr := Sprite2D.new()
		spr.texture = load(tex_path)
		var size: Vector2 = _TEXTURE_SIZES.get(resource_type, Vector2(64.0, 64.0))
		spr.scale = size / Vector2(spr.texture.get_width(), spr.texture.get_height())
		spr.position = Vector2(0.0, node_size * 0.5 - size.y * 0.5)
		add_child(spr)
		_body_sprite = spr
	else:
		# 简单色块表示资源点（铁矿暂无贴图，P0 占位）
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
		_body_rect = rect
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
	_play_harvest_feedback(actual)
	if amount <= 0:
		_is_depleted = true
		queue_free()
	return actual


## 采集即时反馈：挤压弹跳 + 飘字 + 剩余量渐隐（GDD 核心循环"采集成功的微奖励"）
func _play_harvest_feedback(gained: int) -> void:
	if gained > 0:
		_spawn_gain_label(gained)
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector2(1.18, 0.82), 0.08)
		tween.tween_property(self, "scale", Vector2.ONE, 0.14)
	if _body_rect != null:
		_body_rect.modulate.a = clampf(float(amount) / float(_initial_amount), 0.35, 1.0)
	elif _body_sprite != null:
		_body_sprite.modulate.a = clampf(float(amount) / float(_initial_amount), 0.35, 1.0)


## 资源点上方飘出 "+N 资材" 的增益数字（0.8s 上浮淡出后自毁）
func _spawn_gain_label(gained: int) -> void:
	var label := Label.new()
	label.text = "+%d %s" % [gained, _get_type_name()]
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.65))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.position = Vector2(-36, -44)
	label.size = Vector2(72, 20)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(label)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", -96.0, 0.8).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.6).set_delay(0.25)
	tween.chain().tween_callback(label.queue_free)


func is_depleted() -> bool:
	return _is_depleted


## 调试用：获取资源类型中文名
func _get_type_name() -> String:
	match resource_type:
		ResourceType.WOOD: return "木"
		ResourceType.STONE: return "石"
		ResourceType.METAL: return "铁"
	return "?"


## 交互提示用：资源类型完整中文名
func get_display_name() -> String:
	match resource_type:
		ResourceType.WOOD: return "木材"
		ResourceType.STONE: return "石料"
		ResourceType.METAL: return "铁矿"
	return "资源"


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
