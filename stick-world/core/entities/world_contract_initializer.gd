class_name WorldContractInitializer extends RefCounted
## 世界契约初始化器 —— 新开局从 mapdata 真源全量构建政权域/城市域
## （世界模型整合 M1 统一契约，完整版蓝图 §3.4）。
##
## 两路语义：新开局 = 真源构建（本类全量灌入 80 政权 + 1040 城）；
## 读档 = 存档恢复（WorldState.load_save_data，不经本类）。
## 玩家政权壳由 WorldState.start_new_run 先立（state_id "player"），本类灌入用
## merge 非覆盖——玩家壳保留；真源 states 表亦无该 id（防御见 build 内断言）。
##
## ── 数据真源与选择理由 ──
##   政权/归属：political_data.json（states 80 表 + city_owners 1040 表，唯一真相源；
##     72KB，导出包不排除该文件、也无 bin，直接 JSON 读）。
##   城市规模分（population_score）：l3_city 单文件覆盖全部 1040 城（label 连续
##     1..1040 含出生 8 城），其 population_score 与 70 份 l1 包侧逐城全同
##     （1040/1040 一致，实测）；而 70 份 l1_world.json 合计约 100MB，逐包解析
##     不可接受——故规模分取 l3_city，不扫 l1 包。
##   装载约定：l3_city / l1_world 走「bin 优先 + JSON 兜底」（LWDB + bytes_to_var，
##     与 l1/l2/l3_world_data 的 _read_data_dict 同款——导出包 exclude_filter 排除
##     大 JSON 只带 .bin，纯 JSON 读会在导出包静默降级）；political_data 无 bin
##     且不被排除，直接 JSON 读。
##
## ── id / tile_key 映射规律（以实际数据核实）──
##   l3_city.tiles[].label（连续 1..1040）↔ 聚落 id "settlement_city_%03d"
##   （%03d 为最小 3 位零填充：label 1 → settlement_city_001，1036 →
##   settlement_city_1036；与生成端 / l3_world_data 同规则）↔ tile_key
##   "city_%03d"（l1 包/出生包 tile_id 实测格式，同源数字）。
##
## ── level 推导（档位 1-5，与 SettlementRef.Level 同形，语义见 city_state.gd）──
##   level := level_from_score(base_ps)：ps < 0.187 → 1（村）；< 0.342 → 2（镇）；
##   否则 → 3（城）。阈值从当前真源全集反推：对 1040 城 100% 复现 l1 包
##   settlement.level 字段（零误差）——即 L1 场景 SettlementRef.level 的运行时口径，
##   账面档位与玩家进城所见档位逐城一致。不取 l3_city 自带 level 字段：那是战略图
##   blob 的另一套分档（阈值 0.35/0.55），与 L1 场景口径约 75% 城不一致。
##   当前真源只出 1-3 档；4/5 档（中心城市/帝国首都）由 M2+ 人口自然成长涌现
##   （涌现优先于配置），本函数不产出。
##   ⚠️ worldgen 生成端若改 level 规则，须重核两阈值（tests/unit/test_world_contract.gd
##   有对 l1 包样例的锚点断言会红灯提示）。
##
## ── population 推导（自然数、不扎堆整十、同系统同档）──
##   1) 每局扰动：ps_run = base_ps × (1 ± 15%)，rng.seed = hash(settlement_id) +
##      run_seed（确定性每局扰动，镜像 SettlementRef.jitter_population_score 手法；
##      出生聚落免疫——与 L1/L2/L3 装配侧同口径，core 不依赖模块故复制公式，
##      模块侧改幅度/免疫规则时两处须同步）。
##   2) 档内插值：t = clamp((ps_run − 档带ps下界) / 档带ps宽, 0, 1)，
##      population = round(lerp(档带人口下界, 档带人口上界, t))。
##   档带（量级对齐命名与数值口径.md §二：村几十~一两百、城数百、帝都上千；
##   档间留自然断层保证按档单调；连续映射 + ps 抖动天然不整十扎堆——
##   ⚠️ 端点刻意不取整十：抖动钳到带边的城会堆在端点值上，端点整十会造出
##   整十扎堆，实测 60/180/220 端点版本整十占比 23%）：
##     1 村 62~178（ps 0.15~0.187）／2 镇 222~518（0.187~0.342）／
##     3 城 652~1596（0.342~0.80）／4 中心城市 2002~4196（0.80~0.95，预留）／
##     5 帝国首都 5002~8996（0.95~1.0，预留）。
##
## ── garrison 推导（账面 {profile_id: int}，初值口径）──
##   总兵力 = clamp(round(population / 130 × (1 ± 25%)), 2, 12)——按人口比例，
##   抖动盐值与人口序列区分；量级贴合「守军 3/5/8 人」的个数口径
##   （命名与数值口径.md §二边界：守军计数直接写实数，非资产刻度）。
##   编成按档（profile id 均为 config/units/stickmen.tres 实存档案，不造 id）：
##     1 档全 stm_spear_001（长枪）；2 档长枪为主 + stm_sword_001 约 3 成；
##     3 档长枪约 5 成 + 刀 3 成 + stm_bow_001 约 2 成。
##   M4 接 GarrisonSpawner 时可在不动 {profile_id: int} 账面格式的前提下重定编成。

