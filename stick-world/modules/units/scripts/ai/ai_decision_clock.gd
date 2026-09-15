extends RefCounted
## W2 决策时钟族助手 —— 自 ai_controller.gd 下沉的纯逻辑子域：
## 世界时刻解析 / 出生错峰装配 / 域级探测冷却 / 读档序列化。
##
## 纪律：
## - 状态全部留在宿主（ai_controller.gd：_world_time/_next_decision_at/
##   _decision_interval/_timing_armed/_decision_beats/_domain_next_at/_jitter_rng/
##   clock_override/jitter_seed_override），本助手经 _ai 回引读写，不另立状态；
##   测试直读直写的宿主字段名一字不动；
## - _world_time 累加留在宿主 physics_update（累加在宿主、读取在助手）；
## - 各方法与宿主同名壳逐一对应（宿主壳只做一行转发），行为与拆分前逐行等价。
##
## 详见 docs/技术/架构/场景与战斗架构.md §7.1 / §7.3。

## 宿主 AIController 回引（宿主 _init 装配本助手；不写宿主类型防循环 preload）
var _ai: Node


func _init(ai: Node) -> void:
	_ai = ai


# ─────────────────────────────── 常量（自 ai_controller 随迁）────────────────────────────────
## 决策检查间隔（秒）（R1 代码默认：档案 decision_interval 可覆盖，见 _roll_decision_interval）
const DECISION_INTERVAL: float = 0.3
## 决策间隔硬下限（s）：方差掷骰/配置注入不得低于此值，防决策风暴（对齐 A1 MIN_BEAT_INTERVAL 语义）
const MIN_DECISION_INTERVAL: float = 0.05
## 到点判定时间容差（s，1 纳秒）：绝对时刻比较留容差，消除"间隔恰为帧步长整数倍"
## 时浮点累积舍入方向差异（如 0.3s / (1/60) = 18 帧整）导致的周期 ±1 帧漂移——
## 使关错峰时与旧 delta 累加器触发帧号逐位一致（远小于任何物理帧，无提前触发风险）
const DUE_EPSILON: float = 1.0e-9
## W2 出生错峰 RNG 默认种子（专用 RNG、对齐 A3 RETREAT_MOD_DEFAULT_SEED 惯例：
## 生产按实体实例 id 派生 = 每单位不同；实体不可用/单测未注入时兜底，保证可复现）
const SPAWN_JITTER_DEFAULT_SEED: int = 20260912
## 决策时钟族序列化格式版本（存档字段演进留位；导入侧只认当前版本语义）
const TIMING_STATE_VERSION: int = 1
## W2 域级间隔通道表（channel -> 档案间隔键）：探测型行为失败冷却的粒度单位。
## WorldBox M4 冷却挂"行为 index"不挂单位（Actor.cs `_decision_cooldowns[]`）；本项目
## L1 无行为 index 数组，粒度落到"域级探测"，间隔复用 A9 既有键或新增键：
##   combat 选敌探测（_try_combat，复用 acquire_interval 同域节奏）
##   job    派工/采集探测（_try_work/_try_harvest）
const DOMAIN_CHANNELS: Dictionary = {
	"combat": "acquire_interval",
	"job": "job_scan_interval",
}


# ─────────────────── W2 决策冷却错峰（WorldBox M4/Top2）───────────────────
# 语义：所有"下次到期"记**世界时刻**而非剩余秒数（读档零换算成本）；
# 装配时预置 now + interval×(1 - ratio×rand%) 的假偏移 = "上次触发发生在随机
# 过去时刻"，成批出生/读档的群体决策天然错峰（本项目痛点是兵营爆兵齐套尖峰）。

## 世界时刻读取（绝对时刻语义唯一时间源）：注入时钟优先（单测确定性），
## 否则用宿主 AI 的世界时钟（physics_update 按 delta 累加，暂停/hitstop 同步冻结
## ——不用 Time.get_ticks_msec() 实时钟，避免暂停/hitstop 期时钟空转导致恢复后
## 多触发一拍，破坏"关开关与旧累加器逐位等价"）
func _now() -> float:
	if _ai.clock_override.is_valid():
		return float(_ai.clock_override.call())
	return _ai._world_time


## 出生错峰开关（档案；缺载/未配置回落代码默认 false = 零回归）
func _jitter_enabled() -> bool:
	return bool(_ai._get_behavior_profile().get("spawn_jitter_enabled", false))


## 假偏移比例（0~1 钳制；WorldBox 真值 0.5 = rand(0, 0.5×cd)）
func _spawn_jitter_ratio() -> float:
	return clampf(float(_ai._get_behavior_profile().get("spawn_jitter_ratio", 0.5)), 0.0, 1.0)


