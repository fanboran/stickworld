class_name BaseScreen
extends Control
## 模态面板基类 —— 全屏半透明遮罩 + 居中面板 + open/close/toggle 生命周期。
##
## 从 SettingsMenuPanel / SavePanel / WorldMapPanel 的重复实现提炼（2026-08 审计）。
## 这些面板原先各自手写：背景遮罩、面板尺寸/居中定位、toggle 开关、is_open 查询。
##
## 子类用法：
##   extends BaseScreen
##   const PANEL_SIZE := Vector2(640, 480)  # 覆盖默认面板尺寸
##   func _build_content() -> void:         # 构建面板内部内容（_panel 已就绪）
##       ...添加 Label/Button 到 _panel...
##   func setup(...) -> void:               # 注入依赖后调 _build_screen()
##       _build_screen()
##   # 开关：open() / close() / toggle() / is_open()
##
## 定位策略：open() 时按 viewport 手动居中（ModalOverlay 布局时序不可靠，
## 锚点方案弃用，与 SettingsMenuPanel 原实现一致）。

# ─────────────────────────────── Inspector 参数 ────────────────────────────────

## 面板尺寸（子类覆盖或直接赋值）
@export var panel_size: Vector2 = Vector2(480, 460)

## 全屏遮罩透明度
@export var bg_alpha: float = 0.55


# ─────────────────────────────── 内部状态 ────────────────────────────────

var _bg: ColorRect = null
var _panel: Panel = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	visible = false


## 构建遮罩 + 居中面板，并调用 _build_content() 构建内容。
## 子类在 setup() 或 _ready() 中调用（保证依赖已注入）。
func _build_screen() -> void:
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, bg_alpha)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_bg)
	_panel = Panel.new()
	add_child(_panel)
	_build_content()


## 子类实现：往 _panel 中添加面板内容。
func _build_content() -> void:
	pass


# ─────────────────────────────── 开关 ────────────────────────────────

## 打开面板（手动居中定位）
func open() -> void:
	var vp_rect: Rect2 = _get_viewport_rect()
	if _bg != null:
		_bg.size = vp_rect.size
	if _panel != null:
		_panel.size = panel_size
		_panel.position = (vp_rect.size - panel_size) * 0.5
	visible = true


## 关闭面板
func close() -> void:
	visible = false


## 切换开关状态
func toggle() -> void:
	if is_open():
		close()
	else:
		open()


## 面板是否打开
func is_open() -> bool:
	return visible


## 取当前 viewport 可见矩形（节点未入树时兜底 1920x1080）
func _get_viewport_rect() -> Rect2:
	var vp := get_viewport()
	if vp != null:
		return vp.get_visible_rect()
	return Rect2(0, 0, 1920, 1080)
