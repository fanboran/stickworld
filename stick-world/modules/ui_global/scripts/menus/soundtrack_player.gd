class_name SoundtrackPlayer
extends Control
## 原声带页 —— 游戏原声带播放器（主菜单「制作人员」同行的方钮入口）。
##
## 结构按行业惯例的曲目播放器：左 = 曲目表（编号 / 曲名 / 时长，当前曲高亮），
## 右 = 正在播放（曲名 · 调性速度 / 可拖动进度条 / 走带键 / 循环开关 / 音乐音量）。
## 键盘：空格 播放暂停 · ↑↓ 选曲（在播则同时切曲）· ←→ 上/下一曲 · ESC 返回。
##
## 音频归 MusicDirector 的预览模式（绕过情境解析、固定满层、离场还原入场前状态）；
## 本页只管"点哪首、显示什么"。音量滑条写 AudioManager（总线音量唯一消费方）。
## 曲目表不在这里维护——数据源是 music_manifest.json（加一首曲子界面自动多一行）。
##
## 入口与布局约定见 docs/设计/UI/03-主菜单与流程.md §八。

## 曲目行高与间距（行数随清单增长，列表用 ScrollContainer 兜底）
const TRACK_ROW_H := 40.0
## 控制台面板尺寸（左右 240px 留白，四周 ≥ MODAL_MARGIN）。高度按曲目行数取：
## 9 行 × 44 + 页眉页脚 ≈ 500，留一档余量给清单变长
const CONSOLE_SIZE := Vector2(1440.0, 560.0)
const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"
## 进度条拖动步长（秒）：0.1 够细，拖动手感不糊
const SEEK_STEP := 0.1
## 走带键尺寸（播放键加大 = 行业惯例的版式重心）
const BTN_TRANSPORT := 44.0
const BTN_PLAY := 56.0
## 清单层名（作曲侧英文）→ 界面乐器名。缺项回退原名（清单加层不必改代码）
const INSTRUMENT_NAMES: Dictionary = {
	"piano": "钢琴", "strings": "弦乐", "bells": "钟琴", "harp": "竖琴",
	"perc": "定音鼓", "winds": "木管", "guitar": "吉他", "marimba": "马林巴",
	"pad": "合成垫", "vibraphone": "颤音琴",
}

## 曲目表（MusicDirector.get_track_list() 的快照）
var _tracks: Array[Dictionary] = []
## 当前高亮/播放的曲目序（-1 = 清单为空，无可播）
var _selected: int = -1
## 循环开关（默认开：清单里的曲子本就是循环体，原声带页要能一直听）
var _repeat := true
## 用户正在拖进度条：此期间不按播放位置回写滑条（避免与拖动抢值）
var _scrubbing := false
## 预览暂停态（走带键的播放/暂停图标随它切）
var _paused := false

var _list: VBoxContainer = null
var _rows: Array[SketchButton] = []
var _now_title: Label = null
var _now_meta: Label = null
var _now_lineup: Label = null
var _now_tiers: Label = null
var _progress: SketchHSlider = null
var _elapsed_label: Label = null
var _total_label: Label = null
var _play_button: SketchGlyphButton = null
var _repeat_button: SketchGlyphButton = null
var _volume_slider: SketchHSlider = null
var _visualizer: MusicVisualizer = null


func _ready() -> void:
	# 与主菜单同一套启动复位：暂停原语（从游戏内退回时可能带着引擎总闸）、
	# 沸腾动画驱动、主题
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.resume()
	SketchTextures.animation_enabled = true
	SketchTextures.ensure_driver(get_tree())
	theme = StickTheme.create()
	_build_backdrop()
	_build_ui()
	# 预览播到末尾（循环关）→ 自动下一曲
	if MusicDirector != null and MusicDirector.has_method("preview_finished"):
		MusicDirector.preview_finished.connect(_on_preview_finished)
	_load_tracks()


## 离场：预览是"过路状态"，还原入场前在放的曲目（主菜单原本静默则淡出静音）
func _exit_tree() -> void:
	if MusicDirector != null and MusicDirector.has_method("stop_preview"):
		MusicDirector.stop_preview()


func _build_backdrop() -> void:
	var backdrop := MenuBackdrop.new()
	backdrop.name = "Backdrop"
	add_child(backdrop)
	move_child(backdrop, 0)  # 垫在一切之下


# ─────────────────────────────── UI 装配 ────────────────────────────────

