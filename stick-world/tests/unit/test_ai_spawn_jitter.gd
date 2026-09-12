extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：W2 · WorldBox 决策冷却错峰假偏移（设计文档12号 §2.4 W2；逆向笔记
## 《1-个体AI内核》§二 M4 + §三 Top2）。
## 覆盖：① 主决策节拍绝对世界时刻语义（首个到期 = 装配后 interval，与旧 delta
## 累加器逐拍等价；时钟大跳变不连爆）/ ② 出生错峰假偏移（边界、确定性、N=20
## 离散度、域级通道独立）/ ③ 域级探测失败冷却门控（关 = 逐拍重试，现状语义锁定）/
## get_decision_timing_state 字段与到期行为一致 / 档案缺载兜底。
## 不进场景树主流程（确定性：时钟注入 + 档案注入 + 固定种子；BalanceConfig 行
## 注入后须还原，先例 test_ai_param_panel）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
const ScriptAIController := preload("res://modules/units/scripts/ai/ai_controller.gd")

## 基准间隔（代码默认 decision_interval；镜像旧 DECISION_INTERVAL 常量）
const BASE_INTERVAL: float = 0.3

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("W2 关：首个到期 = 装配时刻 + interval（旧累加器逐拍等价）", _test_off_equivalent)
	_runner.add_test("W2 开：首个到期落于 [now+i×(1-ratio), now+i]（比例边界）", _test_on_bounds)
	_runner.add_test("W2 确定性：同种子一致、异种子错开", _test_seed_determinism)
	_runner.add_test("W2 防齐套：20 单位首次到期离散度显著", _test_batch_dispersion)
	_runner.add_test("W2 绝对时刻：时钟大跳变只触发一拍（不连爆）", _test_absolute_clock_no_burst)
	_runner.add_test("W2 域级独立错峰：各通道自持边界与间隔", _test_domain_independence)
	_runner.add_test("W2 get_decision_timing_state 字段齐全且与到期行为一致", _test_timing_state)
	_runner.add_test("W2 缺载兜底：档案移除后代码默认不崩且默认关", _test_config_missing)
	_runner.add_test("W2 ③ 域级失败冷却：关=逐拍重试 / 开=入间隔冷却", _test_probe_fail_cooldown)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试桩 ────────────────────────────────

## 可拨针假时钟（注入 ai.clock_override = Callable(clock, "get_now")）
class _FakeClock extends RefCounted:
	var now: float = 0.0

	func get_now() -> float:
		return now


# ─────────────────────────────── 档案注入 ────────────────────────────────

func _inject_rows(rows: Array) -> void:
	BalanceConfig.data["ai.behavior_profiles"] = rows
	ScriptBehaviorProfiles._cache.clear()


func _restore_rows() -> void:
	# 走装载器同款清理（类型键 + 前缀行键 + _type_paths 同步）后按 .tres 原样回装，
	# 与 test_ai_param_panel 同款——防污染后续套件（该类型是 BalanceConfig 常驻数据）。
	BalanceConfig._remove_type_data("ai.behavior_profiles")
	BalanceConfig._load_tres("res://config/ai/behavior_profiles.tres", "ai.behavior_profiles")
	ScriptBehaviorProfiles._cache.clear()


## 造一个注入了时钟与种子的 AI 控制器（裸 new，不进场景树：时钟/种子全注入，
## 决策时钟族不依赖实体，_get_behavior_profile 对 null 实体回落 SWORD 档）
func _make_ai(clock: _FakeClock, jitter_seed: int) -> AIController:
	var ai: AIController = ScriptAIController.new()
	ai.clock_override = Callable(clock, "get_now")
	ai.jitter_seed_override = jitter_seed
	return ai


# ─────────────────── ① 关：与旧累加器逐拍等价 ────────────────────

