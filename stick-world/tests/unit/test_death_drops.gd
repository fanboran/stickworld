extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：死亡掉落个体化两步机制（spawn 按兵种生成 loadout → 死亡物品
## 直接落地）+ 地面掉落物拾取语义。
##
## 覆盖：
##   ① EntityLoadout.for_spawn：兵种→个体装备记录（主手/盾/弓手箭束/无映射兵种空档）
##   ② note_spawn_weapon 建档守卫：接管实体不建档 / 已有记录不覆盖 / weapon_type
##      setter 单点驱动（外部 spawn 设武器即建档）
##   ③ build_drop_manifest：按 loadout 个体化（回落=weapon_type 反查）+ 绷带掷骰
##   ④ _drop_loadout_items：清单逐件落地为 ground_item 组实体
##   ⑤ GroundItem.take_all：列表制余量留地（满堆拒收/部分拾取/取空自毁）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptEntityLoadout := preload("res://modules/units/scripts/entity/entity_loadout.gd")
const ScriptEntityDeath := preload("res://modules/units/scripts/entity/entity_death.gd")
const ScriptGroundItem := preload("res://modules/units/scripts/entity/ground_item.gd")
const ScriptStickman := preload("res://modules/units/scripts/stickman_entity.gd")
const ScriptWeaponMount := preload("res://modules/units/scripts/entity/weapon_mount.gd")
# 依赖纯逻辑/纯数据一律显式 preload（tests/README 禁区：不依赖 class_name 全局注册）
const ScriptItemContainer := preload("res://modules/items/core/item_container.gd")

## 掉落清单测试桩（entity_death 对实体的 duck 面最小化：get_loadout/weapon_mount）
class StubEntity extends Node2D:
	var user_controlled: bool = false
	var weapon_mount: Node2D = null
	var stub_loadout: Dictionary = {}

	func get_loadout() -> Dictionary:
		return stub_loadout


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("spawn档案-剑兵只有主手", _test_for_spawn_sword)
	_runner.add_test("spawn档案-矛兵带默认盾", _test_for_spawn_spear_shield)
	_runner.add_test("spawn档案-弓手带一束箭", _test_for_spawn_bow_ammo)
	_runner.add_test("spawn档案-无映射兵种空档案", _test_for_spawn_unmapped)
	_runner.add_test("建档守卫-接管实体不建档/已有记录不覆盖", _test_note_guards)
	_runner.add_test("建档挂点-weapon_type setter 单点驱动", _test_setter_hook)
	_runner.add_test("掉落清单-按loadout个体化", _test_manifest_from_loadout)
	_runner.add_test("掉落清单-无档案回落weapon_type反查", _test_manifest_fallback)
	_runner.add_test("物品落地-ground_item组实体逐件散落", _test_drops_spawned)
	_runner.add_test("拾取-余量留地/取空自毁/满堆拒收", _test_take_all)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


# ─────────────────────────────── ① spawn 档案（纯函数）───────────────────────

func _manifest_count_of(items: Array, def_id: StringName) -> int:
	for e in items:
		if e["def_id"] == def_id:
			return int(e["count"])
	return 0


func _test_for_spawn_sword() -> void:
	var lo: Dictionary = ScriptEntityLoadout.for_spawn(0, false)  # SWORD 无盾
	_runner.assert_equal(lo.get("main_hand", ""), "wpn_sword_001", "主手铁剑")
	_runner.assert_false(lo.has("off_hand"), "剑兵无盾")
	_runner.assert_false(lo.has("ammo"), "剑兵无弹药")


func _test_for_spawn_spear_shield() -> void:
	var lo: Dictionary = ScriptEntityLoadout.for_spawn(1, true)  # SPEAR + 兵种默认盾
	_runner.assert_equal(lo.get("main_hand", ""), "wpn_spear_001", "主手长矛")
	_runner.assert_equal(lo.get("off_hand", ""), "shd_wood_001", "矛兵带木盾")


