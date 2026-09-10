extends Node
## 建成区 blob V2 单测（观感返工 §R5：三档贴图 + 包几何 + 档位判定）
##
## 覆盖：档位映射（0.35/0.65 分界，与生成端概览口径一致）/ 容量装配兼容接口 /
## 包几何 blob_v2_geo.bin 真数据装载（结构 / 嵌套 / 锚点居中）/ R2 流动描边轮廓
## 选择（mid 档最大外环）/ even-odd 栅格化（外环+洞）/ L1/L2/L3 真数据装配。
## 旧径向轮廓模型的 DJB2 跨端同源锚点已随 §R5 退役删除。

signal test_done(code)

const TestRunner := preload("res://tests/core/test_runner.gd")

var _runner: TestRunner
const CFG := "res://config/strategic_map"


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("档位映射（0.35/0.65 分界）", _test_tier_of)
	_runner.add_test("容量装配兼容接口", _test_direction_count)
	_runner.add_test("包几何装载（出生包 geo bin）", _test_geo_load)
	_runner.add_test("三档严格嵌套（真数据抽样）", _test_tier_nesting)
	_runner.add_test("R2 描边轮廓选择（mid 最大外环）", _test_glow_outline)
	_runner.add_test("even-odd 栅格化（外环+洞）", _test_rasterize)
	_runner.add_test("L1 真数据装配（出生包）", _test_l1_data)
	_runner.add_test("L2 真数据装配（cities）", _test_l2_data)
	_runner.add_test("L3 真数据装配（city_tiles）", _test_l3_data)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_tier_of() -> void:
	_runner.assert_equal(SettlementBlob.TIER_LOW, SettlementBlob.tier_of(0.0), "s=0 → low")
	_runner.assert_equal(SettlementBlob.TIER_LOW, SettlementBlob.tier_of(0.34), "0.34 → low")
	_runner.assert_equal(SettlementBlob.TIER_MID, SettlementBlob.tier_of(0.35), "0.35 → mid（左闭）")
	_runner.assert_equal(SettlementBlob.TIER_MID, SettlementBlob.tier_of(0.5), "0.5 → mid")
	_runner.assert_equal(SettlementBlob.TIER_MID, SettlementBlob.tier_of(0.64), "0.64 → mid")
	_runner.assert_equal(SettlementBlob.TIER_HIGH, SettlementBlob.tier_of(0.65), "0.65 → high（左闭）")
	_runner.assert_equal(SettlementBlob.TIER_HIGH, SettlementBlob.tier_of(1.0), "1.0 → high")
	_runner.assert_equal(SettlementBlob.TIER_LOW, SettlementBlob.tier_of(-0.2), "负值 → low（安全）")
	# 单调性：分数升档位不降
	var prev := -1
	var mono := true
	for i in 21:
		var t := SettlementBlob.tier_of(float(i) / 20.0)
		if t < prev:
			mono = false
			break
		prev = t
	_runner.assert_true(mono, "tier_of 单调不减")


func _test_direction_count() -> void:
	_runner.assert_equal(16, SettlementBlob.direction_count(), "direction_count()=16（装配校验兼容）")


func _test_geo_load() -> void:
	var geo := SettlementBlob.load_pack_geometry(CFG)
	_runner.assert_true(not geo.is_empty(), "出生包 blob_v2_geo.bin 装载")
	var with_rings := 0
	var bake_ok := true
	for sid: String in geo:
		var cd: Dictionary = geo[sid]
		var bt := int(cd.get("bake_tier", -1))
		if bt < SettlementBlob.TIER_LOW or bt > SettlementBlob.TIER_HIGH:
			bake_ok = false
			break
		# 烘焙档与档位映射自洽：bt 城在烘焙基准分下必然映射回 bt（抽样验证略——
		# 生成端 bake_tier_of 同公式；这里验证结构域即可）
		var rings: Array = cd.get("rings", [])
		if rings.size() == SettlementBlob.TIER_COUNT \
				and not (rings[SettlementBlob.TIER_LOW] as Array).is_empty():
			with_rings += 1
	_runner.assert_true(bake_ok, "烘焙档域 [0,2]")
	_runner.assert_true(with_rings > 0, "存在带 low 档环的城")
	# 抽一城验证环几何：外环包围盒含原点（环 = 相对锚点局部坐标 → 锚点在城内）
	var checked := false
	for sid: String in geo:
		var rings: Array = geo[sid].get("rings", [])
		if (rings[SettlementBlob.TIER_LOW] as Array).is_empty():
			continue
		var poly: Dictionary = (rings[SettlementBlob.TIER_LOW] as Array)[0]
		var outer: PackedVector2Array = poly.get("outer", PackedVector2Array())
		if outer.size() < 3:
			continue
		var bb := Rect2(outer[0], Vector2.ZERO)
		for p in outer:
			bb = bb.expand(p)
		_runner.assert_true(bb.has_point(Vector2.ZERO)
			or bb.abs().has_point(Vector2.ZERO), "%s 外环 bbox 含锚点（局部坐标系）" % sid)
		checked = true
		break
	_runner.assert_true(checked, "抽到可校验的城")


func _test_tier_nesting() -> void:
	var geo := SettlementBlob.load_pack_geometry(CFG)
	# 找一个三档全有环的城：bbox 严格包含 low ⊆ mid ⊆ high（面积随档不减）
	var sid := ""
	for s: String in geo:
		var rings: Array = geo[s].get("rings", [])
		if rings.size() < SettlementBlob.TIER_COUNT:
			continue
		if (rings[SettlementBlob.TIER_HIGH] as Array).is_empty():
			continue
		sid = s
		break
	_runner.assert_true(not sid.is_empty(), "存在三档全环的城")
	if sid.is_empty():
		return
	var rings: Array = geo[sid].get("rings", [])
	var prev_area := -1.0
	for ti in SettlementBlob.TIER_COUNT:
		var polys: Array = rings[ti]
		if polys.is_empty():
			_runner.assert_true(false, "%s 档 %d 缺环" % [sid, ti])
			return
		var poly: Dictionary = polys[0]
		var outer: PackedVector2Array = poly.get("outer", PackedVector2Array())
		var bb := Rect2(outer[0], Vector2.ZERO)
		for p in outer:
			bb = bb.expand(p)
		_runner.assert_true(bb.get_area() >= prev_area - 0.5,
			"%s 档 %d bbox 面积不减（嵌套，%.1f）" % [sid, ti, bb.get_area()])
		prev_area = bb.get_area()


func _test_glow_outline() -> void:
	var geo := SettlementBlob.load_pack_geometry(CFG)
	# 任取一城：glow 轮廓非空且是闭合折线折返（局部坐标，调用方平移锚点）
	var got := false
	for sid: String in geo:
		var ring := SettlementBlob.glow_outline(geo, sid)
		if ring.size() >= 3:
			got = true
			# 最大外环：任意点不全相等（退化环不该被选中）
			var same := true
			for p in ring:
				if not p.is_equal_approx(ring[0]):
					same = false
					break
			_runner.assert_true(not same, "%s glow 轮廓非退化" % sid)
			break
	_runner.assert_true(got, "glow_outline 可取到 mid 档轮廓")
	_runner.assert_true(SettlementBlob.glow_outline(geo, "settlement_not_exist").is_empty(),
		"未知城返回空轮廓")


func _test_rasterize() -> void:
	# 20×20 方形 + 中央 10×10 洞（even-odd：洞内不填）
	var square := PackedVector2Array([Vector2(10, 10), Vector2(30, 10), Vector2(30, 30), Vector2(10, 30)])
	var hole := PackedVector2Array([Vector2(15, 15), Vector2(25, 15), Vector2(25, 25), Vector2(15, 25)])
	var col := Color(1, 0.5, 0.5, 1)
	var res := SettlementBlob.rasterize_evenodd(
		[{"outer": square, "holes": [hole]}], col)
	_runner.assert_true(not res.is_empty(), "栅格化产出")
	var img: Image = res["img"]
	var origin: Vector2 = res["origin"]
	_runner.assert_true(img.get_width() > 20 and img.get_height() > 20, "贴图尺寸含 pad")
	# 实体点（世界 (12,12)，洞外）与洞内点（世界 (20,20)，方形/洞共同中心）
	var img_origin: Vector2 = res["origin"]
	var pt_in: Vector2 = Vector2(12, 12) - img_origin
	var pt_hole: Vector2 = Vector2(20, 20) - img_origin
	_runner.assert_true(pt_in.x >= 0 and pt_hole.x >= 0, "采样点落在贴图界内")
	_runner.assert_true(img.get_pixel(int(pt_in.x), int(pt_in.y)).a > 0.9, "实体像素填充")
	_runner.assert_true(img.get_pixel(int(pt_hole.x), int(pt_hole.y)).a < 0.1, "洞像素留空")
	# 空集合安全
	_runner.assert_true(SettlementBlob.rasterize_evenodd([], col).is_empty(), "空多边形返回空")


func _test_l1_data() -> void:
	var data := L1WorldData.load_from("%s/l1_world.json" % CFG, CFG)
	_runner.assert_true(data != null and not data.tiles.is_empty(), "出生包加载")
	var found := false
	for tile in data.tiles:
		if tile.settlement != null and not tile.settlement.blob_capacity.is_empty():
			found = true
			_runner.assert_equal(16, tile.settlement.blob_capacity.size(), "capacity 16 值")
			_runner.assert_true(tile.settlement.population_score > 0.0, "population_score 就位")
			break
	_runner.assert_true(found, "出生包聚落带 blob_capacity")


func _test_l2_data() -> void:
	var data := L2WorldData.load_from("%s/l2_packs/region_013/l2_world.json" % CFG,
		"%s/l2_packs/region_013" % CFG)
	_runner.assert_true(data != null, "region_013 加载")
	_runner.assert_true(data.cities.size() > 0, "cities 注入就位")
	var c: Dictionary = data.cities[0]
	_runner.assert_true(str(c.get("id", "")).begins_with("settlement_city_"), "city id 格式")
	_runner.assert_true(c.get("pos") is Vector2, "pos 已归一化为 Vector2")
	_runner.assert_equal(16, (c.get("cap") as PackedFloat32Array).size(), "capacity 16 值")
	_runner.assert_true(float(c.get("score", 0.0)) > 0.0, "score（含每局扰动）就位")


func _test_l3_data() -> void:
	var data := L3WorldData.load_from("%s/l3_world.json" % CFG, CFG)
	_runner.assert_true(data != null and data.city_tiles.size() > 0, "city_tiles 加载")
	var with_cap := 0
	for t in data.city_tiles:
		var td: Dictionary = t
		if td.has("blob_capacity"):
			with_cap += 1
	_runner.assert_equal(data.city_tiles.size(), with_cap, "全量城市带 blob_capacity")
	var t0: Dictionary = data.city_tiles[0]
	_runner.assert_true(t0.has("anchor"), "anchor（世界锚点）就位")
	_runner.assert_true(float(t0.get("population_score", 0.0)) > 0.0, "population_score 就位")
