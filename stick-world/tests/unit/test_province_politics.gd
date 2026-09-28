extends Node
## 单元测试：老 L1 省份政治面侧表（邻省上下文上色 + 左右切省箭头方位）
##
## 覆盖：
##   - l1_province_politics.json 全量 69 省、字段完整、色值/质心合法
##   - 与 political_data.json 的政权表一致（state_id ↔ lut_index ↔ color 三方对齐，
##     侧表是采样产物，不能凭空造色）
##   - 首/尾省份可查（L1 视图邻省上色的直接消费点）
##   - ProvincePolitics.load_shared 单例 / color_of / centroid_of / state_name_of 接口
##   - **质心轴序回归**（2026-09-22 缺陷）：l3_l1.json 的 polygons 与 centroid 同为 [y,x]，
##     侧表必须存 [x,y]——不换序会让方位沿主对角轴翻转（历史回归：轴序误存时方位翻转）
##     西北#67 / 正西#68，翻转后会变成 东北/东南/正北）

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")

const SIDE_DATA := "res://config/strategic_map/l1_province_politics.json"
const POLITICAL_DATA := "res://config/strategic_map/political_data.json"
const LAST_L1_LABEL := 69
const BIRTH_NEIGHBORS := [18, 67, 68]
const N_PROVINCES := 69

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("侧表：69 省全量 + 字段完整合法", _test_table_shape)
	_runner.add_test("侧表：色值/政权与 political_data 对齐", _test_color_alignment)
	_runner.add_test("侧表：首/尾省份可查", _test_birth_entries)
	_runner.add_test("ProvincePolitics：装载与查询接口", _test_loader)
	_runner.add_test("质心轴序：[x,y] 存储 + 邻省方位与全球地理一致", _test_centroid_axis)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _test_table_shape() -> void:
	var d := _read_json(SIDE_DATA)
	_runner.assert_true(not d.is_empty(), "侧表可读: %s" % SIDE_DATA)
	var prov: Dictionary = d.get("provinces", {})
	_runner.assert_equal(prov.size(), N_PROVINCES, "69 省齐全")
	var bad := 0
	for key in prov:
		var e: Dictionary = prov[key]
		var col: Array = e.get("color", [])
		var cen: Array = e.get("centroid", [])
		if col.size() < 3 or cen.size() < 2 or int(e.get("lut_index", 0)) <= 0 \
				or str(e.get("state_id", "")).is_empty():
			bad += 1
		elif int(cen[0]) == 0 and int(cen[1]) == 0:
			bad += 1
	_runner.assert_equal(bad, 0, "字段完整且质心非零（坏条目 %d）" % bad)
	# label 覆盖 1..69 连续
	var missing: Array = []
	for i in range(1, N_PROVINCES + 1):
		if not prov.has(str(i)):
			missing.append(i)
	_runner.assert_true(missing.is_empty(), "label 1..69 无缺漏（缺 %s）" % str(missing))


func _test_color_alignment() -> void:
	var prov: Dictionary = _read_json(SIDE_DATA).get("provinces", {})
	var states: Dictionary = _read_json(POLITICAL_DATA).get("states", {})
	_runner.assert_true(not states.is_empty(), "政权表可读")
	# lut_index -> (state_id, color)
	var by_index := {}
	for sid in states:
		var info: Dictionary = states[sid]
		by_index[int(info.get("lut_index", 0))] = [sid, info.get("color", [])]
	var mismatch: Array = []
	for key in prov:
		var e: Dictionary = prov[key]
		var idx := int(e.get("lut_index", 0))
		if not by_index.has(idx):
			mismatch.append("#%s lut_index %d 不在政权表" % [key, idx])
			continue
		var ref: Array = by_index[idx]
		if str(ref[0]) != str(e.get("state_id", "")):
			mismatch.append("#%s state_id 与 lut_index 不符" % key)
		elif (ref[1] as Array) != (e.get("color", []) as Array):
			mismatch.append("#%s 色值与政权表不符" % key)
	_runner.assert_true(mismatch.is_empty(),
			"69 省色值/政权与 political_data 三方对齐（异常 %s）" % str(mismatch.slice(0, 3)))


