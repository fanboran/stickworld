class_name WorldLedger extends RefCounted
## 世界账本 —— 离屏城账面日推进（世界模型整合 M2，完整版蓝图 §3.4）。
##
## 定位：AI 内政＝账面级——政权 tick 推进人口/经济/建军三项，不做建筑清单/
## 生产链级离屏细算（离屏细算玩家看不见，性价比低）。战争/外交不在本层
## （M3+ 批次），军饷/抽象维护费类 tick 属已砍除提案（蓝图 §七），本层不做。
##
## ── 时钟与驱动 ──
##   日脉冲＝EnvironmentSystem 昼夜钟（WorldState.game_time）跨 24 回绕：
##   EventBus.world_day_advanced（无参纯节拍）发射 → SystemSetup 核心域
##   接线调 advance_day(WorldState)。暂停/倍速语义经 sim_delta 总闸自动
##   继承，本类不感知。
##
## ── 纯函数纪律（存档兼容的根基）──
##   advance_day 零随机、零时钟读取、一切推进只依赖城市当前字段——读档后
##   无条件续算，无需 tick 计数器或历史。玩家/AI 同构：只按 SimTier 分档，
##   FOCUS 城（真实实体模拟，现有母城形态）跳过，不按 owner 区分。
##
## ── 推进公式（数值全占位可调，语义锚蓝图 §3.4 土地法则；参考件出处见
##    docs/技术/参考/城市成长曲线P社逆向审计.md 复刻清单）──
##   迁移压力流（先行遍，再成长遍）：近满之城（pop ≥ cap × 0.98）向最近
##     的低压力城（pop ≤ cap × 0.6 且未满）移 1 人/日——人往低处流，跨
##     政权亦然（压力差大才流动，Vic3 迁移口径 + Imperator 部落民件）；
##     衰败之地由此获得战争之外的复活通道。迁 1 人后源城压力落回阈值下，
##     由成长慢慢回补——节流自然涌现，无需冷却计数器。目的地取 anchor
##     最近（同距取 settlement_id 小者，确定性无随机）；anchor 未装载
##     （ZERO）的城不参与迁移两侧。
##   人口：logistic × 活力，**累积制**——日增量小数攒进 pop_progress，
##     攒满 1.0 进一（根治取整断崖：薄土村以年月计爬行而非永停；CK3 进
##     度条的算术卫生，与 CK3 设计无关）；dp = 0.02 × vigor × pop ×
##     (1 − pop/cap)，vigor = clamp((cap/pop − 1) × 0.9, 0.2, 2.2)——
##     活力由 headroom（容量/人口）派生：沃土之城快长、薄土之地近乎停滞。
##     达容量清零进度。pop_capacity 由初始化器定（头寸 1.4~3.6 抖动）；
##     cap=0（旧档）视为无头寸静止。
##   档位：population 跨 POP_BANDS 档带人口下沿即升档（222/652/2002/5002，
##     与初始推导同源——只升不降；降档归 M3 战争域人口损耗时再议）。
##   财富：日入 max(1, round(pop × 0.05))，饱和 pop × 10 停止（繁荣度存量，
##     自限不通胀；消耗端归 M3 战争损耗/占领掠夺，本层只积累）。
##   守军：目标 total_target = clamp(round(pop / 130), 2, 12)（与初始化器
##     GARRISON_POP_DIVISOR 同除数、无抖动＝稳态口径）；每日 +1 长枪
##     补员、只增不减（减员归战争域）；编成细节 M4 接 GarrisonSpawner 重定。

## 日成长率（logistic 系数；2%/日 × 活力 0.2~2.2 → 沃土城月余可跨档、薄土村爬行）
const POP_GROWTH_RATE_DAY := 0.02

## 活力系数：vigor = clamp((cap/pop − 1) × GAIN, MIN, MAX)——headroom 派生
## （语义见头注「人口」段；GAIN 调斜率、MIN 保战后残城极慢回血、MAX 封顶防爆长）
const VIGOR_GAIN := 0.9
const VIGOR_MIN := 0.2
const VIGOR_MAX := 2.2

## 迁移压力阈值：源城 pop/cap ≥ SOURCE 才外流；目标城 pop/cap ≤ TARGET 且
## 未满才接收（压力差带宽即流动门槛——差不够大人不动）
const MIGRATION_SOURCE_PRESSURE := 0.98
const MIGRATION_TARGET_PRESSURE := 0.6

## 补员兵种（与初始化器 PROFILE_SPEAR 同字面量；core 内不跨文件取常量，
## 语义一致由本注释与本文件测试共同守护）
const PROFILE_SPEAR := "stm_spear_001"


