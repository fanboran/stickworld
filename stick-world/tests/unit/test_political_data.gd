extends Node
## 单元测试：政权数据一致性（R7 扩容 80 国 + ID mask/LUT 运行时链路，总体设计 §5.11）。
##
## 覆盖：political_data.json 全量覆盖（1040 城无缺漏/无孤儿）/ 归属合法性 +
## 字段完整 / 政权总数 == 80（创始人 2026-09-08 定档）/ 出生 8 城邦沿用
## l1_world.json 原样（state_id+色不变，LUT 序号排尾）/ lut_index 1..80 连续唯一
## / l3_city 注入一致（state_id+城文化）/ L2 packs 注入一致 / 文化圈锚定
## （首都城文化 == 国文化 100%，城文化归属一致率 ≥95%，9 圈都有政权）
## / L3 ID mask 与 json 一致（首都 anchor 像素 == lut_index，值域合法）
## / L2 ID mask 保留码（254 湖泊 / 255 邻区）/ L3WorldData.states bin 装载
## / PoliticalLut 构建与「改 LUT 即换色」运行时链路（R9 验收硬指标的自证）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const L3WorldData := preload("res://modules/world_map/data/l3_world_data.gd")
const PoliticalLut := preload("res://modules/world_map/data/political_lut.gd")

## 硬锚点文化圈 → 合法 region 集（§5.11.1 种族-地域表 / state_params.json cultures：
## 火焰=region_008、水=region_011、极地=北部冰原带 1/2/3/9、沙漠=南部荒漠带
## 10+南探 6/11、森林=region_004、雪山=region_007）；测试夹具与参数表同源
const LEGAL_REGIONS := {
	"fire": [8], "water": [11], "forest": [4], "giant": [7],
	"polar": [1, 2, 3, 9], "desert": [10, 6, 11],
	"golden": [5, 12], "nomad": [6], "plain": [13],
}
## 越界宽忍度：末轮兜底（圈飞地被邻国实际控制）允许的占比上限
const MAX_REGION_VIOL_RATIO := 0.02
const N_CULTURES := 9
const N_STATES := 80

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("political_data: 城主表全量覆盖", _test_full_coverage)
	_runner.add_test("political_data: 归属全部合法 + 字段完整", _test_owners_legal)
	_runner.add_test("政权总数 == 80（8 城邦 + 72 新国，Zipf 型碎度窗口）", _test_total_states)
	_runner.add_test("出生 8 城邦原样沿用（id+色不变，LUT 序号排尾）", _test_birth_states_preserved)
	_runner.add_test("lut_index 1..80 连续唯一", _test_lut_index_coverage)
	_runner.add_test("l3_city 注入与真相源一致", _test_l3_city_injection)
	_runner.add_test("L2 packs 注入一致（13 地区）", _test_l2_injection)
	_runner.add_test("文化圈锚定（首都 100% / 全城一致率 ≥95% / 9 圈有政权）", _test_culture_anchoring)
	_runner.add_test("L3 ID mask 与 json 一致（首都 anchor 像素 == lut_index）", _test_l3_id_mask)
	_runner.add_test("L2 ID mask 值域与保留码（湖泊/邻区）", _test_l2_id_mask)
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
	_runner.assert_equal(owners.size(), expect, "城主表 = l3_city 城总数")
	var empty := 0
	for k in owners:
		if str(owners[k]).is_empty():
			empty += 1
	_runner.assert_equal(empty, 0, "无空归属")


func _test_owners_legal() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var bad := 0
	for k in pd.get("city_owners", {}):
		if not states.has(pd["city_owners"][k]):
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
	var n_city_state := 0
	for sid in states:
		if states[sid].get("is_city_state", false):
			n_city_state += 1
	_runner.assert_equal(states.size(), N_STATES,
			"政权总数定档 80（实测 %d）" % states.size())
	_runner.assert_equal(n_city_state, 8, "出生城邦 8 个（实测 %d）" % n_city_state)
	_runner.assert_equal(int(pd.get("meta", {}).get("n_states", 0)), N_STATES,
			"meta.n_states = 80")
	# 碎度窗口：Zipf 型大小悬殊（最大国 ≥ 4 倍中位数、上限防巨无霸、每国 ≥1 城）
	var counts := {}
	for k in pd.get("city_owners", {}):
		var sid: String = pd["city_owners"][k]
		counts[sid] = int(counts.get(sid, 0)) + 1
	var sizes: Array = []
	for sid in states:
		if not states[sid].get("is_city_state", false):
			sizes.append(int(counts.get(sid, 0)))
	sizes.sort()
	var smin: int = sizes[0]
	var smax: int = sizes[sizes.size() - 1]
	var median: int = sizes[sizes.size() / 2]
	_runner.assert_true(smin >= 1, "新国每国至少 1 城（min=%d）" % smin)
	_runner.assert_true(smax >= median * 4,
			"大小悬殊（max=%d 应 ≥ 4×中位数 %d，Zipf 型）" % [smax, median])
	_runner.assert_true(smax <= 120, "单国城数 ≤ 120（实测 %d）" % smax)


