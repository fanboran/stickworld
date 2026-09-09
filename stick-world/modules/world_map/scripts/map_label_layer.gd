class_name MapLabelLayer
extends Node2D
## 地图标注层（观感返工 §R8 层3）—— 三级标注（国名/地区名/城市）+ 都城星标，
## 挂在各视图渲染器（L3MapRenderer/L2MapRenderer/MapRenderer）子节点，随视图开关。
##
## 规范来源（§7.3-3 标注两步法 / §7.3-6 规范表）：
##   - 字号分级：国名 18px Bold（中文无大写，以字距 15%/字重表达）> 地区名 14px
##     > 首都 13px Bold > 城市 12px（相邻档差 ≥2pt）；尺寸屏幕像素口径（÷zoom 换算）
##   - halo：字号 1/6~1/5 clamp 1.5~2.5px，描边式四向偏移；政治模式彩色底 = 墨白字 +
##     深墨 halo，L1 浅色地形底 = 暖墨字 + 白 halo
##   - 字体 = StickHand（SketchFonts，与游戏 UI 同源；禁止 fallback 字体）
##   - 缩放显隐阈值（r = zoom / 视图适配 zoom，OSM carto z3/z5/z6 思路按三级视图定标）：
##       L3 国名 r≤6 / 都城星标恒显；L2 地区名 r≤6 / 重镇名 r≥1.2 / 首都恒显；
##       L1 城市名 r≥0.55 / 首都恒显
##   - 防压盖：同屏候选按优先级（首都 > 国名 > 地区 > 重镇/城市）贪心避让——
##     get_string_size 碰撞盒 + 锚点四向候选（右>上>下>左，Axis Maps 简化版），
##     全碰撞时首都兜底右锚强显、其余丢弃
##   - 都城星标：外接圆直径 8px 简洁矢量五星（规范表「首都 8px 星标」；固定 seed
##     微转角，手绘感不沸腾），金 = CONTENT_PALETTE[9]（顶级聚落语义，同 T5 描边）
##
## 数据源：L3 = l3_city.json（80 国 name/capital + 1040 城块 centroid/area）；
## L2 = l2_world.json（region_id + cities[level] + states.capital）；L1 = 包内
## settlement name（「城市N」占位照画）。L3/L2 标注是政治语义 → 仅 POLITICAL 模式
## 显示（国名/都城随政权走）；L1 城市名/星标是聚落语义 → 全模式显示。

## 视图适配 zoom 的竖向占比提示（层自算 fit zoom = 视口高 × hint / 地图跨度；
## 只影响显隐阈值的比例定标，粗对齐各控制器 open() 的适配口径即可）
const FIT_HINT_L3 := 0.88   # (视口高 − 上下海洋边距) / 地图高 ≈ 0.88
const FIT_HINT_L2 := 0.72   # l2 控制器 target_h = 视口高 × 0.72
const FIT_HINT_L1 := 0.85   # l1 控制器 target_h = 视口高 × 0.85

enum Tier { COUNTRY, REGION, CAPITAL, TOWN, CITY }

var _camera: MapCamera = null
var _items: Array[Dictionary] = []
var _stars: Array[Dictionary] = []
## true = 标注是政治语义（L3/L2），仅 POLITICAL 模式绘制；false = 全模式（L1）
var _political_only: bool = false
## 地图跨度（map 单位）+ 适配占比 hint → fit zoom
var _map_extent: float = 1.0
var _fit_hint: float = 0.85

## 相机状态缓存（zoom/offset/模式变化才重绘；拖拽/缩放由本层自轮询——
## MapCamera._notify_renderer 只通知注册的渲染器，不通知子层）
var _last_cam := Vector3.INF
var _last_political := false

var _font_reg: Font = null
var _font_bold: Font = null


func _ready() -> void:
	_font_reg = SketchFonts.hand()
	_font_bold = SketchFonts.bold()


func set_camera(camera: MapCamera) -> void:
	_camera = camera


## ===== 数据装配（set_data 时由各渲染器调用；换数据重复调用即全量重建）=====