func _test_birth_entries() -> void:
	# V2 出生点变更（settlement_city_427）；通用抽查 3 省（含首/尾 label）可查且字段完整
	var prov: Dictionary = _read_json(
			"res://config/strategic_map/l1_province_politics.json").get("provinces", {})
	for label in ["1", str(N_PROVINCES)]:
		var e: Dictionary = prov.get(label, {})
		_runner.assert_true(not e.is_empty(), "省份 #%s 在侧表内" % label)
		_runner.assert_true(str(e.get("name", "")) != "", "省份 #%s 有主导政权名" % label)


func _test_loader() -> void:
	ProvincePolitics.reset_shared()
	var a := ProvincePolitics.load_shared()
	var b := ProvincePolitics.load_shared()
	_runner.assert_true(a != null, "共享实例装载成功")
	_runner.assert_true(a == b, "两次取用同实例（共享缓存）")
	if a == null:
		return
	_runner.assert_equal(a.provinces.size(), N_PROVINCES, "装载 69 省")
	_runner.assert_true(a.has_label(LAST_L1_LABEL), "has_label(#69)")
	_runner.assert_true(not a.has_label(0) and not a.has_label(999), "未知 label 判否")
	_runner.assert_true(a.color_of(LAST_L1_LABEL).a > 0.0, "已知省取到不透明色")
	_runner.assert_true(a.color_of(999).a <= 0.0, "未知省返回透明（调用方按 a 判无）")
	_runner.assert_true(a.centroid_of(999) == Vector2.INF, "未知省质心 = INF")
	_runner.assert_true(a.state_name_of(LAST_L1_LABEL) != "", "已知省有政权名")
	_runner.assert_equal(a.state_name_of(999), "", "未知省政权名空串")


## 轴序回归：侧表存 [x,y]，且 #69 与三个邻省方位与全球地理一致（#18 东北 / #67 西北 /
## #68 正西）——这是「邻块像被对角轴翻转」缺陷的守门断言（见 export_province_politics.py
## 的轴序注释）。省几何为固定底图，V2 只换主导政权，方位断言不变。
func _test_centroid_axis() -> void:
	var prov: Dictionary = _read_json(SIDE_DATA).get("provinces", {})
	var self_e: Dictionary = prov.get(str(LAST_L1_LABEL), {})
	var self_c: Array = self_e.get("centroid", [0, 0])
	# 质心在全局 8192 坐标范围内（[y,x] 误存会整体越界或错位）
	_runner.assert_true(float(self_c[0]) > 0.0 and float(self_c[0]) < 8192.0
			and float(self_c[1]) > 0.0 and float(self_c[1]) < 8192.0,
			"省 #69 质心在全局坐标内（%s）" % str(self_c))
	var cases := [
		[18, 1, -1, "东北"], [67, -1, -1, "西北"], [68, -1, 0, "正西"],
	]
	for c in cases:
		var e: Dictionary = prov.get(str(c[0]), {})
		var vx := float(e.get("centroid", [0, 0])[0]) - float(self_c[0])
		var vy := float(e.get("centroid", [0, 0])[1]) - float(self_c[1])
		var x_ok: bool = (vx > 0.0) if int(c[1]) > 0 else ((vx < 0.0) if int(c[1]) < 0 else absf(vx) < 200.0)
		var y_ok: bool = (vy < 0.0) if int(c[2]) < 0 else ((vy > 0.0) if int(c[2]) > 0 else absf(vy) < 200.0)
		_runner.assert_true(x_ok and y_ok,
				"邻省 #%d 方位应为%s（实测向量 %+.0f,%+.0f）" % [c[0], c[3], vx, vy])
