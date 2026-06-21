extends Control
class_name RegionInfoPanel
## 地块信息面板 —— 点击地块后显示详细信息

## API引用
@export var api_node: Node

## 标题Label
@export var title_label: Label
## 类型Label
@export var type_label: Label
## 资源Label
@export var resource_label: Label
## 火柴人Label
@export var stickman_label: Label
## 归属Label
@export var owner_label: Label

## 面板容器（整个面板的根Control，用于显示/隐藏）
@export var panel_container: Control

func _ready():
	if api_node:
		# 监听地块点击信号
		if api_node.has_signal("region_clicked"):
			api_node.region_clicked.connect(_on_region_clicked)
		# 监听地块悬停信号（可选）
		# api_node.region_hovered.connect(_on_region_hovered)
	_hide_panel()

func _on_region_clicked(region_id: int):
	if api_node == null:
		return
	var region: RegionDefinition = api_node.get_region(region_id)
	if region == null:
		_hide_panel()
		return

	_update_info(region_id, region)
	_show_panel()

func _update_info(region_id: int, region: RegionDefinition):
	if title_label:
		title_label.text = region.name + " (ID:%d)" % region_id

	if type_label:
		type_label.text = "类型: %s" % _get_type_name(region.type)

	if resource_label:
		var res_text: String = ""
		if region.resource_types.is_empty():
			res_text = "无"
		else:
			res_text = ", ".join(region.resource_types)
		resource_label.text = "资源: %s" % res_text

	if stickman_label:
		var sm_text: String = ""
		if region.stickman_types.is_empty():
			sm_text = "未知"
		else:
			sm_text = ", ".join(region.stickman_types)
		stickman_label.text = "火柴人: %s" % sm_text

	if owner_label:
		var owner_id: int = api_node.get_region_owner(region_id)
		if owner_id == -1:
			owner_label.text = "归属: 无主"
		else:
			owner_label.text = "归属: 势力%d" % owner_id

func _show_panel():
	if panel_container:
		panel_container.visible = true

func _hide_panel():
	if panel_container:
		panel_container.visible = false

func _get_type_name(type: int) -> String:
	match type:
		0: return "陆地"
		1: return "海洋"
		2: return "湖泊"
		3: return "荒原"
	return "未知"
