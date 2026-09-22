class_name MapControllerUtil
extends RefCounted
## 战略图控制器公共工具 —— 三级控制器（strategic/L2/L3）共用的组件自探测原语。
##
## 控制器场景装配时组件可能未显式接线，_auto_find_components 用这里的
## 查找原语兜底；类型判定由调用方以 Callable 传入（保持各控制器的类型标注）。

## 三视图控制器组名（各自 _ready 入组）：HUD 层级按钮判层级可达性用——
## 目标视图节点在树内即可跳（L1 场景直开时无 L3/L2 节点，对应按钮自然置灰）。
const GROUP_L1_VIEW := "strategic_l1_view"
const GROUP_L2_VIEW := "strategic_l2_view"
const GROUP_L3_VIEW := "strategic_l3_view"


## 组内是否存在存活视图节点（层级按钮可达性判定；无树/无节点返回 false）
static func view_in_tree(node: Node, group: String) -> bool:
	if node == null:
		return false
	var tree := node.get_tree()
	if tree == null:
		return false
	return tree.get_first_node_in_group(group) != null


## 在 root 的直接子节点中找第一个满足 matcher 的孩子，找不到返回 null。
static func find_child(root: Node, matcher: Callable) -> Node:
	for child in root.get_children():
		if matcher.call(child):
			return child
	return null


## 从 root 的父节点（CanvasLayer）按名找兄弟 UI 指示器，找不到返回 null。
## 指示器统一挂 CanvasLayer 直下：Control 挂 Node2D 下 anchor 参照矩形为 0 会跑位。
static func find_sibling(root: Node, node_name: String) -> Node:
	var layer := root.get_parent()
	if layer == null:
		return null
	return layer.get_node_or_null(node_name)