func _build_ui() -> void:
	# 返回：角落部件一律 dock（自带 SCREEN_MARGIN），不手写坐标
	var back := StickKit.sketch_button(self, "返回（ESC）", _return_to_menu,
			StickKit.ButtonKind.PAPER, StickTokens.BTN_H)
	back.name = "BackButton"
	back.font_size = 15
	back.bg_alpha = 0.62
	StickKit.dock(back, StickKit.Corner.TOP_LEFT, Vector2(140.0, StickTokens.BTN_H))
	var column := $Column as VBoxContainer
	_build_header(column)
	# 控制台：整页一块深玻璃面板（内容分左右两列）
	var panel := StickKit.panel(column, SketchPanel.Tone.DARK)
	panel.custom_minimum_size = CONSOLE_SIZE
	var console := VBoxContainer.new()
	console.add_theme_constant_override("separation", 10)
	panel.add_child(console)
	var body := StickKit.row(console, 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_track_list(body)
	body.add_child(VSeparator.new())
	_build_now_playing(body)
	# 页脚（面板内，保证深底可读）：键盘说明
	var hint := StickKit.label(console,
			"空格 播放/暂停 · ↑↓ 选曲 · ←→ 上/下一曲 · ESC 返回", StickKit.LabelKind.HINT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


## 页头：大标题（暖白字 + 深墨描边，与主菜单标题同族）+ 副题
func _build_header(column: VBoxContainer) -> void:
	var title := StickKit.label(column, "原声带", StickKit.LabelKind.TITLE)
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.99, 0.97, 0.92))
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.04, 0.03, 0.92))
	title.add_theme_constant_override("outline_size", 8)
	var sub := StickKit.label(column, "火柴人帝国模拟 · 全部配乐（原创，本地音源离线渲染）",
			StickKit.LabelKind.HINT)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(0.30, 0.20, 0.14, 0.80)  # 亮天空上的暖墨（版本角标同族）


## 左列：曲目表（编号 + 曲名 + 时长；当前曲 ACCENT 高亮）
func _build_track_list(body: HBoxContainer) -> void:
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(460.0, 0.0)
	left.add_theme_constant_override("separation", 8)
	body.add_child(left)
	StickKit.label(left, "曲目", StickKit.LabelKind.SECTION)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_list)


## 按曲目表建行（清单变化时整体重建；十来行量级无需增量维护）
func _rebuild_rows() -> void:
	for child in _list.get_children():
		child.queue_free()
	_rows = []
	for i in _tracks.size():
		var track: Dictionary = _tracks[i]
		var row := StickKit.sketch_button(_list, "%02d   %s" % [i + 1, track["title"]],
				_on_row_pressed.bind(i), StickKit.ButtonKind.NORMAL, TRACK_ROW_H)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.font_size = 16
		# 行内右缘时长：不占排版位（居中文字按钮加角标同款做法）
		var dur := Label.new()
		dur.text = _format_time(float(track["duration_s"]))
		dur.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dur.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		dur.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
		dur.modulate = StickTokens.TEXT_DIM
		dur.anchor_left = 1.0
		dur.anchor_right = 1.0
		dur.anchor_top = 0.0
		dur.anchor_bottom = 1.0
		dur.offset_left = -66.0
		dur.offset_right = -12.0
		dur.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(dur)
		_rows.append(row)


