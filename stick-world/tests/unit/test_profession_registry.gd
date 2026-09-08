extends Node
## 单元测试：职业注册表（ProfessionRegistry）——档案读取/轮转分配/着装应用/duck 降级。
##
## 覆盖批次 1（小镇生活与NPC职业）验收面：
##   - config/town_life/professions.tres 装载（id/name_zh/uniform/tool 字段完整）
##   - assign_village_job 轮转分配（index % 职业数）+ set_profession 写入
##   - 着装应用（rig.body_color = uniform 色；weapon_mount.weapon_type = tool 映射）
##   - duck 协议降级（无 set_profession/rig/weapon_mount 的实体安全跳过）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

var _runner: TestRunner


# ─────────────────────────────── 测试桩 ────────────────────────────────

## rig 桩：只带 body_color 属性（registry duck 检查 "body_color" in rig）
class FakeRig extends Node2D:
	var body_color: Color = Color.WHITE


## 武器挂载桩：weapon_type 初值 = 真实 WeaponMount 默认（SWORD）
class FakeMount extends Node2D:
	var weapon_type: int = WeaponMount.WeaponType.SWORD


## 实体桩：duck 协议全量（set_profession/get_profession/rig/weapon_mount）
class FakeEntity extends Node2D:
	var rig: Node2D
	var weapon_mount: Node2D
	var _profession_id: String = ""

	func set_profession(id: String) -> void:
		_profession_id = id

	func get_profession() -> String:
		return _profession_id


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("配置装载: 职业行字段完整", _test_config_rows)
	_runner.add_test("按 id 查职业: 命中与未命中", _test_get_profession)
	_runner.add_test("轮转分配: 三实体得三职业 + 越界取模", _test_assign_rotation)
	_runner.add_test("着装应用: body_color 与 weapon_type", _test_appearance)
	_runner.add_test("duck 降级: 裸实体安全返回空", _test_duck_degrade)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_config_rows() -> void:
	var profs: Array = ProfessionRegistry.get_professions()
	_runner.assert_gt(profs.size(), 0, "职业配置不应为空")
	for row in profs:
		_runner.assert_true(row is Dictionary, "职业行应为字典")
		_runner.assert_false(String(row.get("id", "")).is_empty(), "职业行 id 不应为空")
		_runner.assert_false(String(row.get("name_zh", "")).is_empty(), "职业行 name_zh 不应为空")
		_runner.assert_false(String(row.get("uniform", "")).is_empty(), "职业行 uniform 不应为空")
	# 三个起步职业（铁匠/伐木工/矿工）id 唯一
	var ids: Dictionary = {}
	for row in profs:
		ids[String(row["id"])] = true
	_runner.assert_equal(ids.size(), profs.size(), "职业 id 应唯一")


func _test_get_profession() -> void:
	var smith: Dictionary = ProfessionRegistry.get_profession("blacksmith")
	_runner.assert_false(smith.is_empty(), "blacksmith 应命中")
	_runner.assert_equal(String(smith.get("product", "")), "res_iron_ingot", "铁匠产出 = res_iron_ingot")
	_runner.assert_equal(String(smith.get("work_site_def", "")), "smithy_lv1", "铁匠绑定铁匠铺")
	_runner.assert_true(ProfessionRegistry.get_profession("nonexistent").is_empty(), "未知 id 返回空字典")
	_runner.assert_true(ProfessionRegistry.get_profession("").is_empty(), "空 id 返回空字典（待业语义）")


func _test_assign_rotation() -> void:
	var profs: Array = ProfessionRegistry.get_professions()
	var ids: Array = []
	for row in profs:
		ids.append(String(row["id"]))
	# index 0..n-1 依次得各职业（轮转顺序 = 配置顺序）
	var got: Array = []
	for i in profs.size():
		var e := FakeEntity.new()
		e.rig = FakeRig.new()
		e.weapon_mount = FakeMount.new()
		var id := TownLifeAPI.assign_village_job(e, i)
		_runner.assert_equal(id, ids[i], "index %d 应得职业 %s" % [i, ids[i]])
		_runner.assert_equal(e.get_profession(), ids[i], "实体应写入职业 id %s" % ids[i])
		got.append(id)
	_runner.assert_equal(got.size(), profs.size(), "每个实体都应分配到职业")
	# index 越界取模循环不炸
	var e2 := FakeEntity.new()
	var id2 := TownLifeAPI.assign_village_job(e2, profs.size() + 1)
	_runner.assert_equal(id2, ids[1], "越界 index 取模循环")


func _test_appearance() -> void:
	var smith: Dictionary = ProfessionRegistry.get_profession("blacksmith")
	var e := FakeEntity.new()
	e.rig = FakeRig.new()
	e.weapon_mount = FakeMount.new()
	ProfessionRegistry.apply_appearance(e, smith)
	_runner.assert_equal(e.rig.body_color, Color(String(smith["uniform"])), "铁匠身体色 = uniform 配置色")
	_runner.assert_equal(e.weapon_mount.weapon_type, WeaponMount.WeaponType.PICKAXE, "铁匠工具映射 PICKAXE")
	# 未知 tool 值不换装（保持默认剑）
	var bogus: Dictionary = {"id": "x", "uniform": "#123456", "tool": "chainsaw"}
	var e2 := FakeEntity.new()
	e2.rig = FakeRig.new()
	e2.weapon_mount = FakeMount.new()
	ProfessionRegistry.apply_appearance(e2, bogus)
	_runner.assert_equal(e2.rig.body_color, Color("#123456"), "未知 tool 不影响着装色")
	_runner.assert_equal(e2.weapon_mount.weapon_type, WeaponMount.WeaponType.SWORD, "未知 tool 保持默认武器")
	# 缺 rig/weapon_mount 的实体只跳着装不炸
	var e3 := FakeEntity.new()
	ProfessionRegistry.apply_appearance(e3, smith)


func _test_duck_degrade() -> void:
	# 裸 Node：没有 set_profession 方法 → 未分配返回 ""
	var bare := Node2D.new()
	var id := TownLifeAPI.assign_village_job(bare, 0)
	_runner.assert_equal(id, "", "接不住职业的实体返回空（未分配）")
	# null 实体安全
	_runner.assert_equal(TownLifeAPI.assign_village_job(null, 0), "", "null 实体安全返回空")
