extends Node
## 单元测试：政权数据一致性（V2 世界重生成 193 国 + ID mask/LUT 运行时链路）。
##
## 覆盖：political_data.json 全量覆盖（城主表 ⊇ l3_city 1036 城 + 6 原址复种点，无缺漏/无孤儿）/ 归属合法性 +
## 字段完整 / 政权总数 == 193 + 规模谱窗口（1 城邦与 12+ 城大国并存、cap 18）/
## lut_index 1..193 连续唯一 / l3_city 注入一致（state_id+城文化）/
## L2 packs 注入一致 / 文化值域（0 荒野 + 1..22 源点序号）/ L3 ID mask 与 json
## 一致（首都城块质心像素 == lut_index，值域含 253 无主荒地）/ L2 ID mask 保留码
## / L3WorldData.states bin 装载 / PoliticalLut 构建与「改 LUT 即换色」运行时链路。
## V2 出生 8 城邦特殊态取消：出生点为普通小国成员城（settlement_city_399，西达塞行）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L3WorldData := preload("res://modules/world_map/data/l3_world_data.gd")
const PoliticalLut := preload("res://modules/world_map/data/political_lut.gd")

## V2 文化体系：22 文化源点序号（settlements_v2 dominant）+ 0=荒野文化
const MAX_CULTURE := 22
const N_STATES := 193
const N_CITIES := 1036
## 规模谱窗口（截断对数正态采样 + A6 涌现有界）
const CAP_MAX := 18

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("political_data: 城主表全量覆盖", _test_full_coverage)
	_runner.add_test("political_data: 归属全部合法 + 字段完整", _test_owners_legal)
	_runner.add_test("政权总数 == 193 + 规模谱窗口（1 城邦与大国并存，cap 18）", _test_total_states)
	_runner.add_test("出生点（V2 西达塞行成员城）归属合法", _test_spawn_point)
	_runner.add_test("lut_index 1..193 连续唯一", _test_lut_index_coverage)
	_runner.add_test("l3_city 注入与真相源一致", _test_l3_city_injection)
	_runner.add_test("L2 packs 注入一致（13 地区）", _test_l2_injection)
	_runner.add_test("文化值域（0 荒野 + 1..22 源点序号）", _test_culture_anchoring)
	_runner.add_test("L3 ID mask 与 json 一致（首都锚点像素 == lut_index）", _test_l3_id_mask)
	_runner.add_test("L2 ID mask 值域与保留码（自由城邦/湖泊/邻区）", _test_l2_id_mask)
	_runner.add_test("L3WorldData.states 装载（bin 路径）", _test_l3_states_loaded)
	_runner.add_test("PoliticalLut：构建 + 改 LUT 即换色（R9 硬指标自证）", _test_political_lut)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _read_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


func _tiles_by_label(l3: Dictionary) -> Dictionary:
	var out := {}
	for t in (l3.get("tiles", []) as Array):
		out[int(t.get("label", 0))] = t
	return out


func _test_full_coverage() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	_runner.assert_true(not pd.is_empty(), "political_data.json 可读")
	var owners: Dictionary = pd.get("city_owners", {})
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	var expect := (l3.get("tiles", []) as Array).size()
	_runner.assert_true(owners.size() >= expect,
			"城主表覆盖 l3_city 全部城（1042 = 1036 城 + 6 原址复种点，实测 %d）" % owners.size())
	var empty := 0
	for k in owners:
		if str(owners[k]).is_empty():
			empty += 1
	_runner.assert_equal(empty, 6, "空归属恰为 6 原址复种点（无主荒地，实测 %d）" % empty)


func _test_owners_legal() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var bad := 0
	for k in pd.get("city_owners", {}):
		var v := str(pd["city_owners"][k])
		if not v.is_empty() and not states.has(v):
			bad += 1
	_runner.assert_equal(bad, 0)
	# 每个 state 结构完整（完整版字段预留：alliance 可空但键在；R7 增 lut_index）
	var missing := 0
	for sid in states:
		var sd: Dictionary = states[sid]
		for f in ["name", "capital", "culture", "alliance", "color", "lut_index"]:
			if not sd.has(f):
				missing += 1
	_runner.assert_equal(missing, 0)
	# 颜色值合法（0..255 三通道）
	var bad_color := 0
	for sid in states:
		var col: Array = states[sid].get("color", [])
		if col.size() != 3:
			bad_color += 1
			continue
		for v in col:
			if int(v) < 0 or int(v) > 255:
				bad_color += 1
	_runner.assert_equal(bad_color, 0)