func _test_off_equivalent() -> void:
	_restore_rows()  # .tres 基线：spawn_jitter_enabled=false（零回归闸门）
	var ai: AIController = _make_ai(_FakeClock.new(), 1234)
	ai.apply_spawn_jitter()
	# 旧语义 = "从 0 起累计"：首次触发落在装配后 interval 秒
	_runner.assert_approx(ai._next_decision_at, BASE_INTERVAL, 0.000001,
			"错峰关：首个到期 = 装配时刻(0) + interval(0.3)")
	var st: Dictionary = ai.get_decision_timing_state()
	_runner.assert_true(not bool(st["jitter_enabled"]), "错峰关：jitter_enabled=false")
	_runner.assert_true(float(ai._domain_next_at.get("combat", 0.0)) <= 0.0,
			"错峰关：域级通道立即到期（无假偏移）")

	# 逐拍等价演示：1/64 步长（二进制可精确表示，消除浮点累加噪声）下
	# 新绝对时刻模型与旧 delta 累加器模型的触发帧号必须逐一相同
	var d: float = 1.0 / 64.0
	var clock := _FakeClock.new()
	var ref_frames: Array = []
	var new_frames: Array = []
	var timer: float = 0.0
	for i in 600:
		timer += d
		if timer >= BASE_INTERVAL:
			timer = 0.0
			ref_frames.append(i)
		clock.now += d
		if ai._advance_decision_clock(clock.now):
			new_frames.append(i)
	_runner.assert_equal(new_frames.size(), ref_frames.size(), "600 帧触发拍数与旧累加器一致")
	var mismatches: int = 0
	for k in mini(ref_frames.size(), new_frames.size()):
		if int(ref_frames[k]) != int(new_frames[k]):
			mismatches += 1
	_runner.assert_equal(mismatches, 0, "逐拍触发帧号零偏差（等价旧累加器语义）")
	_runner.assert_true(ref_frames.size() >= 29, "触发拍数合理（实测 %d 拍）" % ref_frames.size())

	# 1/60 步长（真实物理帧、浮点累加有噪声）：拍数仍一致，帧号偏差 ≤1（量化误差）
	var d2: float = 1.0 / 60.0
	var clock2 := _FakeClock.new()
	var ai2: AIController = _make_ai(_FakeClock.new(), 1234)
	ai2.apply_spawn_jitter()
	var ref2: Array = []
	var new2: Array = []
	var timer2: float = 0.0
	for i in 600:
		timer2 += d2
		if timer2 >= BASE_INTERVAL:
			timer2 = 0.0
			ref2.append(i)
		clock2.now += d2
		if ai2._advance_decision_clock(clock2.now):
			new2.append(i)
	_runner.assert_equal(new2.size(), ref2.size(), "1/60 步长触发拍数一致")
	var max_delta: int = 0
	for k in mini(ref2.size(), new2.size()):
		max_delta = maxi(max_delta, absi(int(ref2[k]) - int(new2[k])))
	_runner.assert_true(max_delta <= 1, "1/60 步长帧号偏差 ≤1（实测 %d）" % max_delta)
	ai.free()
	ai2.free()


# ─────────────────── ② 开：假偏移边界 / 确定性 / 离散度 ────────────────────

## 注入错峰档案行（比例/间隔可调；方差恒 0 保确定性）
func _inject_jitter(interval: float, ratio: float) -> void:
	_inject_rows([{
		"id": "baseline",
		"decision_interval": interval,
		"decision_variance": 0.0,
		"spawn_jitter_enabled": true,
		"spawn_jitter_ratio": ratio,
		"acquire_interval": 0.4,
		"job_scan_interval": 0.5,
	}])


func _test_on_bounds() -> void:
	var interval: float = 0.4
	var ratio: float = 0.5
	_inject_jitter(interval, ratio)
	var lo: float = INF
	var hi: float = -INF
	for s in 64:
		var ai: AIController = _make_ai(_FakeClock.new(), 5000 + s)
		ai.apply_spawn_jitter()
		lo = minf(lo, ai._next_decision_at)
		hi = maxf(hi, ai._next_decision_at)
		ai.free()
	_runner.assert_true(lo >= interval * (1.0 - ratio) - 0.000001,
			"首个到期下界 now + interval×(1-ratio)（实测 %.4f）" % lo)
	_runner.assert_true(hi <= interval + 0.000001, "首个到期上界 now + interval（实测 %.4f）" % hi)
	_runner.assert_true(hi - lo > interval * 0.1, "假偏移真实生效（极差 %.4f > 0）" % (hi - lo))

	# 比例边界：ratio=1 → 下界 now；ratio=0 → 恒为 now + interval（等价关闭）
	_inject_jitter(interval, 1.0)
	var lo1: float = INF
	for s in 32:
		var a1: AIController = _make_ai(_FakeClock.new(), 7000 + s)
		a1.apply_spawn_jitter()
		lo1 = minf(lo1, a1._next_decision_at)
		if a1._next_decision_at > interval + 0.000001:
			_runner.assert_true(false, "ratio=1 越过上界 interval")
			break
		a1.free()
	_runner.assert_true(lo1 < interval, "ratio=1 可取到近似 now（实测最小 %.4f）" % lo1)
	_inject_jitter(interval, 0.0)
	for s in 8:
		var a0: AIController = _make_ai(_FakeClock.new(), 8000 + s)
		a0.apply_spawn_jitter()
		_runner.assert_approx(a0._next_decision_at, interval, 0.000001, "ratio=0 恒为 now+interval")
		a0.free()
	_restore_rows()


