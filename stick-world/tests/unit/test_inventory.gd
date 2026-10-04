extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：玩家背包（列表制）+ 装备 + Hotbar 指派 + stats 乘子。
##
## 覆盖域（docs/设计/系统/14-背包与装备系统.md §2.2/§2.3）：
##   ① 列表制：无总数量限制、唯一上限=每类 max_stack、溢出余量返回
##   ② 装备规则：槽位类型约束 / 双手锁副手（顶盾/禁装盾）/ 卸装恒成功
##   ③ Hotbar：指派/取消/同物去重/护甲不可指派 / 数字格换装 / 滚轮循环切武器
##   ④ wield 换装 / 序列化 roundtrip / 徒手 NONE / 初始套装 / 矿物堆叠限量
##   ⑤ stats 乘子：weapon_mount effective_damage / 冷却乘 speed_mult
##   ⑥ 状态效果 list_active（沿袭旧套件）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptInventoryService := preload("res://modules/inventory/scripts/inventory_service.gd")
const ScriptWeaponMount := preload("res://modules/units/scripts/entity/weapon_mount.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("列表制-无总数量限制+单类上限", _test_add_and_stack)
	_runner.add_test("列表制-溢出余量返回", _test_overflow_return)
	_runner.add_test("装备-槽位类型约束", _test_equip_slot_rules)
	_runner.add_test("装备-双手武器锁副手卸盾", _test_two_handed_locks_offhand)
	_runner.add_test("装备-双手武器禁装盾", _test_shield_blocked_by_two_handed)
	_runner.add_test("卸装-列表制恒成功", _test_unequip_always_ok)
	_runner.add_test("护甲-聚合减伤与移速", _test_armor_aggregate)
	_runner.add_test("护甲-减伤封顶", _test_armor_cap)
	_runner.add_test("Hotbar-指派/取消/去重/护甲拒绝", _test_hotbar_assign)
	_runner.add_test("Hotbar-数字格武器换装与消耗品使用", _test_use_hotbar_slot)
	_runner.add_test("Hotbar-滚轮循环切武器", _test_cycle_weapon)
	_runner.add_test("wield-已在手空操作/换装回包", _test_wield)
	_runner.add_test("序列化-roundtrip", _test_serialize_roundtrip)
	_runner.add_test("武器-NONE徒手不可攻击", _test_weapon_mount_none)
	_runner.add_test("初始套装-发放齐全+预指派", _test_starter_kit)
	_runner.add_test("矿物-堆叠限量与非装备类", _test_mineral)
	_runner.add_test("乘子-伤害与冷却吃装备 stats", _test_stats_multipliers)
	_runner.add_test("状态效果-list_active", _test_status_list_active)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _make_inv() -> PlayerInventory:
	return PlayerInventory.new()


func _has_exactly(inv: PlayerInventory, id: StringName, n: int) -> bool:
	return inv.count_of(id) == n


# ─────────────────────────────── ① 列表制 ────────────────────────────────

func _test_add_and_stack() -> void:
	var inv := _make_inv()
	_runner.assert_equal(inv.add_item(&"con_bandage", 5), 0, "5 绷带全放入")
	_runner.assert_equal(inv.count_of(&"con_bandage"), 5, "条目计数")
	# 无总数量限制：全部物品种类各一件皆入包（种类数远超任何旧"格数"）
	var kinds: int = 0
	for id in ItemDB.all_ids():
		if inv.add_item(id, 1) == 0:
			kinds += 1
	_runner.assert_equal(kinds, ItemDB.all_ids().size(), "全种类皆可入包（无格数上限）")
	# 单类上限=max_stack：绷带 99 封顶
	inv = _make_inv()
	_runner.assert_equal(inv.add_item(&"con_bandage", 150), 51, "99 上限外余量返回")
	_runner.assert_equal(inv.count_of(&"con_bandage"), 99, "条目钳在 max_stack")


func _test_overflow_return() -> void:
	var inv := _make_inv()
	_runner.assert_equal(inv.add_item(&"mat_diamond", 15), 5, "钻石上限 10 余 5")
	_runner.assert_equal(inv.count_of(&"mat_diamond"), 10, "持有=上限")
	inv.remove_item(&"mat_diamond", 4)
	_runner.assert_equal(inv.add_item(&"mat_diamond", 5), 1, "腾位后按剩余空间收")


# ─────────────────────────────── ② 装备规则 ────────────────────────────────

func _test_equip_slot_rules() -> void:
	var inv := _make_inv()
	for id in [&"wpn_sword_001", &"shd_wood_001", &"arm_head_cloth", &"arm_chest_cloth", &"arm_legs_cloth"]:
		_runner.assert_true(inv.add_item(id, 1) == 0, "%s 入包" % id)
	_runner.assert_true(inv.equip_from_backpack(&"wpn_sword_001"), "剑可装备")
	_runner.assert_true(inv.equip_from_backpack(&"shd_wood_001"), "盾可装备")
	_runner.assert_true(inv.equip_from_backpack(&"arm_head_cloth"), "布头可装备")
	_runner.assert_true(inv.equip_from_backpack(&"arm_chest_cloth"), "布胸可装备")
	_runner.assert_true(inv.equip_from_backpack(&"arm_legs_cloth"), "布腿可装备")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_sword_001", "剑在主手")
	_runner.assert_true(inv.has_shield(), "盾在副手")
	# 消耗品不可装备
	inv.add_item(&"con_bandage", 3)
	_runner.assert_equal(inv.slot_for(&"con_bandage"), -1, "消耗品无装备槽")
	_runner.assert_false(inv.equip_from_backpack(&"con_bandage"), "消耗品装备失败")


func _test_two_handed_locks_offhand() -> void:
	var inv := _make_inv()
	inv.add_item(&"shd_wood_001", 1)
	inv.add_item(&"wpn_bow_001", 1)
	_runner.assert_true(inv.equip_from_backpack(&"shd_wood_001"), "先装盾")
	_runner.assert_true(inv.equip_from_backpack(&"wpn_bow_001"), "弓（双手）装备成功")
	_runner.assert_false(inv.has_shield(), "副手盾被顶回背包")
	_runner.assert_equal(inv.count_of(&"shd_wood_001"), 1, "盾回到背包条目")
	_runner.assert_true(inv.is_offhand_locked(), "副手锁定中")


func _test_shield_blocked_by_two_handed() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_bow_001", 1)
	inv.add_item(&"shd_wood_001", 1)
	inv.equip_from_backpack(&"wpn_bow_001")
	_runner.assert_false(inv.can_equip(&"shd_wood_001"), "双手武器在主手时盾不可装")
	_runner.assert_false(inv.equip_from_backpack(&"shd_wood_001"), "装盾被拒")


func _test_unequip_always_ok() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.equip_from_backpack(&"wpn_sword_001")
	_runner.assert_true(inv.unequip(PlayerInventory.SlotType.MAIN_HAND), "卸装恒成功（列表制无背包满）")
	_runner.assert_equal(inv.count_of(&"wpn_sword_001"), 1, "武器回背包条目")


func _test_armor_aggregate() -> void:
	var inv := _make_inv()
	inv.add_item(&"arm_head_cloth", 1)
	inv.add_item(&"arm_chest_cloth", 1)
	inv.add_item(&"arm_legs_cloth", 1)
	inv.equip_from_backpack(&"arm_head_cloth")
	inv.equip_from_backpack(&"arm_chest_cloth")
	inv.equip_from_backpack(&"arm_legs_cloth")
	_runner.assert_approx(inv.armor_damage_reduction(), 0.13, 0.0001, "布三件 0.04+0.05+0.04")
	_runner.assert_approx(inv.armor_speed_factor(), 1.0, 0.0001, "布三件无移速惩罚")


func _test_armor_cap() -> void:
	var inv := _make_inv()
	for id in [&"arm_head_mail", &"arm_chest_mail", &"arm_legs_mail"]:
		inv.add_item(id, 1)
		inv.equip_from_backpack(id)
	# 锁子三件 0.14+0.18+0.14=0.46，未触 ARMOR_REDUCTION_CAP=0.6
	# （封顶是防未来词条堆穿的硬闸，现档最高甲不触顶）
	_runner.assert_approx(inv.armor_damage_reduction(), 0.46, 0.0001,
			"锁子三件=0.46（cap 0.6 为硬闸，现档不触顶）")


# ─────────────────────────────── ③ Hotbar ────────────────────────────────

func _test_hotbar_assign() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"con_bandage", 5)
	inv.add_item(&"arm_head_cloth", 1)
	_runner.assert_true(inv.hotbar_assign(0, &"wpn_sword_001"), "武器可指派")
	_runner.assert_true(inv.hotbar_assign(1, &"con_bandage"), "消耗品可指派")
	_runner.assert_false(inv.hotbar_assign(2, &"arm_head_cloth"), "护甲不可指派")
	_runner.assert_false(inv.hotbar_assign(2, &"mat_stone"), "材料不可指派")
	# 同物去重：指到别格旧格清空
	inv.hotbar_assign(3, &"wpn_sword_001")
	_runner.assert_equal(inv.hotbar[0], &"", "旧格被清")
	_runner.assert_equal(inv.hotbar[3], &"wpn_sword_001", "新格指派")
	inv.hotbar_clear(3)
	_runner.assert_equal(inv.hotbar[3], &"", "清除指派")


