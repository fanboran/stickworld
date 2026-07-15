class_name PoliticalData
extends Resource
## 政权/联盟数据 —— L3 启动时必加载
##
## 详见 docs/技术/架构/战略图架构.md §3.6
## 政治归属运行时可改（通过 EventBus 同步）

## 所有政权
## key: state_id (String), value: Dictionary {"name": String, "capital_settlement_id": String, "alliance_id": String}
@export var states: Dictionary = {}

## 所有联盟
## key: alliance_id (String), value: Dictionary {"name": String, "member_states": Array[String]}
@export var alliances: Dictionary = {}

## 地区归属（key: region_id, value: state_id）
## 运行时可改
@export var region_owners: Dictionary = {}

## 势力颜色表（key: state_id, value: Color）
@export var owner_colors: Dictionary = {}

## 默认无主地块颜色
@export var neutral_color: Color = Color(0.5, 0.5, 0.5, 1.0)


## 获取地区归属政权
func get_region_owner(region_id: String) -> String:
	return region_owners.get(region_id, "")


## 设置地区归属（运行时可改）
## [Q] region_owners 更新，调用方应通过 EventBus 广播 region_owner_changed
func set_region_owner(region_id: String, state_id: String) -> void:
	region_owners[region_id] = state_id


## 获取政权信息
func get_state_info(state_id: String) -> Dictionary:
	return states.get(state_id, {})


## 获取联盟信息
func get_alliance_info(alliance_id: String) -> Dictionary:
	return alliances.get(alliance_id, {})


## 获取政权显示颜色
func get_state_color(state_id: String) -> Color:
	if state_id.is_empty():
		return neutral_color
	return owner_colors.get(state_id, neutral_color)


## 设置势力颜色
func set_state_color(state_id: String, color: Color) -> void:
	owner_colors[state_id] = color