func _test_seed_determinism() -> void:
	_inject_jitter(BASE_INTERVAL, 0.5)
	var a: AIController = _make_ai(_FakeClock.new(), 7)
	a.apply_spawn_jitter()
	var b: AIController = _make_ai(_FakeClock.new(), 7)
	b.apply_spawn_jitter()
	var c: AIController = _make_ai(_FakeClock.new(), 8)
	c.apply_spawn_jitter()
	_runner.assert_approx(a._next_decision_at, b._next_decision_at, 0.0,
			"同种子两次装配产物逐位一致（%.6f）" % a._next_decision_at)
	_runner.assert_true(absf(a._next_decision_at - c._next_decision_at) > 0.000001,
			"异种子产物不同（%.6f vs %.6f）" % [a._next_decision_at, c._next_decision_at])
	_runner.assert_equal(int(a.get_decision_timing_state()["jitter_seed"]), 7, "状态回报注入种子")
	a.free()
	b.free()
	c.free()
	_restore_rows()


func _test_batch_dispersion() -> void:
	# 兵营爆兵场景：一批 N=20 个单位的首次到期时刻极差须显著
	#（> interval×0.2），否则群体决策仍齐套成尖峰
	_inject_jitter(BASE_INTERVAL, 0.5)
	var lo: float = INF
	var hi: float = -INF
	for s in 20:
		var ai: AIController = _make_ai(_FakeClock.new(), 100 + s)
		ai.apply_spawn_jitter()
		lo = minf(lo, ai._next_decision_at)
		hi = maxf(hi, ai._next_decision_at)
		ai.free()
	var spread: float = hi - lo
	_runner.assert_true(spread > BASE_INTERVAL * 0.2,
			"N=20 首次到期极差 %.4f > interval×0.2(%.4f)" % [spread, BASE_INTERVAL * 0.2])
	_runner.assert_true(hi <= BASE_INTERVAL + 0.000001, "极差上界不越 interval")
	_restore_rows()


# ─────────────────── ① 绝对时刻：跳变不连爆 ────────────────────

func _test_absolute_clock_no_burst() -> void:
	_restore_rows()
	var clock := _FakeClock.new()
	var ai: AIController = _make_ai(clock, 42)
	ai.apply_spawn_jitter()
	_runner.assert_true(not ai._advance_decision_clock(0.29), "0.29 < 0.3 未到点")
	# 时钟大跳变（读档/长暂停）：绝对时刻语义只触发一拍，不按 floor(10/0.3) 连爆
	clock.now = 10.0
	_runner.assert_true(ai._advance_decision_clock(clock.now), "跳变后到点触发一拍")
	var st: Dictionary = ai.get_decision_timing_state()
	_runner.assert_equal(int(st["decision"]["beats"]), 1, "跳变后主节拍累计 1 拍（非 33 拍）")
	_runner.assert_approx(float(st["decision"]["next_at"]), 10.0 + BASE_INTERVAL, 0.000001,
			"下次到期锚定当前时刻 + 间隔（不追赶欠账）")
	_runner.assert_true(not ai._advance_decision_clock(10.0), "同刻重复调用不重复触发")
	_runner.assert_true(not ai._advance_decision_clock(10.29), "10.29 仍未到点")
	_runner.assert_true(ai._advance_decision_clock(10.31), "10.31 到点")
	_runner.assert_equal(int(ai.get_decision_timing_state()["decision"]["beats"]), 2, "累计 2 拍")
	ai.free()


# ─────────────────── ② 域级通道独立错峰 ────────────────────