## L3 大世界：80 国国名（面积加权质心）+ 每国都城星标（l3_city 城块数据）
func setup_l3(data: L3WorldData) -> void:
	_clear()
	_political_only = true
	_fit_hint = FIT_HINT_L3
	if data == null:
		return
	_map_extent = float(maxi(data.size, 1))
	# 城块扫描：首都 id → 质心；政权 → 面积加权质心
	# （l3_city 的 centroid/anchor 实测为 [x,y] 序——与城块多边形 [y,x] 惯例相反，
	#  已按 bbox 对拍核实；勿与 L2 tile centroid 的 [y,x] 混淆）
	var acc: Dictionary = {}    # state_id -> {x, y, a}
	var cap_pos: Dictionary = {}  # settlement_city_XXX -> Vector2
	for t in data.city_tiles:
		var td: Dictionary = t
		var label: int = int(td.get("label", 0))
		if label <= 0:
			continue
		var c: Array = td.get("centroid", [])
		if c.size() < 2:
			continue
		var pos := Vector2(float(c[0]), float(c[1]))
		var city_id := "settlement_city_%03d" % label
		cap_pos[city_id] = pos
		var owner := str(td.get("state_id", ""))
		if owner.is_empty():
			continue
		var area: float = maxf(float(td.get("area_px", 1.0)), 1.0)
		var e: Dictionary = acc.get(owner, {"x": 0.0, "y": 0.0, "a": 0.0})
		e["x"] += pos.x * area
		e["y"] += pos.y * area
		e["a"] += area
		acc[owner] = e
	for st_id in data.states:
		var info: Dictionary = data.states[st_id]
		var sname := str(info.get("name", ""))
		var n_cities := int(info.get("n_cities", 0))
		if not sname.is_empty() and acc.has(st_id):
			var e: Dictionary = acc[st_id]
			if float(e["a"]) > 0.0:
				# 国名锚点 = 领土面积加权质心；国内排序按城数（大国有先占权）
				_items.append({
					"tier": Tier.COUNTRY, "text": sname,
					"pos": Vector2(float(e["x"]) / float(e["a"]), float(e["y"]) / float(e["a"])),
					"sort": 10.0 - float(n_cities) * 0.001, "style": "map",
				})
		var cap := str(info.get("capital", ""))
		if cap_pos.has(cap):
			_stars.append({"pos": cap_pos[cap], "id": cap})


## L2 地区视图：本区 + 邻区地区名 / 都城星标+名 / 重镇名（level 3）
func setup_l2(data: L2WorldData) -> void:
	_clear()
	_political_only = true
	_fit_hint = FIT_HINT_L2
	if data == null:
		return
	_map_extent = float(maxi(maxi(data.context_size.x, data.context_size.y), 1))
	# 当前地区名（region_XXX 无 name 数据 → 「地区 N」，与名牌/粒度指示同一口径）：
	# 锚点 = 本区各地块质心均值（L2 tile centroid 为 [y,x] 序，渲染惯例 c[1],c[0]）
	var region_title := data.region_id
	if region_title.begins_with("region_") and region_title.substr(7).is_valid_int():
		region_title = "地区 %d" % region_title.substr(7).to_int()
	if not data.tiles.is_empty():
		var sx := 0.0
		var sy := 0.0
		var n := 0
		for t in data.tiles:
			var c: Array = t.get("centroid", [])
			if c.size() < 2:
				continue
			sx += float(c[1])
			sy += float(c[0])
			n += 1
		if n > 0:
			_items.append({
				"tier": Tier.REGION, "text": region_title,
				"pos": Vector2(sx / float(n), sy / float(n)),
				"sort": 20.0, "style": "map",
			})
	# 邻区名（灰色扩展区方位标识，优先级低于本区）
	for nb in data.neighbors:
		var nd: Dictionary = nb
		var gl: int = int(nd.get("label", 0))
		if gl <= 0:
			continue
		var cpos := _polygons_bbox_center(nd.get("polygons", [nd.get("polygon", [])]))
		if cpos != Vector2.INF:
			_items.append({
				"tier": Tier.REGION, "text": "地区 %d" % gl,
				"pos": cpos, "sort": 21.0, "style": "map",
			})
	# 都城（星 + 名）与重镇（level 3 名）：本区 cities 已是区内城市
	# （城市名数据端还没有——settlement_city_XXX → 「城市 N」占位，照画）
	var caps: Dictionary = {}
	for s in data.states.values():
		var info: Dictionary = s
		caps[str(info.get("capital", ""))] = true
	for c in data.cities:
		var cd: Dictionary = c
		var city_id := str(cd.get("id", ""))
		var pos_v: Variant = cd.get("pos")
		if city_id.is_empty() or not (pos_v is Vector2):
			continue
		var pos := pos_v as Vector2
		if caps.has(city_id):
			_stars.append({"pos": pos, "id": city_id})
			_items.append({
				"tier": Tier.CAPITAL, "text": _city_display_name(city_id),
				"pos": pos, "sort": 0.0, "style": "map",
			})
		elif int(cd.get("level", 1)) >= 3:
			_items.append({
				"tier": Tier.TOWN, "text": _city_display_name(city_id),
				"pos": pos, "sort": 30.0, "style": "map",
			})