## 真源路径（strategic_map submodule；新 worktree 需先 init submodule——
## 缺文件时 push_error 并降级为空两域，开局退化为纯玩家壳不崩）
const POLITICAL_DATA_PATH := "res://config/strategic_map/political_data.json"
const L3_CITY_PATH := "res://config/strategic_map/l3_city.json"
const L1_WORLD_PATH := "res://config/strategic_map/l1_world.json"

## 玩家政权保留 id（与 WorldState.PLAYER_FACTION_ID 互为双字面量，先例：
## core 内不跨文件取 autoload 常量，语义一致由契约文档保证）
const PLAYER_FACTION_ID := "player"

## level 分档阈值（进入该档的 base_ps 下界；推导规则见头注）
const LEVEL2_PS_MIN := 0.187
const LEVEL3_PS_MIN := 0.342

## 每局扰动幅度（镜像 SettlementRef.POPULATION_JITTER，同步责任见头注）
const POPULATION_JITTER := 0.15

## 人口档带表：level → [ps 下界, ps 上界, 人口下界, 人口上界]（推导规则见头注；
## 4/5 档为预留带，当前真源不产出该档；端点不取整十的原因见头注）
const POP_BANDS := {
	1: [0.15, 0.187, 62, 178],
	2: [0.187, 0.342, 222, 518],
	3: [0.342, 0.80, 652, 1596],
	4: [0.80, 0.95, 2002, 4196],
	5: [0.95, 1.0, 5002, 8996],
}

## 守军账面参数（推导规则见头注）
const GARRISON_POP_DIVISOR := 130.0
const GARRISON_JITTER := 0.25
const GARRISON_MIN := 2
const GARRISON_MAX := 12

## 兵种档案 id（config/units/stickmen.tres 实存行 id，勿造不存在的 id）
const PROFILE_SPEAR := "stm_spear_001"
const PROFILE_SWORD := "stm_sword_001"
const PROFILE_BOW := "stm_bow_001"


## 全量构建初始契约（纯函数，不触 autoload）。
## 返回 {"cities": {settlement_id: CityState}, "factions": {state_id: FactionState}}；
## 真源缺失/坏结构时返回两空域（开局退化为纯玩家壳，调用方不崩）。
## run_seed：本局种子（start_new_run 先定后灌，读档恢复后扰动可逐点复现）。
static func build_initial_contract(run_seed: int) -> Dictionary:
	var pd := _read_political_data()
	var states: Dictionary = pd.get("states", {})
	var owners: Dictionary = pd.get("city_owners", {})
	if states.is_empty() or owners.is_empty():
		push_error("[WorldContractInitializer] political_data.json 缺失/坏结构（strategic_map submodule 未检出？），开局退化为纯玩家壳")
		return {"cities": {}, "factions": {}}
	var scores := _read_city_scores()
	var spawn_id := _read_spawn_settlement_id()
	var factions_out: Dictionary = {}
	for state_id in states:
		var fid := str(state_id)
		# 契约冲突防御：玩家 id 为保留 id，真源混入即跳过该条（80 表实测无此 id，
		# tests/unit/test_world_contract.gd 有独立断言）
		if fid == PLAYER_FACTION_ID:
			push_error("[WorldContractInitializer] states 表混入玩家保留 id \"player\"，跳过该条")
			continue
		var sd: Dictionary = states[state_id]
		var f := FactionState.new()
		f.state_id = fid
		f.name = str(sd.get("name", ""))
		f.capital_settlement_id = str(sd.get("capital", ""))
		f.lut_index = int(sd.get("lut_index", -1))
		factions_out[fid] = f
	var cities_out: Dictionary = {}
	for settlement_id in owners:
		var sid := str(settlement_id)
		var label := _label_of(sid)
		if label <= 0:
			push_warning("[WorldContractInitializer] city_owners 键非生成端格式，跳过: %s" % sid)
			continue
		var base_ps := float(scores.get(label, 0.0))
		var c := CityState.new()
		c.settlement_id = sid
		c.tile_key = "city_%03d" % label
		c.owner_state_id = str(owners[settlement_id])
		c.level = level_from_score(base_ps)
		c.population = derive_population(base_ps, sid, run_seed, sid == spawn_id)
		c.garrison = derive_garrison(c.level, c.population, sid, run_seed)
		cities_out[sid] = c
	return {"cities": cities_out, "factions": factions_out}


## 把初始契约灌入 WorldState 实例（生产入口：WorldState.start_new_run 调用；
## 测试用 preload 脚本 new() 的实例即可，无 autoload 依赖）。
## ws 形参无类型注解：world_state.gd 未声明 class_name（autoload 以路径注册）。
## merge 非覆盖——start_new_run 先立的玩家政权壳不被同名 id 冲掉。
static func apply_to_world_state(ws) -> void:
	var contract := build_initial_contract(int(ws.run_seed))
	(ws.cities as Dictionary).merge(contract["cities"])
	(ws.factions as Dictionary).merge(contract["factions"])