func _test_total_states() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	_runner.assert_equal(states.size(), N_STATES,
			"政权总数定档 193（V2 随机规模谱，实测 %d）" % states.size())
	# 规模谱窗口：1 城邦与 12+ 城大国并存、cap 18 封顶，is_city_state == (城数==1)
	var counts := {}
	for k in pd.get("city_owners", {}):
		var sid: String = pd["city_owners"][k]
		counts[sid] = int(counts.get(sid, 0)) + 1
	var n_one := 0
	var n_big := 0
	var smax := 0
	var flag_bad := 0
	for sid in states:
		var n := int(counts.get(sid, 0))
		if n == 1:
			n_one += 1
		if n >= 12:
			n_big += 1
		smax = maxi(smax, n)
		if states[sid].get("is_city_state", false) != (n == 1):
			flag_bad += 1
	_runner.assert_equal(flag_bad, 0, "is_city_state 与城数不符（%d）" % flag_bad)
	_runner.assert_true(n_one >= 8, "1 城邦 >=8 个（实测 %d）" % n_one)
	_runner.assert_true(n_big >= 5, "12+ 城大国 >=5 个（实测 %d）" % n_big)
	_runner.assert_true(smax <= CAP_MAX, "单国城数 <= cap %d（实测 %d）" % [CAP_MAX, smax])


func _test_spawn_point() -> void:
	# V2 出生点 = 西达塞行成员城（3 城小国 state_v2_085，都城 442）；出生包 l1_069
	var l1 := _read_json("res://config/strategic_map/l1_world.json")
	var spawn := str(l1.get("spawn_settlement_id", ""))
	_runner.assert_equal(spawn, "settlement_city_399",
			"出生点 = settlement_city_399（实测 %s）" % spawn)
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var owners: Dictionary = pd.get("city_owners", {})
	_runner.assert_true(owners.has(spawn), "出生点归属在城表中")
	var sid := str(owners.get(spawn, ""))
	_runner.assert_true(pd.get("states", {}).has(sid), "出生点归属政权在表中（%s）" % sid)


func _test_lut_index_coverage() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var idx: Array = []
	for sid in pd.get("states", {}):
		idx.append(int(pd["states"][sid].get("lut_index", 0)))
	idx.sort()
	_runner.assert_true(idx == range(1, N_STATES + 1),
			"lut_index 应恰为 1..193（实测 %d 个，尾=%s）" % [idx.size(), str(idx.slice(mini(idx.size() - 3, 0)))])


func _test_l3_city_injection() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var owners: Dictionary = pd.get("city_owners", {})
	var pstates: Dictionary = pd.get("states", {})
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	var mismatch := 0
	var missing := 0
	for t in (l3.get("tiles", []) as Array):
		var sid: String = "settlement_city_%03d" % int(t.get("label", 0))
		if not t.has("state_id"):
			missing += 1
		elif str(t["state_id"]) != str(owners.get(sid, "")):
			mismatch += 1
	_runner.assert_equal(missing, 0)
	_runner.assert_equal(mismatch, 0)
	var states: Dictionary = l3.get("states", {})
	_runner.assert_equal(states.size(), pstates.size(), "l3_city 顶层 states 与真相源同规模")
	# states 表逐字段一致（color/lut_index）
	var drift := 0
	for sid in pstates:
		if not states.has(sid):
			drift += 1
			continue
		if states[sid].get("color", []) != pstates[sid].get("color", []) \
				or int(states[sid].get("lut_index", 0)) != int(pstates[sid].get("lut_index", 0)):
			drift += 1
	_runner.assert_equal(drift, 0)


func _test_l2_injection() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var owners: Dictionary = pd.get("city_owners", {})
	var dir := "res://config/strategic_map/l2_packs"
	var regions := 0
	var bad := 0
	for i in range(1, 14):
		var p := "%s/region_%03d/l2_world.json" % [dir, i]
		if not FileAccess.file_exists(p):
			bad += 1
			continue
		regions += 1
		var w := _read_json(p)
		if w.get("states", {}).size() != pd.get("states", {}).size():
			bad += 1
			continue
		for c in (w.get("cities", []) as Array):
			if str(c.get("state_id", "")) != str(owners.get(c.get("id", ""), "")):
				bad += 1
	_runner.assert_equal(regions, 13)
	_runner.assert_equal(bad, 0)