## L1 地块视图：聚落名（包内「城市N」占位照画）+ 都城星标（capital_settlement_id）
func setup_l1(data: L1WorldData) -> void:
	_clear()
	_political_only = false  # 聚落语义，全模式可见
	_fit_hint = FIT_HINT_L1
	if data == null:
		return
	_map_extent = float(maxi(data.context_size.y if data.context_size.y > 0 else data.size, 1))
	var caps: Dictionary = {}
	for st_id in data.states:
		var info: Dictionary = data.states[st_id]
		caps[str(info.get("capital_settlement_id", ""))] = true
	for tile in data.tiles:
		if tile.settlement == null:
			continue
		var is_cap := caps.has(tile.settlement.settlement_id)
		var sname := tile.settlement.name
		if sname.is_empty():
			sname = _city_display_name(tile.settlement.settlement_id)
		if is_cap:
			_stars.append({"pos": tile.settlement.position, "id": tile.settlement.settlement_id})
		_items.append({
			"tier": Tier.CAPITAL if is_cap else Tier.CITY,
			"text": sname, "pos": tile.settlement.position,
			"sort": 0.0 if is_cap else 25.0, "style": "paper",
		})


func _clear() -> void:
	_items.clear()
	_stars.clear()
	_last_cam = Vector3.INF
	queue_redraw()


## settlement_city_057 → 「城市 57」（数据端城市名未定稿的占位显示，与 L1 包内
## 「城市N」占位同语言；正式名落地后此处换数据源即可）
func _city_display_name(city_id: String) -> String:
	var parts := city_id.split("_")
	if parts.size() >= 3 and parts[2].is_valid_int():
		return "城市 %d" % parts[2].to_int()
	return city_id


## ===== 相机轮询 =====

func _process(_delta: float) -> void:
	if not visible or (_items.is_empty() and _stars.is_empty()):
		return
	var political := not _political_only \
			or MapModeManager.current_mode == MapModeManager.Mode.POLITICAL
	if political != _last_political:
		_last_political = political
		queue_redraw()
	if not political:
		return
	var z := 1.0
	var off := Vector2.ZERO
	if _camera != null:
		z = _camera.get_zoom()
		off = _camera.get_offset()
	var key := Vector3(z, off.x, off.y)
	if key != _last_cam:
		_last_cam = key
		queue_redraw()


## ===== 绘制 =====

func _draw() -> void:
	if _items.is_empty() and _stars.is_empty():
		return
	if _political_only and MapModeManager.current_mode != MapModeManager.Mode.POLITICAL:
		return
	var z := 1.0
	var off := Vector2.ZERO
	if _camera != null:
		z = _camera.get_zoom()
		off = _camera.get_offset()
	if z <= 0.0001:
		z = 0.0001
	var vp := get_viewport()
	var vp_size := Vector2(1920, 1080)
	if vp != null:
		vp_size = vp.get_visible_rect().size
	# 可视域（地图坐标）：S = offset + M×zoom → M = (S − offset)/zoom
	var view := Rect2(-off / z, vp_size / z).grow(_map_extent * 0.05)
	var occupied: Array[Rect2] = []
	# 1. 都城星标占位进碰撞集（文字盒及其 halo 不压星；星本体最后画，压不住）
	var star_r := MapTokens.LABEL_STAR_SIZE * 0.5 / z
	for st in _stars:
		var sp: Vector2 = st["pos"]
		if not view.has_point(sp):
			continue
		var sr := star_r + MapTokens.LABEL_COLLIDE_PAD / z
		occupied.append(Rect2(sp - Vector2(sr, sr), Vector2(sr, sr) * 2.0))
	# 2. 标注候选：阈值过滤 + 视口裁剪 + 优先级排序（sort 小者先落位）
	var cands: Array[Dictionary] = []
	var ratio := _zoom_ratio(z, vp_size)
	for item in _items:
		if not _tier_visible(item["tier"], ratio):
			continue
		if not view.has_point(item["pos"]):
			continue
		cands.append(item)
	cands.sort_custom(func(a, b): return float(a["sort"]) < float(b["sort"]))
	for item in cands:
		_draw_label(item, z, occupied)
	# 3. 都城星标最后画（压在标签 halo 之上，任何情况下都是清晰的完整星形）
	for st in _stars:
		var sp: Vector2 = st["pos"]
		if not view.has_point(sp):
			continue
		_draw_star(sp, star_r, MapSketch.id_seed(str(st["id"])), z)


