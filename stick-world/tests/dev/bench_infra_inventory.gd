extends Node
## 基础设施基准⑥：inventory（dev 层，headless）。
##
## add_item / remove_item / 装备穿脱各 1 万次（PlayerInventory 列表制模型，
## 信号照发——与生产形态一致：战斗端 InventoryService 订阅 equipment_changed）。
##
## 运行：godot --headless --path . res://tests/dev/bench_infra_inventory.tscn

const ScriptPlayerInventory := preload("res://modules/inventory/scripts/player_inventory.gd")

const N_OPS := 10000


func _ready() -> void:
	var inv = ScriptPlayerInventory.new()

	# ① add_item × 1 万：可堆叠物（mat_stone，堆叠 50）往列表制背包塞
	# 塞满后走"条目钳在上限 → 返回余量"的真实满载路径
	var t0 := Time.get_ticks_usec()
	var leftover: int = 0
	for i in N_OPS:
		leftover = inv.add_item(&"mat_stone", 1)
	var t_add := Time.get_ticks_usec() - t0
	print("BENCH inventory add_item x%d: %d us（单次 %.2f us，leftover=%d）"
		% [N_OPS, t_add, float(t_add) / N_OPS, leftover])

	# ② remove_item × 1 万：满载条目逐次扣 1（与搬运工/消耗品扣减同形）
	t0 = Time.get_ticks_usec()
	for i in N_OPS:
		if inv.count_of(&"mat_stone") <= 0:
			inv.add_item(&"mat_stone", 50)
		inv.remove_item(&"mat_stone", 1)
	var t_remove := Time.get_ticks_usec() - t0
	print("BENCH inventory remove_item x%d: %d us（单次 %.2f us）" % [N_OPS, t_remove, float(t_remove) / N_OPS])

	# ③ 装备穿脱 × 1 万：add 武器 → equip_from_backpack → unequip 全事务链
	# （每次穿脱含 can_equip 校验与 equipment_changed 信号；独立背包避免石料干扰）
	var inv2 = ScriptPlayerInventory.new()
	t0 = Time.get_ticks_usec()
	var ok_count: int = 0
	for i in N_OPS:
		inv2.add_item(&"wpn_sword_001", 1)
		if inv2.equip_from_backpack(&"wpn_sword_001"):
			ok_count += 1
			inv2.unequip(ScriptPlayerInventory.SlotType.MAIN_HAND)
	var t_equip := Time.get_ticks_usec() - t0
	print("BENCH inventory 装备穿脱(add+equip+unequip) x%d: %d us（单轮 %.2f us，成功 %d）"
		% [N_OPS, t_equip, float(t_equip) / N_OPS, ok_count])
	print("BENCH inventory DONE")
	get_tree().quit(0)