## 由基准 population_score 定 worldgen 档位（1-3；规则与阈值依据见头注）
static func level_from_score(base_ps: float) -> int:
	if base_ps < LEVEL2_PS_MIN:
		return 1
	if base_ps < LEVEL3_PS_MIN:
		return 2
	return 3


## 由基准 population_score 推导账面人口初值（规则全文见头注）。
## base_ps 为未扰动基准分；is_spawn 出生聚落免疫每局扰动（与装配侧同口径）
static func derive_population(base_ps: float, settlement_id: String, run_seed: int, is_spawn: bool) -> int:
	var level := level_from_score(base_ps)
	var band: Array = POP_BANDS[level]
	# 1) 每局扰动：镜像 SettlementRef.jitter_population_score（基准 ≤0 视为未设不扰动）
	var ps := base_ps
	if not is_spawn and base_ps > 0.0:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(settlement_id) + run_seed
		ps = clampf(base_ps * (1.0 + rng.randf_range(-POPULATION_JITTER, POPULATION_JITTER)), 0.0, 1.0)
	# 2) 档内插值（ps_run 抖出档带时钳回带内）
	var ps_lo := float(band[0])
	var ps_hi := float(band[1])
	var t := clampf((ps - ps_lo) / maxf(ps_hi - ps_lo, 0.0001), 0.0, 1.0)
	return roundi(lerpf(float(band[2]), float(band[3]), t))


## 由档位 + 人口推导弹药账面守军初值 {profile_id: int}（规则全文见头注；
## 各档编成保证无 0 计数条目，最小总兵力 GARRISON_MIN）
static func derive_garrison(level: int, population: int, settlement_id: String, run_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	# 盐值区分人口抖动序列（同一 settlement_id 两处抖动不相关）
	rng.seed = hash(settlement_id) * 31 + run_seed + 0x9E3779B9
	var total := int(round(float(population) / GARRISON_POP_DIVISOR
			* (1.0 + rng.randf_range(-GARRISON_JITTER, GARRISON_JITTER))))
	total = clampi(total, GARRISON_MIN, GARRISON_MAX)
	var sword_n := 0
	var bow_n := 0
	if level >= 3:
		bow_n = clampi(roundi(float(total) * 0.2), 1, total - 2)
	if level >= 2:
		sword_n = clampi(roundi(float(total) * 0.3), 1, total - bow_n - 1)
	var out: Dictionary = {}
	out[PROFILE_SPEAR] = total - sword_n - bow_n
	if sword_n > 0:
		out[PROFILE_SWORD] = sword_n
	if bow_n > 0:
		out[PROFILE_BOW] = bow_n
	return out


# ─────────────────────────────── 真源装载 ────────────────────────────────

## political_data.json：政权/归属唯一真相源（72KB，导出包不排除，直接 JSON 读）
static func _read_political_data() -> Dictionary:
	var txt := FileAccess.get_file_as_string(POLITICAL_DATA_PATH)
	if txt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


## l3_city 的 label → population_score 表（bin 优先，见 _read_data_dict；
## 缺该城条目回退 0.0 → 1 档带下沿，当前真源 1040 城全有该字段）
static func _read_city_scores() -> Dictionary:
	var data := _read_data_dict(L3_CITY_PATH)
	var out: Dictionary = {}
	for t in (data.get("tiles", []) as Array):
		var td: Dictionary = t
		out[int(td.get("label", 0))] = float(td.get("population_score", 0.0))
	return out


## 出生聚落 id（l1_world 顶层字段；用于 population 每局扰动免疫——
## 与 L1/L2/L3 装配侧的出生免疫同口径）。读不到返回空串（不免疫，仅此一处偏差）
static func _read_spawn_settlement_id() -> String:
	var data := _read_data_dict(L1_WORLD_PATH)
	return str(data.get("spawn_settlement_id", ""))


## 数据装载：bin 优先（LWDB 魔数 + ver + bytes_to_var 原样序列化）+ JSON 兜底——
## 与 l1/l2/l3_world_data 的 _read_data_dict 同款约定（导出包只带 .bin；
## JSON 被排除）。core 不依赖模块，故复制此装载器；格式改动时四处须同步
static func _read_data_dict(json_path: String) -> Dictionary:
	var bin_path := json_path.get_basename() + ".bin"
	if FileAccess.file_exists(bin_path):
		var f := FileAccess.open(bin_path, FileAccess.READ)
		if f != null:
			if f.get_buffer(4).get_string_from_ascii() == "LWDB":
				f.get_16()  # ver
				var got: Variant = bytes_to_var(f.get_buffer(f.get_length()))
				if got is Dictionary:
					return got
	var txt := FileAccess.get_file_as_string(json_path)
	if txt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


## 聚落 id → label（"settlement_city_%03d" 的数字段；格式不符返回 0）
static func _label_of(settlement_id: String) -> int:
	return int(settlement_id.trim_prefix("settlement_city_"))