## 域级探测失败冷却开关（档案；默认 false = 失败下一拍即重试 = 既有语义）
func _probe_fail_cooldown_enabled() -> bool:
	return bool(_ai._get_behavior_profile().get("probe_fail_cooldown_enabled", false))


## 解析错峰 RNG 种子：显式注入优先（单测/读档可复现），否则按实体实例 id 派生
## （成批出生各实例 id 不同 = 真错峰；实体不可用回落常量种子）
func _resolve_jitter_seed() -> int:
	if _ai.jitter_seed_override >= 0:
		return _ai.jitter_seed_override
	if _ai._entity != null and is_instance_valid(_ai._entity):
		return int(_ai._entity.get_instance_id())
	return SPAWN_JITTER_DEFAULT_SEED


## 首次到期时长 = interval（关）/ interval×(1 - ratio×rand%)（开）——
## 等价"上次触发发生在过去 rand(0, ratio×interval) 秒处"。
## 每次调用抽一次随机数：逐通道各抽 = 通道间独立错峰（通道内一次装配只抽一次）
func _first_interval(interval: float) -> float:
	if not _jitter_enabled():
		return interval
	return interval * (1.0 - _spawn_jitter_ratio() * _ai._jitter_rng.randf())


## 装配时钟族：重掷当前决策间隔 + 预置主节拍与各域级通道的首次到期世界时刻。
## 域级通道在错峰关时置 -1.0e9（立即到期，同 _retreat_mod_next_roll_at 惯例）。
func _init_decision_timing(now: float) -> void:
	_ai._timing_armed = true
	_ai._jitter_rng.seed = _resolve_jitter_seed()
	_ai._decision_interval = _ai._roll_decision_interval()
	_ai._next_decision_at = now + _first_interval(_ai._decision_interval)
	_ai._domain_next_at = {}
	var jitter: bool = _jitter_enabled()
	for ch in DOMAIN_CHANNELS:
		var iv: float = _domain_interval(ch)
		if jitter:
			_ai._domain_next_at[ch] = now + _first_interval(iv)
		else:
			_ai._domain_next_at[ch] = now - 1.0e9


## 出生/读档错峰入口（装配完成、读档还原、首次启用时调用）：幂等——重复调用
## 即重新掷一次假偏移（读档场景 = 按当前时刻重新错峰）。测试可显式调用 +
## 注入 clock_override/jitter_seed_override 做确定性断言。
func apply_spawn_jitter() -> void:
	_init_decision_timing(_now())


# ── WB2 读档序列化（AI 时钟族）──────────────────────────────────────────────
# 语义：导出量一律记"相对当前世界时钟的剩余时长"——实体读档重建后本地时钟从 0
# 重新起算，剩余量回填即恢复原相位（错峰离散度不丢，也不随存档时间基准漂移）。
# 导入只回填、不重掷：错峰 RNG 不再抽一次（重掷 = 错峰双重随机，反而打乱相位）。

## 决策时钟族导出（读档序列化出口）：主节拍与域级通道的剩余时长 + 当前间隔 +
## 错峰种子（字符串保精度：实体实例 id 可能超出 JSON 数值的精确整数范围）。
## 未装配/无到期时刻给 -1.0 哨兵，导入侧跳过。
func export_timing_state() -> Dictionary:
	var now: float = _now()
	var dom: Dictionary = {}
	for ch in DOMAIN_CHANNELS:
		dom[ch] = float(_ai._domain_next_at.get(ch, now - 1.0e9)) - now
	return {
		"version": TIMING_STATE_VERSION,
		"armed": _ai._timing_armed,
		"decision_remaining": (_ai._next_decision_at - now) if is_finite(_ai._next_decision_at) else -1.0,
		"decision_interval": _ai._decision_interval,
		"jitter_seed": str(_resolve_jitter_seed()),
		"domain_remaining": dom,
	}


## 决策时钟族导入（读档序列化入口）：按剩余时长回填到期时刻，**不重掷错峰**；
## 错峰种子回填注入位（后续重新装配可复现同一偏移）。
## 老存档（无该字段）/字段缺失/类型不符 → 保持调用方装配语义（_ready 的
## apply_spawn_jitter 结果），不报错。
func import_timing_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	var now: float = _now()
	if bool(d.get("armed", false)) and d.has("decision_remaining"):
		var rem: float = _safe_float(d["decision_remaining"])
		if is_finite(rem):
			_ai._timing_armed = true
			_ai._next_decision_at = now + rem
	var iv: float = _safe_float(d.get("decision_interval"))
	if is_finite(iv) and iv > 0.0:
		_ai._decision_interval = iv
	var seed: int = _safe_seed(d.get("jitter_seed"))
	if seed >= 0:
		_ai.jitter_seed_override = seed
	var dom: Variant = d.get("domain_remaining")
	if dom is Dictionary:
		var dom_d: Dictionary = dom
		for ch in DOMAIN_CHANNELS:
			if not dom_d.has(ch):
				continue
			var r: float = _safe_float(dom_d[ch])
			if is_finite(r):
				_ai._domain_next_at[ch] = now + r


