extends Node
## 基础设施基准⑥：inventory（dev 层，headless）。
##
## add_item / remove_at / 装备穿脱各 1 万次（PlayerInventory 纯数据模型，
## 信号照发——与生产形态一致：战斗端 InventoryService 订阅 equipment_changed）。
##
## 运行：godot --headless --path . res://tests/dev/bench_infra_inventory.tscn

const ScriptPlayerInventory := preload("res://modules/inventory/scripts/player_inventory.gd")

const N_OPS := 10000


func _ready() -> void:
	var inv = ScriptPlayerInventory.new()

	# ① add_item × 1 万：可堆叠物（mat_stone，堆叠 50）往 24 格背包塞
	# 塞满后走"合并优先 → 空格耗尽 → 返回余量"的真实满载路径
	var t0 := Time.get_ticks_usec()
	var leftover: int = 0
	for i in N_OPS:
		leftover = inv.add_item(&"mat_stone", 1)
	var t_add := Time.get_ticks_usec() - t0
	print("BENCH inventory add_item x%d: %d us（单次 %.2f us，leftover=%d）"
		% [N_OPS, t_add, float(t_add) / N_OPS, leftover])

	# ② remove_at × 1 万：从第 0 格反复取 1（取空后置 null，路径含 get_slot 边界）
	# 背包满载后逐格递减：与搬运工/消耗品扣减同形
	t0 = Time.get_ticks_usec()
	for i in N_OPS:
		var idx: int = i % 24
		if inv.get_slot(idx) == null:
			inv.add_item(&"mat_stone", 50)
		inv.remove_at(idx, 1)
	var t_remove := Time.get_ticks_usec() - t0
	print("BENCH inventory remove_at x%d: %d us（单次 %.2f us）" % [N_OPS, t_remove, float(t_remove) / N_OPS])

	# ③ 装备穿脱 × 1 万：add 武器 → equip_from_backpack → unequip 全事务链
	# （每次穿脱含 can_equip 校验、事务 log、equipment_changed 信号）
	# 独立空背包：避免 ① 塞满的石料挤掉武器放置位（装备 max_stack=1 无处可放）
	var inv2 = ScriptPlayerInventory.new()
	t0 = Time.get_ticks_usec()
	var ok_count: int = 0
	for i in N_OPS:
		inv2.add_item(&"wpn_sword_001", 1)
		# 找到刚放入的格（装备不可堆叠，必在空格）
		var slot_idx := -1
		for j in inv2.slots.size():
			if inv2.get_slot(j) != null and inv2.get_slot(j).def_id == &"wpn_sword_001":
				slot_idx = j
				break
		if slot_idx >= 0 and inv2.equip_from_backpack(slot_idx):
			ok_count += 1
			inv2.unequip(ScriptPlayerInventory.SlotType.MAIN_HAND)
	var t_equip := Time.get_ticks_usec() - t0
	print("BENCH inventory 装备穿脱(add+equip+unequip) x%d: %d us（单轮 %.2f us，成功 %d）"
		% [N_OPS, t_equip, float(t_equip) / N_OPS, ok_count])
	print("BENCH inventory DONE")
	get_tree().quit(0)
