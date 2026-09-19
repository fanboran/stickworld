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
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


var _runner: TestRunner


func _make_container() -> ItemContainer:
	return ItemContainer.new()


## 装满 n 件（断言辅助：全部放入）
func _fill(c: ItemContainer, def_id: StringName, n: int) -> void:
	var left: int = c.add(def_id, n)
	_runner.assert_equal(left, 0, "%s 全部放入（余量 0）" % def_id)


func _test_no_total_limit() -> void:
	var c := _make_container()
	# 全部物品种类各来一件——无格数概念,种类数远超任何"格子数"也不拒
	for id in ItemDB.all_ids():
		_fill(c, id, 1)
	_runner.assert_equal(c.entry_count(), ItemDB.all_ids().size(),
			"全部物品种类各一件皆可入包（无总数量限制）")


func _test_per_item_cap() -> void:
	var c := _make_container()
	var cap: int = ItemDB.get_def(&"mat_stone").max_stack  # 石料 50
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
	var left: int = ItemTransfer.move(from, to, &"mat_stone", 50)
	_runner.assert_equal(left, 0, "目标空,全量转移")
	# 目标已满堆,再从源转——余量全留源
	_fill(from, &"mat_stone", 50)
	left = ItemTransfer.move(from, to, &"mat_stone", 50)
	_runner.assert_equal(left, 50, "目标无空间,余量全留源（原子截断）")
	_runner.assert_equal(from.count_of(&"mat_stone"), 50, "源未受损")
	# 源不足:请求超出持有量
	left = ItemTransfer.move(from, to, &"mat_gold", 10)
	_runner.assert_equal(left, 10, "源无此物,转移量为 0")


func _test_move_all() -> void:
	var from := _make_container()
	var to := _make_container()
	to.add(&"mat_gold", 15)  # 金砂上限 20,目标已有 15
	_fill(from, &"mat_gold", 20)
	var left: int = ItemTransfer.move_all(from, to, &"mat_gold")
	_runner.assert_equal(left, 15, "目标只收得下 5,余 15 留源")
	_runner.assert_equal(to.count_of(&"mat_gold"), 20, "目标满堆")
	_runner.assert_equal(from.count_of(&"mat_gold"), 15, "源剩 15")


func _test_resource_mapping() -> void:
	_runner.assert_equal(ItemsAPI.resource_id_for(&"mat_stone"), &"res_stone",
			"石料→res_stone")
	_runner.assert_equal(ItemsAPI.resource_id_for(&"mat_wood"), &"res_wood",
			"木材→res_wood")
	_runner.assert_equal(ItemsAPI.item_id_for(&"res_iron_ingot"), &"mat_iron_ingot",
			"res_iron_ingot→铁锭")
	_runner.assert_equal(ItemsAPI.resource_id_for(&"wpn_sword_001"), &"",
			"非资源品无映射")
	# 映射表内的 def 必须真实存在（防漂移）
	for def_id in ItemsAPI.RESOURCE_BY_ITEM:
		_runner.assert_not_null(ItemDB.get_def(def_id), "映射物品 %s 已注册" % def_id)
