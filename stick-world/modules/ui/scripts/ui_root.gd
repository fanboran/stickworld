class_name UIRoot
extends CanvasLayer
## UI 根容器 —— 三层 UI 的总装。
##
## 详见 docs/技术/架构/场景与战斗架构.md §十。
## 子节点结构：
##   GlobalHUD       (Control)
##   ModePanel       (Control)
##   ContextPanel    (Control)
##   ModalOverlay    (Control)

const UIAPI := preload("res://modules/ui/api.gd")
const PlayerControlAPI := preload("res://modules/player_control/api.gd")

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var global_hud: Control = get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
@onready var mode_panel: Control = get_node_or_null(UIAPI.PATH_MODE_PANEL)
@onready var context_panel: Control = get_node_or_null(UIAPI.PATH_CONTEXT_PANEL)
@onready var modal_overlay: Control = get_node_or_null(UIAPI.PATH_MODAL_OVERLAY)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_bind_input_dispatcher()
	_bind_event_bus()


func _bind_input_dispatcher() -> void:
	# 通过 GameRoot 找 InputDispatcher
	var dispatcher := _find_input_dispatcher()
	if dispatcher and dispatcher.has_signal("mode_changed"):
		dispatcher.mode_changed.connect(_on_mode_changed)


func _find_input_dispatcher() -> Node:
	var root := get_parent()
	while root:
		if root.has_node("InputDispatcher"):
			return root.get_node("InputDispatcher")
		root = root.get_parent()
	return null


func _bind_event_bus() -> void:
	if not EventBus:
		return
	if EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.connect(_on_notification)


# ─────────────────────────────── 模式切换响应 ────────────────────────────────

func _on_mode_changed(old_mode: int, new_mode: int) -> void:
	# 把模式映射到面板类型
	var panel_type: int = _mode_to_panel_type(new_mode)
	if mode_panel and mode_panel.has_method("switch_to"):
		mode_panel.switch_to(panel_type)
	# 战斗模式打开时清空上下文面板
	if new_mode == PlayerControlAPI.Mode.BATTLE:
		clear_context()


func _mode_to_panel_type(mode: int) -> int:
	match mode:
		PlayerControlAPI.Mode.EXPLORE, PlayerControlAPI.Mode.INDOOR, PlayerControlAPI.Mode.BUILD:
			return UIAPI.PanelType.VILLAGE
		PlayerControlAPI.Mode.BATTLE:
			return UIAPI.PanelType.BATTLE
		PlayerControlAPI.Mode.POSSESS:
			return UIAPI.PanelType.POSSESS
		_:
			return UIAPI.PanelType.VILLAGE


# ─────────────────────────────── 公共 API ────────────────────────────────

## 设置上下文面板内容（节点会 reparent 到 ContextPanel）
func set_context_content(content: Control) -> void:
	if context_panel == null:
		return
	# 清空旧内容
	for child in context_panel.get_children():
		child.queue_free()
	if content:
		context_panel.add_child(content)


## 清空上下文面板
func clear_context() -> void:
	if context_panel == null:
		return
	for child in context_panel.get_children():
		child.queue_free()


## 打开模态弹窗
func open_modal(modal: Control) -> void:
	if modal_overlay == null:
		return
	modal_overlay.add_child(modal)


## 关闭所有模态弹窗
func close_all_modals() -> void:
	if modal_overlay == null:
		return
	for child in modal_overlay.get_children():
		child.queue_free()


# ─────────────────────────────── 通知 ────────────────────────────────

func _on_notification(title: String, body: String, level: String) -> void:
	# P0 阶段：转发给 GlobalHUD 显示
	if global_hud and global_hud.has_method("show_notification"):
		global_hud.show_notification(title, body, level)
