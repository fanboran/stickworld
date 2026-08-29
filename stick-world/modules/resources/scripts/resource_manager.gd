class_name ResourceManager extends RefCounted
## 资源管理器 —— 内部数据结构和供需计算逻辑
##
## 不直接对外暴露，由 api.gd 代理所有外部调用。
## 纯数据层，不涉及信号发射。

# ===== 数据结构 =====

## 库存：{resource_id: {region_id: amount}}
var stocks: Dictionary = {}

## 价格：{resource_id: {region_id: price}}
var prices: Dictionary = {}

## 价格上限：{resource_id: price}
var price_ceilings: Dictionary = {}

## 价格下限：{resource_id: price}
var price_floors: Dictionary = {}

## 税率（全局）
var tax_rate: float = 0.0

## 运输损耗率（默认 5%/单位距离，后期由物流系统配置）
var transport_loss_rate: float = 0.05


# ===== 查询 =====

func get_stock(resource_id: String, region_id: String = "") -> float:
	if region_id == "":
		# 返回全局总量
		var total: float = 0.0
		if stocks.has(resource_id):
			for rid in stocks[resource_id]:
				total += stocks[resource_id][rid]
		return total
	if stocks.has(resource_id) and stocks[resource_id].has(region_id):
		return stocks[resource_id][region_id]
	return 0.0


func get_all_stocks() -> Dictionary:
	return stocks.duplicate(true)


func get_price(resource_id: String, region_id: String) -> float:
	if prices.has(resource_id) and prices[resource_id].has(region_id):
		return prices[resource_id][region_id]
	return 0.0


# ===== 消耗/生产 =====

func consume(resource_id: String, amount: float, region_id: String, _reason: String) -> Dictionary:
	var available: float = get_stock(resource_id, region_id)
	if available < amount:
		return {
			"ok": false,
			"error": "库存不足",
			"available": available,
			"required": amount,
			"resource_id": resource_id,
			"region_id": region_id,
		}

	_ensure_paths(resource_id, region_id)
	stocks[resource_id][region_id] -= amount
	return {
		"ok": true,
		"resource_id": resource_id,
		"amount": amount,
		"region_id": region_id,
		"remaining": stocks[resource_id][region_id],
	}


func produce(resource_id: String, amount: float, region_id: String, _source: String) -> Dictionary:
	_ensure_paths(resource_id, region_id)
	stocks[resource_id][region_id] += amount
	return {
		"ok": true,
		"resource_id": resource_id,
		"amount": amount,
		"region_id": region_id,
		"total": stocks[resource_id][region_id],
	}


# ===== 转移 =====

func transfer(resource_id: String, amount: float, from_region: String, to_region: String) -> Dictionary:
	var available: float = get_stock(resource_id, from_region)
	if available < amount:
		return {
			"ok": false,
			"error": "来源区域库存不足",
			"available": available,
			"required": amount,
			"resource_id": resource_id,
			"from_region": from_region,
			"to_region": to_region,
		}

	_ensure_paths(resource_id, from_region)
	_ensure_paths(resource_id, to_region)

	stocks[resource_id][from_region] -= amount
	# 距离相关运输损耗：当前按固定比例，阶段 1 按实际距离计算
	var actual_arrival: float = amount * (1.0 - transport_loss_rate)
	stocks[resource_id][to_region] += actual_arrival

	return {
		"ok": true,
		"resource_id": resource_id,
		"amount": amount,
		"from_region": from_region,
		"to_region": to_region,
		"actual_arrival": actual_arrival,
	}


# ===== 市场参数 =====

func set_price_ceiling(resource_id: String, price: float) -> Dictionary:
	price_ceilings[resource_id] = price
	return {"ok": true, "resource_id": resource_id, "price_ceiling": price}


func set_price_floor(resource_id: String, price: float) -> Dictionary:
	price_floors[resource_id] = price
	return {"ok": true, "resource_id": resource_id, "price_floor": price}


func set_tax_rate(rate: float) -> Dictionary:
	tax_rate = rate
	return {"ok": true, "tax_rate": rate}


