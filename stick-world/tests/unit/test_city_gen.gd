extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：CityGen 城市生成器（确定性种子 → 城市布局纯算法核心，喂 HD-2D 街图）。
## 管线已按域拆为纯函数步骤（city_gen_seq / city_gen_layout / city_gen_dress），
## 本套件两层验证：
## 1. 确定性契约：同 seed 同参 → plan 逐字段一致；换 seed 布局改变
## 2. 各 _step 域关键不变量（直调纯函数，AAA）：
##    序列规划（侧位合法/队列已烘/拼接不丢/杂物限额/2 层配额）、
##    街道排布（整格吸附/零重叠保距/行政居中唯一/城门居端/宽度口径）、
##    背景两层（数量守恒/跨度契约/已烘卡）、街具组装（吸附/同带互斥零穿模/
##    契约键/各行零重叠/建筑已烘）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
@warning_ignore("shadowed_global_identifier")
const CityGen := preload("res://modules/world/scripts/map/city_gen.gd")
const SeqPlan := preload("res://modules/world/scripts/map/city_gen_seq.gd")
const StreetLayout := preload("res://modules/world/scripts/map/city_gen_layout.gd")
const StreetDress := preload("res://modules/world/scripts/map/city_gen_dress.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("确定性契约: 同 seed 同参 plan 逐字段一致", _test_determinism_same_seed)
	_runner.add_test("确定性契约: 换 seed 布局改变", _test_seed_changes_layout)
	_runner.add_test("序列规划: 分区侧位与区队列不变量", _test_step_zone_queues)
	_runner.add_test("序列规划: 拼接/杂物/2 层配额不变量", _test_step_build_sequences)
	_runner.add_test("街道排布: 整格/零重叠/行政居中/城门/宽度", _test_step_layout_front_row)
	_runner.add_test("街道排布: 背景两层数量守恒与跨度契约", _test_step_background_rows)
	_runner.add_test("档位解析: 未知档回退 townlet", _test_resolve_profile_fallback)
	_runner.add_test("街具组装: 契约键 + 各行零重叠 + 建筑已烘", _test_step_assemble)
	_runner.add_test("街具组装: 道具 0.1 吸附 + 同带互斥零穿模", _test_props_exclusion)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## ── 公共 fixture：全档位走真实管线产物（宽表/占地表读盘，套件内一致）──────
func _widths() -> Dictionary:
	return CityGen.card_widths()


func _seq_out(tier: String, widths: Dictionary) -> Dictionary:
	# 走真实前序步骤拿 sides/queues，再进被测步骤（AAA 的 Arrange 用真管线）
	var conf: Dictionary = SeqPlan.resolve_profile(tier)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var zq: Dictionary = SeqPlan._step_zone_queues(conf["prof"], conf["pools"], widths, rng)
	return SeqPlan._step_build_sequences(tier, conf["pools"], widths, {},
			zq["sides"], zq["queues"], rng)


func _test_determinism_same_seed() -> void:
	var props: Dictionary = CityGen.prop_names()
	for tier: String in ["townlet", "capital"]:
		var a: Dictionary = CityGen.generate(tier, 777, props)
		var b: Dictionary = CityGen.generate(tier, 777, props)
		_runner.assert_equal(JSON.stringify(a), JSON.stringify(b),
				"%s 同 seed 两次生成逐字段一致" % tier)
	var c: Dictionary = CityGen.generate("hamlet", -3, {})
	var d: Dictionary = CityGen.generate("hamlet", -3, {})
	_runner.assert_equal(JSON.stringify(c), JSON.stringify(d),
			"hamlet 空 prop_set 同 seed 一致")


func _test_seed_changes_layout() -> void:
	var seen: Dictionary = {}
	for seed_v: int in [1, 2, 3, 4, 5]:
		var plan: Dictionary = CityGen.generate("town", seed_v, {})
		seen[JSON.stringify(plan)] = true
	_runner.assert_gt(seen.size(), 1, "5 个 seed 至少产出 2 种布局（非全同）")


func _test_step_zone_queues() -> void:
	var widths: Dictionary = _widths()
	for tier: String in ["hamlet", "town", "metropolis"]:
		var conf: Dictionary = SeqPlan.resolve_profile(tier)
		var rng := RandomNumberGenerator.new()
		rng.seed = 42
		var out: Dictionary = SeqPlan._step_zone_queues(conf["prof"], conf["pools"], widths, rng)
		var sides: Dictionary = out["sides"]
		var queues: Dictionary = out["queues"]
		for z: String in ["market", "craft", "living", "production", "storage"]:
			# 八档链各分区计数均 >0 → 全部分到侧位（±1），队列非空
			_runner.assert_true(int(sides[z]) in [-1, 1], "%s/%s 侧位合法" % [tier, z])
			_runner.assert_false((queues[z] as Array).is_empty(), "%s/%s 队列非空" % [tier, z])
		for z: String in queues:
			var seen: Dictionary = {}
			for d: String in queues[z]:
				# 未烘卡过滤：队列卡必须全部已烘（含兜底 house_w8）
				_runner.assert_true(widths.has(d), "%s/%s 队列卡已烘: %s" % [tier, z, d])
				seen[d] = int(seen.get(d, 0)) + 1
			for d: String in seen:
				if int(seen[d]) > 1:
					# 重复只放行 2 层卡白名单成员，且每 def 上限 2 张
					_runner.assert_true(SeqPlan.TALL2_DEFS.has(str(d).rsplit("_w", true, 1)[0]) \
							and int(seen[d]) <= 2,
							"%s/%s 重复卡必为 2 层白名单且 ≤2: %s×%d" % [tier, z, d, seen[d]])


func _test_step_build_sequences() -> void:
	var widths: Dictionary = _widths()
	for tier: String in ["village", "city"]:
		var conf: Dictionary = SeqPlan.resolve_profile(tier)
		var out: Dictionary = _seq_out(tier, widths)
		var seq: Dictionary = out["seq"]
		var clutter: Dictionary = out["clutter"]
		# 拼接不丢：两侧 seq 合计多重集 ⊇ 各区队列合计多重集（浮动/杂物/空档只增不减）
		var seq_count: Dictionary = {}
		for s: int in [-1, 1]:
			for d: String in seq[s]:
				seq_count[d] = int(seq_count.get(d, 0)) + 1
		var zq: Dictionary = SeqPlan._step_zone_queues(conf["prof"], conf["pools"], widths,
				_rng_at(42))
		var queue_count: Dictionary = {}
		for z: String in zq["queues"]:
			for d: String in zq["queues"][z]:
				queue_count[d] = int(queue_count.get(d, 0)) + 1
		for d: String in queue_count:
			_runner.assert_true(int(seq_count.get(d, 0)) >= int(queue_count[d]),
					"%s 队列卡 %s 全数入序列（%d≥%d）" % [tier, d, seq_count.get(d, 0), queue_count[d]])
		# 无未烘卡漏网：seq 每项要么已烘卡、要么空档槽、要么杂物
		for s: int in [-1, 1]:
			for d: String in seq[s]:
				_runner.assert_true(widths.has(d) or clutter.has(d) \
						or d == SeqPlan.GAP_SLOT or d == SeqPlan.GAP_SLOT_WIDE,
						"%s seq 项合法: %s" % [tier, d])
		# 杂物限额：每域 ≤ clutter_per_zone（村档 1 / 其余 2），仅仓储/生产两域 6 种
		var per_zone: int = 1 if tier in ["hamlet", "village", "townlet"] else 2
		_runner.assert_true(clutter.size() <= 2 * per_zone,
				"%s 杂物件数 ≤ 2域×%d（实得 %d）" % [tier, per_zone, clutter.size()])
		# 2 层配额补足：有配额档位（city=9）补位后 seq 内 2 层卡数 ≥ 配额
		var quota: int = int(SeqPlan.TALL2_QUOTA.get(tier, 0))
		if quota > 0:
			var n_tall := 0
			for s: int in [-1, 1]:
				for d: String in seq[s]:
					if SeqPlan.TALL2_DEFS.has(str(d).rsplit("_w", true, 1)[0]):
						n_tall += 1
			_runner.assert_true(n_tall >= quota,
					"%s 前排 2 层卡 %d ≥ 配额 %d" % [tier, n_tall, quota])


## 重放同一 seed 的步骤 1（配平+队列），供拼接不变量比对队列多重集
func _rng_at(seed_v: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	return rng


func _test_step_layout_front_row() -> void:
	var widths: Dictionary = _widths()
	var prop_fp: Dictionary = CityGen.prop_footprints()
	for tier: String in ["hamlet", "burgh"]:
		var conf: Dictionary = SeqPlan.resolve_profile(tier)
		var out: Dictionary = _seq_out(tier, widths)
		var front: Dictionary = StreetLayout._step_layout_front_row(conf["prof"],
				_step_queues(tier, widths), widths, prop_fp, {},
				out["seq"], out["clutter"])
		var placements: Array = front["placements"]
		# 整格吸附：每个落位 x 均为整数（创始人：建筑必须整格摆放）
		for p: Dictionary in placements:
			_runner.assert_true(is_equal_approx(float(p["x"]), roundf(float(p["x"]))),
					"%s 落位整格: %s@%s" % [tier, p["def"], p["x"]])
		# 零重叠保距：排序后相邻间距 ≥ 半宽和 + MIN_GAP（推挤保底承诺）
		var sorted_placements: Array = placements.duplicate()
		sorted_placements.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
		for i: int in range(1, sorted_placements.size()):
			var gap: float = float(sorted_placements[i]["x"]) - float(sorted_placements[i - 1]["x"]) \
					- (float(sorted_placements[i]["w"]) + float(sorted_placements[i - 1]["w"])) * 0.5
			_runner.assert_true(gap >= StreetLayout.MIN_GAP - 0.001,
					"%s 相邻间距 %.3f ≥ MIN_GAP" % [tier, gap])
		# 行政居中唯一 + 城门恰两座分居两端（door=true）
		var cores := 0
		var gates: Array = []
		for p: Dictionary in placements:
			if str(p["zone"]) == "core":
				cores += 1
			if str(p["zone"]) == "gate":
				gates.append(p)
				_runner.assert_true(bool(p["door"]), "%s 城门 door=true" % tier)
		_runner.assert_equal(cores, 1, "%s 行政槽恰 1 座" % tier)
		_runner.assert_equal(gates.size(), 2, "%s 城门恰 2 座" % tier)
		_runner.assert_true(float(gates[0]["x"]) < float(gates[1]["x"]),
				"%s 城门分列左右" % tier)
		_runner.assert_true(gates[0] == sorted_placements[0] or gates[1] == sorted_placements[0],
				"%s 最左落位是城门" % tier)
		_runner.assert_true(gates[0] == sorted_placements[sorted_placements.size() - 1] \
				or gates[1] == sorted_placements[sorted_placements.size() - 1],
				"%s 最右落位是城门" % tier)
		# 城市宽度口径：width_cells = 跨度 + 两侧墙留边（WALL_MARGIN×2）
		var lo: float = float(sorted_placements[0]["x"]) - float(sorted_placements[0]["w"]) * 0.5
		var hi: float = float(sorted_placements[sorted_placements.size() - 1]["x"]) \
				+ float(sorted_placements[sorted_placements.size() - 1]["w"]) * 0.5
		_runner.assert_equal(int(front["width_cells"]), int(round(hi - lo + StreetLayout.WALL_MARGIN * 2.0)),
				"%s width_cells = 跨度 + 墙留边" % tier)


## 重放步骤 1 取队列（与 _seq_out 同 seed 同参 → 与序列步骤入参一致）
func _step_queues(tier: String, widths: Dictionary) -> Dictionary:
	var conf: Dictionary = SeqPlan.resolve_profile(tier)
	return SeqPlan._step_zone_queues(conf["prof"], conf["pools"], widths, _rng_at(42))["queues"]


func _test_step_background_rows() -> void:
	var widths: Dictionary = _widths()
	for tier: String in ["hamlet", "metropolis"]:
		var conf: Dictionary = SeqPlan.resolve_profile(tier)
		var out: Dictionary = _seq_out(tier, widths)
		var front: Dictionary = StreetLayout._step_layout_front_row(conf["prof"],
				_step_queues(tier, widths), widths, CityGen.prop_footprints(), {},
				out["seq"], out["clutter"])
		var placements: Array = front["placements"]
		var bg: Dictionary = StreetLayout._step_background_rows(conf["pools"], widths,
				placements, _rng_at(7))
		var rows: Dictionary = bg["rows"]
		# 数量守恒：背景总数 = 2 × 前排分区建筑数（core/gate/clutter/gap 不产生背景）
		var zone_count := 0
		for p: Dictionary in placements:
			if not ["core", "gate", "clutter", "gap"].has(str(p["zone"])):
				zone_count += 1
		_runner.assert_equal(int(rows[1].size()) + int(rows[2].size()), 2 * zone_count,
				"%s 背景总数 = 2×分区建筑数（%d 对 %d）" % [tier, int(rows[1].size()) + int(rows[2].size()), zone_count])
		# 背景跨度契约：每排 ≥ 前排跨度 − 6（收 3 格/侧拉伸，推挤只增不减）
		var lo: float = INF
		var hi: float = -INF
		for p: Dictionary in placements:
			lo = minf(lo, float(p["x"]) - float(p["w"]) * 0.5)
			hi = maxf(hi, float(p["x"]) + float(p["w"]) * 0.5)
		for row: int in [1, 2]:
			var bs: Array = rows[row]
			_runner.assert_true(bs.size() >= 2, "%s 背景第 %d 排非退化" % [tier, row])
			bs.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
			var rlo: float = float(bs[0]["x"]) - float(bs[0]["w"]) * 0.5
			var rhi: float = float(bs[bs.size() - 1]["x"]) + float(bs[bs.size() - 1]["w"]) * 0.5
			_runner.assert_true(rhi - rlo >= (hi - lo) - 6.0 - 0.01,
					"%s 第 %d 排跨度 %.1f ≥ 前排 %.1f − 6" % [tier, row, rhi - rlo, hi - lo])


func _test_resolve_profile_fallback() -> void:
	var conf: Dictionary = SeqPlan.resolve_profile("nonexistent_tier")
	_runner.assert_equal(conf["prof"], SeqPlan.TIERS["townlet"], "未知档 prof 回退 townlet")
	_runner.assert_equal(conf["pools"], SeqPlan.ZONE_POOLS["townlet"], "未知档 pools 回退 townlet")
	_runner.assert_equal(SeqPlan.resolve_profile("town")["prof"], SeqPlan.TIERS["town"],
			"已知档取原配置")


func _test_step_assemble() -> void:
	var widths: Dictionary = _widths()
	var plan: Dictionary = CityGen.generate("burgh", 2024, {})
	# layout_data 契约键：cell_w/tier/seed 回显、buildings/props/trees 齐备
	_runner.assert_equal(int(plan["cell_w"]), 32, "契约 cell_w=32")
	_runner.assert_equal(str(plan["tier"]), "burgh", "契约 tier 回显")
	_runner.assert_equal(int(plan["seed"]), 2024, "契约 seed 回显")
	_runner.assert_true(int(plan["width_cells"]) > 0, "width_cells > 0")
	_runner.assert_true((plan["trees"] as Array).is_empty(), "trees 空（本版不出树）")
	# 各排零重叠：产物级修复后同排相邻间距 ≥ 半宽和 + MIN_GAP
	var rows: Dictionary = {}
	for b: Dictionary in plan["buildings"]:
		var row: int = int(b["row"])
		if not rows.has(row):
			rows[row] = []
		rows[row].append(b)
	for row: int in rows:
		var bs: Array = rows[row]
		_runner.assert_true(bs.size() > 0, "第 %d 排非空" % row)
		bs.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
		for i: int in range(1, bs.size()):
			var gap: float = float(bs[i]["x"]) - float(bs[i - 1]["x"]) \
					- (float(bs[i]["cells"]) + float(bs[i - 1]["cells"])) * 0.5
			_runner.assert_true(gap >= StreetLayout.MIN_GAP - 0.01,
					"第 %d 排相邻间距 %.3f ≥ MIN_GAP" % [row, gap])
	for b: Dictionary in plan["buildings"]:
		# 空档槽只占格不出卡（不出现在产物）；背景排取自未过滤分区池，卡可未烘
		# （渲染端兜底）——已烘过滤的断言在队列/序列/前排各步
		_runner.assert_false(str(b["card"]).begins_with("_gap"), "空档槽不出卡")
	for b: Dictionary in plan["buildings"]:
		if int(b["row"]) == 0:
			# 前排口径：全部经未烘过滤（区队列/浮动/行政候选），卡必已烘
			_runner.assert_true(widths.has(str(b["card"])), "前排建筑卡已烘: " + str(b["card"]))


func _test_props_exclusion() -> void:
	var plan: Dictionary = CityGen.generate("city", 555, {})   # prop_set 空 → 避让半宽走默认 1.5
	var props: Array = plan["props"]
	_runner.assert_true(props.size() > 0, "city 档有街具产出")
	# 落位吸附：x 全部有限且对齐 0.1 格（"测的值=最终值"口径）
	for pr: Dictionary in props:
		var x: float = float(pr["x"])
		_runner.assert_true(is_finite(x), "道具 %s x 有限" % pr["card"])
		_runner.assert_true(is_equal_approx(x, snappedf(x, 0.1)),
				"道具 %s x 吸附 0.1 格" % pr["card"])
	# 同带互斥零穿模：|Δz|<1.5 的道具对，占格区间不相交（≥1.5 前后遮挡合法）
	for i: int in props.size():
		for j: int in range(i + 1, props.size()):
			var a: Dictionary = props[i]
			var b: Dictionary = props[j]
			if absf(float(a["z"]) - float(b["z"])) >= StreetDress.PROP_EXCL_BAND:
				continue
			var ha := _prop_half(a)
			var hb := _prop_half(b)
			var clear: bool = float(a["x"]) + ha <= float(b["x"]) - hb + 0.0001 \
					or float(b["x"]) + hb <= float(a["x"]) - ha + 0.0001
			_runner.assert_true(clear, "同带道具不穿模: %s@%s / %s@%s" % [a["card"], a["x"], b["card"], b["x"]])


## 道具占格半宽（与 _step_street_props 登记表同口径）：
## 杂物=occ_cells/2；灯柱=1.0（登记 [lx±1]）；空 prop_set 下功能件默认半宽 1.5/2+0.1
func _prop_half(pr: Dictionary) -> float:
	if pr.has("occ_cells"):
		return float(pr["occ_cells"]) * 0.5
	if StreetDress.FURNITURE_LAMPS.has(str(pr["card"])):
		return 1.0
	return 0.85
