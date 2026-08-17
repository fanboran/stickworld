class_name UIRoot
extends CanvasLayer
## UI 根容器 —— 三层 UI 的总装。
##
## 详见 docs/技术/架构/场景与战斗架构.md §十。
## 子节点结构（z 从低到高）：
##   GlobalHUD / ModePanel / ContextPanel / ResourceBar / HudOverlay
##   ModalOverlay（z=50，模态遮罩盖住全部 UI） / UiInspector（z=100，F3 调试）

const _DebugUiInspectorScript: GDScript = preload("res://modules/ui_global/scripts/debug_ui_inspector.gd")

# UIAPI / PlayerControlAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var global_hud: Control = get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
@onready var mode_panel: Control = get_node_or_null(UIAPI.PATH_MODE_PANEL)
@onready var context_panel: Control = get_node_or_null(UIAPI.PATH_CONTEXT_PANEL)
@onready var modal_overlay: Control = get_node_or_null(UIAPI.PATH_MODAL_OVERLAY)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	add_to_group("ui_root")
	_bind_event_bus()
	_apply_theme()
	_setup_ui_inspector()


## F3 调试模式 UI 名称检查器（挂最上层，DebugApi 可见时生效）
func _setup_ui_inspector() -> void:
	var inspector := Control.new()
	inspector.set_script(_DebugUiInspectorScript)
	inspector.name = "UiInspector"
	inspector.z_index = LayerOrder.Z_INSPECTOR
	add_child(inspector)


## 由 SystemSetup 装配时调用，注入 InputDispatcher（不自行向上遍历查找）。
func setup(input_dispatcher: Node) -> void:
	if input_dispatcher != null and input_dispatcher.has_signal("mode_changed"):
		input_dispatcher.mode_changed.connect(_on_mode_changed)


## 挂主题：全 UI 树走 StickTheme（黑玻璃窗 + 琥珀强调）。
## 主题层在 modules/ui_global/scripts/theme/，模板层提升为正式共享层。
func _apply_theme() -> void:
	var t: Theme = StickTheme.create()
	for slot_name in ["GlobalHUD", "ModePanel", "ContextPanel", "ResourceBar",
			"ModalOverlay", "HudOverlay"]:
		var slot := get_node_or_null(slot_name) as Control
		if slot:
			slot.theme = t


func _bind_event_bus() -> void:
	if not EventBus:
		return
	if EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.connect(_on_notification)


# ─────────────────────────────── 模式切换响应 ────────────────────────────────

func _on_mode_changed(_old_mode: int, new_mode: int) -> void:
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


# ─────────────────────────────── 槽位化路由（P2）────────────────────────────────

## 取具名槽（HudOverlay / ModePanel / ModalOverlay 等）。槽在 ui_root.tscn 中声明，
## 是布局唯一真相源。
func get_slot(slot_name: String) -> Control:
	return get_node_or_null(slot_name) as Control


## 挂到具名槽（P2 槽位化路由）：模块 UI 通过此方法注册进槽，由槽管理显隐与布局空间。
## 子控件自身的 anchor 由它自己负责（全屏面板用 UIKit.full_rect，角落 HUD 自设 anchor）。
func add_to_slot(slot_name: String, node: Node) -> bool:
	var slot := get_node_or_null(slot_name) as Control
	if slot == null:
		push_warning("[UIRoot] 槽不存在: %s" % slot_name)
		return false
	slot.add_child(node)
	return true


# ─────────────────────────────── 通知 ────────────────────────────────

func _on_notification(title: String, body: String, level: String) -> void:
	# P0 阶段：转发给 GlobalHUD 显示
	if global_hud and global_hud.has_method("show_notification"):
		global_hud.show_notification(title, body, level)
