extends Node
## resources 模块公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 resources 内部脚本的方法。
##
## 经济系统：管理资源库存、价格、供需计算。

# ===== 公共信号 =====

## 资源数量变化
signal resource_changed(resource_id: String, amount: float, delta: float, region_id: String)
## 资源不足
signal resource_not_enough(resource_id: String, required: float, available: float, region_id: String)
## 价格波动
@warning_ignore("unused_signal")
signal price_changed(resource_id: String, old_price: float, new_price: float, region_id: String)


# ===== 内部引用 =====

var _resource_manager: ResourceManager
var _is_initialized: bool = false

## 供需定价 tick 周期（现实秒；暂停时不累计）
const PRICE_TICK_INTERVAL := 5.0
var _price_tick_accumulator: float = 0.0


# ===== 初始化 =====

## 由 resources 场景的根节点调用，注入内部组件引用（Node 签名，2026-08 审计收敛）
func setup(resource_manager: Object) -> void:
	_resource_manager = resource_manager as ResourceManager
	_is_initialized = true
	if _resource_manager != null:
		_resource_manager.init_market()


func _process(delta: float) -> void:
	if _resource_manager == null:
		return
	# 暂停时冻结市场（与全局时间流速一致）
	if TimeManager and TimeManager.is_paused():
		return
	_price_tick_accumulator += delta
	if _price_tick_accumulator < PRICE_TICK_INTERVAL:
		return
	_price_tick_accumulator = 0.0
	for change: Dictionary in _resource_manager.tick_supply_demand():
		price_changed.emit(
			str(change["resource_id"]), float(change["old"]), float(change["new"]), str(change["region_id"]))


# ===== 查询库存 =====

## 获取指定资源在指定区域的库存量
## region_id 为空时返回全局总量
func get_stock(resource_id: String, region_id: String = "") -> float:
	if _resource_manager == null:
		return 0.0
	return _resource_manager.get_stock(resource_id, region_id)


## 获取所有资源的库存快照
## 返回 {resource_id: {region_id: amount}}
func get_all_stocks() -> Dictionary:
	if _resource_manager == null:
		return {}
	return _resource_manager.get_all_stocks()


# ===== 查询价格 =====

## 获取指定资源在指定区域的当前价格
func get_price(resource_id: String, region_id: String) -> float:
	if _resource_manager == null:
		return 0.0
	return _resource_manager.get_price(resource_id, region_id)


# ===== 消耗/生产 =====

## 消耗资源
## [P] amount <= get_stock(resource_id, region_id)
## [Q] 库存扣减, 发射 resource_changed 或 resource_not_enough
func consume(resource_id: String, amount: float, region_id: String, reason: String) -> Dictionary:
	if _resource_manager == null:
		return {"ok": false, "error": "资源系统未初始化"}

	var result: Dictionary = _resource_manager.consume(resource_id, amount, region_id, reason)
	if result.get("ok", false):
		resource_changed.emit(resource_id, result.remaining + amount, -amount, region_id)
	else:
		resource_not_enough.emit(resource_id, amount, result.get("available", 0.0), region_id)
	return result


## 生产/增加资源
## [Q] 库存增加, 发射 resource_changed
func produce(resource_id: String, amount: float, region_id: String, source: String) -> Dictionary:
	if _resource_manager == null:
		return {"ok": false, "error": "资源系统未初始化"}

	var result: Dictionary = _resource_manager.produce(resource_id, amount, region_id, source)
	if result.get("ok", false):
		resource_changed.emit(resource_id, result.total, amount, region_id)
	return result


# ===== 转移 =====

## 跨区域转移资源（运输系统调用）
## [Q] from 扣减, to 增加（有运输损耗, 实际到达 = amount * (1 - 损耗率)）
func transfer(resource_id: String, amount: float, from_region: String, to_region: String) -> Dictionary:
	if _resource_manager == null:
		return {"ok": false, "error": "资源系统未初始化"}
	return _resource_manager.transfer(resource_id, amount, from_region, to_region)


# ===== 市场参数调节（L4+ 层级可用） =====

## 设置价格上限
func set_price_ceiling(resource_id: String, price: float) -> Dictionary:
	if _resource_manager == null:
		return {"ok": false, "error": "资源系统未初始化"}
	return _resource_manager.set_price_ceiling(resource_id, price)


## 设置价格下限
func set_price_floor(resource_id: String, price: float) -> Dictionary:
	if _resource_manager == null:
		return {"ok": false, "error": "资源系统未初始化"}
	return _resource_manager.set_price_floor(resource_id, price)


## 设置税率
func set_tax_rate(rate: float) -> Dictionary:
	if _resource_manager == null:
		return {"ok": false, "error": "资源系统未初始化"}
	return _resource_manager.set_tax_rate(rate)


# ===== 调试接口（DebugToolsPanel 专用，生产代码勿用） =====

## 跳过 tick 周期立即结算一次市场；返回变更条数（price_changed 已随之发射）
func debug_force_market_tick() -> int:
	if _resource_manager == null:
		return 0
	var count: int = 0
	for change: Dictionary in _resource_manager.tick_supply_demand():
		price_changed.emit(
				str(change["resource_id"]), float(change["old"]), float(change["new"]),
				str(change["region_id"]))
		count += 1
	return count


## 全部已知资源定义行（id/name_zh/initial_price），来自 BalanceConfig
func debug_resource_rows() -> Array:
	var rows: Variant = BalanceConfig.get_value("resources.resources") if BalanceConfig else null
	return rows if rows is Array else []


## 当前税率
func debug_tax_rate() -> float:
	return _resource_manager.tax_rate if _resource_manager != null else 0.0
