extends Node
## 基础设施基准③：资源市场（dev 层，headless）。
##
## 100 资源 × 5 区域：tick_supply_demand × 5000；produce / consume 各 × 10000。
## 走真实 ResourcesApi（信号照发）+ ResourceManager 纯函数分项。
##
## 运行：godot --headless --path . res://tests/dev/bench_infra_market.tscn

const ScriptResourcesApi := preload("res://modules/resources/api.gd")
const ScriptResourceManager := preload("res://modules/resources/scripts/resource_manager.gd")

const N_RESOURCES := 100
const N_REGIONS := 5
const N_TICKS := 5000
const N_OPS := 10000


func _ready() -> void:
	var api: Node = ScriptResourcesApi.new()
	api.name = "BenchResourcesApi"
	add_child(api)
	var mgr: ResourceManager = ScriptResourceManager.new()
	api.setup(mgr)
	# 100 资源 × 5 区域铺满库存与价格表
	for r in N_RESOURCES:
		var rid := "res_%03d" % r
		for g in N_REGIONS:
			mgr.produce(rid, 100.0 + r + g, "region_%d" % g, "bench")
	print("BENCH market 数据规模: %d 资源 × %d 区域" % [N_RESOURCES, N_REGIONS])

	# ① tick_supply_demand（每拍 500 组合，返回数组 + 逐条 price_changed emit）
	# 基准进程无订阅者 → 测纯计算 + 数组分配；真实 api._process 另计 emit
	# 同进程 A/B：交替跑新（直迭代+下标直读）旧（keys()+get_stock 间接读）各 3 轮取中位
	var changes: Array = []
	var t_new_runs: Array = []
	var t_old_runs: Array = []
	for round_i in 3:
		var t0 := Time.get_ticks_usec()
		for i in N_TICKS:
			changes = mgr.tick_supply_demand()
		t_new_runs.append(Time.get_ticks_usec() - t0)
		t0 = Time.get_ticks_usec()
		for i in N_TICKS:
			changes = _bench_tick_legacy(mgr)
		t_old_runs.append(Time.get_ticks_usec() - t0)
	t_new_runs.sort()
	t_old_runs.sort()
	var t_tick: int = t_new_runs[1]
	var t_tick_old: int = t_old_runs[1]
	print("BENCH market tick_supply_demand x%d（%d 组合/拍）新: %d us（单拍 %.1f us）"
		% [N_TICKS, changes.size(), t_tick, float(t_tick) / N_TICKS])
	print("BENCH market tick_supply_demand x%d（%d 组合/拍）旧:直扫对照 %d us（单拍 %.1f us）"
		% [N_TICKS, changes.size(), t_tick_old, float(t_tick_old) / N_TICKS])

	# ② api._process 驱动形态：tick + 逐条 emit price_changed（带真实信号分发）
	var t0 := Time.get_ticks_usec()
	for i in N_TICKS:
		for change: Dictionary in mgr.tick_supply_demand():
			api.price_changed.emit(str(change["resource_id"]), float(change["old"]), float(change["new"]), str(change["region_id"]))
	var t_tick_emit := Time.get_ticks_usec() - t0
	print("BENCH market tick+逐条emit x%d: %d us（单拍 %.1f us）" % [N_TICKS, t_tick_emit, float(t_tick_emit) / N_TICKS])

	# ③ produce × 1 万（经 api：库存写 + resource_changed emit）
	t0 = Time.get_ticks_usec()
	for i in N_OPS:
		api.produce("res_%03d" % (i % N_RESOURCES), 1.0, "region_%d" % (i % N_REGIONS), "bench")
	var t_produce := Time.get_ticks_usec() - t0
	print("BENCH market produce x%d: %d us（单次 %.2f us）" % [N_OPS, t_produce, float(t_produce) / N_OPS])

	# ④ consume × 1 万（库存检查 + 扣减 + resource_changed emit）
	t0 = Time.get_ticks_usec()
	for i in N_OPS:
		api.consume("res_%03d" % (i % N_RESOURCES), 0.5, "region_%d" % (i % N_REGIONS), "bench")
	var t_consume := Time.get_ticks_usec() - t0
	print("BENCH market consume x%d: %d us（单次 %.2f us）" % [N_OPS, t_consume, float(t_consume) / N_OPS])
	print("BENCH market DONE")
	get_tree().quit(0)


## 旧版 tick_supply_demand 直扫实现（修复前原逻辑逐行复刻，仅作 A/B 对照：
## keys() 临时数组 + update_price 内 get_stock/get_base_price 间接调用）
func _bench_tick_legacy(mgr: ResourceManager) -> Array:
	var changes: Array = []
	for res_id in mgr.stocks.keys():
		for region_id in mgr.stocks[res_id].keys():
			changes.append(_bench_update_price_legacy(mgr, res_id, region_id))
	return changes


func _bench_update_price_legacy(mgr: ResourceManager, resource_id: String, region_id: String) -> Dictionary:
	mgr._ensure_paths(resource_id, region_id)
	var stock: float = mgr.get_stock(resource_id, region_id)
	var scarcity: float = mgr.EQUILIBRIUM_STOCK / maxf(stock, 1.0)
	var target: float = mgr.get_base_price(resource_id) * pow(scarcity, mgr.PRICE_ELASTICITY) * (1.0 + mgr.tax_rate)
	if mgr.price_ceilings.has(resource_id):
		target = minf(target, mgr.price_ceilings[resource_id])
	if mgr.price_floors.has(resource_id):
		target = maxf(target, mgr.price_floors[resource_id])
	target = maxf(target, mgr.PRICE_MIN)
	var old: float = mgr.prices[resource_id][region_id]
	if old <= 0.0:
		mgr.prices[resource_id][region_id] = target
		return {"resource_id": resource_id, "region_id": region_id, "old": 0.0, "new": target}
	var ratio: float = clampf((target - old) / old, -mgr.MAX_ADJUST_PER_TICK, mgr.MAX_ADJUST_PER_TICK)
	var new_price: float = maxf(old * (1.0 + ratio), mgr.PRICE_MIN)
	mgr.prices[resource_id][region_id] = new_price
	return {"resource_id": resource_id, "region_id": region_id, "old": old, "new": new_price}
