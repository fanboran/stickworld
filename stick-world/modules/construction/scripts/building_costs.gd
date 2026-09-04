class_name BuildingCosts
extends RefCounted
## 建造成本系统 —— 建筑定义资源成本的提取与扣减（P0-9）。
##
## 职责：
##   1. 从建筑定义提取资源成本字典（可乘系数：升级 0.5、修理按损伤比例）
##   2. 统一扣费入口：先全量检查，再逐项扣减；中途失败回滚已扣部分
##   3. 建造成本检查+扣减一步入口（资源系统未接入 / 无定义 / 无成本项时跳过）
##
## 由 ConstructionManager 持有（一个 Manager 对应一个 Costs），
## ResourcesApi 引用经 set_resources_api 注入（与 manager 注入点同步）；
## 建筑定义由调用方传入（manager 侧查 catalog），本组件不反向依赖 manager。

# ─────────────────────────────── 字段 ────────────────────────────────

## ResourcesApi 引用（由 ConstructionManager 注入，P0-9 资源检查）
var _resources_api: Node = null


# ─────────────────────────────── 注入 ────────────────────────────────

## 由 ConstructionManager.set_resources_api 同步注入 ResourcesApi 引用。
func set_resources_api(resources_api: Node) -> void:
	_resources_api = resources_api


# ─────────────────────────────── 成本检查与扣减（P0-9）────────────────────────────────

## 检查并扣减建造成本。建筑定义 def 由调用方传入（空 def 跳过）。
## 返回 {ok:true} 或 {ok:false, reason}
func check_and_consume(def: Dictionary, region_id: String, reason: String) -> Dictionary:
	if _resources_api == null:
		return {"ok": true}  # 资源系统未接入，跳过检查
	if def.is_empty():
		return {"ok": true}  # 无定义，跳过
	var costs: Dictionary = extract_def_costs(def)
	if costs.is_empty():
		return {"ok": true}
	return consume(costs, region_id, reason)


## 从建筑定义提取资源成本字典（可乘系数：升级 0.5、修理按损伤比例）
static func extract_def_costs(def: Dictionary, factor: float = 1.0) -> Dictionary:
	var costs: Dictionary = {}
	for key in ["build_cost_wood", "build_cost_stone", "build_cost_metal"]:
		if def.has(key) and float(def[key]) > 0:
			var res_id: String = key.replace("build_cost_", "res_")
			# build_cost_wood -> res_wood, build_cost_metal -> res_metal_ore（特殊映射）
			if key == "build_cost_metal":
				res_id = "res_metal_ore"
			costs[res_id] = ceilf(float(def[key]) * factor)
	return costs


## 统一扣费入口：先全量检查，再逐项扣减；中途失败回滚已扣部分。
func consume(costs: Dictionary, region_id: String, reason: String) -> Dictionary:
	for res_id in costs.keys():
		var stock: float = _resources_api.get_stock(res_id, region_id)
		if stock < costs[res_id]:
			return {"ok": false, "reason": "缺少 %s (需要 %d, 现有 %d)" % [res_id, costs[res_id], stock]}
	var consumed: Array = []
	for res_id in costs.keys():
		var result: Dictionary = _resources_api.consume(res_id, costs[res_id], region_id, reason)
		if not result.get("ok", false):
			for entry in consumed:
				_resources_api.produce(entry.res_id, entry.amount, region_id, "建造扣减回滚")
			return {"ok": false, "reason": "扣减失败: %s" % result.get("error", "")}
		consumed.append({"res_id": res_id, "amount": costs[res_id]})
	return {"ok": true}
