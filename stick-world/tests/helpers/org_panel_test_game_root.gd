extends Node
## 测试专用依赖桩——只实现 OrgPanel.setup 依赖的 get_organization_api 访问器。
## 面板经 has_method 探测，缺什么静默降级。不承载布局（合规出口见 UI.md，非 UI 根用法）。

var _api: Node = null
## 可选地图桩：测试注入后作为 get_current_map 返回（其 get_entities 供士气聚合口径）
var map: Node = null


func _ready() -> void:
	_api = get_parent().get_node_or_null("OrganizationApi")


func get_organization_api() -> Node:
	return _api


func get_current_map() -> Node:
	return map
