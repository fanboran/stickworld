extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：items 域核心（列表制容器/转移原语/资源品映射）。
##
## 钉死三条域级语义：
## ① 容器**无总数量限制**——任意多种物品皆可入包，唯一上限=每类 max_stack；
## ② add 的溢出语义——超出单类上限的部分作为余量返回，由来源处理；
## ③ 转移原子性——按 目标容量/源持有 双向截断，两侧不出错态。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
# 依赖纯逻辑/纯数据一律显式 preload（tests/README 禁区：不依赖 class_name 全局注册）
const ScriptItemsAPI := preload("res://modules/items/api.gd")
const ScriptItemContainer := preload("res://modules/items/core/item_container.gd")
const ScriptItemDef := preload("res://modules/items/core/item_def.gd")
const ScriptItemDB := preload("res://modules/items/item_db.gd")
const ScriptItemTransfer := preload("res://modules/items/core/item_transfer.gd")

func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("容器: 无总数量限制(多类任意入)", _test_no_total_limit)
	_runner.add_test("容器: 单类上限=max_stack,溢出返回余量", _test_per_item_cap)
	_runner.add_test("容器: override 覆盖单类上限", _test_stack_override)
	_runner.add_test("容器: remove 不足整体失败", _test_remove_insufficient)
	_runner.add_test("容器: 条目排序=类别序+名称序", _test_entries_sorted)
	_runner.add_test("容器: 序列化 roundtrip", _test_container_roundtrip)
	_runner.add_test("转移: 原子双向截断", _test_transfer_atomic)
	_runner.add_test("转移: move_all 搬空", _test_move_all)
	_runner.add_test("映射: 资源品↔resource_id 双向", _test_resource_mapping)
	_runner.add_test("弹药: 箭矢 def 注册（AMMO/堆叠50/非装备）", _test_ammo_def_registered)
	_runner.add_test("弹药: 弓 ammo_id 接线 + 免弹开关", _test_ammo_weapon_wiring)
	_runner.add_test("弹药: 容器堆叠与扣减", _test_ammo_in_container)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _make_container() -> ScriptItemContainer:
	return ScriptItemContainer.new()


## 装满 n 件（断言辅助：全部放入）
func _fill(c: ScriptItemContainer, def_id: StringName, n: int) -> void:
	var left: int = c.add(def_id, n)
	_runner.assert_equal(left, 0, "%s 全部放入（余量 0）" % def_id)


func _test_no_total_limit() -> void:
	var c := _make_container()
	# 全部物品种类各来一件——无格数概念,种类数远超任何"格子数"也不拒
	for id in ScriptItemDB.all_ids():
		_fill(c, id, 1)
	_runner.assert_equal(c.entry_count(), ScriptItemDB.all_ids().size(),
			"全部物品种类各一件皆可入包（无总数量限制）")


func _test_per_item_cap() -> void:
	var c := _make_container()
	var cap: int = ScriptItemDB.get_def(&"mat_stone").max_stack  # 石料 50
	_fill(c, &"mat_stone", cap)
	var left: int = c.add(&"mat_stone", 10)
	_runner.assert_equal(left, 10, "超上限部分作为余量返回（不放入）")
	_runner.assert_equal(c.count_of(&"mat_stone"), cap, "持有量钳在上限")
	# 消耗后再加,余量按剩余空间收敛
	c.remove(&"mat_stone", 30)
	left = c.add(&"mat_stone", 30)
	_runner.assert_equal(left, 0, "腾出空间后可补满")
	_runner.assert_equal(c.count_of(&"mat_stone"), cap, "持有量回到上限")


func _test_stack_override() -> void:
	var c := _make_container()
	c.stack_overrides[&"mat_stone"] = 200  # 村仓大宗口径
	_fill(c, &"mat_stone", 200)
	_runner.assert_equal(c.add(&"mat_stone", 1), 1, "override 上限生效(200>50)")
	_runner.assert_equal(c.stack_cap(&"mat_stone"), 200, "cap 查询走 override")


func _test_remove_insufficient() -> void:
	var c := _make_container()
	_fill(c, &"con_bandage", 3)
	_runner.assert_false(c.remove(&"con_bandage", 5), "数量不足整体失败")
	_runner.assert_equal(c.count_of(&"con_bandage"), 3, "失败不动条目")
	_runner.assert_true(c.remove(&"con_bandage", 3), "足量移除成功")
	_runner.assert_false(c.has_item(&"con_bandage"), "清空后无此物")


func _test_entries_sorted() -> void:
	var c := _make_container()
	_fill(c, &"con_bandage", 2)
	_fill(c, &"wpn_sword_001", 1)
	_fill(c, &"mat_stone", 9)
	var es: Array = c.entries()
	_runner.assert_equal(es.size(), 3, "三类各一条目")
	# 类别序:WEAPON(0) < MATERIAL(5) < CONSUMABLE(按枚举序)——断言首条是武器
	_runner.assert_equal(es[0]["def_id"], &"wpn_sword_001", "条目按类别序排列")


