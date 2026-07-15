extends Control
class_name SettlementTooltip
## 聚落悬停提示 —— L1 粒度下鼠标悬停聚落时显示信息
##
## 详见 docs/技术/架构/战略图架构.md §二 模块结构

## API 引用
@export var api_node: Node

## 名称标签
@export var name_label: Label

## 级别标签
@export var level_label: Label

## 产业标签
@export var industry_label: Label

## 规模标签
@export var population_label: Label

## 归属标签
@export var owner_label: Label

## 面板容器（用于显示/隐藏）
@export var panel_container: Control


func _ready() -> void:
	if api_node:
		if api_node.has_signal("region_hovered"):
			api_node.region_hovered.connect(_on_region_hovered)
	_hide_tooltip()


func _on_region_hovered(granularity: int, region_id: String, tile_id: String, settlement_id: String) -> void:
	# 只在 L1 粒度且有聚落命中时显示
	if granularity != 2 or settlement_id.is_empty():
		_hide_tooltip()
		return
	if api_node == null:
		_hide_tooltip()
		return
	var settlement: SettlementRef = api_node.get_settlement_ref(settlement_id)
	if settlement == null:
		_hide_tooltip()
		return
	_update_info(settlement, region_id)
	_show_tooltip()


func _update_info(settlement: SettlementRef, region_id: String) -> void:
	# TODO: SM-3 实现
	if name_label:
		name_label.text = settlement.name
	if level_label:
		level_label.text = "级别: T%d" % settlement.level
	if industry_label:
		industry_label.text = "产业: %s" % ", ".join(settlement.industry)
	if population_label:
		population_label.text = "规模: %d%%" % int(settlement.population_score * 100)
	if owner_label:
		var owner: String = api_node.get_region_owner(region_id)
		owner_label.text = "归属: %s" % (owner if not owner.is_empty() else "无主")


func _show_tooltip() -> void:
	if panel_container:
		panel_container.visible = true


func _hide_tooltip() -> void:
	if panel_container:
		panel_container.visible = false
