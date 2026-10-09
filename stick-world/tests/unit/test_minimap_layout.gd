extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：小地图数据供给与投影（小地图优化与细化）
##
## 覆盖三件"改了会静默出错"的事：
##   ① 投影数学：世界↔小地图 X/Y 往返、边界钳制（放大版与小地图共用此核，
##      算错 = 两处点位对不上或点位跑到画面外）；
##   ② 建筑 def → 类型/材质色的登记完整性：**核对 cards.json 实际卡表**，
##      新卡未登记就落到兜底色 = 小地图上多一个灰点而没人发现；
##   ③ 类型键 ↔ UI 图例的覆盖：新增功能类型未配图例 = 图例缺项。
##
## 依赖用 const preload，不依赖 class_name 全局注册（headless 下不可靠）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const StyleScript := preload("res://modules/hd2d/scripts/hd2d_minimap_style.gd")
const PainterScript := preload("res://modules/ui_global/scripts/hud/minimap_painter.gd")
const ZoneScript := preload("res://modules/ui_global/scripts/hud/hud_zone_layout.gd")
const MapBaseScript := preload("res://modules/world/scripts/map/map_base.gd")

## HD-2D 卡表（管线烘卡清单，新卡加进来必须同步登记样式）
const CARDS_JSON := "res://modules/hd2d/assets/tex/proto25d/cards.json"

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("投影: 世界X→小地图X 线性且端点对齐", _test_world_to_x)
	_runner.add_test("投影: 世界Y 落在地面带内（靠后=靠上）", _test_world_to_y)
	_runner.add_test("投影: X 往返可逆", _test_x_round_trip)
	_runner.add_test("投影: Y 越出地面带被钳制", _test_y_clamp)
	_runner.add_test("样式: 已知 def 的类型与材质色", _test_style_known)
	_runner.add_test("样式: 未登记 def 走兜底不崩", _test_style_fallback)
	_runner.add_test("样式: cards.json 全部卡 def 已登记", _test_style_covers_cards)
	_runner.add_test("样式: 每种功能类型都有图例项或为兜底", _test_legend_covers_types)
	_runner.add_test("跨度: top_center 保留区落在顶栏空档内", _test_zone_span)
	_runner.add_test("跨度: 最大宽度随画布收紧且不超空档", _test_max_width)
	_runner.add_test("供给: 基类默认布局为空（HD-2D 覆写）", _test_base_layout_empty)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 夹具 ────────────────────────────────

## 合成快照：地图 x∈[-1000,1000]、地面带 y∈[0,1000]、地面占画布 50%
func _snap() -> Dictionary:
	return {
		"map_left": -1000.0, "map_right": 1000.0, "map_width": 2000.0,
		"ground_y": 0.0, "ground_bottom": 1000.0, "ground_ratio": 0.5,
		"surfaces": [], "buildings": [],
	}

## 小地图视口 200×100 → 天地分界 y=50，地面带 50..100
func _rect() -> Rect2:
	return Rect2(0.0, 0.0, 200.0, 100.0)


# ─────────────────────────────── ① 投影数学 ────────────────────────────────

func _test_world_to_x() -> void:
	var s := _snap()
	var r := _rect()
	_runner.assert_approx(PainterScript.world_to_x(-1000.0, r, s), 0.0, 0.001, "世界左界 → 小地图左缘")
	_runner.assert_approx(PainterScript.world_to_x(0.0, r, s), 100.0, 0.001, "世界中点 → 小地图中点")
	_runner.assert_approx(PainterScript.world_to_x(1000.0, r, s), 200.0, 0.001, "世界右界 → 小地图右缘")
	# 带 rect 偏移（放大版窗口里地图区不一定在原点）
	var off := Rect2(40.0, 10.0, 200.0, 100.0)
	_runner.assert_approx(PainterScript.world_to_x(-1000.0, off, s), 40.0, 0.001, "带偏移时端点跟着偏移")


func _test_world_to_y() -> void:
	var s := _snap()
	var r := _rect()
	# 地面带顶（世界 y=ground_y）落在天地分界；带底落小地图底缘
	_runner.assert_approx(PainterScript.ground_split_y(r, s), 50.0, 0.001, "天地分界 = 高 50%")
	_runner.assert_approx(PainterScript.world_to_y(0.0, r, s), 50.0, 0.001, "地面带顶 → 分界线")
	_runner.assert_approx(PainterScript.world_to_y(1000.0, r, s), 100.0, 0.001, "地面带底 → 小地图底")
	_runner.assert_approx(PainterScript.world_to_y(500.0, r, s), 75.0, 0.001, "带中腰 → 地面带中腰")
	# 靠后（y 小）= 靠上：这是"不再钉死在分界线"的核心语义
	_runner.assert_true(PainterScript.world_to_y(200.0, r, s) < PainterScript.world_to_y(800.0, r, s),
			"站得靠后（y 小）画得更靠上")


func _test_x_round_trip() -> void:
	var s := _snap()
	var r := _rect()
	for w in [-1000.0, -437.5, 0.0, 512.0, 1000.0]:
		var back: float = PainterScript.x_to_world(PainterScript.world_to_x(w, r, s), r, s)
		_runner.assert_approx(back, w, 0.5, "X 往返一致（%s）" % w)


func _test_y_clamp() -> void:
	var s := _snap()
	var r := _rect()
	# 实体站在地图地面带之外（掉出边界/未落地）时不能画到小地图外
	_runner.assert_approx(PainterScript.world_to_y(-500.0, r, s), 50.0, 0.001, "带外上侧钳到分界线")
	_runner.assert_approx(PainterScript.world_to_y(9999.0, r, s), 100.0, 0.001, "带外下侧钳到底缘")