## 右列：正在播放（曲名 / 元信息 / 进度 / 走带 / 循环 / 音量）
func _build_now_playing(body: HBoxContainer) -> void:
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	body.add_child(right)
	StickKit.label(right, "正在播放", StickKit.LabelKind.SECTION)
	_now_title = StickKit.label(right, "—", StickKit.LabelKind.TITLE)
	_now_title.add_theme_font_size_override("font_size", 32)
	_now_meta = StickKit.label(right, "", StickKit.LabelKind.HINT)
	# 编制与强度分层：都从清单的层明细推出来（换成别的曲子自动跟着变，不写死文案）
	_now_lineup = StickKit.label(right, "", StickKit.LabelKind.BODY)
	_now_lineup.modulate = StickTokens.TEXT_DIM
	_now_tiers = StickKit.label(right, "", StickKit.LabelKind.HINT)
	# 信息块与走带挨着放：无专辑封面可占位，把柔性空白集中到最下方一处
	# （一整块贴顶 + 一整块贴底会读成"中间没做完"）
	var lead_gap := _spacer(false)
	lead_gap.custom_minimum_size = Vector2(0.0, 10.0)
	right.add_child(lead_gap)
	# 进度行：左已播 / 中可拖动滑条 / 右总长
	var prog_row := StickKit.row(right, 10)
	_elapsed_label = _time_label(prog_row, HORIZONTAL_ALIGNMENT_LEFT)
	_progress = SketchHSlider.new()
	_progress.name = "ProgressSlider"
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.step = SEEK_STEP
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prog_row.add_child(_progress)
	_total_label = _time_label(prog_row, HORIZONTAL_ALIGNMENT_RIGHT)
	_progress.drag_started.connect(func() -> void: _scrubbing = true)
	_progress.drag_ended.connect(_on_seek_ended)
	# 走带行：上一曲 / 播放暂停 / 下一曲 ｜ 循环 ｜ 音乐音量
	var bar := StickKit.row(right, 12)
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.custom_minimum_size = Vector2(0.0, BTN_PLAY)
	_add_glyph_button(bar, SketchDraw.Glyph.PREV, "上一曲", BTN_TRANSPORT, _play_prev)
	_play_button = _add_glyph_button(bar, SketchDraw.Glyph.PLAY, "播放 / 暂停",
			BTN_PLAY, _toggle_play)
	_play_button.name = "PlayButton"
	_add_glyph_button(bar, SketchDraw.Glyph.NEXT, "下一曲", BTN_TRANSPORT, _play_next)
	var gap := _spacer(false)
	gap.custom_minimum_size = Vector2(18.0, 0.0)
	bar.add_child(gap)
	_repeat_button = _add_glyph_button(bar, SketchDraw.Glyph.REPEAT, "循环播放",
			BTN_TRANSPORT, _toggle_repeat)
	_repeat_button.name = "RepeatButton"
	bar.add_child(_spacer(true))
	StickKit.label(bar, "音乐音量", StickKit.LabelKind.HINT)
	_volume_slider = SketchHSlider.new()
	_volume_slider.name = "VolumeSlider"
	_volume_slider.min_value = 0.0
	_volume_slider.max_value = 100.0
	_volume_slider.step = 1.0
	_volume_slider.custom_minimum_size = Vector2(200.0, 24.0)
	_volume_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_volume_slider.value = _music_volume() * 100.0   # 先取当前值再接线，免写回抖动
	_volume_slider.value_changed.connect(_on_volume_changed)
	bar.add_child(_volume_slider)
	# 电平表：占住中下部空间，且不是装饰——读 BGM 总线峰值，真的跟着出声起伏
	_visualizer = MusicVisualizer.new()
	_visualizer.name = "Visualizer"
	_visualizer.custom_minimum_size = Vector2(0.0, 110.0)
	_visualizer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_visualizer)
	# 底注：满层说明（编制与强度分层已由上面两行动态行承担，不重复写死文案）
	var note := StickKit.label(right, "此处按完整编制播放；游戏内按情境纵向混音。",
			StickKit.LabelKind.TINY)
	note.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM


## 弹性占位（expand=true 撑满剩余，false = 固定宽度的间隔块）。
## 必须 IGNORE 鼠标：裸 Control 默认 STOP，会在面板上空出一块吃掉点击的死区
func _spacer(expand: bool) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


func _add_glyph_button(parent: Control, glyph: int, tip: String, size: float,
		cb: Callable) -> SketchGlyphButton:
	var b := SketchGlyphButton.new()
	b.glyph = glyph
	b.square_size = size
	b.tooltip_text = tip
	# 手动建的按钮不经 StickKit._setup_button，点击音与 hover 缩放这里自己挂
	b.pressed.connect(func() -> void:
		if AudioManager != null and AudioManager.has_method("play_event"):
			AudioManager.play_event("ui_click"))
	b.pressed.connect(cb)
	b.resized.connect(func() -> void: b.pivot_offset = b.size * 0.5)
	b.mouse_entered.connect(func() -> void:
		if AudioManager != null and AudioManager.has_method("play_event"):
			AudioManager.play_event("ui_hover")
		var tw := b.create_tween()
		tw.tween_property(b, "scale", Vector2(1.03, 1.03), 0.08))
	b.mouse_exited.connect(func() -> void:
		var tw := b.create_tween()
		tw.tween_property(b, "scale", Vector2.ONE, 0.1))
	parent.add_child(b)
	return b


func _time_label(parent: Control, align: int) -> Label:
	var l := StickKit.label(parent, "0:00", StickKit.LabelKind.HINT)
	l.custom_minimum_size = Vector2(56.0, 0.0)
	l.horizontal_alignment = align as HorizontalAlignment
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


