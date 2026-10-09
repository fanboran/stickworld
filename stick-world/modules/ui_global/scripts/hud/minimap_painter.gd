class_name MinimapPainter
extends RefCounted
## 小地图绘制核 —— 顶部小地图（Minimap）与放大版窗口（MinimapWindow）共用的唯一绘制出口。
##
## 为什么抽出：两处消费者尺寸、配色模式、图例有无都不同，但**世界→小地图的投影
## 与图层顺序必须逐像素一致**（否则"点开放大版看位置"就对不上）。故绘制只此一份，
## 差异走 opts（尺寸 / 配色模式 / 是否画图例 / 是否画视野框）。
##
## 数据来源全在地图侧（map.get_minimap_layout / get_entities），本类只做投影与落笔：
##   - 地表色带、建筑（含实际材质色与功能类型）由地图侧供给（HD-2D 侧见
##     modules/hd2d/scripts/hd2d_minimap_style.gd）；
##   - **类型着色的颜色与图例文案归 UI**（本类，token 取色），地图侧只给类型键——
##     颜色是 UI 语义，不该由地图模块决定。
##
## 单位：世界 px（画布域原点 x=0），与小地图 rect 的像素换算全在此处。

# ─────────────────────────────── 落笔常量 ────────────────────────────────
## 边框宽度（白描边最强档，与 ZoomBar 同质感）
const BORDER_W := 2.0
## 建筑块最小宽/最小纵深（px，基准尺寸下；放大版按 _size_scale 等比）
const BUILDING_MIN_W := 2.0
const BUILDING_MIN_DEPTH := 1.5
## 地表色带最小绘制宽（px）：窄于此不画（防亚像素杂边）
const SURFACE_MIN_W := 1.5
## 实体点半径（此为"基准尺寸"小地图下的值，放大版按 _size_scale 等比放大）
const DOT_R := 2.2
const PLAYER_DOT_R := 3.0
## 设计基准高度（px）：顶部小地图高度——放大版的尺寸倍数以此为参照
const REF_HEIGHT := 120.0
## 玩家光环脉动周期（秒）与最大半径
const HALO_PERIOD := 1.2
const HALO_MAX_R := 6.0
## 视野框线宽
const VIEWPORT_W := 1.5

## 无地表数据时的兜底（单色地面 / 天空）
const SKY_FALLBACK := Color(0.42, 0.62, 0.80, 0.7)
const GROUND_FALLBACK := Color(0.48, 0.68, 0.32, 0.85)

## 配色模式
const MODE_ACTUAL := "actual"   ## 实际颜色（默认）：地表/建筑按世界真实材质色
const MODE_TYPE := "type"       ## 类型着色：按功能类型上色（放大版窗口，配图例）


# ─────────────────────────────── 快照（地图态冻结）────────────────────────────────

## 构建地图态快照。map_info = [map_left, map_right, ground_y, ground_ratio]
## （调用方从 map 上取；与 set_map_info 同源，避免各自读 map 字段）。
static func build_snapshot(map: Node2D, map_info: Array) -> Dictionary:
	var left: float = float(map_info[0])
	var right: float = float(map_info[1])
	var ground_y: float = float(map_info[2])
	var ground_ratio: float = float(map_info[3])
	var ground_bottom: float = ground_y + 1.0
	if map != null and map.has_method("get_ground_bottom"):
		ground_bottom = float(map.get_ground_bottom())
	ground_bottom = maxf(ground_bottom, ground_y + 1.0)
	var layout: Dictionary = {}
	if map != null and map.has_method("get_minimap_layout"):
		layout = map.get_minimap_layout()
	return {
		"map_left": left,
		"map_right": right,
		"map_width": maxf(right - left, 1.0),
		"ground_y": ground_y,
		"ground_bottom": ground_bottom,
		"ground_ratio": clampf(ground_ratio, 0.05, 0.95),
		"surfaces": layout.get("surfaces", []),
		"buildings": layout.get("buildings", []),
	}


