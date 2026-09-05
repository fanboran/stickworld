class_name SketchLineEdit
extends LineEdit
## 手绘涂鸦输入框 —— 九宫格沸腾贴图（聚焦态琥珀描边帧）。


func _ready() -> void:
	add_theme_stylebox_override("normal", SketchStyle.groove())
	add_theme_stylebox_override("focus", SketchStyle.groove_focus())
