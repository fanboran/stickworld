## 节点工具类
## 提供常用的节点树操作辅助方法
class_name NodeUtils


## 按类名查找第一个匹配类型的子节点（递归深度优先）
## @param type_name: 目标类型的类名字符串，如 "Sprite2D"
static func find_child_by_type(node: Node, type_name: String) -> Node:
	if not node:
		return null
	for child in node.get_children():
		if child.get_class() == type_name:
			return child
		var found: Node = find_child_by_type(child, type_name)
		if found:
			return found
	return null


## 清空节点的所有子节点
static func remove_all_children(node: Node) -> void:
	if not node:
		return
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


## 获取节点所属的场景根节点
static func get_root(node: Node) -> Node:
	if not node:
		return null
	return node.get_tree().root if node.get_tree() else null