func _test_use_hotbar_slot() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"wpn_bow_001", 1)
	inv.add_item(&"con_bandage", 2)
	inv.hotbar_assign(0, &"wpn_sword_001")
	inv.hotbar_assign(1, &"wpn_bow_001")
	inv.hotbar_assign(2, &"con_bandage")
	_runner.assert_equal(inv.use_hotbar_slot(0), &"wpn_sword_001", "数字格装剑")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_sword_001", "剑在手")
	_runner.assert_equal(inv.use_hotbar_slot(1), &"wpn_bow_001", "数字格换弓")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_bow_001", "弓在手")
	_runner.assert_equal(inv.count_of(&"wpn_sword_001"), 1, "旧武器回背包")
	_runner.assert_equal(inv.use_hotbar_slot(2), &"con_bandage", "数字格用绷带")
	_runner.assert_equal(inv.count_of(&"con_bandage"), 1, "绷带扣 1")
	_runner.assert_equal(inv.use_hotbar_slot(9), &"", "空格无事发生")


func _test_cycle_weapon() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"wpn_bow_001", 1)
	inv.add_item(&"con_bandage", 5)
	inv.hotbar_assign(0, &"wpn_sword_001")
	inv.hotbar_assign(3, &"con_bandage")   # 中间夹消耗品——滚轮只切武器
	inv.hotbar_assign(5, &"wpn_bow_001")
	_runner.assert_equal(inv.hotbar_cycle_weapon(1), &"wpn_bow_001",
			"滚轮向后跳过消耗品格切到弓")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_bow_001", "弓已换上")
	_runner.assert_equal(inv.hotbar_selected, 5, "选中锚点落在弓格")
	_runner.assert_equal(inv.hotbar_cycle_weapon(1), &"wpn_sword_001",
			"再滚循环回剑（环形）")
	_runner.assert_equal(inv.get_main_weapon().def_id, &"wpn_sword_001", "剑已换上")


