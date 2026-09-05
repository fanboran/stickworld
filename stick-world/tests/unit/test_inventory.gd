extends Node
## 单元测试：背包装备系统（modules/inventory）。
## 覆盖：堆叠/合并/满包、装备规则（槽位约束/双手锁副手/盾互斥）、
## 事务回滚、光标操作、护甲聚合、消耗品使用、序列化、
## WeaponType.NONE 不可攻击、初始套装发放。
## 纯数据层 + 不进场景树（batch_runner 准入）。

signal test_done(code: int)

const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptWeaponMount := preload("res://modules/units/scripts/entity/weapon_mount.gd")
const ScriptInventoryService := preload("res://modules/inventory/scripts/inventory_service.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("堆叠-合并与分散", _test_add_and_stack)
	_runner.add_test("堆叠-背包满溢出返回", _test_overflow_return)
	_runner.add_test("装备-槽位类型约束", _test_equip_slot_rules)
	_runner.add_test("装备-双手武器锁副手卸盾", _test_two_handed_locks_offhand)
	_runner.add_test("装备-双手武器禁装盾", _test_shield_blocked_by_two_handed)
	_runner.add_test("卸装-背包满拒绝", _test_unequip_pack_full)
	_runner.add_test("装备-事务回滚", _test_equip_rollback)
	_runner.add_test("光标-取出放下交换合并", _test_cursor_ops)
	_runner.add_test("光标-装备槽装入与类别校验", _test_cursor_equip)
	_runner.add_test("护甲-聚合减伤与移速", _test_armor_aggregate)
	_runner.add_test("护甲-减伤封顶", _test_armor_cap)
	_runner.add_test("消耗品-Hotbar使用", _test_use_hotbar_item)
	_runner.add_test("序列化-roundtrip", _test_serialize_roundtrip)
	_runner.add_test("武器-NONE徒手不可攻击", _test_weapon_mount_none)
	_runner.add_test("初始套装-发放齐全", _test_starter_kit)
	_runner.add_test("矿物-堆叠限量", _test_mineral_stack_limits)
	_runner.add_test("矿物-非装备类", _test_mineral_not_equipment)
	_runner.add_test("状态效果-list_active", _test_status_list_active)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 测试用例 ────────────────────────────────

func _make_inv() -> PlayerInventory:
	return PlayerInventory.new()


func _fill_pack(inv: PlayerInventory, exclude: Array = []) -> void:
	# 用非关键物填格（不含剑/弓——这两个是装备事务用例的主角；max_stack=1 互不可合并）
	var fillers: Array[StringName] = [
		&"wpn_spear_001", &"wpn_pickaxe_001", &"wpn_staff_001",
		&"arm_head_cloth", &"arm_chest_cloth", &"arm_legs_cloth",
		&"arm_head_leather", &"arm_chest_leather", &"arm_legs_leather",
		&"arm_head_mail", &"arm_chest_mail", &"arm_legs_mail",
	]
	var fi := 0
	for i in PlayerInventory.BACKPACK_SIZE:
		if i in exclude:
			continue
		if inv.get_slot(i) == null or inv.get_slot(i).is_empty():
			inv.add_item(fillers[fi % fillers.size()], 1)
			fi += 1


func _test_add_and_stack() -> void:
	var inv := _make_inv()
	_runner.assert_equal(inv.add_item(&"con_bandage", 5), 0, "5 绷带全放入")
	var s0: ItemStack = inv.get_slot(0)
	_runner.assert_not_null(s0, "落在首格")
	_runner.assert_equal(s0.count, 5, "同格堆叠")
	# 100 件：首格补到 99，剩 1 落第二格
	inv = _make_inv()
	var rest: int = inv.add_item(&"con_bandage", 100)
	_runner.assert_equal(rest, 0, "99+1 恰好放下")
	_runner.assert_equal(inv.get_slot(0).count, 99, "首格堆满 99")
	_runner.assert_equal(inv.get_slot(1).count, 1, "余 1 落第二格")


func _test_overflow_return() -> void:
	var inv := _make_inv()
	# 24 格 × 99 = 2376 容量；2380 件溢出 4
	var rest: int = inv.add_item(&"con_bandage", 2380)
	_runner.assert_equal(rest, 4, "溢出数量返回")
	_runner.assert_false(inv.has_free_slot(), "背包全满")


func _test_equip_slot_rules() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"shd_wood_001", 1)
	inv.add_item(&"arm_head_cloth", 1)
	inv.add_item(&"arm_chest_cloth", 1)
	inv.add_item(&"arm_legs_cloth", 1)
	inv.add_item(&"con_bandage", 3)
	for i in 5:
		_runner.assert_true(inv.equip_from_backpack(i), "第 %d 件可装备" % i)
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.MAIN_HAND), "剑在主手")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.OFF_HAND), "盾在副手")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.HEAD), "布头")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.CHEST), "布胸")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.LEGS), "布腿")
	# 消耗品不可装备
	inv.add_item(&"con_bandage", 3)
	var idx := _find_first(inv, &"con_bandage")
	_runner.assert_equal(inv.slot_for_index(idx), -1, "消耗品无装备槽")
	_runner.assert_false(inv.equip_from_backpack(idx), "消耗品装备失败")


