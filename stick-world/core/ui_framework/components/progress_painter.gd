class_name ProgressPainter
extends Node2D
## 进度条 _draw 公共基类（L0 纯绘制原语，零资产零模块依赖）。
##
## 收敛世界空间头顶进度条的最小公共语义：bg 填充 rect + 前景按进度填充 rect
## （进度 ≤ 0 不画前景）+ 1px 描边 rect；进度一律 clampf 到 [0,1] 后再画。
## 尺寸/配色/条数/排布属子类配置，子类自持并在 `_draw()` 里调 `draw_bar()`。
##
## 分层契约见 core/ui_framework/README.md（视觉/主题实现属 L1，本类不涉及）。

## 通用底色（半透明黑）
const COLOR_BG := Color(0, 0, 0, 0.6)
## 通用描边色（深墨）
const COLOR_BORDER := Color(0, 0, 0, 0.8)

## 当前进度 [0,1]（子类经 set_progress_value 更新）
var progress := 0.0


## 更新进度并请求重绘（clampf 收敛到 [0,1]）
func set_progress_value(ratio: float) -> void:
	progress = clampf(ratio, 0.0, 1.0)
	queue_redraw()


## 画一根进度条：bg 填充 + 前景（宽度 = w × 进度，进度 ≤ 0 跳过）+ 描边。
## 外观与收编前两处实现逐像素一致（绘制顺序/颜色/线宽不变）。
func draw_bar(x: float, y: float, w: float, h: float, ratio: float,
		fg_color: Color, bg_color: Color = COLOR_BG) -> void:
	draw_rect(Rect2(x, y, w, h), bg_color, true)
	var fg_w: float = w * clampf(ratio, 0.0, 1.0)
	if fg_w > 0.0:
		draw_rect(Rect2(x, y, fg_w, h), fg_color, true)
	draw_rect(Rect2(x, y, w, h), COLOR_BORDER, false, 1.0)
