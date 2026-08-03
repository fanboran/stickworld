class_name PanelKit
extends RefCounted
## 底部 HUD 面板通用构造工具 —— 消除各业务面板（BattlePanel/PossessPanel 等）的重复代码。
##
## 用法：
##   var section := PanelKit.create_section(hbox, "框选")
##   PanelKit.add_separator(hbox)
##   var btn := PanelKit.create_button(hbox, "前进", _on_pressed)


## 创建带灰色小标题的 VBox 区块
static func create_section(parent: Container, title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 4)
	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 11)
	title_label.modulate = Color(0.7, 0.7, 0.7)
	section.add_child(title_label)
	parent.add_child(section)
	return section


## 添加竖直分隔线
static func add_separator(parent: Container) -> void:
	parent.add_child(VSeparator.new())


## 创建标准 HUD 按钮（高 28px）
static func create_button(parent: Container, text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 28)
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn
