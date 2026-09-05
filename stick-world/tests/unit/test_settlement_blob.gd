extends Node
## 城市 blob 生长模型单测（C2，总体设计 §5.7）
##
## 覆盖：参数表加载 / 确定性（读档一致）/ 加性扩张（base 特征保留）/ 方向不均
## （capacity 调制）/ 轮廓规模与闭合 / 跨端公式锚点（DJB2 + 数值，防 Python/GDScript
## 任一端漂移）/ 三层视图包真数据装配（L1 SettlementRef / L2 cities / L3 city_tiles）。
##
## 锚点值出处：tools/worldgen/l1/blob_bake.py 同参数同输入实算（2026-09 定标）。

signal test_done(code)

const TestRunner := preload("res://tests/core/test_runner.gd")

var _runner: TestRunner
const CFG := "res://config/strategic_map"


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("参数表加载", _test_params)
	_runner.add_test("跨端公式锚点（DJB2/半径/轮廓）", _test_anchor)
	_runner.add_test("确定性（同参数逐点一致）", _test_determinism)
	_runner.add_test("加性扩张（base 特征保留）", _test_additive)
	_runner.add_test("方向不均（capacity 调制增量）", _test_directional)
	_runner.add_test("capacity 全零（规模不敏感）", _test_zero_cap)
	_runner.add_test("轮廓规模与闭合", _test_outline_shape)
	_runner.add_test("L1 真数据装配（出生包）", _test_l1_data)
	_runner.add_test("L2 真数据装配（cities）", _test_l2_data)
	_runner.add_test("L3 真数据装配（city_tiles）", _test_l3_data)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _cap_pattern() -> PackedFloat32Array:
	# 0-7 方向满容量、8-15 低容量（方向不均用例）
	var cap := PackedFloat32Array()
	for i in 16:
		cap.append(0.8 if i < 8 else 0.1)
	return cap


func _test_params() -> void:
	var p := SettlementBlob.params()
	_runner.assert_equal(16, int(p.get("K", 0)), "K=16")
	_runner.assert_equal(72, int(p.get("sample_points", 0)), "sample_points=72")
	_runner.assert_true(p.has("levels") and p["levels"].has("3"), "levels 表含 T3")
	_runner.assert_equal(16, SettlementBlob.direction_count(), "direction_count()=16")
	# 生长曲线单调（s 升 → g 升），γ<1 先快后慢（差分斜率递减）
	var g1 := SettlementBlob.growth(3, 0.2)
	var g2 := SettlementBlob.growth(3, 0.6)
	var g3 := SettlementBlob.growth(3, 0.9)
	_runner.assert_true(g1 < g2 and g2 < g3, "g(s) 单调递增")
	var slope_early := (g2 - g1) / (0.6 - 0.2)
	var slope_late := (g3 - g2) / (0.9 - 0.6)
	_runner.assert_true(slope_early > slope_late, "γ<1 先快后慢")


func _test_anchor() -> void:
	_runner.assert_equal(2530983083, SettlementBlob.djb2("settlement_city_1036"),
		"DJB2 与生成端一致（防单侧漂移）")
	var br := SettlementBlob.base_radii("settlement_city_1036", 3)
	_runner.assert_approx(43.8919, br[0], 0.001, "base_radii[0] 锚点")
	_runner.assert_approx(57.8416, br[3], 0.001, "base_radii[3] 锚点")
	var dr := SettlementBlob.direction_radii("settlement_city_1036", 3, _cap_pattern(), 0.6)
	_runner.assert_approx(66.2717, dr[0], 0.001, "direction_radii[0] 锚点")
	_runner.assert_approx(48.9389, dr[8], 0.001, "direction_radii[8] 锚点")
	var ol := SettlementBlob.generate_outline("settlement_city_1036", 3, _cap_pattern(), 0.6)
	_runner.assert_approx(66.2717, ol[0].x, 0.001, "outline[0].x 锚点（θ=0 沿 +x）")
	_runner.assert_approx(0.0, ol[0].y, 0.001, "outline[0].y 锚点")


func _test_determinism() -> void:
	var a := SettlementBlob.generate_outline("settlement_city_001", 2, _cap_pattern(), 0.42)
	var b := SettlementBlob.generate_outline("settlement_city_001", 2, _cap_pattern(), 0.42)
	_runner.assert_equal(a.size(), b.size(), "两次生成点数一致")
	var same := true
	for i in a.size():
		if not a[i].is_equal_approx(b[i]):
			same = false
			break
	_runner.assert_true(same, "同参数重复生成逐点一致（读档一致基础）")


func _test_additive() -> void:
	# Δr(θᵢ) = capacity(θᵢ) × Δg —— 与 base 无关的加性增量
	var cap := _cap_pattern()
	var lo := SettlementBlob.direction_radii("settlement_city_002", 3, cap, 0.2)
	var hi := SettlementBlob.direction_radii("settlement_city_002", 3, cap, 0.8)
	var dg := SettlementBlob.growth(3, 0.8) - SettlementBlob.growth(3, 0.2)
	var all_ok := true
	for i in 16:
		var expect := cap[i] * dg
		if absf((hi[i] - lo[i]) - expect) > 0.0001:
			all_ok = false
			break
	_runner.assert_true(all_ok, "各方向增量 = capacity×Δg（加性，非等比缩放）")
	# base 凹凸特征保留：r 差恒定 → 形状特征不随规模抹平
	var b0 := SettlementBlob.base_radii("settlement_city_002", 3)
	var keep := true
	for i in 16:
		if absf((hi[i] - b0[i]) - cap[i] * SettlementBlob.growth(3, 0.8)) > 0.0001:
			keep = false
			break
	_runner.assert_true(keep, "base(θ) 特征全程保留")


func _test_directional() -> void:
	var cap := _cap_pattern()
	var lo := SettlementBlob.direction_radii("settlement_city_003", 3, cap, 0.1)
	var hi := SettlementBlob.direction_radii("settlement_city_003", 3, cap, 0.9)
	var delta_hi := hi[0] - lo[0]     # cap=0.8 方向
	var delta_lo := hi[8] - lo[8]     # cap=0.1 方向
	_runner.assert_true(delta_hi > delta_lo * 4.0,
		"高容量方向增量远大于低容量方向（依地形不均匀扩散）")


func _test_zero_cap() -> void:
	var zero := PackedFloat32Array()
	zero.resize(16)
	var a := SettlementBlob.direction_radii("settlement_city_004", 2, zero, 0.1)
	var b := SettlementBlob.direction_radii("settlement_city_004", 2, zero, 0.95)
	var same := true
	for i in 16:
		if absf(a[i] - b[i]) > 0.0001:
			same = false
			break
	_runner.assert_true(same, "capacity 全零时规模不敏感（纯 base 轮廓）")


func _test_outline_shape() -> void:
	var p := SettlementBlob.params()
	var ol := SettlementBlob.generate_outline("settlement_city_005", 3, _cap_pattern(), 0.7)
	_runner.assert_equal(72, ol.size(), "固定 72 采样点")
	var cfg: Dictionary = SettlementBlob.level_cfg(3)
	var r_min := float(cfg["base"]) * 0.5
	var r_max := float(cfg["base"]) + float(cfg["g_max"]) * 1.05
	var in_range := true
	var no_nan := true
	for pt in ol:
		if pt.x != pt.x or pt.y != pt.y:   # NaN 检查
			no_nan = false
			break
		var r := pt.length()
		if r < r_min or r > r_max:
			in_range = false
			break
	_runner.assert_true(no_nan, "无 NaN")
	_runner.assert_true(in_range, "半径落在 [base×0.5, base+g_max] 内")
	# 闭合性：首点 θ=0、相邻点角距恒定（72 点均匀角度采样）
	_runner.assert_approx(ol[0].x, ol[0].length(), 0.001, "首点在 +x 轴上")
	_runner.assert_true((ol[1] - ol[0]).length() < (ol[2] - ol[0]).length(),
		"相邻点距小于隔点距（无自交序）")


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
