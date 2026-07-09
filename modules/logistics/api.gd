extends Node

## 物流模块公共 API
## 外部只能通过此文件调用物流系统功能
## 依赖：resources（转移物资）、organization（承运单位）


# ============================================================
# 创建物流路线
# ============================================================

func create_supply_chain(origin_region: String, dest_region: String,
		resource_id: String, quantity: float,
		frequency: float, carrier_org_id: String) -> Dictionary:
	# [P] carrier_org 标签=COMMERCE 或 MILITARY
	# [Q] 发射 supply_chain 创建, 资源开始流动
	pass
	return {"ok": false, "error": "未实现"}


# ============================================================
# 查询
# ============================================================

func get_supply_chains() -> Array[Dictionary]:
	pass
	return []


func get_supply_efficiency(chain_id: String) -> float:
	pass
	return 0.0


# ============================================================
# 修改
# ============================================================

func update_supply_chain(chain_id: String, changes: Dictionary) -> Dictionary:
	pass
	return {"ok": false, "error": "未实现"}


func cancel_supply_chain(chain_id: String) -> Dictionary:
	pass
	return {"ok": false, "error": "未实现"}


# ============================================================
# 基础设施
# ============================================================

func build_road(from_region: String, to_region: String, org_id: String) -> Dictionary:
	pass
	return {"ok": false, "error": "未实现"}


func upgrade_road(from_region: String, to_region: String) -> Dictionary:
	pass
	return {"ok": false, "error": "未实现"}