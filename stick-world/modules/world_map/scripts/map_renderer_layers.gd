extends RefCounted
## MapRenderer 交互叠加层绘制件（全 static；第一参传宿主 h = Node2D 画布，
## FlowOutline 传 canvas 同款先例；不写 class_name 防全局类循环引用）。
## 宿主 _draw 按层序号逐层调用，本文件只读宿主状态、不写。
##
## 子域：快速旅行路由高亮（1.6 层）/ 邻居空心轮廓（4.5 层）/ 城市中心点（6.5 层）/
## F3 城市编号（8 层）/ 玩家位置标记（9 层）。
## 线宽/色 token 真相源在宿主 MapTokens 别名层（经 h 取用），
## 本文件零新增色值字面量（与拆分前逐行等价）。


## 快速旅行路由高亮（P6）：途经道路琥珀虚线加粗 + 节点空心圆（全模式——
## UI 操作语义的虚线，§7.2-4；水系之上连续可见）。
## R8 层2：操作线 = ACCENT。feedback1 去抖动：平滑直绘（虚线切段保留）
static func draw_route_highlight(h, ctx_size: Vector2, zz: float) -> void:
	if h._route_road_pts.is_empty():
		return
	var rw: float = maxf(ctx_size.x * h.ROUTE_HIGHLIGHT_WIDTH, 2.0)
	var dash_segs := PackedVector2Array()
	for ri in h._route_road_pts.size():
		MapSketch.dash_segments(dash_segs, h._route_road_pts[ri],
			ctx_size.x * h.ROUTE_DASH, ctx_size.x * h.ROUTE_GAP)
	if dash_segs.size() >= 2:
		h.draw_multiline(dash_segs, h.ROUTE_HIGHLIGHT_COLOR, rw, true)
	var nr: float = h.ROUTE_NODE_RADIUS
	if zz > 0.0001:
		nr = h.ROUTE_NODE_RADIUS / zz
	for pos in h._route_nodes:
		h.draw_arc(pos, nr, 0.0, TAU, 48, Color.WHITE, maxf(rw * 0.35, 1.0), true)


## 邻居老 L1 块空心描边（A3：只描边不填充；屏幕像素固定）
static func draw_neighbor_outlines(h, zz: float) -> void:
	var nbw: float = h.NEIGHBOR_BORDER_WIDTH
	if zz > 0.0001:
		nbw = h.NEIGHBOR_BORDER_WIDTH / zz
	for outline in h._cached_neighbor_outlines:
		h.draw_polyline(outline, h.NEIGHBOR_COLOR, nbw, true)


## 城市中心标记点（小圆点 + 细环，屏幕像素固定——半径和环宽都随缩放换算成地图单位，
## 放大环不遮白点、缩小环不消失；粗细保持屏幕一致）
static func draw_city_dots(h, zz: float) -> void:
	var dot_r: float = h.CITY_DOT_RADIUS
	var ring_w: float = h.CITY_DOT_RING_WIDTH
	if zz > 0.0001:
		dot_r = h.CITY_DOT_RADIUS / zz
		ring_w = h.CITY_DOT_RING_WIDTH / zz
	for tile in h._data.tiles:
		if tile.settlement == null:
			continue
		h.draw_circle(tile.settlement.position, dot_r, h.CITY_DOT_COLOR)
		h.draw_arc(tile.settlement.position, dot_r, 0.0, TAU, 48, h.CITY_DOT_RING, ring_w, true)


## F3 调试：给城市打编号（屏幕恒定字号，不随缩放放大成大字）。
## 字体归正（R8 层3）：StickHand 与全游戏 UI 同源，不用 fallback 字体
static func draw_city_labels(h) -> void:
	var font := SketchFonts.hand()
	if font == null:
		return
	var zz: float = 1.0
	if h._camera != null and h._camera.has_method("get_zoom"):
		zz = h._camera.get_zoom()
	var fs: float = h.LABEL_SIZE
	if zz > 0.0001:
		# 原生渲染：固定地图单元字号（随地图缩放，默认整图适配即可见、大小合适）。
		# 不再 ÷ 缩放——曾让局部字号过小（如 2.6 地图单元）导致 Godot 渲染消失；
		# 仅高缩放时按屏幕像素上限封顶，防"雷霆大字"。
		fs = minf(h.LABEL_SIZE, h.LABEL_SCREEN_CAP / zz)
	var halo: float = maxf(1.5, fs * 0.12)
	for tile in h._data.tiles:
		if tile.settlement == null:
			continue
		var num := city_num_from_tile_id(tile.tile_id)
		if num.is_empty():
			continue
		var pos := tile.settlement.position
		var txt := "L1城#" + num
		h.draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			maxi(1, roundi(halo)), h.LABEL_BG)
		h.draw_string(font, pos + Vector2(2.0, -fs * 0.35), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, h.LABEL_COLOR)


## 从 tile_id（"city_2082"）解析城市编号
static func city_num_from_tile_id(tile_id: String) -> String:
	var prefix := "city_"
	if tile_id.begins_with(prefix):
		return tile_id.substr(prefix.length())
	return tile_id


## 玩家位置标记（R2，替代拟物图钉；feedback1 去抖动：环回平滑 draw_arc）：
## 中心 4px 玩家国色点（白描边）+ 12px 静态细环（白，半透明）
## + 1.5s 周期脉冲扩散环（12→36px alpha 0.5→0，玩家国色）。全部屏幕像素固定。
static func draw_player_marker(h, zz: float) -> void:
	var dot_r: float = h.PLAYER_DOT_RADIUS
	var dot_ow: float = h.PLAYER_DOT_OUTLINE_W
	var ring_r: float = h.PLAYER_RING_RADIUS
	var ring_w: float = h.PLAYER_RING_WIDTH
	var p_from: float = h.PLAYER_PULSE_FROM
	var p_to: float = h.PLAYER_PULSE_TO
	if zz > 0.0001:
		dot_r /= zz
		dot_ow /= zz
		ring_r /= zz
		ring_w /= zz
		p_from /= zz
		p_to /= zz
	# 静态细环（白，半透明度略降避免喧宾夺主）
	h.draw_arc(h._player_pos, ring_r, 0.0, TAU, 64, MapTokens.L1_PLAYER_RING_COLOR, ring_w, true)
	# 脉冲扩散环：0→1 相位，半径 12→36px、alpha 0.5→0，玩家国色
	var t: float = fmod(h._pulse_time, h.PLAYER_PULSE_PERIOD) / h.PLAYER_PULSE_PERIOD
	var pa: float = lerpf(h.PLAYER_PULSE_ALPHA, 0.0, t)
	if pa > 0.01:
		h.draw_arc(h._player_pos, lerpf(p_from, p_to, t), 0.0, TAU, 64,
			Color(h._player_state_color, pa), ring_w, true)
	# 中心点：玩家国色填充 + 白描边
	h.draw_circle(h._player_pos, dot_r, h._player_state_color)
	h.draw_arc(h._player_pos, dot_r, 0.0, TAU, 48, Color.WHITE, dot_ow, true)