func _test_birth_states_preserved() -> void:
	var birth := _read_json("res://config/strategic_map/l1_world.json")
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var owners: Dictionary = pd.get("city_owners", {})
	var ok := true
	for s in (birth.get("states", []) as Array):
		var sid: String = s["state_id"]
		if not states.has(sid):
			ok = false
			break
		if states[sid].get("color", []) != s.get("color", []):
			ok = false
			break
	_runner.assert_true(ok, "出生 states 的 id/色在 political_data 中原样")
	# 出生城邦 LUT 序号排尾（73..80），新国占 1..72
	var birth_idx: Array = []
	for sid in states:
		if states[sid].get("is_city_state", false):
			birth_idx.append(int(states[sid].get("lut_index", 0)))
	birth_idx.sort()
	_runner.assert_true(birth_idx == [73, 74, 75, 76, 77, 78, 79, 80],
			"出生城邦 lut_index = 73..80（实测 %s）" % str(birth_idx))
	for tl in (birth.get("tiles", []) as Array):
		var s: Dictionary = tl.get("settlement", {})
		_runner.assert_equal(str(owners.get(s.get("settlement_id", ""), "")),
				str(tl.get("owner_state_id", "")), "出生城归属沿用 owner_state_id")


func _test_lut_index_coverage() -> void:
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var idx: Array = []
	for sid in pd.get("states", {}):
		idx.append(int(pd["states"][sid].get("lut_index", 0)))
	idx.sort()
	_runner.assert_true(idx == range(1, N_STATES + 1),
			"lut_index 应恰为 1..80（实测 %d 个，尾=%s）" % [idx.size(), str(idx.slice(mini(idx.size() - 3, 0)))])


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
	var pd := _read_json("res://config/strategic_map/political_data.json")
	var states: Dictionary = pd.get("states", {})
	var l3 := _read_json("res://config/strategic_map/l3_city.json")
	# 9 文化圈都有政权（含 6 硬锚点圈：火焰/水/森林/雪山/极地/沙漠）
	var cultures := {}
	for sid in states:
		cultures[str(states[sid].get("culture", ""))] = true
	var missing := 0
	for c in LEGAL_REGIONS:
		if not cultures.has(c):
			missing += 1
	_runner.assert_equal(missing, 0, "硬锚点文化圈都有政权")
	_runner.assert_true(cultures.size() >= N_CULTURES,
			"文化圈全覆盖（实测 %d 圈）" % cultures.size())
	# 首都城文化 == 国文化（生成端种子只在合法区选 → 应 100%）
	var tiles := _tiles_by_label(l3)
	var cap_bad := 0
	var cap_checked := 0
	for sid in states:
		var sd: Dictionary = states[sid]
		var label := int(str(sd.get("capital", "")).trim_prefix("settlement_city_"))
		var t: Dictionary = tiles.get(label, {})
		if t.is_empty():
			continue
		cap_checked += 1
		if str(t.get("culture", "")) != str(sd.get("culture", "")):
			cap_bad += 1
	_runner.assert_true(cap_checked == N_STATES, "首都城全部查到（%d）" % cap_checked)
	_runner.assert_equal(cap_bad, 0, "首都城文化 == 国文化（越界 %d）" % cap_bad)
	# §5.11.1 region 锚定（政权必须落在对应文化圈合法区）：tile.region ∈
	# 所属国文化合法区。越界只允许来自末轮兜底（圈飞地被邻国实际控制），
	# 总量 ≤2%，且硬锚点圈（火焰/水/森林/雪山/极地）零越界
	var viol := 0
	var hard_viol := 0
	var total := 0
	for t in (l3.get("tiles", []) as Array):
		var sid := str(t.get("state_id", ""))
		if sid.is_empty() or not states.has(sid):
			continue
		total += 1
		var cu := str(states[sid].get("culture", ""))
		var region := int(t.get("region", -1))
		if not LEGAL_REGIONS.get(cu, []).has(region):
			viol += 1
			if cu in ["fire", "water", "forest", "giant", "polar"]:
				hard_viol += 1
	_runner.assert_true(total > 1000, "参查城数（%d）" % total)
	_runner.assert_equal(hard_viol, 0, "硬锚点圈 region 零越界（越界 %d）" % hard_viol)
	_runner.assert_true(float(viol) / float(maxi(total, 1)) <= MAX_REGION_VIOL_RATIO,
			"region 越界 ≤2%%（实测 %d/%d）" % [viol, total])


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
	# 值域：只允许 0..80（0 = 海/无）——稀疏采样 ~20 万点
	var bad_val := 0
	var n := 8192 * 8192
	var step := 8192 * 33 + 17
	for i in range(0, n, step):
		var v := int(img.get_pixel(i % 8192, int(i / 8192.0)).r * 255.0 + 0.5)
		if v > states.size():
			bad_val += 1
	_runner.assert_equal(bad_val, 0, "ID mask 值域 ⊆ 0..80（稀疏采样越界 %d）" % bad_val)
	# 首都 anchor 像素 == lut_index（anchor 是 8192 级 [x,y]）
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
	_runner.assert_true(checked == N_STATES, "80 国首都全查（%d）" % checked)
	_runner.assert_equal(mismatch, 0, "首都 anchor 像素 == lut_index（错 %d）" % mismatch)