## 实体点集（每个绘制帧现取，位置随时变）：[{x, y, faction, player}]
## 阵营判定只认 entity.get_faction()（BattleInstance 分配的 id）与 is_possessed()；
## 玩家自身阵营由调用方经 player_faction_of() 取，用于"敌我"分辨。
static func collect_points(map: Node2D) -> Array:
	var out: Array = []
	if map == null or not map.has_method("get_entities"):
		return out
	for e in map.get_entities():
		if e == null or not is_instance_valid(e) or not e is Node2D:
			continue
		var faction: int = int(e.get_faction()) if e.has_method("get_faction") else 0
		var possessed: bool = e.has_method("is_possessed") and bool(e.is_possessed())
		out.append({
			"x": (e as Node2D).global_position.x,
			"y": (e as Node2D).global_position.y,
			"faction": faction,
			"player": possessed,
		})
	return out


## 本方阵营 id：附身实体所属阵营；无附身（观战/战场看全局）返回 null
static func player_faction_of(points: Array) -> Variant:
	for p: Dictionary in points:
		if bool(p["player"]):
			return int(p["faction"])
	return null


# ─────────────────────────────── 投影（唯一出口）────────────────────────────────

## 世界 X → 小地图 X
static func world_to_x(world_x: float, rect: Rect2, snap: Dictionary) -> float:
	return rect.position.x + (world_x - float(snap["map_left"])) / float(snap["map_width"]) * rect.size.x


## 世界 Y → 小地图 Y：只在地面带内映射（地面带顶 = 天空/地面分界）。
## 站位纵深因此可读（靠后 = 靠上），而非一律钉在分界线上。
static func world_to_y(world_y: float, rect: Rect2, snap: Dictionary) -> float:
	var split: float = ground_split_y(rect, snap)
	var gy: float = float(snap["ground_y"])
	var gb: float = float(snap["ground_bottom"])
	var t: float = clampf((world_y - gy) / maxf(gb - gy, 1.0), 0.0, 1.0)
	return split + t * (rect.end.y - split)


## 地面带像素高 = 画布高 × ground_ratio：与游戏画面同构图（地面占屏比例一致，
## 本作城镇约 57%）。与 Minimap._desired_width 共用同一条：**该像素高代表地图的
## 地面世界深度**，由此定出"世界 px / 小地图 px"，横向同比例尺取宽
## → 横纵比例尺一致，房屋/地块形状不变形（见 tests/unit/test_minimap_layout 的比例尺用例）。
static func ground_band_px(rect: Rect2, snap: Dictionary) -> float:
	return rect.size.y * float(snap["ground_ratio"])


## 天空/地面分界线的 y（小地图坐标）
static func ground_split_y(rect: Rect2, snap: Dictionary) -> float:
	return rect.end.y - ground_band_px(rect, snap)


## 尺寸倍数（相对基准小地图高 120）：放大版里点/线/最小建筑宽按此等比放大，
## 否则同样的 2px 点在大图上显得更小、反而看不清（放大版的意义是"看得更清"）。
static func _size_scale(rect: Rect2) -> float:
	return clampf(rect.size.y / REF_HEIGHT, 1.0, 4.0)


## 小地图 X → 世界 X（点击跳转用）
static func x_to_world(minimap_x: float, rect: Rect2, snap: Dictionary) -> float:
	return (minimap_x - rect.position.x) / maxf(rect.size.x, 1.0) * float(snap["map_width"]) \
			+ float(snap["map_left"])


# ─────────────────────────────── 绘制 ────────────────────────────────

