extends Node

## 战斗模块公共 API
## 外部只能通过此文件调用战斗系统功能


# ============================================================
# 创建战斗
# ============================================================

func initiate_battle(attacker_org_id: String, defender_region_id: String) -> Dictionary:
	# [Q] 创建 Battle 实例, 发射 battle_started
	pass
	return {"ok": false, "error": "未实现"}


# ============================================================
# 查询
# ============================================================

func get_active_battles() -> Array[String]:
	pass
	return []


func get_battle_state(battle_id: String) -> Dictionary:
	pass
	return {"ok": false, "error": "未实现"}


# ============================================================
# 指令（玩家手动干预）
# ============================================================

func issue_order(battle_id: String, org_id: String, order_type: String, params: Dictionary) -> Dictionary:
	# order_type: "advance" / "defend" / "flank" / "retreat" / "hold"
	pass
	return {"ok": false, "error": "未实现"}


# ============================================================
# 附身
# ============================================================

func possess_commander(org_id: String, tier: int) -> Dictionary:
	# 玩家直接操控该组织的指挥官
	pass
	return {"ok": false, "error": "未实现"}


func release_possession() -> Dictionary:
	pass
	return {"ok": false, "error": "未实现"}


# ============================================================
# 呼叫支援
# ============================================================

func call_reinforcements(battle_id: String, org_id: String) -> Dictionary:
	pass
	return {"ok": false, "error": "未实现"}


func call_airstrike(battle_id: String, target: Vector2) -> Dictionary:
	# 巫师空袭
	pass
	return {"ok": false, "error": "未实现"}