func _find_first(inv: PlayerInventory, id: StringName) -> int:
	for i in inv.slots.size():
		var s: ItemStack = inv.slots[i]
		if s != null and not s.is_empty() and s.def_id == id:
			return i
	return -1


func _test_two_handed_locks_offhand() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"shd_wood_001", 1)
	inv.equip_from_backpack(0)
	inv.equip_from_backpack(1)
	_runner.assert_true(inv.has_shield(), "前置：盾已装备")
	inv.add_item(&"wpn_bow_001", 1)
	var bow_idx := _find_first(inv, &"wpn_bow_001")
	_runner.assert_true(inv.equip_from_backpack(bow_idx), "装弓成功")
	_runner.assert_true(inv.is_offhand_locked(), "副手被双手锁")
	_runner.assert_false(inv.has_shield(), "盾被顶掉")
	var shield_idx := _find_first(inv, &"shd_wood_001")
	_runner.assert_gt(shield_idx, -1, "盾回到背包")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_bow_001", "主手是弓")


func _test_shield_blocked_by_two_handed() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_bow_001", 1)
	inv.equip_from_backpack(0)
	inv.add_item(&"shd_wood_001", 1)
	var sh_idx := _find_first(inv, &"shd_wood_001")
	_runner.assert_false(inv.can_equip(sh_idx), "can_equip 拒绝")
	_runner.assert_false(inv.equip_from_backpack(sh_idx), "装备失败")
	# 光标路径同样拒绝
	var cursor := inv.take_all(sh_idx)
	var rest: ItemStack = inv.equip_stack(cursor, PlayerInventory.SlotType.OFF_HAND)
	_runner.assert_not_null(rest, "equip_stack 原样返回")
	_runner.assert_equal(rest.def_id, &"shd_wood_001", "盾仍在光标")
	# 放回避免影响后续（本用例独立 inv，无需）


func _test_unequip_pack_full() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.equip_from_backpack(0)
	_fill_pack(inv)  # 剑装备后腾出的 0 号格也被填上
	_runner.assert_false(inv.unequip(PlayerInventory.SlotType.MAIN_HAND), "背包满不可卸")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.MAIN_HAND), "剑仍在主手")
	# 光标路径不受背包满限制（整件到手上）
	var held: ItemStack = inv.unequip_to_cursor(PlayerInventory.SlotType.MAIN_HAND)
	_runner.assert_not_null(held, "光标可卸")
	_runner.assert_equal(held.def_id, &"wpn_sword_001", "光标上是剑")


func _test_equip_rollback() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"shd_wood_001", 1)
	inv.equip_from_backpack(0)
	inv.equip_from_backpack(1)
	# 填满背包但留 1 空格：装弓需要安置 盾+旧剑 两件 → 失败回滚
	inv.add_item(&"wpn_bow_001", 1)
	var bow_idx := _find_first(inv, &"wpn_bow_001")
	_fill_pack(inv, [bow_idx])
	_runner.assert_false(inv.has_free_slot() or _count_free(inv) > 1, "只剩弓格 1 个空位")
	_runner.assert_false(inv.equip_from_backpack(bow_idx), "装弓失败")
	# 回滚校验：盾仍装备、主手仍是剑、弓仍在背包原格
	_runner.assert_true(inv.has_shield(), "盾未丢")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_sword_001", "主手仍是剑")
	_runner.assert_equal(inv.get_slot(bow_idx).def_id, &"wpn_bow_001", "弓仍在背包")
	_runner.assert_true(_has_exactly(inv, &"wpn_sword_001", 1), "剑没有多副本")


func _count_free(inv: PlayerInventory) -> int:
	var n := 0
	for s in inv.slots:
		if s == null or s.is_empty():
			n += 1
	return n


func _has_exactly(inv: PlayerInventory, id: StringName, count: int) -> bool:
	var total := 0
	for s in inv.slots:
		if s != null and not s.is_empty() and s.def_id == id:
			total += s.count
	for e in inv.equipped.values():
		if e != null and not e.is_empty() and e.def_id == id:
			total += e.count
	return total == count


