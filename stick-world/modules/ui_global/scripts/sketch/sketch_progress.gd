class_name SketchProgress
extends ProgressBar
## 手绘涂鸦进度条 —— 九宫格沸腾贴图（轨道 + 填充；帧由 SketchTextures 驱动）。


func _ready() -> void:
	add_theme_stylebox_override("background", SketchStyle.progress_bg())
	add_theme_stylebox_override("fill", SketchStyle.progress_fill())
