extends Control
class_name GranularityIndicator
## 当前粒度指示器 —— 显示 L3/L2/L1 和面包屑导航
##
## 详见 docs/技术/架构/战略图架构.md §二 模块结构
## 显示当前所在粒度级别和层级路径（如：大陆 > region_001 > tile_042）

## API 引用
@export var api_node: Node

## 路径标签（显示 "大陆 > 北方行省 > 河口地块"）
@export var path_label: Label

## 粒度图标容器
@export var granularity_icons: HBoxContainer

## L3/L2/L1 图标（高亮当前）
@export var icon_l3: TextureRect
@export var icon_l2: TextureRect
@export var icon_l1: TextureRect


func _ready() -> void:
	if api_node:
		if api_node.has_signal("granularity_changed"):
			api_node.granularity_changed.connect(_on_granularity_changed)
	_update_display()


func _on_granularity_changed(old_g: int, new_g: int, focused_parent_id: String) -> void:
	_update_display()


func _update_display() -> void:
	# TODO: SM-1 实现
	# 1. 根据 api_node.get_granularity() 高亮对应图标
	# 2. 根据 focused_parent_id 查询名称，构建面包屑路径
	#    L3: "大陆"
	#    L2: "大陆 > <region_name>"
	#    L1: "大陆 > <region_name> > <tile_name>"
	if path_label == null:
		return
	if api_node == null:
		return
	var g: int = api_node.get_granularity()
	match g:
		0: path_label.text = "大陆"
		1: path_label.text = "大陆 > %s" % api_node.get_focused_parent_id()
		2: path_label.text = "大陆 > ... > %s" % api_node.get_focused_parent_id()
