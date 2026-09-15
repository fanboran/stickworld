class_name ResourceNode
extends Node2D
## 城内资源点 -- 纯逻辑节点（阶段 F §5.7.4.5）
##
## 储量有限；采空后进入枯竭态（隐藏+不可采），按重生节拍自动恢复（NPC 采集
## 经济配套，小镇生活批次 2；重生节拍为 AI 提案数值，待实测定稿——原"砍完
## 彻底不再生"语义不满足长期经济循环）。
## 已知限制：枯竭态节点不写入存档（save_resource_nodes_to_db 过滤
## is_depleted），跨存档读回后该点消失、不处于重生倒计时。建造时自动清场。
##
## **2D 笔触视觉根除（创始人 2026-09-14）**：程序化树/岩块/贴图池全部删除——
## 树冠闪绿光属于 2D 笔触
## 树，随之移除；HD-2D 图观感由自然物 PBR 卡承担（点位/类型由资源分布算法
## 给出，卡随点落）。采集反馈保留飘字与音效；飘字在 HD-2D 图经
## fx_pos_remapper 组重映射到 3D 投影地面线。

## 资源类型枚举
enum ResourceType {
	WOOD,    ## 树木 -> res_wood
	STONE,   ## 石头 -> res_stone
	METAL,   ## 铁矿 -> res_metal_ore
	DIAMOND, ## 钻石 -> res_diamond
	GOLD,    ## 黄金 -> res_gold
}

## 资源类型（对应 ResourceType 枚举）
@export var resource_type: int = ResourceType.WOOD
## 储量（剩余可采集量）
@export var amount: int = 100
## 占地大小（像素）
@export var node_size: float = 32.0

var _is_depleted: bool = false
var _debug_label: Label = null
var _initial_amount: int = 0
var _crit_gain: bool = false


func _ready() -> void:
	add_to_group("resource_node")
	_initial_amount = maxi(amount, 1)
	# 调试标签：显示资源类型名（F3 开关控制，生产不可见）
	_debug_label = Label.new()
	_debug_label.text = _get_type_name()
	_debug_label.add_theme_font_size_override("font_size", 10)
	_debug_label.position = Vector2(-node_size * 0.5, node_size * 0.5)
	add_child(_debug_label)
	_update_debug_visibility()
	# 2026-08 修复依赖反转：经 EventBus 订阅调试可见性（生产代码不再依赖 debug_gui autoload）
	if EventBus != null and EventBus.has_signal("debug_visibility_changed"):
		EventBus.debug_visibility_changed.connect(_update_debug_visibility)


func _update_debug_visibility(_v: bool = false) -> void:
	if _debug_label != null:
		_debug_label.visible = _v


## 采集指定数量，返回实际采集量
func harvest(qty: int) -> int:
	if _is_depleted:
		return 0
	var actual: int = mini(qty, amount)
	if randf() < 0.12:
		actual = mini(qty * 2, amount)
		_crit_gain = true
	amount -= actual
	_play_harvest_feedback(actual)
	if amount <= 0:
		_is_depleted = true
		_enter_depleted()
	return actual


## 枯竭态表现与重生（小镇生活批次 2，重生节拍 [提案/待定] 90s 游戏秒）：
## 采空不再自毁，改为隐藏 + 单次 Timer 到点重生长满。
## 存档过滤不写枯竭节点（见类头已知限制）；建造清场 queue_free 不受影响。
const REGEN_TIME: float = 90.0

## 重生倒计时 Timer（枯竭时创建）
var _regen_timer: Timer = null


func _enter_depleted() -> void:
	visible = false
	if _regen_timer != null:
		return  # 已在重生倒计时（防御：同一枯竭周期不重复挂表）
	_regen_timer = Timer.new()
	_regen_timer.one_shot = true
	_regen_timer.wait_time = REGEN_TIME
	_regen_timer.timeout.connect(_regrow)
	add_child(_regen_timer)
	_regen_timer.start()


## 重生长满：储量回满、解除枯竭、恢复可见（点位/类型不变 = "原地长回来"）
func _regrow() -> void:
	amount = maxi(_initial_amount, 1)
	_crit_gain = false
	_is_depleted = false
	visible = true
	if _regen_timer != null and is_instance_valid(_regen_timer):
		_regen_timer.queue_free()
	_regen_timer = null


## 采集即时反馈：飘字 + 敲击音（GDD 核心循环"采集成功的微奖励"）
func _play_harvest_feedback(gained: int) -> void:
	if gained > 0:
		_spawn_gain_label(gained, _crit_gain)
		_crit_gain = false
		if AudioManager != null:
			# 敲击音分材质（材质敲击 = "世界里的声音"，NPC 劳作同样该有）
			# **入账音（harvest_gain）不在这里**：那是"给玩家的反馈"，
			# 留在模型层会让 NPC 伐木采矿也一直叮咚（见 音效触发规范.md §四）
			if resource_type == ResourceType.WOOD:
				AudioManager.play_event("harvest_wood", global_position)
			else:
				AudioManager.play_event("harvest_hit", global_position)


## 资源点上方飘出 "+N 资材" 的增益数字（0.8s 上浮淡出后自毁）。
## HD-2D 图（fx_pos_remapper 组在树）把出生点压到 3D 投影地面线、挂到地图
## 宿主下绘制；纯 2D 图维持原语义（挂节点自身、节点局部坐标）。
func _spawn_gain_label(gained: int, crit: bool = false) -> void:
	var label := Label.new()
	label.text = ("暴击 +%d %s!" % [gained, _get_type_name()]) if crit else ("+%d %s" % [gained, _get_type_name()])
	label.add_theme_font_size_override("font_size", 20 if crit else 16)
	label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.25) if crit else Color(1.0, 0.93, 0.65))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.size = Vector2(72, 20)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var remapper: Node = get_tree().get_first_node_in_group("fx_pos_remapper") \
			if get_tree() != null else null
	if remapper != null and remapper.has_method("remap_fx_pos"):
		label.position = (remapper.remap_fx_pos(global_position) as Vector2) + Vector2(-36.0, -56.0)
		var host: Node = get_parent() if get_parent() != null else self
		host.add_child(label)
	else:
		label.position = Vector2(-36, -44)
		add_child(label)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 52.0, 0.8).set_ease(Tween.EASE_OUT)
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
		ResourceType.DIAMOND: return "钻"
		ResourceType.GOLD: return "金"
	return "?"


## 交互提示用：资源类型完整中文名
func get_display_name() -> String:
	match resource_type:
		ResourceType.WOOD: return "木材"
		ResourceType.STONE: return "石料"
		ResourceType.METAL: return "铁矿"
		ResourceType.DIAMOND: return "钻石"
		ResourceType.GOLD: return "黄金"
	return "资源"


## 获取对应的资源 ID
func get_resource_id() -> String:
	match resource_type:
		ResourceType.WOOD: return "res_wood"
		ResourceType.STONE: return "res_stone"
		ResourceType.METAL: return "res_metal_ore"
		ResourceType.DIAMOND: return "res_diamond"
		ResourceType.GOLD: return "res_gold"
	return ""