# ─────────────────────────────── ② 建筑样式登记 ────────────────────────────────

func _test_style_known() -> void:
	_runner.assert_equal(StyleScript.type_for("smithy2"), StyleScript.TYPE_PRODUCTION, "作坊 → 生产")
	_runner.assert_equal(StyleScript.type_for("cottage"), StyleScript.TYPE_RESIDENTIAL, "村舍 → 居住")
	_runner.assert_equal(StyleScript.type_for("cathedral"), StyleScript.TYPE_CIVIC, "大教堂 → 市政")
	_runner.assert_equal(StyleScript.type_for("barracks"), StyleScript.TYPE_MILITARY, "兵营 → 军事")
	_runner.assert_equal(StyleScript.type_for("timber_cottage"), StyleScript.TYPE_RESIDENTIAL,
			"运行时 def（玩家自建）同样可判")
	_runner.assert_equal(StyleScript.type_for("wall_tier1"), StyleScript.TYPE_MILITARY, "城墙 → 军事")
	# 材质色是"近似实际色"：至少与兜底色不同，否则等于没登记
	var c: Color = StyleScript.color_for("cottage")
	_runner.assert_true(not c.is_equal_approx(StyleScript.FALLBACK[1]), "已登记 def 的色不等于兜底色")


func _test_style_fallback() -> void:
	_runner.assert_equal(StyleScript.type_for("def_not_registered"), StyleScript.TYPE_MISC,
			"未登记 def → 其他（不崩）")
	_runner.assert_true(StyleScript.color_for("def_not_registered").is_equal_approx(StyleScript.FALLBACK[1]),
			"未登记 def → 兜底色")


## 管线新加一张卡（cards.json）却没登记样式 → 小地图上就是个灰点，没人会发现。
## 故这里直接核对实际卡表：每个 def 都必须命中（不是 FALLBACK）。
func _test_style_covers_cards() -> void:
	var f := FileAccess.open(CARDS_JSON, FileAccess.READ)
	if f == null:
		_runner.assert_true(false, "读不到卡表 %s" % CARDS_JSON)
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if not (data is Array):
		_runner.assert_true(false, "卡表格式异常（期望 JSON 数组）")
		return
	var missing: Array = []
	var seen: Dictionary = {}
	for entry: Dictionary in data:
		var def: String = str(entry.get("def", ""))
		if def.is_empty() or seen.has(def):
			continue
		seen[def] = true
		if not StyleScript.STYLE.has(def):
			missing.append(def)
	_runner.assert_true(seen.size() > 20, "卡表读到足量 def（%d 个）" % seen.size())
	_runner.assert_true(missing.is_empty(), "卡表 def 全部已登记样式（缺：%s）" % str(missing))


## UI 图例（PainterScript.TYPE_LEGEND）必须覆盖地图侧产出的每种功能类型
## （兜底类型 misc 不上图例）；地图侧新增类型而未配图例 = 图例缺项。
func _test_legend_covers_types() -> void:
	var legend_keys: Dictionary = {}
	for row: Array in PainterScript.TYPE_LEGEND:
		legend_keys[String(row[0])] = true
	var missing: Array = []
	for def: String in StyleScript.STYLE:
		var t: String = str(StyleScript.STYLE[def][0])
		if t == StyleScript.TYPE_MISC:
			continue
		if not legend_keys.has(t):
			missing.append(t)
	_runner.assert_true(missing.is_empty(), "所有功能类型都有图例项（缺：%s）" % str(missing))
	_runner.assert_equal(legend_keys.size(), PainterScript.TYPE_LEGEND.size(), "图例键无重复")


# ─────────────────────────────── ③ 顶部中央跨度合同 ────────────────────────────────

func _test_zone_span() -> void:
	var vp := Vector2(1920.0, 1080.0)
	var r: Rect2 = ZoneScript.zone_rect(&"top_center", vp)
	_runner.assert_approx(r.position.x, ZoneScript.TOP_CENTER_FREE_LEFT_PX, 0.01,
			"1920 下保留区左缘 = 顶栏空档左界 703（实测 %.1f）" % r.position.x)
	_runner.assert_true(r.end.x <= ZoneScript.TOP_CENTER_FREE_RIGHT_PX,
			"1920 下保留区右缘不越空档右界 %.0f（实测 %.1f）"
			% [ZoneScript.TOP_CENTER_FREE_RIGHT_PX, r.end.x])
	_runner.assert_true(r.position.x >= ZoneScript.TOP_CENTER_FREE_LEFT_PX,
			"1920 下保留区不压左按钮群")


func _test_max_width() -> void:
	var vp_x: float = 1920.0
	var w: float = ZoneScript.top_center_max_width(vp_x)
	# 左按钮群是紧的一侧：(960-703)*2 = 514
	_runner.assert_approx(w, 514.0, 0.01, "1920 画布最大宽度 514（实测 %.1f）" % w)
	_runner.assert_true(ZoneScript.top_center_max_width(1280.0) < w, "画布变窄 → 最大宽度收紧")
	_runner.assert_true(ZoneScript.top_center_max_width(2560.0) > w, "画布变宽 → 最大宽度放宽")


func _test_base_layout_empty() -> void:
	var m: MapBase = MapBaseScript.new()
	var layout: Dictionary = m.get_minimap_layout()
	_runner.assert_true(layout.has("surfaces") and layout.has("buildings"),
			"基类布局含 surfaces/buildings 两键（消费方按此取数）")
	_runner.assert_equal((layout["surfaces"] as Array).size(), 0, "基类无地表带")
	_runner.assert_equal((layout["buildings"] as Array).size(), 0, "基类无建筑")
	m.free()