func _test_l2_id_mask() -> void:
	var tex: Texture2D = load("res://config/strategic_map/l2_packs/region_013/l2_political_id.png")
	_runner.assert_true(tex != null, "l2_political_id.png 已导入（region_013）")
	if tex == null:
		return
	var img: Image = tex.get_image()
	_runner.assert_true(img != null and img.get_width() > 0, "L2 ID mask 可读")
	if img == null:
		return
	# 值域：政权码 1..80 + 保留码 254/255 + 0
	var bad := 0
	var has_state := false
	var has_reserved := false
	for y in range(0, img.get_height(), 7):
		for x in range(0, img.get_width(), 7):
			var v := int(img.get_pixel(x, y).r * 255.0 + 0.5)
			if v == PoliticalLut.CODE_LAKE or v == PoliticalLut.CODE_NEIGHBOR:
				has_reserved = true
			elif v > 0:
				if v > N_STATES:
					bad += 1
				else:
					has_state = true
	_runner.assert_equal(bad, 0, "L2 mask 值域合法（越界 %d）" % bad)
	_runner.assert_true(has_state, "L2 mask 含政权码")
	_runner.assert_true(has_reserved, "L2 mask 含保留码（湖泊/邻区灰底）")


func _test_l3_states_loaded() -> void:
	var data = L3WorldData.load_from(
			"res://config/strategic_map/l3_world.json", "res://config/strategic_map")
	_runner.assert_true(data != null, "L3 数据可加载")
	_runner.assert_true(data.states.size() == N_STATES,
			"states 经 bin 装载（实测 %d）" % data.states.size())
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
	_runner.assert_equal(lut.states.size(), N_STATES, "LUT 覆盖 80 国")
	_runner.assert_true(lut.texture != null, "LUT 纹理已建")
	# LUT 色与真相源一致（取一个非城邦样本）
	var sample := ""
	for s in pd.get("states", {}):
		if not pd["states"][s].get("is_city_state", false):
			sample = s
			break
	_runner.assert_true(not sample.is_empty(), "样本国存在")
	if sample.is_empty():
		return
	var col: Array = pd["states"][sample].get("color", [])
	var want := Color(float(col[0]) / 255.0, float(col[1]) / 255.0, float(col[2]) / 255.0)
	_runner.assert_true(lut.color_of(sample).is_equal_approx(want),
			"LUT 色 == political_data 色（%s）" % sample)
	# 保留码（湖泊/邻区灰底，与 L2 mask 同源）
	_runner.assert_true(lut.image.get_pixel(PoliticalLut.CODE_LAKE, 0)
			.is_equal_approx(PoliticalLut.LAKE_COLOR), "保留码 254 = 湖泊色")
	_runner.assert_true(lut.image.get_pixel(PoliticalLut.CODE_NEIGHBOR, 0)
			.is_equal_approx(PoliticalLut.NEIGHBOR_COLOR), "保留码 255 = 邻区灰底")
	# 「改 LUT 即换色」运行时链路自证（R9 验收硬指标）：set_state_color 改共享
	# LUT 图像并就地 texture.update()——shader 每帧采样该纹理，L2/L3 政治模式
	# 即刻换色、零重烘（headless 可证：图像像素即时变化 + update 路径无错）
	var before := lut.color_of(sample)
	var alt := Color(1.0, 0.0, 0.0) if before.r < 0.5 else Color(0.0, 0.5, 1.0)
	lut.set_state_color(sample, alt)
	_runner.assert_true(lut.color_of(sample).is_equal_approx(alt),
			"set_state_color 后 LUT 像素即时更新（%s: %s → %s）" % [sample, before, alt])
	_runner.assert_true(lut.texture != null, "LUT 纹理在改色后仍有效（shader 持续采样）")
	# 还原（共享实例跨用例存活，别污染后续检查）
	lut.set_state_color(sample, want)
	_runner.assert_true(lut.color_of(sample).is_equal_approx(want), "还原原色")
