extends Node
## 场景管理与视图切换。
##
## 每个"视图"是一个预注册的 PackedScene。
## 通过 switch_view(name) 切换；通过 back() 回到上一个视图。
## 通过 EventBus.ui_switch_view("city") 也能触发切换。

signal view_changed(view_name: String, view_node: Node)
signal view_not_found(view_name: String)

# 已注册视图：view_name -> PackedScene
var _views: Dictionary = {}
# 历史栈
var _history: Array = []
# 当前状态
var _current_name: String = ""
var _current_view: Node = null
# 视图容器。SceneManager 通常挂在 root 下，自己作为容器。
var _container: Node = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	if _container == null:
		_container = self
	# 订阅 EventBus 的视图切换请求
	if EventBus and EventBus.has_signal("ui_switch_view"):
		EventBus.ui_switch_view.connect(_on_switch_view_request)


func _on_switch_view_request(view_name: String) -> void:
	switch_view(view_name, false)


# ─────────────────────────────── 视图注册 ────────────────────────────────

func register_view(view_name: String, packed_scene: PackedScene) -> void:
	if packed_scene == null:
		push_warning("[SceneManager] 注册空场景: %s" % view_name)
		return
	_views[view_name] = packed_scene


func has_view(view_name: String) -> bool:
	return _views.has(view_name)


func register_views(view_map: Dictionary) -> void:
	for k in view_map.keys():
		register_view(k, view_map[k])


# ─────────────────────────────── 切换逻辑 ────────────────────────────────

func switch_view(view_name: String, push_history: bool = true) -> Node:
	if not _views.has(view_name):
		push_warning("[SceneManager] 未注册的视图: %s" % view_name)
		view_not_found.emit(view_name)
		return null

	var packed: PackedScene = _views[view_name]
	var new_view: Node = packed.instantiate()
	if new_view == null:
		push_warning("[SceneManager] 场景实例化失败: %s" % view_name)
		return null

	# 压栈当前视图名
	if push_history and _current_name != "" and _current_name != view_name:
		_history.append(_current_name)

	# 释放旧视图
	if _current_view and is_instance_valid(_current_view):
		_current_view.queue_free()

	# 挂载新视图
	_container.add_child(new_view)
	_current_view = new_view
	_current_name = view_name

	view_changed.emit(view_name, new_view)
	return new_view


func instantiate_view(view_name: String) -> Node:
	if not _views.has(view_name):
		return null
	var packed: PackedScene = _views[view_name]
	return packed.instantiate()


func back() -> Node:
	if _history.is_empty():
		return null
	var prev: String = _history.pop_back()
	return switch_view(prev, false)


func clear_history() -> void:
	_history.clear()


# ─────────────────────────────── 查询 ───────────────────────────────────

func get_current_view_name() -> String:
	return _current_name


func get_current_view() -> Node:
	return _current_view


func get_history() -> Array:
	return _history.duplicate()


# ─────────────────────────────── 外部容器 ────────────────────────────────

func set_container(container: Node) -> void:
	_container = container