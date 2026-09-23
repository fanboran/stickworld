class_name MusicVisualizer
extends Control
## 原声带页的电平表 —— 数据源是 BGM 总线的实时峰值（AudioServer 峰值表），
## 不是逐帧假动画：音乐停/暂停柱子自己趴回去，音乐音量拉低柱子跟着矮。
##
## **诚实标注**：这是电平表，不是频谱。引擎侧没有现成的 FFT 读数，真频谱要往总线挂
## AudioEffectSpectrumAnalyzer——那是 AudioManager 的地盘（总线唯一写者），
## 一个菜单页面不该去改音频图，所以这里只做"电平 × 窗函数"的经典电平显示。
##
## 手绘语言：柱子用 SketchDraw.draw_panel（与面板/血条同源的 boiling 描边），
## 底部一条波浪基线，琥珀填充（§1.2 强调色）。

## 柱数（宽度自适应）
const BAR_COUNT := 36
## 柱间距（px）
const BAR_GAP := 3.0
## 静音时的半柱高（在中线上留一条琥珀虚线当基线，不是空无一物）
const BAR_MIN_H := 1.5
## 起振/回落速度（每秒趋于目标的比率）：快起慢落 = 有落拍感，不糊成一根
const ATTACK := 16.0
const RELEASE := 3.5
## dB 映射地板：成品配乐峰值多在 -6~-12dB，地板取 -34 让常用区间落在中段
## （地板压到 -46 会让音乐一响柱子就顶满，读成一堵墙）
const DB_FLOOR := -34.0
## 响应曲线指数：>1 把常用区间往中段压，留出可读的起伏余量
const CURVE := 2.0

var _levels := PackedFloat32Array()
var _seed: int = 0
var _timer: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seed = randi()
	_levels.resize(BAR_COUNT)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var level := _bus_level()
	for i in BAR_COUNT:
		var want: float = pow(maxf(level * _window(i), 0.0), CURVE)
		var rate := ATTACK if want > _levels[i] else RELEASE
		_levels[i] = lerpf(_levels[i], want, clampf(rate * delta, 0.0, 1.0))
	# boiling：与面板/血条同节拍重掷相位
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		_seed = randi()
	queue_redraw()


## BGM 总线峰值 → 0~1 电平（-inf/+inf 都当静音；总线缺失时静默降级）
func _bus_level() -> float:
	if AudioManager == null:
		return 0.0
	var idx := AudioServer.get_bus_index(AudioManager.BUS_BGM)
	if idx < 0:
		return 0.0
	var db := AudioServer.get_bus_peak_volume_left_db(idx, 0)
	if is_inf(db) or is_nan(db):
		return 0.0
	return clampf((db - DB_FLOOR) / -DB_FLOOR, 0.0, 1.0)


## 窗函数：中间高两侧低（电平表外观）；带定型扰动，避免一排等高的机械感
func _window(i: int) -> float:
	if BAR_COUNT < 2:
		return 1.0
	var t := float(i) / float(BAR_COUNT - 1)
	var w := 0.45 + 0.55 * sin(PI * t)
	return clampf(w * (1.0 + SketchDraw.wobble(i * 7, _seed) * 0.10), 0.0, 1.2)


func _draw() -> void:
	var bw: float = (size.x - BAR_GAP * float(BAR_COUNT - 1)) / float(BAR_COUNT)
	if bw < 1.0 or size.y < 8.0:
		return
	# 中线镜像（上下对称长）：一根柱子跨中线，比"贴底长高"更像电平表，
	# 也让这块留白被填满而不显得是"没做完的空档"
	var mid := size.y * 0.5
	var half := size.y * 0.5 - 2.0
	SketchDraw.draw_wavy_line(self, Vector2(0.0, mid), Vector2(size.x, mid),
			_seed + 91, Color(StickTokens.BORDER.r, StickTokens.BORDER.g,
			StickTokens.BORDER.b, 0.30), 1.3)
	for i in BAR_COUNT:
		var h: float = BAR_MIN_H + half * _levels[i]
		var r := Rect2(Vector2(float(i) * (bw + BAR_GAP), mid - h), Vector2(bw, h * 2.0))
		SketchDraw.draw_panel(self, r, _seed + i * 3,
				Color(StickTokens.ACCENT, 0.55), Color(StickTokens.ACCENT, 0.85), 1.3, 3.0)
