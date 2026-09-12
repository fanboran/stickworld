extends Node
## 单元测试：职业注册表（ProfessionRegistry）——档案读取/轮转分配/装具应用/duck 降级。
##
## 覆盖批次 1（小镇生活与NPC职业）验收面：
##   - config/town_life/professions.tres 装载（id/name_zh/tool 字段完整）
##   - assign_village_job 轮转分配（index % 职业数）+ set_profession 写入
##   - 装具应用（weapon_mount.weapon_type = tool 映射；身体色不做身份染色）
##   - duck 协议降级（无 set_profession/rig/weapon_mount 的实体安全跳过）
## 覆盖批次 4（人口扩充与配比）验收面：
##   - count_work_capacity：真建筑槽位累计 / 占位表兜底容量 1 / 无处可干 0
##   - assign_village_jobs 配比分配：quota 上限、工位容量约束、配额满待业池

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

## batch_runner 收割退出码用（TestRunner.finish_process 依赖本信号）
signal test_done(code: int)

var _runner: TestRunner


# ─────────────────────────────── 测试桩 ────────────────────────────────

## rig 桩：带 body_color 属性——用于验证装具应用不会去改它
##（火柴人身体不做身份染色，见 stickman_rig.gd 类头）
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
	_runner.add_test("装具应用: weapon_type 映射 + 不染身体", _test_appearance)
	_runner.add_test("duck 降级: 裸实体安全返回空", _test_duck_degrade)
	_runner.add_test("配比: 工位容量计数（真建筑/占位兜底/无处可干）", _test_count_work_capacity)
	_runner.add_test("配比: 批量分配（quota+工位容量约束、配额满待业）", _test_assign_village_jobs)
	_runner.add_test("配比: 无工位职业全待业（容量 0 不分配）", _test_jobs_capacity_zero_idle)
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
		_runner.assert_false(row.has("uniform"), "职业行不应再有 uniform 染色字段（身体不做身份染色）")
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
	_runner.assert_equal(e.weapon_mount.weapon_type, WeaponMount.WeaponType.PICKAXE, "铁匠工具映射 PICKAXE")
	_runner.assert_equal(e.rig.body_color, Color.WHITE, "装具应用不改身体色（火柴人身体不做身份染色）")
	# 未知 tool 值不换装（保持默认剑）
	var bogus: Dictionary = {"id": "x", "tool": "chainsaw"}
	var e2 := FakeEntity.new()
	e2.rig = FakeRig.new()
	e2.weapon_mount = FakeMount.new()
	ProfessionRegistry.apply_appearance(e2, bogus)
	_runner.assert_equal(e2.rig.body_color, Color.WHITE, "未知 tool 同样不染身体色")
	_runner.assert_equal(e2.weapon_mount.weapon_type, WeaponMount.WeaponType.SWORD, "未知 tool 保持默认武器")
	# 缺 rig/weapon_mount 的实体只跳装具不炸
	var e3 := FakeEntity.new()
	ProfessionRegistry.apply_appearance(e3, smith)


func _test_duck_degrade() -> void:
	# 裸 Node：没有 set_profession 方法 → 未分配返回 ""
	var bare := Node2D.new()
	var id := TownLifeAPI.assign_village_job(bare, 0)
	_runner.assert_equal(id, "", "接不住职业的实体返回空（未分配）")
	# null 实体安全
	_runner.assert_equal(TownLifeAPI.assign_village_job(null, 0), "", "null 实体安全返回空")


# ───────────────────────── 批次 4：村庄职业配比 ────────────────────────────────

func _test_count_work_capacity() -> void:
	# 本套件无建筑环境：smithy_lv1 走占位表兜底（批次 3 语义 = "村子有打铁需求"）
	var e := FakeEntity.new()
	add_child(e)  # 容量计数借实体取场景树
	_runner.assert_equal(ProfessionRegistry.count_work_capacity(e, "smithy_lv1"), 1,
			"无真建筑但占位表覆盖 smithy_lv1 → 容量 1（占位计入配比的兜底）")
	_runner.assert_equal(ProfessionRegistry.count_work_capacity(e, "no_such_shop"), 0,
			"占位表未覆盖且无建筑 → 容量 0")
	_runner.assert_equal(ProfessionRegistry.count_work_capacity(e, ""), 0,
			"空 def 容量 0（资源点职业不走工位约束）")
	_runner.assert_equal(ProfessionRegistry.count_work_capacity(null, "smithy_lv1"), 0,
			"null 参照实体安全返回 0")
	e.queue_free()


func _test_assign_village_jobs() -> void:
	# 无建筑环境：铁匠容量 = 占位兜底 1。断言值随 professions.tres quota 联动
	#（当前 blacksmith 1 / lumberjack 3 / miner 3）。
	var entities: Array = []
	for i in 10:
		var e := FakeEntity.new()
		e.rig = FakeRig.new()
		e.weapon_mount = FakeMount.new()
		add_child(e)
		entities.append(e)
	var stats: Dictionary = TownLifeAPI.assign_village_jobs(entities)
	var jobs: Dictionary = stats.get("jobs", {})
	_runner.assert_equal(int(jobs.get("blacksmith", 0)), 1, "铁匠配额 1（quota=1 与占位容量 1 取小）")
	_runner.assert_equal(int(jobs.get("lumberjack", 0)), 3, "伐木工配额 3（quota=3，资源点职业不受工位约束）")
	_runner.assert_equal(int(jobs.get("miner", 0)), 3, "矿工配额 3（quota=3，资源点职业不受工位约束）")
	_runner.assert_equal(int(stats.get("idle", 0)), 3, "配额外村民进待业池 3 人")
	# 职业确实写入实体、装具同步应用（身体色不被染色）
	var smith_count: int = 0
	for e in entities:
		var pid := String(e.get_profession())
		if pid == "blacksmith":
			smith_count += 1
			_runner.assert_equal(e.rig.body_color, Color.WHITE, "铁匠装具已应用且不动身体色")
	_runner.assert_equal(smith_count, int(jobs.get("blacksmith", 0)), "实体侧职业计数与统计一致")
	for e in entities:
		e.queue_free()


func _test_jobs_capacity_zero_idle() -> void:
	# 注入自定义档案（静态缓存，用例退出恢复）：容量 0 的工位职业不分配；
	# 资源点职业按 quota 上限分配；配额外全待业。
	var saved: Array = ProfessionRegistry._cached
	ProfessionRegistry._cached = [
		{"id": "mason", "name_zh": "石匠", "work_site_def": "no_such_shop", "quota": 2},
		{"id": "farmer", "name_zh": "农夫", "work_site_def": "", "quota": 1},
	]
	var entities: Array = []
	for i in 4:
		var e := FakeEntity.new()
		add_child(e)
		entities.append(e)
	var stats: Dictionary = TownLifeAPI.assign_village_jobs(entities)
	var jobs: Dictionary = stats.get("jobs", {})
	_runner.assert_false(jobs.has("mason"), "容量 0 的工位职业不参与分配（无处可干不上岗）")
	_runner.assert_equal(int(jobs.get("farmer", 0)), 1, "资源点职业按 quota 分配 1 人")
	_runner.assert_equal(int(stats.get("idle", 0)), 3, "其余 3 人全部待业")
	ProfessionRegistry._cached = saved
	for e in entities:
		e.queue_free()