# ===== 供需定价（2026-08-22 实现，替代阶段 1 框架占位） =====

## 均衡库存：库存等于该值时价格 = 基准价（阶段 1 全局常数；后续按资源/区域在 .tres 中配置）
const EQUILIBRIUM_STOCK := 200.0
## 价格对稀缺度的敏感指数：target = base × (均衡/库存)^指数。0.5 = 平方根响应（缓和）
const PRICE_ELASTICITY := 0.5
## 单次 tick 最大调价幅度（比例），防止价格跳变
const MAX_ADJUST_PER_TICK := 0.15
## 价格下限保护（绝对值），防止模型把价格打到 0
const PRICE_MIN := 0.01

## 基准价表：{resource_id: initial_price}，由 init_market 从 BalanceConfig 引导
var _base_prices: Dictionary = {}


## 市场引导：从 BalanceConfig 读 resources.tres 的 initial_price 建基准价表。
## 由 api.setup() 调用；BalanceConfig 未就绪时留空，价格按 PRICE_MIN 兜底。
func init_market() -> void:
	_base_prices.clear()
	var rows: Variant = BalanceConfig.get_value("resources.resources") if BalanceConfig else null
	if rows is Array:
		for entry in rows:
			if entry is Dictionary and entry.has("id"):
				_base_prices[str(entry["id"])] = float(entry.get("initial_price", 1.0))


func get_base_price(resource_id: String) -> float:
	return float(_base_prices.get(resource_id, 1.0))


## 计算并步进指定资源在指定区域的价格。
## 模型：目标价 = 基准价 × (均衡库存/当前库存)^弹性 × (1+税率)，单次限幅逼近；
## 显式上下限（set_price_ceiling/floor）优先于模型目标。
## 返回 {resource_id, region_id, old, new}（纯计算，不发信号——由 api 发射 price_changed）。
func update_price(resource_id: String, region_id: String) -> Dictionary:
	_ensure_paths(resource_id, region_id)
	var stock: float = get_stock(resource_id, region_id)
	# 稀缺度：库存低于均衡 → >1 提价；高于均衡 → <1 降价
	var scarcity: float = EQUILIBRIUM_STOCK / maxf(stock, 1.0)
	var target: float = get_base_price(resource_id) * pow(scarcity, PRICE_ELASTICITY) * (1.0 + tax_rate)
	if price_ceilings.has(resource_id):
		target = minf(target, price_ceilings[resource_id])
	if price_floors.has(resource_id):
		target = maxf(target, price_floors[resource_id])
	target = maxf(target, PRICE_MIN)

	var old: float = prices[resource_id][region_id]
	if old <= 0.0:
		# 首次定价：直接落到目标价，不做限幅
		prices[resource_id][region_id] = target
		return {"resource_id": resource_id, "region_id": region_id, "old": 0.0, "new": target}

	# 限幅逼近：单次最多变化 ±MAX_ADJUST_PER_TICK
	var ratio: float = clampf((target - old) / old, -MAX_ADJUST_PER_TICK, MAX_ADJUST_PER_TICK)
	var new_price: float = maxf(old * (1.0 + ratio), PRICE_MIN)
	prices[resource_id][region_id] = new_price
	return {"resource_id": resource_id, "region_id": region_id, "old": old, "new": new_price}


## 供需周期：遍历所有已开库的 资源×区域 组合各步进一次价格。
## 返回变更数组（元素同 update_price 返回值）；由 api 定时驱动并发信号。
func tick_supply_demand() -> Array:
	var changes: Array = []
	for res_id in stocks.keys():
		for region_id in stocks[res_id].keys():
			changes.append(update_price(res_id, region_id))
	return changes


# ===== 内部工具 =====

func _ensure_paths(resource_id: String, region_id: String) -> void:
	if not stocks.has(resource_id):
		stocks[resource_id] = {}
	if not stocks[resource_id].has(region_id):
		stocks[resource_id][region_id] = 0.0
	if not prices.has(resource_id):
		prices[resource_id] = {}
	if not prices[resource_id].has(region_id):
		prices[resource_id][region_id] = 0.0
