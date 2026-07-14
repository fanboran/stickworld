extends Node
## DebugApi -- 调试覆盖层状态管理（autoload 单例）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.5。
## 职责：
##   - 注册/注销调试绘制器（各模块注册自己的绘制器）
##   - 管理调试覆盖层可见性（F3 切换）
##   - 管理图例可见性
##
## 各模块通过本单例注册绘制器 Callable，DebugOverlay 在 _draw() 时调用。

signal visibility_changed(is_visible: bool)
signal legend_visibility_changed(is_visible: bool)

## 已注册的绘制器：name -> Callable(control: Control, ctx: Dictionary)
var _drawers: Dictionary = {}

## 调试覆盖层是否可见（启动时默认开启，便于开发）
var _visible: bool = true
## 图例是否可见
var _legend_visible: bool = true


## 注册绘制器
func register_drawer(drawer_name: String, drawer: Callable) -> void:
	_drawers[drawer_name] = drawer


## 注销绘制器
func unregister_drawer(drawer_name: String) -> void:
	_drawers.erase(drawer_name)


## 获取所有已注册的绘制器
func get_drawers() -> Dictionary:
	return _drawers


## F3 切换调试覆盖层显示/隐藏
func toggle_visibility() -> void:
	_visible = not _visible
	visibility_changed.emit(_visible)


## 设置可见性
func set_visible(v: bool) -> void:
	if _visible == v:
		return
	_visible = v
	visibility_changed.emit(_visible)


## 是否可见
func is_visible() -> bool:
	return _visible


## 显示图例
func show_legend() -> void:
	_legend_visible = true
	legend_visibility_changed.emit(_legend_visible)


## 隐藏图例
func hide_legend() -> void:
	_legend_visible = false
	legend_visibility_changed.emit(_legend_visible)


## 图例是否可见
func is_legend_visible() -> bool:
	return _legend_visible
