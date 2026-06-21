class_name DisplayUtils

## 获取设备像素比（DPI 缩放因子）
static func get_dpr(node: Node) -> float:
	return node.get_tree().root.content_scale_factor

## 获取主屏幕的物理像素尺寸
static func get_screen_size() -> Vector2:
	var size_i := DisplayServer.screen_get_size()
	return Vector2(float(size_i.x), float(size_i.y))

## 获取当前视口尺寸
static func get_viewport_size(node: Node) -> Vector2:
	return node.get_tree().root.get_viewport().get_size()

## 安全获取窗口尺寸（node 为 null 时返回零向量）
static func get_window_size(node: Node) -> Vector2i:
	return node.get_window().size if node else Vector2i.ZERO

## 安全获取窗口位置（node 为 null 时返回零向量）
static func get_window_position(node: Node) -> Vector2i:
	return node.get_window().position if node else Vector2i.ZERO
