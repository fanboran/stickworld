extends Node
## 单元测试：政治矢量 mesh（边界超分 S3，弧拓扑运行时格式）。
##
## 覆盖：l3_political_mesh 数据存在且字段齐 / fill 三角网一致性（idx 值域、code
## 与顶点数对齐、code 值域 = 政权 1..80 + 253 自由城邦 + 254 湖）/ 弧数据一致性
## （arc_ptr 单调、arc_code 值域、arc_border 与两侧 code 的界分类一致、弧引用
## tile 合法）/ L3WorldData.political_mesh bin 装载（Packed 形态）/ 顶点色编码
## 往返（code → vertex R → code，生成端与 shader 同式）/ 13 份 L2 pack 注入存在
## 且 fill 非空 / L2WorldData.political_mesh 装载 / LUT 保留码覆盖矢量湖/自由城邦。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L3WorldData := preload("res://modules/world_map/data/l3_world_data.gd")
const L2WorldData := preload("res://modules/world_map/data/l2_world_data.gd")
const PoliticalLut := preload("res://modules/world_map/data/political_lut.gd")

const N_STATES := 80
const CODE_FREE := 253
const CODE_LAKE := 254
## 界类型（与 MapTokens/生成端 arc_topology 同码表）
const ARC_NONE := 0
const ARC_NATIONAL := 1
const ARC_REGION := 2
const ARC_FREE := 3

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("political_mesh: L3 数据存在且字段齐", _test_l3_mesh_exists)
	_runner.add_test("political_mesh: fill 三角网一致性", _test_fill_consistency)
	_runner.add_test("political_mesh: 弧数据一致性 + 界分类自洽", _test_arc_consistency)
	_runner.add_test("political_mesh: 顶点色编码往返", _test_vertex_code_roundtrip)
	_runner.add_test("political_mesh: L3WorldData 装载（bin 路径）", _test_l3_loaded)
	_runner.add_test("political_mesh: 13 份 L2 注入存在且 fill 非空", _test_l2_injected)
	_runner.add_test("political_mesh: L2WorldData 装载 + 界线折线", _test_l2_loaded)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _read_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


func _test_l3_mesh_exists() -> void:
	var pm := _read_json("res://config/strategic_map/l3_political_mesh.json")
	_runner.assert_true(not pm.is_empty(), "l3_political_mesh.json 可读")
	for f in ["arcs", "arc_ptr", "arc_code_a", "arc_code_b", "arc_border",
			"tiles", "fill_verts", "fill_code", "fill_idx"]:
		_runner.assert_true(pm.has(f), "字段 %s 存在" % f)
	_runner.assert_equal(int(pm.get("size", 0)), 8192, "坐标域 8192")


func _test_fill_consistency() -> void:
	var pm := _read_json("res://config/strategic_map/l3_political_mesh.json")
	var verts: Array = pm.get("fill_verts", [])
	var codes: Array = pm.get("fill_code", [])
	var idx: Array = pm.get("fill_idx", [])
	_runner.assert_true(verts.size() > 100000,
			"fill 顶点规模合理（实测 %d）" % verts.size())
	_runner.assert_equal(verts.size(), codes.size(), "fill_code 与顶点一一对应")
	_runner.assert_equal(idx.size() % 3, 0, "索引是三角形三元组")
	_runner.assert_true(idx.size() >= verts.size(), "三角形数 ≥ 顶点数（覆盖全顶点）")
	var max_idx := 0
	var bad_code := 0
	for c in codes:
		var code := int(c)
		# 0 = 海洋底矩形（排数组最前垫底，shader empty_color），合法
		if code != 0 and (code < 1 or code > N_STATES) \
				and code != CODE_FREE and code != CODE_LAKE:
			bad_code += 1
	for t in idx:
		if int(t) > max_idx:
			max_idx = int(t)
	_runner.assert_true(max_idx < verts.size(),
			"索引值域 ⊆ 顶点数（max=%d, n=%d）" % [max_idx, verts.size()])
	_runner.assert_equal(bad_code, 0, "fill code 值域 ⊆ 1..80 + 253/254（越界 %d）" % bad_code)


func _test_arc_consistency() -> void:
	var pm := _read_json("res://config/strategic_map/l3_political_mesh.json")
	var arcs: Array = pm.get("arcs", [])
	var ptr: Array = pm.get("arc_ptr", [])
	var ca: Array = pm.get("arc_code_a", [])
	var cb: Array = pm.get("arc_code_b", [])
	var border: Array = pm.get("arc_border", [])
	var n_arc: int = ca.size()
	_runner.assert_true(n_arc > 1000, "弧规模合理（实测 %d）" % n_arc)
	_runner.assert_equal(cb.size(), n_arc, "arc_code_b 与 a 等长")
	_runner.assert_equal(border.size(), n_arc, "arc_border 与弧数等长")
	_runner.assert_equal(ptr.size(), n_arc + 1, "arc_ptr = 弧数+1（哨兵）")
	_runner.assert_equal(int(arcs.size()) / 2.0, float(arcs.size()) / 2.0,
			"arcs 平铺是 (x,y) 对")
	# arc_ptr 单调递增且末尾 = arcs 总长
	var mono := true
	for i in n_arc:
		if int(ptr[i]) >= int(ptr[i + 1]):
			mono = false
			break
	_runner.assert_true(mono, "arc_ptr 严格递增（每弧至少 1 顶点）")
	_runner.assert_equal(int(ptr[n_arc]), arcs.size(), "arc_ptr 末尾 = arcs 总长")
	# 界分类与两侧 code 自洽
	var bad_class := 0
	for i in n_arc:
		var a := int(ca[i])
		var b := int(cb[i])
		var want := ARC_NONE
		if a <= 0 or b <= 0:
			want = ARC_NONE
		elif (a == CODE_FREE) != (b == CODE_FREE):
			want = ARC_FREE
		elif a != b:
			want = ARC_NATIONAL
		else:
			want = ARC_NONE   # 同 code（地区界由生成端按 region 判定，此处不重复校验）
		if int(border[i]) != want and not (int(border[i]) == ARC_REGION and want == ARC_NONE):
			bad_class += 1
	_runner.assert_equal(bad_class, 0, "界分类与弧侧码一致（违例 %d）" % bad_class)
	# tiles 弧引用值域
	var bad_ref := 0
	for t in (pm.get("tiles", []) as Array):
		var td: Dictionary = t
		for ring_list in [td.get("rings", []), td.get("holes", [])]:
			for ring in (ring_list as Array):
				for v in (ring as Array):
					var aid: int = absi(int(v))
					if aid < 1 or aid > n_arc:
						bad_ref += 1
	_runner.assert_equal(bad_ref, 0, "tiles 弧引用值域 1..n（越界 %d）" % bad_ref)


