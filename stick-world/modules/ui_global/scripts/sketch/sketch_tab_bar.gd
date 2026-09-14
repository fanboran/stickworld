class_name SketchTabBar
extends TabBar
## 手绘涂鸦页签（独立 TabBar 版）—— 引擎画页签底色与文字（主题玻璃 Flat），
## boiling 描边 + 选中琥珀下划线由 _draw() 叠加（SketchTabContainer 同源）。
##
## 用途：页签作"过滤器/切换器"（切换同一内容区的显示，无独立页面）时用本控件，
## 如组织面板树过滤器、战略总览报表过滤；多页面板仍用 SketchTabContainer。
## 选中态琥珀只上底不上字（§1.5）：字走主题白色，选中 = 琥珀马克笔底线。

var _seed: int = 0
var _timer: float = 0.0
## 悬停页签索引（tab_hovered 信号维护）
var _hover: int = -1


func _ready() -> void:
	_seed = randi()
	resized.connect(queue_redraw)
	tab_changed.connect(func(_i: int) -> void: queue_redraw())
	tab_selected.connect(func(_i: int) -> void: queue_redraw())
	tab_hovered.connect(func(i: int) -> void:
		_hover = i
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hover = -1
		queue_redraw())


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	# boiling：与血条/面板同节拍重掷相位
	_timer += delta
	if _timer >= SketchDraw.WOBBLE_INTERVAL:
		_timer = 0.0
		_seed = randi()
		queue_redraw()


func _draw() -> void:
	for i in tab_count:
		if is_tab_hidden(i) or is_tab_disabled(i):
			continue
		var r := get_tab_rect(i)
		if r.size.x < 2.0:
			continue
		var selected := i == current_tab
		# 描边：选中/悬停强描边，未选淡描边（手绘页签轮廓感）
		var outline: Color = StickTokens.BORDER_STRONG \
				if (selected or i == _hover) else StickTokens.BORDER
		SketchDraw.draw_panel(self, r, _seed + i * 17, Color.TRANSPARENT,
				outline, SketchDraw.OUTLINE_WIDTH, 5.0)
		# 选中态：琥珀马克笔底线（只上底不上字），圆头收笔
		if selected:
			var y: float = r.end.y - 0.75
			var from := Vector2(r.position.x + 2.5, y)
			var to := Vector2(r.end.x - 2.5, y)
			SketchDraw.draw_wavy_line(self, from, to, _seed + 53,
					Color(StickTokens.ACCENT, 0.95), 2.4)
			draw_circle(from, 1.2, Color(StickTokens.ACCENT, 0.95))
			draw_circle(to, 1.2, Color(StickTokens.ACCENT, 0.95))
