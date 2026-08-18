extends Control
## UI 名称调试器 —— F3 调试模式（DebugApi 可见）时，鼠标悬停 UI 控件即显示其信息。
##
## 帮助定位"这是哪个控件/来自哪个场景"，排查布局与分层问题。
## 显示：控件名（类型）+ 脚本来源路径。浮层跟随鼠标右下偏移。
## 挂 UIRoot 最上层（z 最高），DebugApi 关闭时完全隐藏、不参与交互。

const OFFSET := Vector2(18, 18)

var _panel: PanelContainer = null
var _label: Label = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", StickStyle.window_panel())
	# 白面板子树挂浅色表面主题（深色文字）
	_panel.theme = StickTheme.create_light_surface()
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_panel.add_child(_label)
	add_child(_panel)
	_panel.visible = false


func _process(_delta: float) -> void:
	var debug_on: bool = DebugApi != null and DebugApi.is_visible()
	if not debug_on:
		_panel.visible = false
		return
	var hovered := get_viewport().gui_get_hovered_control()
	if hovered == null:
		_panel.visible = false
		return
	_panel.visible = true
	_label.text = _describe(hovered)
	# 跟随鼠标（右下偏移），不遮住悬停控件本身的信息
	var pos: Vector2 = get_viewport().get_mouse_position() + OFFSET
	_panel.position = pos


## 描述控件：名称（类型）+ 脚本来源路径
func _describe(c: Control) -> String:
	var text := "%s (%s)" % [c.name, c.get_class()]
	var script: Script = c.get_script()
	if script != null and script.resource_path != "":
		text += "\n" + script.resource_path.trim_prefix("res://")
	return text