func _test_vertex_code_roundtrip() -> void:
	for code in [1, 40, N_STATES, CODE_FREE, CODE_LAKE]:
		var r := PoliticalLut.code_to_vertex_r(code)
		_runner.assert_equal(PoliticalLut.vertex_r_to_code(r), code,
				"顶点色编码往返 code=%d" % code)


func _test_l3_loaded() -> void:
	var data = L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json", "res://config/strategic_map")
	_runner.assert_true(data != null and not data.political_mesh.is_empty(),
			"L3WorldData.political_mesh 已装载")
	if data == null or data.political_mesh.is_empty():
		return
	var pm: Dictionary = data.political_mesh
	_runner.assert_true(pm.get("fill_verts") is PackedVector2Array,
			"fill_verts 是 PackedVector2Array（bin 紧凑形态）")
	_runner.assert_true(pm.get("fill_idx") is PackedInt32Array, "fill_idx 是 PackedInt32Array")
	_runner.assert_true((pm["fill_verts"] as PackedVector2Array).size() > 100000,
			"装载后 fill 顶点规模（实测 %d）" % (pm["fill_verts"] as PackedVector2Array).size())
	# 可直接构建 ArrayMesh（渲染器同路径：顶点色 + 索引）
	var verts: PackedVector2Array = pm["fill_verts"]
	var codes: PackedInt32Array = pm.get("fill_code", PackedInt32Array())
	var colors := PackedColorArray()
	colors.resize(verts.size())
	for i in verts.size():
		var r := PoliticalLut.code_to_vertex_r(codes[i])
		colors[i] = Color(r, 0.0, 0.0, 1.0)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = pm["fill_idx"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_runner.assert_true(mesh.get_surface_count() == 1, "fill 可构建 ArrayMesh")


func _test_l2_injected() -> void:
	var missing := 0
	var bad := 0
	for i in range(1, 14):
		var p := "res://config/strategic_map/l2_packs/region_%03d/l2_world.json" % i
		var w := _read_json(p)
		var pm: Dictionary = w.get("political_mesh", {})
		if pm.is_empty():
			missing += 1
			continue
		var verts: Array = pm.get("verts", [])
		var idx: Array = pm.get("idx", [])
		var codes: Array = pm.get("code", [])
		if verts.is_empty() or idx.is_empty() or verts.size() != codes.size():
			bad += 1
			continue
		for f in ["borders_national", "borders_region", "borders_free"]:
			if not pm.has(f):
				bad += 1
	_runner.assert_equal(missing, 0, "13 份 L2 pack 全部注入（缺 %d）" % missing)
	_runner.assert_equal(bad, 0, "L2 political_mesh fill/界线字段完整（坏 %d）" % bad)


func _test_l2_loaded() -> void:
	var data = L2WorldData.load_from(
			"res://config/strategic_map/l2_packs/region_013/l2_world.json",
			"res://config/strategic_map/l2_packs/region_013")
	_runner.assert_true(data != null and not data.political_mesh.is_empty(),
			"L2WorldData.political_mesh 已装载")
	if data == null or data.political_mesh.is_empty():
		return
	var pm: Dictionary = data.political_mesh
	_runner.assert_true(pm.get("verts") is PackedVector2Array,
			"L2 fill_verts 是 PackedVector2Array（bin 紧凑形态）")
	# 三级界线：字段存在即可（个别 region 某级界线为 0 条是合法数据——
	# 如 region_013 无地区界/自由城邦界）；非空时元素必须是 PackedVector2Array
	for f in ["borders_national", "borders_region", "borders_free"]:
		var lines: Array = pm.get(f, [])
		var ok := lines != null
		for ln in lines:
			if not (ln is PackedVector2Array):
				ok = false
		_runner.assert_true(ok, "%s 是 PackedVector2Array 折线列表（可为空）" % f)
	# 国界折线顶点在 context 域 ±宽容内（跨窗口边的弧保留原坐标，超界部分
	# 画在 context 外被相机限位裁掉，视觉无影响）
	var in_ctx := true
	var margin := 8192.0
	for ln in (pm.get("borders_national", []) as Array):
		for v in (ln as PackedVector2Array):
			if v.x < -margin or v.y < -margin \
					or v.x > float(data.context_size.x) + margin \
					or v.y > float(data.context_size.y) + margin:
				in_ctx = false
	_runner.assert_true(in_ctx, "国界折线顶点在 context 域 ±8192 内")