func _test_container_roundtrip() -> void:
	var c := _make_container()
	_fill(c, &"wpn_sword_001", 1)
	_fill(c, &"mat_stone", 42)
	_fill(c, &"con_bandage", 7)
	var d := c.to_dict()
	var c2 := _make_container()
	c2.from_dict(d)
	_runner.assert_equal(c2.count_of(&"wpn_sword_001"), 1, "roundtrip 武器")
	_runner.assert_equal(c2.count_of(&"mat_stone"), 42, "roundtrip 石料")
	_runner.assert_equal(c2.count_of(&"con_bandage"), 7, "roundtrip 绷带")
	_runner.assert_equal(c2.entry_count(), 3, "roundtrip 条目数")


func _test_transfer_atomic() -> void:
	var from := _make_container()
	var to := _make_container()
	_fill(from, &"mat_stone", 50)  # 源满堆
	var left: int = ScriptItemTransfer.move(from, to, &"mat_stone", 50)
	_runner.assert_equal(left, 0, "目标空,全量转移")
	# 目标已满堆,再从源转——余量全留源
	_fill(from, &"mat_stone", 50)
	left = ScriptItemTransfer.move(from, to, &"mat_stone", 50)
	_runner.assert_equal(left, 50, "目标无空间,余量全留源（原子截断）")
	_runner.assert_equal(from.count_of(&"mat_stone"), 50, "源未受损")
	# 源不足:请求超出持有量
	left = ScriptItemTransfer.move(from, to, &"mat_gold", 10)
	_runner.assert_equal(left, 10, "源无此物,转移量为 0")


func _test_move_all() -> void:
	var from := _make_container()
	var to := _make_container()
	to.add(&"mat_gold", 15)  # 金砂上限 20,目标已有 15
	_fill(from, &"mat_gold", 20)
	var left: int = ScriptItemTransfer.move_all(from, to, &"mat_gold")
	_runner.assert_equal(left, 15, "目标只收得下 5,余 15 留源")
	_runner.assert_equal(to.count_of(&"mat_gold"), 20, "目标满堆")
	_runner.assert_equal(from.count_of(&"mat_gold"), 15, "源剩 15")


func _test_resource_mapping() -> void:
	_runner.assert_equal(ScriptItemsAPI.resource_id_for(&"mat_stone"), &"res_stone",
			"石料→res_stone")
	_runner.assert_equal(ScriptItemsAPI.resource_id_for(&"mat_wood"), &"res_wood",
			"木材→res_wood")
	_runner.assert_equal(ScriptItemsAPI.item_id_for(&"res_iron_ingot"), &"mat_iron_ingot",
			"res_iron_ingot→铁锭")
	_runner.assert_equal(ScriptItemsAPI.resource_id_for(&"wpn_sword_001"), &"",
			"非资源品无映射")
	# 映射表内的 def 必须真实存在（防漂移）
	for def_id in ScriptItemsAPI.RESOURCE_BY_ITEM:
		_runner.assert_not_null(ScriptItemDB.get_def(def_id), "映射物品 %s 已注册" % def_id)


# ─────────────────────────────── 弹药域（AMMO 接线，蓝图 §4.2）───────────────

func _test_ammo_def_registered() -> void:
	var def: ScriptItemDef = ScriptItemDB.get_def(&"ammo_arrow_001")
	_runner.assert_not_null(def, "箭矢 def 已注册")
	if def == null:
		return
	_runner.assert_equal(def.category, ScriptItemDef.Category.AMMO, "类别=AMMO")
	_runner.assert_equal(def.max_stack, 50, "堆叠上限 50（箭进背包一叠五十）")
	_runner.assert_false(def.is_equipment(), "弹药不占装备槽")
	_runner.assert_not_null(def.icon, "图标接战斗箭矢贴图")


func _test_ammo_weapon_wiring() -> void:
	var bow: ScriptItemDef = ScriptItemDB.get_def(&"wpn_bow_001")
	_runner.assert_not_null(bow, "弓 def 存在")
	if bow != null:
		_runner.assert_equal(bow.ammo_id, &"ammo_arrow_001", "弓耗弹指向箭矢")
		_runner.assert_equal(int(bow.stat("spawn_ammo", 0)), 20, "弓手出生带箭 20")
	# 免弹武器（数据开关：ammo_id 空 = 免弹）
	for id in [&"wpn_sword_001", &"wpn_spear_001", &"wpn_staff_001", &"wpn_pickaxe_001"]:
		var d: ScriptItemDef = ScriptItemDB.get_def(id)
		_runner.assert_equal(d.ammo_id if d != null else &"<missing>", &"",
				"%s 免弹（ammo_id 空）" % id)
	# 弹药自身不耗弹（防自引用）
	var arrow: ScriptItemDef = ScriptItemDB.get_def(&"ammo_arrow_001")
	_runner.assert_equal(arrow.ammo_id if arrow != null else &"<missing>", &"",
			"箭矢自身免弹")


func _test_ammo_in_container() -> void:
	var c := _make_container()
	_fill(c, &"ammo_arrow_001", 50)
	_runner.assert_equal(c.add(&"ammo_arrow_001", 1), 1, "满堆后余量返回")
	_runner.assert_true(c.remove(&"ammo_arrow_001", 20), "扣 20 箭")
	_runner.assert_equal(c.count_of(&"ammo_arrow_001"), 30, "剩 30 箭")