func _test_for_spawn_bow_ammo() -> void:
	var lo: Dictionary = ScriptEntityLoadout.for_spawn(2, false)  # BOW
	_runner.assert_equal(lo.get("main_hand", ""), "wpn_bow_001", "主手短弓")
	var ammo: Dictionary = lo.get("ammo", {})
	_runner.assert_equal(int(ammo.get("ammo_arrow_001", 0)), 20,
			"弓手出生带箭 20（spawn_ammo 数据）")


func _test_for_spawn_unmapped() -> void:
	# MERIC(5) 祭司专用不开放装备 → 空档案（死亡掉落走回落路径）
	var lo: Dictionary = ScriptEntityLoadout.for_spawn(5, false)
	_runner.assert_true(lo.is_empty(), "无映射兵种空档案")


# ─────────────────────────────── ② 建档守卫 ────────────────────────────────

func _test_note_guards() -> void:
	var ent = ScriptStickman.new()
	# 已有记录不覆盖
	ent.set_loadout({"main_hand": "wpn_spear_001"})
	ent.note_spawn_weapon(0)
	_runner.assert_equal(ent.get_loadout().get("main_hand", ""), "wpn_spear_001",
			"已有档案不被 spawn 覆盖（读档回填优先）")
	# 接管实体不建档（玩家装备不属于 NPC 个体）
	var ent2 = ScriptStickman.new()
	ent2.set_user_controlled(true)
	ent2.note_spawn_weapon(0)
	_runner.assert_true(ent2.get_loadout().is_empty(), "接管实体不建档")
	# 正常建档（weapon_mount 未装配时盾缺省 false）
	var ent3 = ScriptStickman.new()
	ent3.note_spawn_weapon(2)
	_runner.assert_equal(ent3.get_loadout().get("main_hand", ""), "wpn_bow_001",
			"spawn 建档主手")
	_runner.assert_equal(int(ent3.get_loadout().get("ammo", {}).get("ammo_arrow_001", 0)),
			20, "spawn 建档弓手箭束")
	ent.free()
	ent2.free()
	ent3.free()


func _test_setter_hook() -> void:
	# weapon_type setter 单点驱动：外部 spawn（garrison/recruit/召唤）设武器即建档
	var ent = ScriptStickman.new()
	var wm: Node = ScriptWeaponMount.new()
	ent.add_child(wm)
	wm.weapon_type = 0  # SWORD
	_runner.assert_equal(ent.get_loadout().get("main_hand", ""), "wpn_sword_001",
			"setter 设武器即建档")
	# 再设弓——已有档案不覆盖（单档案生命周期：spawn 定档）
	wm.weapon_type = 2
	_runner.assert_equal(ent.get_loadout().get("main_hand", ""), "wpn_sword_001",
			"二次设武器不覆盖档案")
	ent.free()


# ─────────────────────────────── ③④ 死亡掉落 ────────────────────────────────

func _test_manifest_from_loadout() -> void:
	var stub := StubEntity.new()
	add_child(stub)
	stub.stub_loadout = {
		"main_hand": "wpn_bow_001",
		"ammo": {"ammo_arrow_001": 20},
	}
	var death = ScriptEntityDeath.new(stub)
	var items: Array = death.build_drop_manifest()
	_runner.assert_equal(_manifest_count_of(items, &"wpn_bow_001"), 1, "弓手掉弓")
	_runner.assert_equal(_manifest_count_of(items, &"ammo_arrow_001"), 20, "弓手掉箭束")
	# 坏档案防御：def 不存在的条目剔除
	stub.stub_loadout = {"main_hand": "wpn_ghost", "ammo": {"ammo_ghost": 5}}
	items = death.build_drop_manifest()
	_runner.assert_equal(_manifest_count_of(items, &"wpn_ghost"), 0, "幽灵武器不落清单")
	_runner.assert_equal(_manifest_count_of(items, &"ammo_ghost"), 0, "幽灵弹药不落清单")
	stub.free()