## 全量重放。opts（缺省即默认）：
##   color_mode: MODE_ACTUAL / MODE_TYPE
##   viewport_world: Rect2（相机可视世界范围；空 Rect2 = 不画视野框）
##   halo_phase: float（玩家光环相位 0..1；缺省按引擎时钟自算）
static func draw(ci: CanvasItem, rect: Rect2, snap: Dictionary, points: Array,
		opts: Dictionary = {}) -> void:
	var mode: String = String(opts.get("color_mode", MODE_ACTUAL))
	var split: float = ground_split_y(rect, snap)
	# 1. 天空 + 地面底
	ci.draw_rect(rect, Color(SKY_FALLBACK.r, SKY_FALLBACK.g, SKY_FALLBACK.b, SKY_FALLBACK.a), true)
	ci.draw_rect(Rect2(rect.position.x, split, rect.size.x, rect.end.y - split),
			Color(GROUND_FALLBACK.r, GROUND_FALLBACK.g, GROUND_FALLBACK.b, GROUND_FALLBACK.a), true)
	# 2. 地表材质色带（按地图侧铺设顺序叠色 = 后铺者压前）
	_draw_surfaces(ci, rect, snap, split)
	# 3. 建筑（真占地块，画在地面带上其实际纵深处）
	_draw_buildings(ci, rect, snap, mode)
	# 4. 实体点（玩家 / 同阵营 / 敌方 / 中立）
	_draw_points(ci, rect, snap, points, opts)
	# 5. 视野框
	_draw_viewport(ci, rect, snap, opts)
	# 6. 边框
	ci.draw_rect(rect, StickTokens.BORDER_STRONG, false, BORDER_W)


## 地表色带：两种配色模式都按实际地表色铺——"类型着色"的作用对象是**建筑**
## （功能类型是建筑属性），地面若跟着换色会让人以为地表变了（关掉类型着色的
## 一瞬间"石板路变草地"），反而读错图。
static func _draw_surfaces(ci: CanvasItem, rect: Rect2, snap: Dictionary, split: float) -> void:
	var band := Rect2(rect.position.x, split, rect.size.x, rect.end.y - split)
	for s: Dictionary in snap["surfaces"]:
		var x0: float = world_to_x(float(s["x0"]), rect, snap)
		var x1: float = world_to_x(float(s["x1"]), rect, snap)
		var bx0: float = maxf(x0, band.position.x)
		var bx1: float = minf(x1, band.end.x)
		if bx1 - bx0 < SURFACE_MIN_W:
			continue
		var c: Color = s["color"]
		ci.draw_rect(Rect2(bx0, band.position.y, bx1 - bx0, band.size.y), c, true)


## 建筑：按**真占地**画俯视块（世界宽 × 占地纵深），不画"图标"。
## 立面高在俯视图里没有对应维度，画成图标会让房子看着比实际小得多（曾是小细条
## 贴在天地分界线上、脚下真占地整片空着），也读不出"沿街一排在哪个纵深"。
static func _draw_buildings(ci: CanvasItem, rect: Rect2, snap: Dictionary,
		mode: String) -> void:
	var k: float = _size_scale(rect)
	for b: Dictionary in snap["buildings"]:
		var cx: float = world_to_x(float(b["x"]), rect, snap)
		var w: float = maxf(BUILDING_MIN_W * k,
				float(b["width"]) / float(snap["map_width"]) * rect.size.x)
		if cx + w * 0.5 < rect.position.x or cx - w * 0.5 > rect.end.x:
			continue
		var y_front: float = world_to_y(float(b.get("y", snap["ground_y"])), rect, snap)
		var y_back: float = world_to_y(
				float(b.get("y", snap["ground_y"])) - float(b.get("depth", 0.0)), rect, snap)
		var h: float = maxf(y_front - y_back, BUILDING_MIN_DEPTH * k)
		var c: Color = type_color(String(b.get("type", ""))) if mode == MODE_TYPE \
				else Color(b.get("color", GROUND_FALLBACK))
		ci.draw_rect(Rect2(cx - w * 0.5, y_front - h, w, h), c, true)


static func _draw_points(ci: CanvasItem, rect: Rect2, snap: Dictionary, points: Array,
		opts: Dictionary) -> void:
	var my_faction: Variant = player_faction_of(points)
	var k: float = _size_scale(rect)
	var phase: float = float(opts.get("halo_phase", -1.0))
	if phase < 0.0:
		phase = fmod(Time.get_ticks_msec() / 1000.0, HALO_PERIOD) / HALO_PERIOD
	for p: Dictionary in points:
		var px: float = world_to_x(float(p["x"]), rect, snap)
		var py: float = world_to_y(float(p["y"]), rect, snap)
		if px < rect.position.x - 4.0 or px > rect.end.x + 4.0:
			continue
		if bool(p["player"]):
			# 玩家：实心点 + 呼吸光环（活的位置通用动画语言）
			var halo: Color = StickTokens.SUCCESS
			halo.a = 0.5 * (1.0 - phase)
			var dot_r: float = PLAYER_DOT_R * k
			ci.draw_circle(Vector2(px, py), dot_r + phase * (HALO_MAX_R * k - dot_r), halo)
			ci.draw_circle(Vector2(px, py), dot_r, StickTokens.SUCCESS)
			continue
		ci.draw_circle(Vector2(px, py), DOT_R * k, point_color(int(p["faction"]), my_faction))