## 推进全世界一个游戏日（生产入口：world_day_advanced 信号接线调用；
## 测试直接调）。ws 形参无类型注解：world_state.gd 未声明 class_name。
## 次序固定：迁移压力流 → 逐城成长（人口/档位/财富/守军）。
static func advance_day(ws) -> void:
	var cities: Dictionary = ws.cities
	_migrate(cities)
	for settlement_id in cities:
		var c := cities[settlement_id] as CityState
		if c.sim_tier != CityState.SimTier.LEDGER:
			continue
		_advance_city(c)


## 迁移压力流：近满之城 → anchor 最近的低压力城，1 人/日（语义见头注）。
## O(源城数 × 全城数) 的日界批量扫描——千城量级毫秒级，够用；上量再空间分桶
static func _migrate(cities: Dictionary) -> void:
	for sid in cities:
		var src := cities[sid] as CityState
		if src.sim_tier != CityState.SimTier.LEDGER or src.pop_capacity <= 0:
			continue
		if float(src.population) < float(src.pop_capacity) * MIGRATION_SOURCE_PRESSURE:
			continue
		if src.anchor == Vector2.ZERO:
			continue
		var dst := _nearest_low_pressure(cities, src)
		if dst == null:
			continue
		src.population -= 1
		dst.population += 1


## 最近低压力目的城（同距取 settlement_id 字典序小者——确定性无随机；
## 目标须 LEDGER 档、有 anchor、未满且压力 ≤ TARGET）
static func _nearest_low_pressure(cities: Dictionary, src: CityState) -> CityState:
	var best: CityState = null
	var best_d := 0.0
	for tid in cities:
		var c := cities[tid] as CityState
		if c.sim_tier != CityState.SimTier.LEDGER or c.pop_capacity <= 0:
			continue
		if c.anchor == Vector2.ZERO or c.population >= c.pop_capacity:
			continue
		if float(c.population) > float(c.pop_capacity) * MIGRATION_TARGET_PRESSURE:
			continue
		var d: float = src.anchor.distance_squared_to(c.anchor)
		if best == null or d < best_d or (d == best_d and str(tid) < str(best.settlement_id)):
			best = c
			best_d = d
	return best


## 单城一日推进（拆出便于测试直驱单城）。
static func _advance_city(c: CityState) -> void:
	if c.population <= 0:
		return
	# 人口：logistic × 活力，累积制——攒满进一（分化即质感，爬行非永停）
	if c.pop_capacity > c.population:
		var pop_f := float(c.population)
		var cap_f := float(c.pop_capacity)
		var vigor := clampf((cap_f / pop_f - 1.0) * VIGOR_GAIN, VIGOR_MIN, VIGOR_MAX)
		c.pop_progress += POP_GROWTH_RATE_DAY * vigor * pop_f * (1.0 - pop_f / cap_f)
		if c.pop_progress >= 1.0:
			var dp := mini(int(c.pop_progress), c.pop_capacity - c.population)
			c.population += dp
			c.pop_progress = 0.0 if c.population >= c.pop_capacity else c.pop_progress - dp
	else:
		c.pop_progress = 0.0
	# 档位：人口跨档带下沿即升档（阈值与初始化器 POP_BANDS 同源）
	c.level = maxi(c.level, level_from_population(c.population))
	# 财富：日入趋饱和（繁荣度存量，自限不通胀）
	var wealth_sat := roundi(float(c.population) * 10.0)
	if c.wealth < wealth_sat:
		c.wealth = mini(c.wealth + maxi(1, roundi(float(c.population) * 0.05)), wealth_sat)
	# 守军：向目标补员（每日 +1 长枪，只增不减——减员归战争域）
	var target := _garrison_target(c.population)
	var current := 0
	for profile_id in c.garrison:
		current += int(c.garrison[profile_id])
	if current < target:
		c.garrison[PROFILE_SPEAR] = int(c.garrison.get(PROFILE_SPEAR, 0)) + 1


## 人口 → 档位（升档判定；阈值 = WorldContractInitializer.POP_BANDS 各档带
## 人口下沿，引用同源防漂移。4/5 档由此自然涌现，初始真源只出 1-3 档）
static func level_from_population(population: int) -> int:
	var bands: Dictionary = WorldContractInitializer.POP_BANDS
	var level := 1
	for lvl in [2, 3, 4, 5]:
		if population >= int(bands[lvl][2]):
			level = lvl
	return level


## 守军补员目标（与初始化器 derive_garrison 同除数/GARRISON_MIN/MAX，无抖动
## ＝稳态；引用同源常量防两处漂移）
static func _garrison_target(population: int) -> int:
	return clampi(roundi(float(population) / WorldContractInitializer.GARRISON_POP_DIVISOR),
			WorldContractInitializer.GARRISON_MIN, WorldContractInitializer.GARRISON_MAX)