func _test_domain_independence() -> void:
	# 主节拍 0.3 / 选敌 0.4（sword 档）/ 派工采集 0.5：三通道各抽一次随机数 = 独立
	_inject_jitter(BASE_INTERVAL, 0.5)
	var a: AIController = _make_ai(_FakeClock.new(), 2024)
	a.apply_spawn_jitter()
	var d_off: float = a._next_decision_at
	var c_off: float = float(a._domain_next_at.get("combat", -1.0))
	var j_off: float = float(a._domain_next_at.get("job", -1.0))
	_runner.assert_true(d_off >= 0.15 and d_off <= 0.3 + 0.000001, "主节拍偏移在自己界内（%.4f）" % d_off)
	_runner.assert_true(c_off >= 0.2 - 0.000001 and c_off <= 0.4 + 0.000001,
			"选敌通道偏移在 acquire_interval 界内（%.4f）" % c_off)
	_runner.assert_true(j_off >= 0.25 - 0.000001 and j_off <= 0.5 + 0.000001,
			"派工通道偏移在 job_scan_interval 界内（%.4f）" % j_off)
	_runner.assert_true(not (is_equal_approx(d_off, c_off) and is_equal_approx(c_off, j_off)),
			"三通道独立抽样（非同一个偏移复制：%.4f/%.4f/%.4f）" % [d_off, c_off, j_off])
	# 域级假偏移真实生效（不是惰性数据）：装配后到点前该通道探测被门控
	var clock := _FakeClock.new()
	var b: AIController = _make_ai(clock, 2024)
	b.apply_spawn_jitter()
	var b_off: float = float(b._domain_next_at.get("combat", -1.0))
	_runner.assert_true(not b._probe_domain_due("combat"),
			"错峰开：选敌探测在假偏移到点前被门控（偏移 %.4f）" % b_off)
	clock.now = b_off - 0.000001
	_runner.assert_true(not b._probe_domain_due("combat"), "假偏移到点前一位仍不可探测")
	clock.now = b_off
	_runner.assert_true(b._probe_domain_due("combat"), "假偏移到点恢复探测")
	# 派工通道按自己的偏移独立到期（与选敌通道到点与否无关）
	var b_job: float = float(b._domain_next_at.get("job", -1.0))
	clock.now = maxf(b_off, b_job) - 0.000001
	_runner.assert_true(not b._probe_domain_due("job"),
			"派工通道在自己的偏移到点前仍被门控（偏移 %.4f，当前 %.4f）" % [b_job, clock.now])
	clock.now = b_job
	_runner.assert_true(b._probe_domain_due("job"), "派工通道按自身偏移到点（%.4f）" % b_job)
	b.free()

	# 各通道用自己的间隔：20 个种子里选敌通道必有 > 主节拍上界的样本
	#（0.4 档 > 0.3），证明域级偏移不是主节拍偏移的派生
	var max_combat: float = -INF
	var max_decision: float = -INF
	for s in 20:
		var ai: AIController = _make_ai(_FakeClock.new(), 300 + s)
		ai.apply_spawn_jitter()
		max_combat = maxf(max_combat, float(ai._domain_next_at.get("combat", -1.0)))
		max_decision = maxf(max_decision, ai._next_decision_at)
		ai.free()
	_runner.assert_true(max_combat > BASE_INTERVAL + 0.000001,
			"选敌通道按自身间隔(0.4)抽样（实测最大 %.4f > 0.3）" % max_combat)
	_runner.assert_true(max_decision <= BASE_INTERVAL + 0.000001,
			"主节拍上界仍为 0.3（实测最大 %.4f）" % max_decision)
	a.free()
	_restore_rows()


# ─────────────────── 观测面 / 缺载 / ③ 门控 ────────────────────

func _test_timing_state() -> void:
	_restore_rows()
	var clock := _FakeClock.new()
	var ai: AIController = _make_ai(clock, 9)
	ai.apply_spawn_jitter()
	var st: Dictionary = ai.get_decision_timing_state()
	for key in ["now", "jitter_enabled", "jitter_ratio", "jitter_seed",
			"probe_fail_cooldown_enabled", "decision", "domains"]:
		_runner.assert_true(st.has(key), "状态含字段 %s" % key)
	var dec: Dictionary = st["decision"]
	for key2 in ["next_at", "interval", "beats", "jittered"]:
		_runner.assert_true(dec.has(key2), "decision 含字段 %s" % key2)
	var domains: Dictionary = st["domains"]
	for ch in ["combat", "job"]:
		_runner.assert_true(domains.has(ch), "domains 含通道 %s" % ch)
		for key3 in ["next_at", "interval", "gate_enabled", "cooling_down"]:
			_runner.assert_true((domains[ch] as Dictionary).has(key3),
					"通道 %s 含字段 %s" % [ch, key3])
	_runner.assert_approx(float(dec["next_at"]), ai._next_decision_at, 0.000001,
			"状态 next_at 与内部到期时刻一致")
	_runner.assert_approx(float(domains["combat"]["interval"]), 0.4, 0.000001,
			"选敌通道间隔取档案 acquire_interval")
	_runner.assert_approx(float(domains["job"]["interval"]), 0.5, 0.000001,
			"派工通道间隔取档案 job_scan_interval")

	# 与实际到期行为一致：到点前不触发、到点触发并把 next_at 推到 now+interval
	var next_at: float = ai._next_decision_at
	_runner.assert_true(not ai._advance_decision_clock(next_at - 0.000001), "到点前不触发")
	_runner.assert_true(ai._advance_decision_clock(next_at), "到点触发")
	var st2: Dictionary = ai.get_decision_timing_state()
	_runner.assert_equal(int(st2["decision"]["beats"]), 1, "拍数 +1")
	_runner.assert_approx(float(st2["decision"]["next_at"]), next_at + BASE_INTERVAL, 0.000001,
			"下次到期 = 触发时刻 + 当前间隔")
	ai.free()


