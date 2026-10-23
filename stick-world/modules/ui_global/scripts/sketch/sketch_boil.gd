class_name SketchBoil
extends RefCounted
## 手绘控件 boiling 相位驱动器 —— 自绘控件家族共享的 _seed/_timer 对（mixin 式助手）。
##
## sketch 自绘控件引擎基类各异（CheckBox/HSlider/TabBar/…），无法上提共同基类；
## boiling 节拍原先以 7 行 _process × 8 处逐字复制——上提到本件：控件持有一个
## SketchBoil，_process 一行 tick，_draw 读 phase。
##
## 节拍语义（血条同源，间隔 = SketchDraw.WOBBLE_INTERVAL）：
##   tick 仅在控件可见时调用（调用方以 is_visible_in_tree 短路——不可见既不推进
##   计时也不重绘，与原守卫逐帧语义一致）；到点重掷相位并返回 true，调用方
##   queue_redraw 整图换帧。

## 当前相位种子（_draw 的 wobble 输入；每次重掷整图换相位）
var phase: int = 0

## 节拍计时（累计可见帧 delta，到点清零）
var _timer: float = 0.0


## 初始重掷（控件 _ready 调用；对齐原 `_seed = randi()` 首掷）
func reset() -> void:
	phase = randi()


## 每帧推进（控件 _process 调用）。返回 true = 到点重掷了相位，调用方应 queue_redraw。
func tick(delta: float) -> bool:
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		phase = randi()
		return true
	return false
