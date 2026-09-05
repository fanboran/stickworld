class_name UIRoot
extends CanvasLayer
## UI 根容器 —— 三层 UI 的总装。
##
## 详见 docs/技术/架构/场景与战斗架构.md §十。
## 子节点结构（z 从低到高）：
##   GlobalHUD / ModePanel / ContextPanel / ResourceBar / HudOverlay
##   ModalOverlay（Z_MODAL，模态遮罩盖住全部 UI） / UiInspector（Z_INSPECTOR，F3 调试）
##   SystemOverlay（Z_SYSTEM，toast/确认框，在模态之上）
##   UIModalStack（模态栈：层键字典 + 逐层 pop，见 ui_modal_stack.gd）

const _DebugUiInspectorScript: GDScript = preload("res://modules/ui_global/scripts/debug_ui_inspector.gd")
const _FpsCounterScript: GDScript = preload("res://modules/ui_global/scripts/hud/fps_counter.gd")
const _NotificationFeedScript: GDScript = preload("res://modules/ui_global/scripts/hud/notification_feed.gd")

# UIAPI 是全局 class_name，无需 preload（模式枚举经映射器注入，不依赖 PlayerControlAPI）

# ─────────────────────────────── 子节点引用 ────────────────────────────────
@onready var global_hud: Control = get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
@onready var mode_panel: Control = get_node_or_null(UIAPI.PATH_MODE_PANEL)
@onready var context_panel: Control = get_node_or_null(UIAPI.PATH_CONTEXT_PANEL)
@onready var modal_overlay: Control = get_node_or_null(UIAPI.PATH_MODAL_OVERLAY)

## 统一模态栈（UIModalStack 子节点，ESC/输入屏蔽/暂停的单一权威）
var modal_stack: UIModalStack = null
## FPS 计数器（设置面板 video/show_fps 开关驱动）
var _fps_counter: Label = null
## 通知流（左下堆叠 feed，EventBus ui_notification 驱动）
var _notification_feed: NotificationFeed = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	add_to_group("ui_root")
	_apply_slot_z_orders()
	_setup_modal_stack()
	_setup_notification_feed()
	_bind_event_bus()
	_apply_theme()
	_setup_ui_inspector()
	_setup_fps_counter()


## 槽位层序统一走 LayerOrder 常量（场景文件不写 z_index，单一真相源见 layer_order.gd）
func _apply_slot_z_orders() -> void:
	var modal := get_node_or_null("ModalOverlay") as Control
	if modal != null:
		modal.z_index = LayerOrder.Z_MODAL
	var system := get_node_or_null("SystemOverlay") as Control
	if system != null:
		system.z_index = LayerOrder.Z_SYSTEM


## 装配统一模态栈（层键字典 + 逐层 pop，替代 GameRoot._handle_escape 特判）
func _setup_modal_stack() -> void:
	var stack := UIModalStack.new()
	stack.name = "UIModalStack"
	add_child(stack)
	modal_stack = stack


## 取模态栈（供 GameRoot / StickKit 等调用）
func get_modal_stack() -> UIModalStack:
	return modal_stack


## 装配通知流（左下堆叠 feed，挂 HudOverlay 槽；无该槽的裸环境直接挂 UIRoot）
func _setup_notification_feed() -> void:
	var feed: NotificationFeed = _NotificationFeedScript.new()
	feed.name = "NotificationFeed"
	if not add_to_slot("HudOverlay", feed):
		add_child(feed)
	_notification_feed = feed


## 取通知流（供测试/调试调用）
func get_notification_feed() -> NotificationFeed:
	return _notification_feed


## F3 调试模式 UI 名称检查器（挂最上层，DebugApi 可见时生效）
func _setup_ui_inspector() -> void:
	var inspector := UIKit.full_rect(_DebugUiInspectorScript, "UiInspector")
	inspector.z_index = LayerOrder.Z_INSPECTOR
	add_child(inspector)


## 挂载 FPS 计数器（设置面板 video/show_fps，启动时读存量配置）
func _setup_fps_counter() -> void:
	var counter := Label.new()
	counter.set_script(_FpsCounterScript)
	counter.name = "FpsCounter"
	add_child(counter)
	_fps_counter = counter
	_fps_counter.visible = false
	if ConfigManager and ConfigManager.has_key("video/show_fps"):
		_fps_counter.visible = bool(ConfigManager.get_value("video/show_fps"))


## 显示/隐藏 FPS 计数器（设置面板应用时调用）
func set_fps_counter_visible(visible: bool) -> void:
	if _fps_counter != null:
		_fps_counter.visible = visible


## 模式→面板映射器（Callable(int mode) -> int，返回 UIAPI.PanelType）。
## 由装配方注入，本模块不依赖业务模块的模式枚举（断 ui_global↔player_control 环）。
var _mode_mapper: Callable = Callable()


## 由 SystemSetup 装配时调用：注入 InputDispatcher 与模式→面板映射器。
func setup(input_dispatcher: Node, mode_mapper: Callable = Callable()) -> void:
	if input_dispatcher != null and input_dispatcher.has_signal("mode_changed"):
		input_dispatcher.mode_changed.connect(_on_mode_changed)
	_mode_mapper = mode_mapper


## 挂主题：全 UI 树走 StickTheme（游戏内手绘涂鸦 + 琥珀强调）。
## 主题层在 modules/ui_global/scripts/theme/，模板层提升为正式共享层。
func _apply_theme() -> void:
	var t: Theme = StickTheme.create()
	for slot_name in ["GlobalHUD", "ModePanel", "ContextPanel", "ResourceBar",
			"ModalOverlay", "HudOverlay", "SystemOverlay"]:
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
	# 映射器未注入（裸 UIRoot 环境）时不动面板
	if not _mode_mapper.is_valid():
		return
	apply_mode_panel(int(_mode_mapper.call(new_mode)))


## 切换模式面板（panel_type 为 UIAPI.PanelType；模式→面板映射由装配方负责）。
func apply_mode_panel(panel_type: int) -> void:
	if mode_panel and mode_panel.has_method("switch_to"):
		mode_panel.switch_to(panel_type)
	# 战斗面板打开时清空上下文面板
	if panel_type == UIAPI.PanelType.BATTLE:
		clear_context()


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
	# 转发左下堆叠 feed（多通知并存，自动过期，04-游戏内HUD §六）
	if _notification_feed != null:
		_notification_feed.push_notification(title, body, level)