func _test_config_missing() -> void:
	# 档案缺载（类型键移除）→ 合并结果回落代码 BASELINE，不崩且默认关
	BalanceConfig._remove_type_data("ai.behavior_profiles")
	ScriptBehaviorProfiles._cache.clear()
	var ai: AIController = _make_ai(_FakeClock.new(), 5)
	ai.apply_spawn_jitter()
	_runner.assert_approx(ai._next_decision_at, BASE_INTERVAL, 0.000001, "缺载：代码默认间隔 0.3")
	var st: Dictionary = ai.get_decision_timing_state()
	_runner.assert_true(not bool(st["jitter_enabled"]), "缺载：错峰默认关")
	_runner.assert_approx(float(st["jitter_ratio"]), 0.5, 0.000001, "缺载：比例默认 0.5")
	_runner.assert_true(not bool(st["probe_fail_cooldown_enabled"]), "缺载：失败冷却默认关")
	_runner.assert_true(ai._probe_domain_due("combat"), "缺载：域级探测恒到期（逐拍）")
	_runner.assert_approx(float(st["domains"]["job"]["interval"]), 0.5, 0.000001,
			"缺载：job 域间隔回落代码默认 0.5")
	ai.free()
	_restore_rows()


func _test_probe_fail_cooldown() -> void:
	# 现状判定锁定：失败冷却关（默认）→ 探测失败不做任何冷却，下一拍照常探测
	_restore_rows()
	var clock := _FakeClock.new()
	var ai: AIController = _make_ai(clock, 11)
	ai.apply_spawn_jitter()
	clock.now = 5.0
	ai._note_probe_failure("combat")
	_runner.assert_true(ai._probe_domain_due("combat"), "关：失败后仍逐拍到期（既有语义锁定）")
	# 主节拍推进同样与探测成败无关：到点即触发
	var st: Dictionary = ai.get_decision_timing_state()
	var next_at: float = float(st["decision"]["next_at"])
	_runner.assert_true(ai._advance_decision_clock(next_at), "探测失败不影响主节拍到点触发")

	# 开：失败入该通道一个间隔的短冷却（WorldBox M6 cooldown_on_launch_failure）
	_inject_rows([{
		"id": "baseline",
		"decision_interval": BASE_INTERVAL,
		"decision_variance": 0.0,
		"probe_fail_cooldown_enabled": true,
		"acquire_interval": 0.4,
		"job_scan_interval": 0.5,
	}])
	var clock2 := _FakeClock.new()
	var ai2: AIController = _make_ai(clock2, 12)
	ai2.apply_spawn_jitter()
	_runner.assert_true(ai2._probe_domain_due("combat"), "开：初始立即到期（未被失败占位）")
	clock2.now = 5.0
	ai2._note_probe_failure("combat")
	_runner.assert_true(not ai2._probe_domain_due("combat"), "开：失败入冷却是刻即不可探测")
	_runner.assert_true(ai2._probe_domain_due("job"), "开：失败冷却按通道隔离（job 不受影响）")
	_runner.assert_approx(float(ai2._domain_next_at["combat"]), 5.0 + 0.4, 0.000001,
			"开：冷却长度 = 该通道 interval")
	clock2.now = 5.39
	_runner.assert_true(not ai2._probe_domain_due("combat"), "开：冷却窗内仍不可探测")
	clock2.now = 5.40
	_runner.assert_true(ai2._probe_domain_due("combat"), "开：冷却窗过恢复探测")
	var st2: Dictionary = ai2.get_decision_timing_state()
	_runner.assert_true(bool(st2["domains"]["combat"]["gate_enabled"]), "状态回报门控开")
	ai.free()
	ai2.free()
	_restore_rows()