## 实体点色。阵营语义与头顶血条同族：1 = 蓝（本方）/ 2 = 红（敌方）/
## 0 = 中立（村民·NPC，土石压暗）。
##
## 敌我判定两种口径：
##   - my_faction 非空（玩家在场）：同阵营 = 蓝、异阵营 = 红；
##   - my_faction 为空（**观战 / 战场看全局**，无附身单位）：退回固定阵营色表
##     ——否则两边都是"非我方"，会各画一片红，敌我不可分（兵力配置读不出来）。
static func point_color(faction: int, my_faction: Variant) -> Color:
	if faction == 0:
		var neutral: Color = StickTokens.content_color(&"stone")
		neutral.a = 0.75
		return neutral
	if my_faction != null:
		return StickTokens.content_color(&"sky_blue") if faction == int(my_faction) \
				else StickTokens.DANGER
	if faction == 1:
		return StickTokens.content_color(&"sky_blue")
	if faction == 2:
		return StickTokens.DANGER
	# 第三方阵营（罕见）：内容色环取色，稳定可辨
	return StickTokens.content_color_at(faction + 3)


static func _draw_viewport(ci: CanvasItem, rect: Rect2, snap: Dictionary,
		opts: Dictionary) -> void:
	var vp_world: Rect2 = opts.get("viewport_world", Rect2())
	if vp_world.size.x <= 0.0:
		return
	var vp_x: float = world_to_x(vp_world.position.x, rect, snap)
	var vp_w: float = vp_world.size.x / float(snap["map_width"]) * rect.size.x
	var r := Rect2(vp_x, rect.position.y, vp_w, rect.size.y).intersection(rect)
	if r.size.x <= 0.0:
		return
	ci.draw_rect(r, Color(StickTokens.DANGER, 0.85), false, VIEWPORT_W * _size_scale(rect))


# ─────────────────────────────── 类型着色（UI 侧语义）────────────────────────────────

## 功能类型 → 颜色（token 取色）。键口径与 Hd2dMinimapStyle.type_for 约定一致
## （该文件是类型键的唯一产出方；本表未收录的键回退 clay，不崩）。
static func type_color(key: String) -> Color:
	if key == "residential":
		return StickTokens.content_color(&"wood")
	if key == "production":
		return StickTokens.content_color(&"umber")
	if key == "commercial":
		return StickTokens.content_color(&"amber")
	if key == "civic":
		return StickTokens.content_color(&"stone")
	if key == "military":
		return StickTokens.content_color(&"iron")
	return StickTokens.content_color(&"clay")


## 类型键 → 图例文案（放大版窗口图例用；顺序即图例顺序）
const TYPE_LEGEND: Array = [
	["residential", "居住"],
	["production", "生产"],
	["commercial", "商业"],
	["civic", "市政"],
	["military", "军事"],
]

## 图例整体高度（放大版窗口预留，供窗口布局计算）
const LEGEND_ROW_H := 16.0


static func legend_height() -> float:
	return LEGEND_ROW_H * TYPE_LEGEND.size()


## 画图例（origin = 左上角）。色块 + 文案竖排
static func draw_legend(ci: CanvasItem, origin: Vector2, font: Font, font_size: int = 12) -> void:
	var y: float = origin.y
	for row: Array in TYPE_LEGEND:
		var c: Color = type_color(String(row[0]))
		ci.draw_rect(Rect2(origin.x, y + 2.0, 10.0, 10.0), c, true)
		ci.draw_string(font, Vector2(origin.x + 16.0, y + 11.0), String(row[1]),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.92, 0.93, 0.96))
		y += LEGEND_ROW_H