func _test_manifest_fallback() -> void:
	# 无档案（测试桩/旧实体）→ weapon_type 反查（与旧遗物生成同口径）
	var stub := StubEntity.new()
	add_child(stub)
	var wm: Node = ScriptWeaponMount.new()
	stub.add_child(wm)
	wm.shield_enabled = true
	stub.weapon_mount = wm
	wm.weapon_type = 1  # SPEAR（setter 无宿主实体——wm 父是 StubEntity 非 CharacterBody2D）
	var death = ScriptEntityDeath.new(stub)
	var items: Array = death.build_drop_manifest()
	_runner.assert_equal(_manifest_count_of(items, &"wpn_spear_001"), 1, "回落掉矛")
	_runner.assert_equal(_manifest_count_of(items, &"shd_wood_001"), 1, "矛兵默认盾落清单")
	stub.free()


func _test_drops_spawned() -> void:
	var stub := StubEntity.new()
	add_child(stub)
	stub.global_position = Vector2(100, 200)
	stub.stub_loadout = {"main_hand": "wpn_bow_001", "ammo": {"ammo_arrow_001": 20}}
	var death = ScriptEntityDeath.new(stub)
	death._drop_loadout_items()
	# 掷骰绷带可能多落一件——核心两件必须在地上且带数量
	var bow_drop = null
	var arrow_drop = null
	for n in get_tree().get_nodes_in_group("ground_item"):
		if n.get_parent() != self:
			continue
		if n.def_id == &"wpn_bow_001":
			bow_drop = n
		elif n.def_id == &"ammo_arrow_001":
			arrow_drop = n
	_runner.assert_not_null(bow_drop, "弓已落地")
	_runner.assert_not_null(arrow_drop, "箭束已落地")
	if arrow_drop != null:
		_runner.assert_equal(arrow_drop.count, 20, "箭束数量随档案")
		_runner.assert_equal(arrow_drop.get_display_name(), "箭矢", "掉落物显示名")
	# 空清单静默跳过（绷带掷骰是清单的风味项，不计入核心产物）
	var stub2 := StubEntity.new()
	add_child(stub2)
	stub2.stub_loadout = {}
	var before: int = _core_drops_on_node()
	ScriptEntityDeath.new(stub2)._drop_loadout_items()
	_runner.assert_equal(_core_drops_on_node(), before,
			"空档案零核心产物落地（绷带掷骰除外）")
	stub.free()
	stub2.free()


## 本测试节点上的核心掉落物数（剔除绷带掷骰的随机风味项）
func _core_drops_on_node() -> int:
	var n: int = 0
	for g in get_tree().get_nodes_in_group("ground_item"):
		if g.get_parent() == self and g.def_id != &"con_bandage":
			n += 1
	return n


# ─────────────────────────────── ⑤ 拾取语义 ────────────────────────────────

func _test_take_all() -> void:
	# 部分拾取：目标已 40/50，只收得下 10，余量留地
	var item = ScriptGroundItem.new()
	add_child(item)
	item.setup(&"ammo_arrow_001", 30)
	var bag := ScriptItemContainer.new()
	bag.add(&"ammo_arrow_001", 40)
	var taken: int = item.take_all(bag)
	_runner.assert_equal(taken, 10, "部分拾取=剩余容量")
	_runner.assert_equal(item.count, 20, "余量留地")
	_runner.assert_false(item.is_queued_for_deletion(), "有余量不自毁")
	# 取空自毁
	var bag2 := ScriptItemContainer.new()
	taken = item.take_all(bag2)
	_runner.assert_equal(taken, 20, "余量全取")
	_runner.assert_true(item.is_queued_for_deletion(), "取空自毁")
	# 满堆拒收（武器类 max_stack=1：背包已有同款 → 一件没取，掉落物原地）
	var sword = ScriptGroundItem.new()
	add_child(sword)
	sword.setup(&"wpn_sword_001", 1)
	var bag3 := ScriptItemContainer.new()
	bag3.add(&"wpn_sword_001", 1)
	_runner.assert_equal(sword.take_all(bag3), 0, "目标满堆拒收")
	_runner.assert_equal(sword.count, 1, "拒收不掉数量")
	_runner.assert_false(sword.is_queued_for_deletion(), "拒收不自毁")