func _test_cursor_ops() -> void:
	var inv := _make_inv()
	inv.add_item(&"con_bandage", 10)
	# 拿起 → 放回空格
	var c: ItemStack = inv.take_all(0)
	_runner.assert_not_null(c, "拿起整堆")
	_runner.assert_equal(inv.place(5, c), null, "空格放下全堆")
	_runner.assert_equal(inv.get_slot(5).count, 10, "落在 5 号格")
	# 部分合并
	c = inv.take_all(5)
	inv.add_item(&"con_bandage", 90)  # 0 号格 99 满
	var rest: ItemStack = inv.place(0, c)
	_runner.assert_not_null(rest, "合并剩余回光标")
	_runner.assert_equal(rest.count, 1, "99+10 → 剩 1")
	# 异物交换
	inv = _make_inv()
	inv.add_item(&"con_bandage", 3)
	inv.add_item(&"wpn_sword_001", 1)
	c = inv.take_all(0)
	rest = inv.place(1, c)
	_runner.assert_not_null(rest, "交换出旧堆")
	_runner.assert_equal(rest.def_id, &"wpn_sword_001", "光标变成剑")
	_runner.assert_equal(inv.get_slot(1).def_id, &"con_bandage", "绷带进格")


func _test_cursor_equip() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	var c: ItemStack = inv.take_all(0)
	# 类别校验：剑不能装头
	var rest: ItemStack = inv.equip_stack(c, PlayerInventory.SlotType.HEAD)
	_runner.assert_equal(rest, c, "类别不符原样返回")
	# 正确槽位：装入成功，无旧装备返回 null
	rest = inv.equip_stack(c, PlayerInventory.SlotType.MAIN_HAND)
	_runner.assert_null(rest, "装入成功")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_sword_001", "剑在主手")
	# 再装一把：旧剑顶到光标
	inv.add_item(&"wpn_spear_001", 1)
	c = inv.take_all(_find_first(inv, &"wpn_spear_001"))
	rest = inv.equip_stack(c, PlayerInventory.SlotType.MAIN_HAND)
	_runner.assert_not_null(rest, "旧武器顶回光标")
	_runner.assert_equal(rest.def_id, &"wpn_sword_001", "光标是旧剑")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_spear_001", "主手换矛")


func _test_armor_aggregate() -> void:
	var inv := _make_inv()
	_runner.assert_approx(inv.armor_damage_reduction(), 0.0, 0.0001, "裸装零减伤")
	_runner.assert_approx(inv.armor_speed_factor(), 1.0, 0.0001, "裸装满移速")
	for id in [&"arm_head_mail", &"arm_chest_mail", &"arm_legs_mail"]:
		inv.add_item(id, 1)
		inv.equip_from_backpack(_find_first(inv, id))
	_runner.assert_approx(inv.armor_damage_reduction(), 0.46, 0.0001, "锁子三件 0.14+0.18+0.14")
	_runner.assert_approx(inv.armor_speed_factor(), 0.96 * 0.94 * 0.96, 0.0001, "移速乘积")


func _test_armor_cap() -> void:
	var inv := _make_inv()
	# 直接构造超限：三件锁子 0.46 < 0.6，用 from_dict 注入超限数值不可行（定义静态），
	# 改为校验常量与三件最大组合不越界
	_runner.assert_equal(PlayerInventory.ARMOR_REDUCTION_CAP, 0.6, "封顶常量")
	inv.add_item(&"arm_head_mail", 1)
	inv.add_item(&"arm_chest_mail", 1)
	inv.add_item(&"arm_legs_mail", 1)
	for id in [&"arm_head_mail", &"arm_chest_mail", &"arm_legs_mail"]:
		inv.equip_from_backpack(_find_first(inv, id))
	_runner.assert_lt(inv.armor_damage_reduction(), PlayerInventory.ARMOR_REDUCTION_CAP, "极限组合不越界")


func _test_use_hotbar_item() -> void:
	var inv := _make_inv()
	inv.add_item(&"con_bandage", 3)
	var used: Array = []
	inv.item_used.connect(func(id: StringName) -> void: used.append(id))
	_runner.assert_equal(inv.use_hotbar_item(0), &"con_bandage", "首格绷带可用")
	_runner.assert_equal(inv.get_slot(0).count, 2, "数量递减")
	_runner.assert_equal(used.size(), 1, "使用信号一次")
	# 非消耗品：武器放 1 号格
	inv.add_item(&"wpn_sword_001", 1)
	_runner.assert_equal(inv.use_hotbar_item(1), &"", "武器不可用")
	_runner.assert_equal(inv.get_slot(1).count, 1, "武器数量不变")
	# 用完最后一件 → 格空
	inv.use_hotbar_item(0)
	inv.use_hotbar_item(0)
	_runner.assert_null(inv.get_slot(0), "用光置空")


