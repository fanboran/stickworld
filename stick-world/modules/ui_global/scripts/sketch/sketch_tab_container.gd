class_name SketchTabContainer
extends TabContainer
## 手绘涂鸦页签 —— 引擎画页签底色与文字（主题玻璃 Flat），
## boiling 描边 + 选中琥珀下划线由 _draw() 叠加（血条同源 boiling）。
##
## 层级说明：TabBar 是 TabContainer 的子控件，其绘制（底色/文字）叠在本控件
## _draw 之上——主题页签底全是低透明/全透明色，自绘描边透出不受遮盖。
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
	var tb := get_tab_bar()
	if tb == null:
		return
	var base: Vector2 = tb.position  # TabBar 子控件在 TabContainer 内的偏移
	for i in get_tab_count():
		if is_tab_hidden(i):
			continue
		var r := tb.get_tab_rect(i)
		r.position += base
		if r.size.x < 2.0:
			continue
		var disabled := is_tab_disabled(i)
		var selected := i == current_tab
		if disabled:
			continue
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