func _test_culture_anchoring() -> void:
	# V2 文化值域：states[].culture in 0..22（0=荒野文化）；tile.culture 同域；
	# 荒野城（culture 0）占比 <20%（文化场覆盖率合理）
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var mad := 0
	for sid in states:
		var c := int(states[sid].get("culture", -1))
		if c < 0 or c > MAX_CULTURE:
			mad += 1
	_runner.assert_equal(mad, 0, "states[].culture 值域 0..%d（越界 %d）" % [MAX_CULTURE, mad])
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	var bad := 0
	var wild := 0
	var total := 0
	for t in (l3.get("tiles", []) as Array):
		var c := int(t.get("culture", -1))
		total += 1
		if c < 0 or c > MAX_CULTURE:
			bad += 1
		if c == 0:
			wild += 1
	_runner.assert_equal(bad, 0, "tile.culture 值域（越界 %d）" % bad)
	_runner.assert_true(total >= 1000, "参查城数（%d）" % total)
	_runner.assert_true(float(wild) / float(maxi(total, 1)) < 0.2,
			"荒野文化城占比 <20%%（实测 %d/%d）" % [wild, total])


func _test_l3_id_mask() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	var tex: Texture2D = load("res://config/strategic_map/l3_political_id_8192.png")
	_runner.assert_true(tex != null, "l3_political_id_8192.png 已导入")
	if tex == null:
		return
	var img: Image = tex.get_image()
	_runner.assert_true(img != null and img.get_width() == 8192,
			"ID mask 8192（实测 %d）" % (img.get_width() if img != null else 0))
	if img == null:
		return
	# 值域：政权码 0..193 + 保留码 253（无主荒地）/ 254（湖泊）——稀疏采样
	var bad_val := 0
	var has_free := false
	var has_lake := false
	var n := 8192 * 8192
	var step := 8192 * 33 + 17
	for i in range(0, n, step):
		var v := int(img.get_pixel(i % 8192, int(i / 8192.0)).r * 255.0 + 0.5)
		if v == PoliticalLut.CODE_FREE_CITY:
			has_free = true
		elif v == PoliticalLut.CODE_LAKE:
			has_lake = true
		elif v > states.size():
			bad_val += 1
	_runner.assert_equal(bad_val, 0, "ID mask 值域 ⊆ 0..193 + 253/254（稀疏采样越界 %d）" % bad_val)
	# 保留码存在性：253 荒野回填 / 254 块内湖都是细碎斑块，稀疏对角线采不到 →
	# 16px 子格稠密扫描（26 万采样，headless <1s）
	has_free = false
	has_lake = false
	for y in range(0, 8192, 16):
		for x in range(0, 8192, 16):
			var v := int(img.get_pixel(x, y).r * 255.0 + 0.5)
			if v == PoliticalLut.CODE_FREE_CITY:
				has_free = true
			elif v == PoliticalLut.CODE_LAKE:
				has_lake = true
	_runner.assert_true(has_free, "ID mask 含 253 无主荒地保留码（V2 荒地语义）")
	_runner.assert_true(has_lake, "ID mask 含 254 湖泊保留码（块内湖不再是海色洞）")
	# 首都城块锚点像素 == lut_index（anchor = 聚落烘焙锚点，必在城块内；
	# 质心不可用——块含内湖时质心可能落在湖像素上（254））
	var tiles := _tiles_by_label(l3)
	var mismatch := 0
	var checked := 0
	for sid in states:
		var sd: Dictionary = states[sid]
		var label := int(str(sd.get("capital", "")).trim_prefix("settlement_city_"))
		var t: Dictionary = tiles.get(label, {})
		if t.is_empty():
			continue
		var a: Array = t.get("anchor", [0, 0])
		var v := int(img.get_pixel(int(a[0]), int(a[1])).r * 255.0 + 0.5)
		checked += 1
		if v != int(sd.get("lut_index", -1)):
			mismatch += 1
	_runner.assert_true(checked == N_STATES, "193 国首都全查（%d）" % checked)
	_runner.assert_equal(mismatch, 0, "首都质心像素 == lut_index（错 %d）" % mismatch)