# ─────────────────────────────── 曲目表数据 ────────────────────────────────

func _load_tracks() -> void:
	if MusicDirector != null:
		_tracks = MusicDirector.get_track_list()
	_rebuild_rows()
	if _tracks.is_empty():
		# 清单缺失（先跑 tools/music/render_all.py）：说明白并把走带置灰，不假装能播
		_now_title.text = "无曲目"
		_now_meta.text = "音乐清单缺失：res://assets/audio/bgm/music_manifest.json"
		for c: Control in [_progress, _play_button, _repeat_button, _volume_slider]:
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c.modulate = Color(1.0, 1.0, 1.0, 0.45)
		return
	_selected = 0
	_refresh_rows()
	_refresh_now_playing()


# ─────────────────────────────── 播放控制 ────────────────────────────────

func _on_row_pressed(idx: int) -> void:
	_play_track(idx)


## 点播某一首：进预览模式（固定满层，循环与否随页面开关）
func _play_track(idx: int) -> void:
	if idx < 0 or idx >= _tracks.size():
		return
	if not MusicDirector.start_preview(str(_tracks[idx]["id"]), _repeat):
		return
	_selected = idx
	_paused = false
	_refresh_rows()
	_refresh_now_playing()


func _toggle_play() -> void:
	if not MusicDirector.is_previewing():
		_play_track(_selected)
		return
	# 曲尾停住（循环关、最后一首播完，层已自然结束）：播放键 = 从头再来一遍，
	# 而不是去"继续"一个已经结束的流（那样只会在曲尾静坐）
	if _paused and not MusicDirector.is_playing():
		_play_track(_selected)
		return
	_paused = not _paused
	MusicDirector.set_preview_paused(_paused)
	_refresh_transport()


## 上/下一曲（列表首尾回绕）
func _play_next() -> void:
	if _tracks.is_empty():
		return
	_play_track((_selected + 1) % _tracks.size())


func _play_prev() -> void:
	if _tracks.is_empty():
		return
	_play_track(wrapi(_selected - 1, 0, _tracks.size()))


func _toggle_repeat() -> void:
	_repeat = not _repeat
	# 开关立刻生效：循环是流自身的属性，重起当前曲目才改得掉（进度回到曲首）
	if MusicDirector.is_previewing() and _selected >= 0:
		MusicDirector.start_preview(str(_tracks[_selected]["id"]), _repeat)
		_paused = false
	_refresh_transport()


## 循环关闭时播到末尾 → 顺着往下走（最后一曲停住，进度停在曲尾）。
## 只认当前曲的收尾：串台通知（理论上 Director 侧已滤掉退役层）不驱动跳曲
func _on_preview_finished(cue_id: String) -> void:
	if _tracks.is_empty() or _repeat or _selected < 0 or _selected >= _tracks.size():
		return
	if cue_id != str(_tracks[_selected]["id"]):
		return
	if _selected >= _tracks.size() - 1:
		_paused = true
		_refresh_transport()
		return
	_play_next()


func _on_seek_ended(_changed: bool) -> void:
	_scrubbing = false
	if MusicDirector.is_previewing():
		MusicDirector.preview_seek(_progress.value)


func _on_volume_changed(value: float) -> void:
	if AudioManager != null and AudioManager.has_method("set_volume"):
		AudioManager.set_volume("bgm", clampf(value / 100.0, 0.0, 1.0))


func _music_volume() -> float:
	if AudioManager != null and AudioManager.has_method("get_volume"):
		return float(AudioManager.get_volume("bgm"))
	return 1.0


# ─────────────────────────────── 刷新 ────────────────────────────────

func _process(_delta: float) -> void:
	if not MusicDirector.is_previewing():
		return
	var dur := MusicDirector.preview_duration()
	var pos := MusicDirector.preview_position()
	if not is_equal_approx(_progress.max_value, maxf(dur, 0.001)):
		_progress.max_value = maxf(dur, 0.001)
		_total_label.text = _format_time(dur)
	if _scrubbing:
		return
	_progress.set_value_no_signal(pos)
	_progress.queue_redraw()   # set_value_no_signal 不发信号，自绘层要手动重画
	_elapsed_label.text = _format_time(pos)


## 曲目行高亮：当前曲 = ACCENT 琥珀档（与设置分类选中态同一套"选中"语言）
func _refresh_rows() -> void:
	for i in _rows.size():
		_rows[i].kind = SketchButton.Kind.ACCENT if i == _selected else SketchButton.Kind.DARK