## 存档数值安全读取（JSON 往返：int/float 均可；类型不符/缺失 → NAN，调用方跳过）
static func _safe_float(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	return NAN


## 存档错峰种子安全读取（字符串优先保精度；非法值 → -1 表示不注入）
static func _safe_seed(v: Variant) -> int:
	if v is String:
		var s: String = v
		return int(s) if s.is_valid_int() else -1
	if v is float or v is int:
		return int(v)
	return -1


## 决策时钟推进（纯时钟，不决策）：时钟未装配则先装配（懒装配 = 与旧"首次
## physics_update 起累计"语义一致）；到点则记一拍、重掷间隔、下次到期 =
## 当前时刻 + 新间隔，返回 true 由调用方执行 _make_decision。
## _make_decision 不读 _decision_interval（重掷先于决策 = 旧"决策后重掷"等价）
func _advance_decision_clock(now: float) -> bool:
	if not _ai._timing_armed:
		_init_decision_timing(now)
	if now + DUE_EPSILON < _ai._next_decision_at:
		return false
	_ai._decision_beats += 1
	_ai._decision_interval = _ai._roll_decision_interval()
	_ai._next_decision_at = now + _ai._decision_interval
	return true


## 域级通道间隔（s，档案键经 DOMAIN_CHANNELS 映射；钳 MIN_DECISION_INTERVAL 防风暴）
func _domain_interval(ch: String) -> float:
	var key: String = str(DOMAIN_CHANNELS.get(ch, ""))
	if key.is_empty():
		return DECISION_INTERVAL
	var p: Dictionary = _ai._get_behavior_profile()
	return maxf(float(p.get(key, DECISION_INTERVAL)), MIN_DECISION_INTERVAL)


## 域级探测是否到期（可探测）。两开关全关（默认）= 恒到期 = 逐拍探测（既有语义）；
## 错峰开 = 假偏移生效（首次探测错峰到 now+偏移，等价"上次探测在随机过去时刻"）；
## 失败冷却开 = 探测失败后一个间隔内不再重探。
func _probe_domain_due(ch: String) -> bool:
	if not _probe_fail_cooldown_enabled() and not _jitter_enabled():
		return true
	return _now() + DUE_EPSILON >= float(_ai._domain_next_at.get(ch, -1.0e9))


## 记一次域级探测失败：失败冷却开 → 入该通道一个间隔的短冷却（WorldBox M6
## "action_check_launch 失败也入冷却，防反复探测昂贵条件"）；关 → 不记（下一拍即重试）。
## 只冷却失败分支，成功路径的节拍不受影响。
func _note_probe_failure(ch: String) -> void:
	if not _probe_fail_cooldown_enabled():
		return
	_ai._domain_next_at[ch] = _now() + _domain_interval(ch)


## 决策时钟状态只读快照（W2 调试面板/单测出口）：主节拍 + 各域级通道的下次
## 到期世界时刻/当前间隔/是否已错峰。纯查询零副作用，档案缺载降级安全默认。
func get_decision_timing_state() -> Dictionary:
	var now: float = _now()
	var gate_enabled: bool = _probe_fail_cooldown_enabled() or _jitter_enabled()
	var domains: Dictionary = {}
	for ch in DOMAIN_CHANNELS:
		var next_at: float = float(_ai._domain_next_at.get(ch, -1.0e9))
		domains[ch] = {
			"next_at": next_at,
			"interval": _domain_interval(ch),
			"gate_enabled": gate_enabled,
			"cooling_down": gate_enabled and now + DUE_EPSILON < next_at,
		}
	return {
		"now": now,
		"jitter_enabled": _jitter_enabled(),
		"jitter_ratio": _spawn_jitter_ratio(),
		"jitter_seed": _resolve_jitter_seed(),
		"probe_fail_cooldown_enabled": _probe_fail_cooldown_enabled(),
		"decision": {
			"next_at": _ai._next_decision_at,
			"interval": _ai._decision_interval,
			"beats": _ai._decision_beats,
			"jittered": _jitter_enabled(),
		},
		"domains": domains,
	}