# ─────────────────────────────── ④ wield / 序列化 ────────────────────────────────

func _test_wield() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.wield(&"wpn_sword_001")
	_runner.assert_true(inv.wield(&"wpn_sword_001"), "已在手=空操作成功")
	_runner.assert_equal(inv.count_of(&"wpn_sword_001"), 0, "仍只有一件（在手不在包）")
	_runner.assert_false(inv.wield(&"wpn_spear_001"), "背包没有的武器不可 wield")


func _test_serialize_roundtrip() -> void:
	var inv := _make_inv()
	inv.add_item(&"wpn_sword_001", 1)
	inv.add_item(&"shd_wood_001", 1)
	inv.add_item(&"arm_head_leather", 1)
	inv.add_item(&"con_bandage", 7)
	inv.equip_from_backpack(&"wpn_sword_001")
	inv.equip_from_backpack(&"shd_wood_001")
	inv.hotbar_assign(4, &"con_bandage")
	inv.hotbar_select(4)
	var d := inv.to_dict()
	var inv2 := _make_inv()
	inv2.from_dict(d)
	_runner.assert_equal(inv2.get_main_weapon().def_id, &"wpn_sword_001", "主手还原")
	_runner.assert_true(inv2.has_shield(), "副手盾还原")
	_runner.assert_equal(inv2.count_of(&"arm_head_leather"), 1, "护甲条目还原")
	_runner.assert_equal(inv2.count_of(&"con_bandage"), 7, "数量还原")
	_runner.assert_equal(inv2.hotbar[4], &"con_bandage", "指派还原")
	_runner.assert_equal(inv2.hotbar_selected, 4, "选中格还原")
	# 空背包 roundtrip
	var inv3 := _make_inv()
	inv3.from_dict(inv3.to_dict())
	_runner.assert_true(inv3.bag.is_empty(), "空背包不炸")


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
	# Hotbar 预指派（1-6：五武器+绷带）
	_runner.assert_equal(inv.hotbar[0], &"wpn_sword_001", "预指派 1=铁剑")
	_runner.assert_equal(inv.hotbar[3], &"wpn_pickaxe_001", "预指派 4=铁镐")
	_runner.assert_equal(inv.hotbar[5], &"con_bandage", "预指派 6=绷带")
	service.free()


func _test_mineral() -> void:
	# 堆叠限量：石 50 / 铁 30 / 金 20 / 钻 10（创始人裁决"仅限每类内部上限"）
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
	var inv := _make_inv()
	_runner.assert_equal(inv.add_item(&"mat_stone", 51), 1, "51 块石头余 1（上限 50）")
	_runner.assert_equal(inv.slot_for(&"mat_gold"), -1, "矿物无装备槽")
	inv.add_item(&"mat_gold", 5)
	_runner.assert_false(inv.equip_from_backpack(&"mat_gold"), "矿物装备失败")
	_runner.assert_false(inv.hotbar_assignable(&"mat_gold"), "矿物不可指派")


# ─────────────────────────────── ⑤ stats 乘子 ────────────────────────────────

func _test_stats_multipliers() -> void:
	var wm: Node = ScriptWeaponMount.new()
	wm.weapon_type = 0  # SWORD（不进树）
	wm.damage = 20.0
	wm.cooldown = 1.2
	_runner.assert_approx(wm.effective_damage(), 20.0, 0.0001, "默认乘子 1.0=基础值")
	var cd0: float = wm._get_effective_cooldown()
	wm.equip_attack_mult = 1.2
	wm.equip_speed_mult = 1.5
	_runner.assert_approx(wm.effective_damage(), 24.0, 0.0001, "伤害 × attack_mult")
	_runner.assert_approx(wm._get_effective_cooldown(), cd0 / 1.5, 0.0001,
			"有效冷却 ÷ speed_mult（攻速变快）")
	wm.free()


# ─────────────────────────────── ⑥ 状态效果（沿袭） ────────────────────────────────

func _test_status_list_active() -> void:
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