func _refresh_now_playing() -> void:
	if _selected < 0 or _selected >= _tracks.size():
		return
	var t: Dictionary = _tracks[_selected]
	_now_title.text = str(t["title"])
	_now_meta.text = "%s · %d BPM · %s · %d 层%s" % [
		_key_label(str(t["key"])), int(round(float(t["bpm"]))),
		_format_time(float(t["duration_s"])), int(t["layer_count"]),
		"" if bool(t["loop"]) else "（短句）",
	]
	_now_lineup.text = "编制　" + _lineup_text(t.get("lineup", []))
	_now_tiers.text = "游戏内强度分层　" + _tier_text(t.get("lineup", []))
	_progress.value = 0.0
	_progress.max_value = maxf(float(t["duration_s"]), 0.001)
	_elapsed_label.text = _format_time(0.0)
	_total_label.text = _format_time(float(t["duration_s"]))
	_refresh_transport()


func _refresh_transport() -> void:
	var playing: bool = MusicDirector.is_previewing() and not _paused
	if _play_button != null:
		_play_button.glyph = SketchDraw.Glyph.PAUSE if playing else SketchDraw.Glyph.PLAY
	if _repeat_button != null:
		_repeat_button.active = _repeat


# ─────────────────────────────── 输入 ────────────────────────────────

## 键盘：空格 播放暂停 · ↑↓ 选曲 · ←→ 上/下一曲 · ESC 返回。
## 本页是独立场景、没有别的输入消费者，命中的键一律消费掉（防误触底层）
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	# 视口先取出来：ESC/返回 会切场景，切完本节点已不在树上、get_viewport() 变 null，
	# 事后拿它 set_input_as_handled 会报 "Cannot call method on a null value"（踩过一次）
	var vp := get_viewport()
	if vp == null:
		return
	match (event as InputEventKey).keycode:
		KEY_ESCAPE:
			_return_to_menu()
		KEY_SPACE:
			_toggle_play()
		KEY_UP:
			_move_selection(-1)
		KEY_DOWN:
			_move_selection(1)
		KEY_LEFT:
			_play_prev()
		KEY_RIGHT:
			_play_next()
		_:
			return
	vp.set_input_as_handled()


## 选曲移动：在播则同时切曲（曲目页惯例——翻曲单就换歌），未播只移动高亮
func _move_selection(step: int) -> void:
	if _tracks.is_empty():
		return
	var idx := wrapi(_selected + step, 0, _tracks.size())
	if MusicDirector.is_previewing():
		_play_track(idx)
		return
	_selected = idx
	_refresh_rows()
	_refresh_now_playing()


func _return_to_menu() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ─────────────────────────────── 文案格式 ────────────────────────────────

## 秒 → m:ss（曲长都是一两分钟，不上 hh）
static func _format_time(sec: float) -> String:
	var s: int = maxi(0, int(round(sec)))
	@warning_ignore("integer_division")
	return "%d:%02d" % [s / 60, s % 60]


## 编制文案：按清单声明序列出乐器中文名（钢琴 · 弦乐 · 钟琴）
static func _lineup_text(lineup: Array) -> String:
	var names: Array[String] = []
	for layer: Dictionary in lineup:
		names.append(str(INSTRUMENT_NAMES.get(str(layer["name"]), layer["name"])))
	return " · ".join(names)


## 强度分层文案：地基 → +常规档 → +点亮档（与游戏内纵向混音同序，见音乐系统 §三）。
## 例：钢琴 → +弦乐 → +钟琴 · 竖琴
static func _tier_text(lineup: Array) -> String:
	var by_tier: Array[Array] = [[], [], []]
	for layer: Dictionary in lineup:
		var tier: int = clampi(int(layer["tier"]), 0, 2)
		by_tier[tier].append(str(INSTRUMENT_NAMES.get(str(layer["name"]), layer["name"])))
	var parts: Array[String] = []
	for tier in 3:
		if by_tier[tier].is_empty():
			continue
		var prefix := "" if tier == 0 else "+"
		parts.append(prefix + " · ".join(by_tier[tier]))
	return " → ".join(parts)


## 清单里的调性写作 "D major" / "B minor"（作曲侧记法），显示成「D 大调」「B 小调」
static func _key_label(raw: String) -> String:
	var parts := raw.split(" ", false)
	if parts.size() < 2:
		return raw
	var mode := "大调" if parts[1].begins_with("maj") else "小调"
	return "%s %s" % [parts[0], mode]