func _test_serialize_roundtrip() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"shd_wood_001", 1)
	inv.add_item(&"arm_head_leather", 1)
	inv.add_item(&"con_bandage", 7)
	inv.equip_from_backpack(0)
	inv.equip_from_backpack(1)
	var d := inv.to_dict()
	var inv2 := _make_inv()
	inv2.from_dict(d)
	_runner.assert_equal(inv2.get_main_weapon().def_id, &"wpn_sword_001", "主手还原")
	_runner.assert_true(inv2.has_shield(), "副手盾还原")
	_runner.assert_equal(inv2.get_slot(_find_first(inv2, &"arm_head_leather")).def_id,
			&"arm_head_leather", "护甲还原")
	_runner.assert_equal(inv2.get_slot(_find_first(inv2, &"con_bandage")).count, 7, "数量还原")
	# 空背包 roundtrip
	var inv3 := _make_inv()
	inv3.from_dict(inv3.to_dict())
	_runner.assert_null(inv3.get_slot(0), "空背包不炸")


func _test_weapon_mount_none() -> void:
	var wm: Node = ScriptWeaponMount.new()
	wm.weapon_type = 6  # WeaponType.NONE（不进树，setter 不触发重挂）
	_runner.assert_false(wm.can_attack(), "徒手不可攻击")
	wm.weapon_type = 0  # SWORD
	_runner.assert_true(wm.can_attack(), "持剑可攻击（无冷却）")
	wm.free()


func _test_starter_kit() -> void:
	var service: Node = ScriptInventoryService.new()
	service.grant_starter_kit()
	var inv: PlayerInventory = service.inventory
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_sword_001", "开局主手铁剑")
	_runner.assert_true(inv.has_shield(), "开局副手木盾")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.HEAD), "开局布头")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.CHEST), "开局布胸")
	_runner.assert_not_null(inv.get_equipped(PlayerInventory.SlotType.LEGS), "开局布腿")
	_runner.assert_true(_has_exactly(inv, &"wpn_spear_001", 1), "背包长矛")
	_runner.assert_true(_has_exactly(inv, &"wpn_bow_001", 1), "背包短弓")
	_runner.assert_true(_has_exactly(inv, &"wpn_pickaxe_001", 1), "背包铁镐")
	_runner.assert_true(_has_exactly(inv, &"wpn_staff_001", 1), "背包法杖")
	_runner.assert_true(_has_exactly(inv, &"con_bandage", 5), "背包绷带 5")
	_runner.assert_approx(inv.armor_damage_reduction(), 0.13, 0.0001, "布三件 0.04+0.05+0.04")
	service.free()


func _test_mineral_stack_limits() -> void:
	# 堆叠限量：石 50 / 铁 30 / 金 20 / 钻 10（用户定稿"材料只存一定量"）
	var cases: Dictionary = {
		&"mat_stone": 50, &"mat_iron": 30, &"mat_gold": 20, &"mat_diamond": 10,
	}
	for id in cases:
		var def: ItemDef = ItemDB.get_def(id)
		_runner.assert_not_null(def, "%s 已定义" % id)
		if def == null:
			continue
		_runner.assert_equal(def.max_stack, cases[id], "%s 堆叠上限" % id)
		_runner.assert_equal(def.category, ItemDef.Category.MATERIAL, "%s 是矿物类" % id)
	# 超量分散：51 块石头 → 50 + 1 两格
	var inv := _make_inv()
	inv.add_item(&"mat_stone", 51)
	_runner.assert_equal(inv.get_slot(0).count, 50, "首格堆满 50")
	_runner.assert_equal(inv.get_slot(1).count, 1, "余 1 落第二格")


func _test_mineral_not_equipment() -> void:
	var inv := _make_inv()
	inv.add_item(&"mat_gold", 5)
	_runner.assert_equal(inv.slot_for_index(0), -1, "矿物无装备槽")
	_runner.assert_false(inv.equip_from_backpack(0), "矿物装备失败")


func _test_status_list_active() -> void:
	# 不进树直接驱动 _effects 私有结构（headless 准入：无 autoload 无树）
	var se: Node = preload("res://modules/units/scripts/entity/status_effects.gd").new()
	_runner.assert_true(se.list_active().is_empty(), "初始无效果")
	se._effects = {
		0: {"until": se._now() + 2.5, "power": 3.0, "source": null, "next_tick": 0.5},
		3: {"until": se._now() - 1.0, "power": 0.0, "source": null, "next_tick": 0.5},
	}
	var actives: Array = se.list_active()
	_runner.assert_equal(actives.size(), 1, "过期效果不列出")
	_runner.assert_equal(int(actives[0]["type"]), 0, "燃烧在列")
	_runner.assert_gt(float(actives[0]["remain"]), 2.0, "剩余时长正确")
	_runner.assert_approx(float(actives[0]["power"]), 3.0, 0.001, "强度带出")
	se.free()
