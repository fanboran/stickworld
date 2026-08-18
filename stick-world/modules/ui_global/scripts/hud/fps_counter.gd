class_name FpsCounter
extends Label
## FPS 计数器 —— 右上角时钟下方的小标签（设置面板「显示 FPS」开关驱动）。
##
## 由 UIRoot 挂载管理可见性；每 0.5s 刷新一次，避免每帧写文本。\n\nvar _timer: float = 0.0\n\n\nfunc _ready() -> void:\n\tset_anchors_preset(Control.PRESET_TOP_RIGHT)\n\toffset_left = -80.0\n\toffset_top = 84.0\n\toffset_right = -12.0\n\toffset_bottom = 104.0\n\thorizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT\n\tadd_theme_font_size_override(\"font_size\", StickTokens.FONT_HINT)\n\tmodulate = StickTokens.TEXT_DIM\n\tmouse_filter = Control.MOUSE_FILTER_IGNORE\n\ttext = \"FPS: --\"\n\n\nfunc _process(delta: float) -> void:\n\t_timer += delta\n\tif _timer >= 0.5:\n\t\t_timer = 0.0\n\t\ttext = \"FPS: %d\" % Engine.get_frames_per_second()\n