## 显隐阈值表（r = zoom / 视图适配 zoom；MapTokens.LABEL_ZOOM_*）：
## 首都恒显；国名/地区名上限；重镇/城市下限
func _tier_visible(tier: int, r: float) -> bool:
	match tier:
		Tier.COUNTRY:
			return r <= MapTokens.LABEL_ZOOM_COUNTRY_MAX
		Tier.REGION:
			return r <= MapTokens.LABEL_ZOOM_REGION_MAX
		Tier.TOWN:
			return r >= MapTokens.LABEL_ZOOM_TOWN_MIN
		Tier.CITY:
			return r >= MapTokens.LABEL_ZOOM_CITY_MIN
		_:
			return true  # CAPITAL


## 视图适配 zoom = 视口高 × hint / 地图跨度（与各控制器 open() 的整图适配口径粗对齐）
func _zoom_ratio(z: float, vp_size: Vector2) -> float:
	var fit := _fit_hint * vp_size.y / maxf(_map_extent, 1.0)
	return z / fit if fit > 0.0001 else 1.0


## 单条标注：按锚点候选序（面标注居中单候选 / 点标注 右>上>下>左）贪心避让，
## 全碰撞时首都兜底右锚强显、其余丢弃。halo = 四向偏移描边（字号 1/6~1/5 clamp）。
func _draw_label(item: Dictionary, z: float, occupied: Array[Rect2]) -> void:
	var tier: int = item["tier"]
	var bold := tier == Tier.COUNTRY or tier == Tier.CAPITAL
	var font := _font_bold if bold else _font_reg
	if font == null:
		return
	var fs_px := _tier_font_size(tier)
	var fs := fs_px / z  # 屏幕像素 → 地图单位（本层随渲染器被相机缩放）
	var text: String = item["text"]
	var pos: Vector2 = item["pos"]
	var tracking := fs * MapTokens.LABEL_COUNTRY_TRACKING if tier == Tier.COUNTRY else 0.0
	var text_w := _spaced_width(font, text, fs, tracking)
	var line_h := font.get_height(fs)
	var ascent := font.get_ascent(fs)
	var ink: Color = MapTokens.LABEL_INK_MAP if item["style"] == "map" else MapTokens.LABEL_INK_CITY
	var halo: Color = MapTokens.LABEL_HALO_DARK if item["style"] == "map" else MapTokens.LABEL_HALO_WHITE
	var gap := MapTokens.LABEL_ANCHOR_GAP / z
	# halo 宽：屏幕像素口径 clamp（字号 1/6~1/5，1.5~2.5px）再 ÷zoom 成地图单位——
	# clamp 必须发生在屏幕尺度，否则远 zoom 时 halo 被放大/吃掉
	var halo_w := clampf(fs_px * 0.18, MapTokens.LABEL_HALO_MIN, MapTokens.LABEL_HALO_MAX) / z
	# 锚点候选（文字盒左上角相对锚点）；面标注（国名/地区名）按制图惯例居中单候选。
	# 点标注首候选「右」：都城须让出星标半径（星最后画，但文字盒先让位不与之重叠）
	var anchors: Array[Vector2] = [Vector2(-text_w * 0.5, -line_h * 0.5)]
	if tier != Tier.COUNTRY and tier != Tier.REGION:
		var lead := gap
		if tier == Tier.CAPITAL:
			lead = MapTokens.LABEL_STAR_SIZE * 0.5 / z + gap
		anchors = [
			Vector2(lead, -line_h * 0.5),           # 右（都城：星缘之外）
			Vector2(-text_w * 0.5, -line_h - gap),  # 上
			Vector2(-text_w * 0.5, gap),            # 下
			Vector2(-text_w - gap, -line_h * 0.5),  # 左
		]
	var pad := MapTokens.LABEL_COLLIDE_PAD / z
	var chosen := -1
	var chosen_rect := Rect2()
	for i in anchors.size():
		var rect := Rect2(pos + anchors[i], Vector2(text_w, line_h)).grow(pad)
		var hit := false
		for o in occupied:
			if rect.intersects(o):
				hit = true
				break
		if not hit:
			chosen = i
			chosen_rect = rect
			break
	if chosen < 0:
		if tier != Tier.CAPITAL:
			return  # 让位：非首都标注全碰撞即丢弃（贪心避让）
		chosen = 0  # 首都兜底右锚强显（永不静默）
		chosen_rect = Rect2(pos + anchors[0], Vector2(text_w, line_h)).grow(pad)
	occupied.append(chosen_rect)
	# 绘制原点 = 文字盒左上 + 基线偏移；国名走逐字距绘制
	var origin := chosen_rect.position + Vector2(-pad, -pad) + Vector2(0.0, ascent)
	if tracking > 0.0:
		_draw_spaced(font, text, origin, fs, tracking, halo_w, halo, ink)
	else:
		_draw_halo_string(font, text, origin, fs, halo_w, halo, ink)


