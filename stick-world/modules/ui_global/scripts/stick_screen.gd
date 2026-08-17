class_name StickScreen
extends Control
## 统一弹窗基类（Container-based）—— 替代旧 BaseScreen 的手写绝对定位。
##
## 结构：全屏半透明遮罩 + 居中 PanelContainer（StickStyle.window_panel，
##       content_margin 24/12 统一内边距）+ VBox( 标题 / body 内容区 / footer 底栏 )。
## 所有弹窗（设置/存档/占位等）共用此骨架 → 外观与边距天然一致。
##
## 子类用法：
##   extends StickScreen
##   var panel_size := Vector2(640, 480)   # 覆盖尺寸
##   var panel_title := "标题"             # 覆盖标题
##   func _build_content() -> void:        # 往 _body / _footer 加内容（Container 布局）
##   # 生命周期：open() / close() / toggle() / is_open()（与 BaseScreen 同契约）

# ─────────────────────────────── Inspector 参数 ────────────────────────────────

@export var panel_size: Vector2 = Vector2(640, 480)
@export var bg_alpha: float = 0.55
@export var panel_title: String = ""

# ─────────────────────────────── 内部节点 ────────────────────────────────

var _bg: ColorRect = null
var _panel: PanelContainer = null
var _title_label: Label = null
## 内容区（子类往这里加控件）
var _body: VBoxContainer = null
## 底栏（子类往这里加动作按钮，右对齐）
var _footer: HBoxContainer = null

## 打开前的时间速度（用于 close 时恢复；打开时若已暂停则无需恢复）
var _prev_speed: int = -1

# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	visible = false


## 构建遮罩 + 居中面板 + 统一骨架（子类在 setup() 或 _ready() 中调用）。
func _build_screen() -> void:
	# 遮罩
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, bg_alpha)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 真正消费鼠标事件（STOP 只挡下层 UI 派发，不阻止进 _unhandled_input → 相机穿透）
	_bg.gui_input.connect(func(_event: InputEvent):
		get_viewport().set_input_as_handled()
	)
	add_child(_bg)
	# 居中面板（黑玻璃 + 统一内边距，不手写 position）
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", StickStyle.window_panel())
	add_child(_panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)
	# 标题
	_title_label = Label.new()
	_title_label.text = panel_title
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	vbox.add_child(_title_label)
	# 内容区
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_body)
	# 底栏
	_footer = HBoxContainer.new()
	_footer.alignment = BoxContainer.ALIGNMENT_END
	_footer.add_theme_constant_override("separation", 8)
	vbox.add_child(_footer)
	# 子类内容
	_build_content()


## 子类实现：往 _body / _footer 添加内容（Container 布局，禁止手写 position）
func _build_content() -> void:
	pass


# ─────────────────────────────── 开关（居中用 anchor 方案，不受窗口尺寸影响）────────────────────────────────

func open() -> void:
	if _bg == null:
		return
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.offset_left = -panel_size.x * 0.5
	_panel.offset_top = -panel_size.y * 0.5
	_panel.offset_right = panel_size.x * 0.5
	_panel.offset_bottom = panel_size.y * 0.5
	# 模态打开自动暂停（世界/玩家/缩放/悬停反馈全部冻结；close 恢复原速度）
	if TimeManager:
		if TimeManager.is_paused():
			_prev_speed = -1
		else:
			_prev_speed = TimeManager.current_speed
			TimeManager.set_speed(TimeManager.Speed.PAUSED)
	visible = true


func close() -> void:
	visible = false
	# 只恢复"由本面板打开的暂停"（嵌套模态时由最外层恢复）
	if _prev_speed >= 0 and TimeManager and TimeManager.is_paused():
		TimeManager.set_speed(_prev_speed)
	_prev_speed = -1


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func is_open() -> bool:
	return visible
