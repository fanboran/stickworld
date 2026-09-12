extends Control
## 世界加载覆盖 —— 游戏根启动后、世界就绪前的全屏加载页。
##
## 元素与过渡加载屏（loading_screen.tscn）同族：标题 + 阶段文字 + 加载环 +
## 进度条 + 底部提示轮换——本屏承载真正的加载全期（分段装配+世界生成），
## 元素不全会让加载期比过渡屏还素。
## 进度条由 game_root 分段装配驱动（Minecraft 式模块计数），每段先更新再让出
## 一帧渲染后干活——进度是真实推进，不是假动画。
## **两级进度条（Minecraft 式）**：上条 = 总阶段（装配 9 段），下条更窄 = 当前
## 阶段内部的细分步（下条走满即上条进一格）。阶段没细分进度可报时下条隐藏。
## 挂 UIRoot 高 z（模态 z=50 之上、F3 调试 z=100 之下）。

const _SpinnerScript: GDScript = preload("res://modules/ui_global/scripts/menus/loading_spinner.gd")
const BAR_WIDTH: float = 260.0
const SUB_BAR_WIDTH: float = 186.0
const SUB_BAR_HEIGHT: float = 4.0
const TIP_INTERVAL: float = 2.5

## 过渡期提示（与 loading_screen 同池；轮换显示，加载期有活东西看）
const LOADING_TIPS: Array[String] = [
	"提示：空格暂停 · 1/2/3 调速 · Tab 战略图",
	"提示：F5 快速保存 · F9 快速读档 · Ctrl+S 存档面板",
	"提示：按 F3 调试（悬停 UI 显示控件名）",
	"提示：设置 → 游戏 里有「脱离卡死」自救按钮",
]

var _title_label: Label = null
var _label: Label = null
var _tip_label: Label = null
var _bar_track: Control = null
var _bar_fill: ColorRect = null
var _sub_track: Control = null
var _sub_fill: ColorRect = null
var _shown: bool = false
var _tip_timer: float = 0.0
var _tip_idx: int = 0


func _ready() -> void:
	add_to_group("world_loading_overlay")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.01, 0.012, 0.016, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical = Control.GROW_DIRECTION_BOTH
	center.add_theme_constant_override("separation", 18)
	add_child(center)
	# 标题（与过渡屏同一句游戏名——两屏无缝观感）
	_title_label = Label.new()
	_title_label.text = "火柴人帝国模拟"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	center.add_child(_title_label)
	# 阶段文字（主信息行）
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", StickTokens.FONT_HUD)
	_label.modulate = StickTokens.TEXT_DIM
	center.add_child(_label)
	var spinner := Control.new()
	spinner.set_script(_SpinnerScript)
	spinner.custom_minimum_size = Vector2(56, 56)
	spinner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	center.add_child(spinner)
	# 两级进度条容器（条间距 5px——紧贴成一组，与组外元素仍隔 18px）
	var bars := VBoxContainer.new()
	bars.add_theme_constant_override("separation", 5)
	bars.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	center.add_child(bars)
	# 主进度条（总阶段；与副条同亮同灭——纯文案阶段不假装有进度）
	_bar_track = Control.new()
	_bar_track.custom_minimum_size = Vector2(BAR_WIDTH, 6)
	_bar_track.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bar_track.clip_contents = true
	_bar_track.visible = false
	bars.add_child(_bar_track)
	var track_bg := ColorRect.new()
	track_bg.color = Color(1, 1, 1, 0.12)
	track_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bar_track.add_child(track_bg)
	_bar_fill = ColorRect.new()
	_bar_fill.color = StickTokens.ACCENT
	_bar_fill.position = Vector2.ZERO
	_bar_fill.size = Vector2(0, 6)
	_bar_track.add_child(_bar_fill)
	# 副进度条（当前阶段内部细分；更窄更矮更暗，视觉上从属于上条）
	_sub_track = Control.new()
	_sub_track.custom_minimum_size = Vector2(SUB_BAR_WIDTH, SUB_BAR_HEIGHT)
	_sub_track.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_sub_track.clip_contents = true
	_sub_track.visible = false
	bars.add_child(_sub_track)
	var sub_bg := ColorRect.new()
	sub_bg.color = Color(1, 1, 1, 0.10)
	sub_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sub_track.add_child(sub_bg)
	_sub_fill = ColorRect.new()
	_sub_fill.color = StickTokens.ACCENT
	_sub_fill.modulate = Color(1, 1, 1, 0.62)
	_sub_fill.position = Vector2.ZERO
	_sub_fill.size = Vector2(0, SUB_BAR_HEIGHT)
	_sub_track.add_child(_sub_fill)
	# 底部提示（与过渡屏同池轮换）
	_tip_label = Label.new()
	_tip_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_tip_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_tip_label.offset_bottom = -36.0
	_tip_label.offset_top = -60.0
	_tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_tip_label.modulate = StickTokens.TEXT_FAINT
	_tip_label.text = LOADING_TIPS[0]
	add_child(_tip_label)
	visible = false


func _process(delta: float) -> void:
	if not _shown:
		return
	_tip_timer += delta
	if _tip_timer >= TIP_INTERVAL:
		_tip_timer = 0.0
		_tip_idx = (_tip_idx + 1) % LOADING_TIPS.size()
		_tip_label.text = LOADING_TIPS[_tip_idx]


## 显示加载覆盖（阶段文字；ratio 0~1 同时亮主进度条，<0 隐藏只留文字；
## sub_ratio 为当前阶段内部细分进度，<0 = 该阶段无细分进度）
func show_loading(message: String, ratio: float = -1.0, sub_ratio: float = -1.0) -> void:
	_label.text = message
	set_progress(ratio)
	set_sub_progress(sub_ratio)
	visible = true
	modulate.a = 1.0
	_shown = true


## 更新主进度条（钳 0~1；<0 隐藏整组进度条只留文字）
func set_progress(ratio: float) -> void:
	if ratio < 0.0:
		_bar_track.visible = false
		_sub_track.visible = false
		return
	_bar_track.visible = true
	_bar_fill.size.x = BAR_WIDTH * clampf(ratio, 0.0, 1.0)


## 更新副进度条（当前阶段内部细分；主条未亮时一并隐藏——避免孤零零一条副条）
func set_sub_progress(ratio: float) -> void:
	if ratio < 0.0 or not _bar_track.visible:
		_sub_track.visible = false
		return
	_sub_track.visible = true
	_sub_fill.size.x = SUB_BAR_WIDTH * clampf(ratio, 0.0, 1.0)


## 世界就绪后淡出（幂等）
func hide_loading() -> void:
	if not _shown:
		return
	_shown = false
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.35)
	tween.tween_callback(func():
		visible = false
		modulate.a = 1.0
	)