## 四向偏移 halo + 主文（描边式白/深 halo，§7.3-3）；halo_w 已是地图单位
func _draw_halo_string(font: Font, text: String, pos: Vector2, fs: float, halo_w: float,
		halo: Color, ink: Color) -> void:
	for off in [Vector2(-halo_w, 0), Vector2(halo_w, 0), Vector2(0, -halo_w), Vector2(0, halo_w)]:
		draw_string(font, pos + off, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, halo)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


## 国名逐字绘制（字距 15%——中文无大写，以字距/字重表达层级）
func _draw_spaced(font: Font, text: String, pos: Vector2, fs: float, tracking: float,
		halo_w: float, halo: Color, ink: Color) -> void:
	var cursor := pos
	for ch in text:
		for off in [Vector2(-halo_w, 0), Vector2(halo_w, 0), Vector2(0, -halo_w), Vector2(0, halo_w)]:
			draw_string(font, cursor + off, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, halo)
		draw_string(font, cursor, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)
		cursor.x += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + tracking


## 含字距的文本总宽（碰撞盒口径，与 _draw_spaced 推进一致）
func _spaced_width(font: Font, text: String, fs: float, tracking: float) -> float:
	if tracking <= 0.0:
		return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var w := 0.0
	for i in text.length():
		w += font.get_string_size(text[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if i < text.length() - 1:
			w += tracking
	return w


func _tier_font_size(tier: int) -> float:
	match tier:
		Tier.COUNTRY:
			return MapTokens.LABEL_SIZE_COUNTRY
		Tier.REGION:
			return MapTokens.LABEL_SIZE_REGION
		Tier.CAPITAL:
			return MapTokens.LABEL_SIZE_CAPITAL
		_:
			return MapTokens.LABEL_SIZE_CITY


## 都城星标：外接圆直径 8px 简洁矢量五星（规范表），固定 seed 微转角（手绘感
## 不沸腾——星标是静态符号，不做 boiling）；金填充 + 墨描边
func _draw_star(center: Vector2, outer_r: float, seed: int, z: float) -> void:
	if outer_r <= 0.0001:
		return
	var rot := fposmod(float(seed) * 0.6180339887, 1.0) * 0.24 - 0.12
	var pts := PackedVector2Array()
	pts.resize(10)
	for i in 10:
		var ang := rot - PI * 0.5 + TAU * float(i) / 10.0
		var rr := outer_r if i % 2 == 0 else outer_r * 0.42
		pts[i] = center + Vector2(cos(ang), sin(ang)) * rr
	draw_colored_polygon(pts, MapTokens.LABEL_STAR_FILL)
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, MapTokens.LABEL_STAR_OUTLINE, 1.2 / z, true)


## 多边形组（Vector2 / [y,x] 数组两态兼容）的包围盒中心；空/无效返回 Vector2.INF
func _polygons_bbox_center(polys: Variant) -> Vector2:
	var mn := Vector2.INF
	var mx := -Vector2.INF
	if not (polys is Array):
		return Vector2.INF
	for poly in polys:
		if not (poly is Array or poly is PackedVector2Array):
			continue
		for pp in poly:
			var p: Vector2 = pp if pp is Vector2 else Vector2(float(pp[1]), float(pp[0]))
			mn = mn.min(p)
			mx = mx.max(p)
	if mn == Vector2.INF or mx == Vector2.INF:
		return Vector2.INF
	return (mn + mx) * 0.5