func _test_l2_id_mask() -> void:
	var tex: Texture2D = load("res://config/strategic_map/l2_packs/region_013/l2_political_id.png")
	_runner.assert_true(tex != null, "l2_political_id.png 已导入（region_013）")
	if tex == null:
		return
	var img: Image = tex.get_image()
	_runner.assert_true(img != null and img.get_width() > 0, "L2 ID mask 可读")
	if img == null:
		return
	# 值域：政权码 1..193 + 保留码 253/254/255 + 0
	var bad := 0
	var has_state := false
	var has_reserved := false
	for y in range(0, img.get_height(), 7):
		for x in range(0, img.get_width(), 7):
			var v := int(img.get_pixel(x, y).r * 255.0 + 0.5)
			if v == PoliticalLut.CODE_LAKE or v == PoliticalLut.CODE_NEIGHBOR \
					or v == PoliticalLut.CODE_FREE_CITY:
				has_reserved = true
			elif v > 0:
				if v > N_STATES:
					bad += 1
				else:
					has_state = true
	_runner.assert_equal(bad, 0, "L2 mask 值域合法（越界 %d）" % bad)
	_runner.assert_true(has_state, "L2 mask 含政权码")
	_runner.assert_true(has_reserved, "L2 mask 含保留码（自由城邦/湖泊/邻区灰底）")


func _test_l3_states_loaded() -> void:
	var data = L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json", "res://config/strategic_map")
	_runner.assert_true(data != null, "L3 数据可加载")
	_runner.assert_true(data.states.size() == N_STATES,
			"states 经 bin 装载（实测 %d，193 国）" % data.states.size())
	var has_state_id := false
	for t in data.city_tiles:
		if str(t.get("state_id", "")).begins_with("state_"):
			has_state_id = true
			break
	_runner.assert_true(has_state_id, "city_tiles[].state_id 透传")
	var has_lut := false
	for sid in data.states:
		if int(data.states[sid].get("lut_index", 0)) > 0:
			has_lut = true
			break
	_runner.assert_true(has_lut, "states[].lut_index 透传（LUT 上色数据源）")


func _test_political_lut() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var data = L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json", "res://config/strategic_map")
	_runner.assert_true(data.states.size() == N_STATES, "前置：L3 states 已装载")
	var lut := PoliticalLut.shared_from_states(data.states)
	_runner.assert_true(lut != null, "PoliticalLut 可从 L3 states 构建")
	if lut == null:
		return
	_runner.assert_equal(lut.states.size(), N_STATES, "LUT 覆盖 193 国")
	_runner.assert_true(lut.texture != null, "LUT 纹理已建")
	# LUT 色与真相源一致（取一个非城邦样本）
	var sample := ""
	for s in pd.get("states", {}):
		if int(pd["states"][s].get("n_cities", 0)) > 3:
			sample = s
			break
	_runner.assert_true(not sample.is_empty(), "样本国存在")
	if sample.is_empty():
		return
	var col: Array = pd["states"][sample].get("color", [])
	var want := Color(float(col[0]) / 255.0, float(col[1]) / 255.0, float(col[2]) / 255.0)
	_runner.assert_true(lut.color_of(sample).is_equal_approx(want),
			"LUT 色 == political_data 色（%s）" % sample)
	# 保留码（自由城邦/湖泊/邻区灰底，与 L3/L2 mask 同码表）
	_runner.assert_true(lut.image.get_pixel(PoliticalLut.CODE_FREE_CITY, 0)
			.is_equal_approx(PoliticalLut.FREE_CITY_COLOR), "保留码 253 = 自由城邦灰")
	_runner.assert_true(lut.image.get_pixel(PoliticalLut.CODE_LAKE, 0)
			.is_equal_approx(PoliticalLut.LAKE_COLOR), "保留码 254 = 湖泊色")
	_runner.assert_true(lut.image.get_pixel(PoliticalLut.CODE_NEIGHBOR, 0)
			.is_equal_approx(PoliticalLut.NEIGHBOR_COLOR), "保留码 255 = 邻区灰底")
	# 「改 LUT 即换色」运行时链路自证（R9 验收硬指标）：set_state_color 改共享
	# LUT 图像并就地 texture.update()——shader 每帧采样该纹理，L2/L3 政治模式
	# 即刻换色、零重烘（headless 可证：图像像素即时变化 + update 路径无错）
	var before := lut.color_of(sample)
	# alt 必须 8bit 精确（image.set_pixel 按 RGBA8 量化，is_equal_approx 容差
	# 1e-5 判不出 0.5→127/255 的差——2026-09-11 色板改暖调后踩坑）
	var alt := Color8(0, 128, 255)
	lut.set_state_color(sample, alt)
	_runner.assert_true(lut.color_of(sample).is_equal_approx(alt),
			"set_state_color 后 LUT 像素即时更新（%s: %s → %s）" % [sample, before, alt])
	_runner.assert_true(lut.texture != null, "LUT 纹理在改色后仍有效（shader 持续采样）")
	# 还原（共享实例跨用例存活，别污染后续检查）
	lut.set_state_color(sample, want)
	_runner.assert_true(lut.color_of(sample).is_equal_approx(want), "还原原色")
