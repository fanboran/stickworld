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

func consume(resource_id: String, amount: float, region_id: String, reason: String) -> Dictionary:
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


func produce(resource_id: String, amount: float, region_id: String, source: String) -> Dictionary:
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
	# TODO: 根据实际距离计算运输损耗
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


# ===== 供需计算（框架，后期实现） =====

## 更新指定资源在指定区域的价格（基于供需）
func _update_price(resource_id: String, region_id: String) -> void:
	# TODO: 根据供需关系计算价格
	# 1. 计算供需比 supply / demand
	# 2. 根据供需比调整价格
	# 3. 应用价格上下限
	# 4. 发射 price_changed 信号
	pass


## 定期供需平衡（由 TimeManager 定时调用）
func _tick_supply_demand(delta: float) -> void:
	# TODO: 遍历所有资源+区域，调用 _update_price
	pass


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
