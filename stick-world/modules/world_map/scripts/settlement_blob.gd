class_name SettlementBlob
extends RefCounted
## 聚落覆盖团块（blob）生长模型（总体设计 §5.7 / C2，战略图架构 §4.6）
##
## 卫星图式建成区轮廓 = 确定性纯函数，零存储、零运行时地形数据：
##   r(θᵢ, s) = base(θᵢ) + capacity(θᵢ) × g(s)
##     base(θᵢ)     谐波叠加初始形状（相位由 settlement_id DJB2 派生，两端同源）
##     capacity(θᵢ) 16 方向地形容量（生成端 blob_bake.py 预烘焙进视图包，运行时纯查表）
##     g(s)         = G_MAX(level) × s^γ（s = population_score，先快后慢）
## 16 方向半径 → 周期 Catmull-Rom 插值 → 固定采样点闭合折线。
##
## 行为保证（创始人三点要求）：
##   - 规模变化在原轮廓上加性扩张（base 凹凸特征全程保留，非等比缩放）
##   - 各方向增量 ∝ capacity：平地满长 / 缓坡少长 / 陡坡停 / 水面挡
##   - 全系数外置 config/strategic_map/blob_params.json（与生成端烘焙同源同表）
## 与生成端 tools/worldgen/l1/blob_bake.py 逐位同公式（DJB2 + 同参数表）——
## 预览图即游戏内形状；读档一致（population_score 每局扰动由 run_seed 派生并存档）。

const PARAMS_PATH := "res://config/strategic_map/blob_params.json"

## 参数表缓存（进程内一份；加载失败用内置回退保证渲染不缺层）
static var _params: Dictionary = {}
static var _params_loaded: bool = false


## DJB2 哈希（与 blob_bake.py 同实现——base 相位两端逐位一致，勿改单侧）
static func djb2(s: String) -> int:
	var h: int = 5381
	for b in s.to_utf8_buffer():
		h = (h * 33 + b) & 0xFFFFFFFF
	return h


static func params() -> Dictionary:
	if not _params_loaded:
		_params_loaded = true
		if FileAccess.file_exists(PARAMS_PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
			if parsed is Dictionary and not (parsed as Dictionary).is_empty():
				_params = parsed
		if _params.is_empty():
			push_warning("[SettlementBlob] 参数表缺失/无效，用内置回退: %s" % PARAMS_PATH)
			_params = {
				"K": 16, "sample_points": 72, "gamma": 0.7,
				"harmonics": {"n": [2, 3, 5], "amp": [0.1, 0.06, 0.04]},
				"levels": {
					"1": {"base": 12, "g_max": 8}, "2": {"base": 25, "g_max": 15},
					"3": {"base": 50, "g_max": 40}, "4": {"base": 100, "g_max": 50},
					"5": {"base": 150, "g_max": 70},
				},
			}
	return _params


static func direction_count() -> int:
	return int(params().get("K", 16))


## 级别参数（{base, g_max}；未知级别回退 T1）
static func level_cfg(level: int) -> Dictionary:
	var levels: Dictionary = params().get("levels", {})
	var key := str(clampi(level, 1, 5))
	if levels.has(key):
		return levels[key]
	return {"base": 12.0, "g_max": 8.0}


## 全局生长量 g(s) = G_MAX × s^γ（s 单调 → 收缩可逆）
static func growth(level: int, s: float) -> float:
	return float(level_cfg(level).get("g_max", 8.0)) * pow(maxf(s, 0.0), float(params().get("gamma", 0.7)))


## base(θᵢ) = R_lv × (1 + Σ aₙ·sin(n·θᵢ + φₙ))；φₙ 由 settlement_id DJB2 派生（K 个方向半径）
static func base_radii(settlement_id: String, level: int) -> PackedFloat32Array:
	var p := params()
	var r_base := float(level_cfg(level).get("base", 12.0))
	var harm: Dictionary = p.get("harmonics", {})
	var ns: Array = harm.get("n", [2, 3, 5])
	var amps: Array = harm.get("amp", [0.1, 0.06, 0.04])
	var k := direction_count()
	var seed := djb2(settlement_id)
	var phases := PackedFloat32Array()
	for j in ns.size():
		# 每谐波独立相位：seed 与谐波序号混合（低 16 位取相位，与 blob_bake.py 一致）
		phases.append(TAU * float((seed ^ (j * 0x9E3779B1)) & 0xFFFF) / 65535.0)
	var out := PackedFloat32Array()
	out.resize(k)
	for i in k:
		var theta := TAU * float(i) / float(k)
		var shape := 1.0
		for j in ns.size():
			shape += float(amps[j]) * sin(float(ns[j]) * theta + phases[j])
		out[i] = r_base * shape
	return out


## 16 方向半径 r(θᵢ) = base + capacity × g(s)（capacity 长度不足回退均匀 0.65）
static func direction_radii(settlement_id: String, level: int, capacity: PackedFloat32Array, s: float) -> PackedFloat32Array:
	var bases := base_radii(settlement_id, level)
	var k := bases.size()
	var g := growth(level, s)
	var out := PackedFloat32Array()
	out.resize(k)
	for i in k:
		var cap := 0.65
		if capacity.size() == k:
			cap = capacity[i]
		out[i] = bases[i] + cap * g
	return out


## 生成 blob 轮廓（以 (0,0) 为中心的闭合折线，调用方自行 + 聚落锚点平移）。
## capacity 缺失（旧数据）时回退均匀容量，形状退化为「谐波圆」仍可辨级别与规模。
static func generate_outline(settlement_id: String, level: int, capacity: PackedFloat32Array, s: float) -> PackedVector2Array:
	var radii := direction_radii(settlement_id, level, capacity, s)
	var k := radii.size()
	var n_out := int(params().get("sample_points", 72))
	var pts := PackedVector2Array()
	pts.resize(n_out)
	for m in n_out:
		var theta := TAU * float(m) / float(n_out)
		var t := theta / TAU * float(k)
		var i := int(t) % k
		var f := t - floorf(t)
		var p0: float = radii[(i - 1 + k) % k]
		var p1: float = radii[i]
		var p2: float = radii[(i + 1) % k]
		var p3: float = radii[(i + 2) % k]
		# Catmull-Rom 标量插值（周期闭合）
		var r: float = 0.5 * ((2.0 * p1)
				+ (-p0 + p2) * f
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f * f * f)
		pts[m] = Vector2(r * cos(theta), r * sin(theta))
	return pts
