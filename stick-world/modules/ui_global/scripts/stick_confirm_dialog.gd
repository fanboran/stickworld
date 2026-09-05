class_name StickConfirmDialog
extends Control
## 确认框（模态）—— 确认框族的栈化实现。
##
## 替代旧 StickKit.confirm 的裸 ColorRect 拼装：作为独立节点入 UIModalStack
## CONFIRM 层（栈顶），ESC = 取消（05 篇：ESC 等效取消，不触发 on_confirm）。
## 全屏遮罩 + 居中窗口（anchor 方案，不手写 position）；点遮罩不关闭
## （确认框白名单 ❌，必须显式选择）。关闭即销毁（queue_free）。
##
## 用法：通常经 StickKit.confirm() 工厂创建（保持旧签名），不直接 new。

var _dim: Control = null
var _window: PanelContainer = null
var _on_confirm: Callable = Callable()


## 构建骨架（子类/工厂调用）
func setup(title: String, message: String, on_confirm: Callable,
		confirm_text: String, kind: int) -> void:
	_on_confirm = on_confirm
	# 根必须铺满父容器（FULL_RECT + 双向 grow），否则内部遮罩（锚 FULL_RECT）
	# 会塌缩成 0 尺寸不可见（曾致确认框静默不显示）
	set_anchors_preset(Control.PRESET_FULL_RECT)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	# 遮罩：生成艺术背景（压暗 + 旋转圆润立方体 + 光标光晕；自身消费鼠标防穿透）
	_dim = GenerativeBackdrop.new()
	_dim.name = "Dim"
	_dim.dim_color = StickTokens.MODAL_DIM
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)
	# 居中窗口（anchor 归零 + 相对 dim 计算；Godot 的 position setter 配 anchor 会失效）
	_window = StickKit.panel(_dim, SketchPanel.Tone.DARK)
	_window.custom_minimum_size = Vector2(440, 0)
	_window.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_window.resized.connect(func():
		if is_instance_valid(_window) and is_instance_valid(_dim):
			_window.position = (_dim.size - _window.size) * 0.5
	)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_window.add_child(box)
	# 标题居中大字，消息居中自动换行，按钮居中成对——小确认框不摆官僚架势
	var title_l := StickKit.label(box, title, StickKit.LabelKind.BODY)
	title_l.add_theme_font_size_override("font_size", 18)
	title_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var msg := StickKit.label(box, message, StickKit.LabelKind.BODY)
	msg.modulate = StickTokens.TEXT_DIM
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var btn_row := StickKit.row(box, 12)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	StickKit.auto_button(btn_row, "取消", close, StickKit.ButtonKind.NORMAL, 34.0)
	StickKit.auto_button(btn_row, confirm_text, _on_confirm_pressed, kind, 34.0)


func _on_confirm_pressed() -> void:
	close()
	if _on_confirm.is_valid():
		_on_confirm.call()


func open() -> void:
	visible = true


## 关闭并销毁（ESC/取消/确定统一走这里；销毁由 queue_free 负责）
func close() -> void:
	visible = false
	queue_free()


func is_open() -> bool:
	return visible
