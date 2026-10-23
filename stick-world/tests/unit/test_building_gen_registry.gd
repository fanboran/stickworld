extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：building_gen 模块注册表与程序化装配纯逻辑（api.gd + BuildingExterior）。
##
## 覆盖面：
##   - 场景注册表：默认 def_id 全集可加载 PackedScene 且可实例化（注册表↔磁盘一致性）
##   - 未知 def_id 返回 null（不炸）
##   - 管线 def 反查：CityGen 卡名 → 运行时 def_id 映射命中 / 未收录空串
##   - pipeline_def_map：深拷贝隔离（外部改不脏内部表）
##   - 映射不变量：键 ⊆ 场景注册表（物化层要求可加载）、defs 非空、宽度 > 0、
##     管线 def 全局唯一（一卡只归一个运行时壳）
##   - _fill_pillars：柱距均匀分布 / 端点锚定 / 退化跨度
##   - InteractionZone 程序化补件：几何口径（24px 轨）+ 宽度重摆 + 幂等
##   - 室内 z 带序契约（INT-1）：Floor/Props 与 L1~L5 层 z_index、Interior 默认
##     不可见、场景自带 WorkSlots 保留
##
## batch 准入：纯逻辑/离树实例（BuildingExterior.new() 不入树，只调指定方法），
## 零 autoload 触碰；实例经 runner.track_node 登记、用例结束自动释放。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const BuildingGenAPI := preload("res://modules/building_gen/api.gd")
const ScriptExterior := preload("res://modules/building_gen/buildings/building_exterior.gd")

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("注册表: 默认 def_id 全集可加载可实例化", _test_scene_registry_loadable)
	_runner.add_test("注册表: 未知 def_id 返回 null", _test_unknown_def_null)
	_runner.add_test("管线反查: 卡名 → 运行时 def_id", _test_runtime_def_lookup)
	_runner.add_test("映射表: 深拷贝隔离", _test_pipeline_map_copy)
	_runner.add_test("映射不变量: 键⊆场景表/defs 非空/宽度>0/卡名唯一", _test_pipeline_map_invariants)
	_runner.add_test("柱距: _fill_pillars 均布与退化", _test_fill_pillars)
	_runner.add_test("触发区: 程序化补件几何/宽度重摆/幂等", _test_interaction_zone)
	_runner.add_test("室内: z 带序契约/默认隐藏/WorkSlots 保留", _test_interior_z_contract)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_scene_registry_loadable() -> void:
	var ids: Array = BuildingGenAPI.get_default_building_def_ids()
	_runner.assert_gt(ids.size(), 0, "默认 def_id 非空")
	for id: String in ids:
		var scene: PackedScene = BuildingGenAPI.load_building_scene(id)
		_runner.assert_not_null(scene, "def_id '%s' 可加载场景" % id)
		if scene != null:
			_runner.assert_true(scene.can_instantiate(), "def_id '%s' 场景可实例化" % id)


func _test_unknown_def_null() -> void:
	var scene: PackedScene = BuildingGenAPI.load_building_scene("no_such_building")
	_runner.assert_null(scene, "未知 def_id 返回 null（不炸）")


func _test_runtime_def_lookup() -> void:
	# 命中：同一运行时壳覆盖多张管线卡
	var hits := {
		"smithy1": "smithy_lv1", "smithy4": "smithy_lv1",
		"warehouse": "warehouse",
		"barracks": "barracks",
		"guildhall": "grand_hall", "imperial_palace": "grand_hall",
		"house": "timber_cottage", "rowhouse": "timber_cottage",
		"cottage": "placeholder", "inn_post": "placeholder",
	}
	for card: String in hits:
		_runner.assert_equal(BuildingGenAPI.runtime_def_for_pipeline(card), hits[card],
				"管线卡 '%s' 反查 '%s'" % [card, hits[card]])
	# 未收录：空串（无运行时实体，3D 烘卡纯视觉、物化层跳过）
	_runner.assert_equal(BuildingGenAPI.runtime_def_for_pipeline("no_such_card"), "",
			"未收录卡返回空串")


func _test_pipeline_map_copy() -> void:
	var m1: Dictionary = BuildingGenAPI.pipeline_def_map()
	m1.erase("smithy_lv1")
	if m1.has("warehouse"):
		m1["warehouse"]["width"] = -999
	var m2: Dictionary = BuildingGenAPI.pipeline_def_map()
	_runner.assert_true(m2.has("smithy_lv1"), "外部 erase 不脏内部表")
	_runner.assert_equal(int(m2["warehouse"]["width"]), 16, "外部改值不脏内部表")


func _test_pipeline_map_invariants() -> void:
	var scene_ids: Dictionary = {}
	for id: String in BuildingGenAPI.get_default_building_def_ids():
		scene_ids[id] = true
	var seen_cards: Dictionary = {}
	var m: Dictionary = BuildingGenAPI.pipeline_def_map()
	for runtime_id: String in m:
		_runner.assert_true(scene_ids.has(runtime_id),
				"运行时壳 '%s' 必须在场景注册表中（物化层要求可加载）" % runtime_id)
		var entry: Dictionary = m[runtime_id]
		var defs: Array = entry["defs"]
		_runner.assert_gt(defs.size(), 0, "'%s' 的管线卡名单非空" % runtime_id)
		_runner.assert_gt(int(entry["width"]), 0, "'%s' 首选宽度为正" % runtime_id)
		for card: String in defs:
			_runner.assert_false(seen_cards.has(card),
					"管线卡 '%s' 重复归壳（'%s' 与 '%s'）" % [card, seen_cards.get(card, ""), runtime_id])
			seen_cards[card] = runtime_id


func _test_fill_pillars() -> void:
	var ext: Node = _runner.track_node(ScriptExterior.new())
	# 整除：固定柱 0、右锚 300、期望间距 100 → 中柱 100/200，全列 4 根等距
	var xs: Array = ext._fill_pillars([0.0], 300.0, 100.0)
	_runner.assert_equal(xs.size(), 4, "整除时 4 根柱")
	for i in range(1, xs.size()):
		_runner.assert_approx(float(xs[i]) - float(xs[i - 1]), 100.0, 0.001,
				"第 %d 间距恰为 pitch" % i)
	_runner.assert_approx(float(xs[0]), 0.0, 0.001, "首柱=固定柱")
	_runner.assert_approx(float(xs[xs.size() - 1]), 300.0, 0.001, "末柱=右锚柱")
	# 非整除：中柱数 = round(span/pitch)-1，间距在 pitch 附近浮动
	var xs2: Array = ext._fill_pillars([0.0], 300.0, 90.0)
	_runner.assert_equal(xs2.size(), 4, "span/pitch=3.33 → 2 中柱 + 两端")
	for i in range(1, xs2.size()):
		var gap := float(xs2[i]) - float(xs2[i - 1])
		_runner.assert_true(gap > 72.0 and gap < 108.0, "第 %d 间距浮动在 pitch±20%% 内（实测 %.1f）" % [i, gap])
	# 原始口径：左组合体双柱 + 右锚，span 恰一步 → 不插中柱
	var xs3: Array = ext._fill_pillars([-205.0, -0.5], 204.0, 204.5)
	_runner.assert_equal(xs3.size(), 3, "原始口径 3 根（无中柱）")
	_runner.assert_approx(float(xs3[2]), 204.0, 0.001, "右锚柱就位")
	# 退化：右锚在最后固定柱左侧（span≤0）→ 仅追加右锚
	var xs4: Array = ext._fill_pillars([0.0], -50.0, 100.0)
	_runner.assert_equal(xs4.size(), 2, "退化跨度不插中柱")
	_runner.assert_approx(float(xs4[1]), -50.0, 0.001, "退化时仍锚右")


func _test_interaction_zone() -> void:
	var ext: Node = _runner.track_node(ScriptExterior.new())
	ext.width = 10
	ext._ensure_interaction_zone()
	var zone: Area2D = ext.get_node("InteractionZone")
	_runner.assert_equal(zone.collision_mask, 2, "只探测实体层（StickmanEntity layer=2）")
	_runner.assert_equal(zone.collision_layer, 0, "自身不在任何物理层")
	var cs: CollisionShape2D = zone.get_node("ZoneShape")
	var rect: RectangleShape2D = cs.shape
	_runner.assert_true(rect.size.is_equal_approx(Vector2(240.0, 272.0)),
			"宽度随 10 格 ×24px，高盖 ZONE_TOP..ZONE_BOTTOM")
	_runner.assert_true(cs.position.is_equal_approx(Vector2(120.0, -160.0)),
			"碰撞形中心 = 半宽 + 上下沿中点（下沿锚地板线下 1 格）")
	# 幂等：重复补件不重复建
	ext._ensure_interaction_zone()
	var zone_count := 0
	for child in ext.get_children():
		if child.name == "InteractionZone":
			zone_count += 1
	_runner.assert_equal(zone_count, 1, "重复补件幂等（仍 1 个触发区）")
	# 宽度重摆：建造时拉伸的实际宽度 ≠ 场景默认 → 触发区同步缩放
	ext.width = 16
	ext._resize_interaction_zone()
	var rect2: RectangleShape2D = cs.shape
	_runner.assert_true(rect2.size.is_equal_approx(Vector2(384.0, 272.0)), "重摆后宽度 16 格")
	_runner.assert_true(cs.position.is_equal_approx(Vector2(192.0, -160.0)), "重摆后中心随宽移")


func _test_interior_z_contract() -> void:
	var ext: Node = _runner.track_node(ScriptExterior.new())
	# 离树补室内：Interior/Floor/Props 程序化补齐 + 带序显式赋值
	ext._build_interior()
	var interior: Node2D = ext.get_node("Interior")
	_runner.assert_false(interior.visible, "Interior 默认不可见（进屋才显）")
	var floor_node: Node2D = interior.get_node("Floor")
	var props: Node2D = interior.get_node("Props")
	_runner.assert_equal(floor_node.z_index, 4, "地板 z=4（INT-1 带序表）")
	_runner.assert_equal(props.z_index, 5, "家具/设备 z=5（遮走地图级 z=3 的火柴人）")
	# 场景自带 Interior/WorkSlots：补件保留 WorkSlots 不动（smithy 先例）
	var ext2: Node = _runner.track_node(ScriptExterior.new())
	var interior2 := Node2D.new()
	interior2.name = "Interior"
	var slots := Node2D.new()
	slots.name = "WorkSlots"
	var marker := Marker2D.new()
	marker.position = Vector2(10, 0)
	slots.add_child(marker)
	interior2.add_child(slots)
	ext2.add_child(interior2)
	ext2._build_interior()
	var kept: Node = ext2.get_node("Interior").get_node_or_null("WorkSlots")
	_runner.assert_not_null(kept, "场景自带 WorkSlots 保留不重建")
	_runner.assert_equal(kept.get_child_count(), 1, "WorkSlots 原有 marker 不丢")
	_runner.assert_not_null(ext2.get_node("Interior").get_node_or_null("Floor"), "补齐 Floor")
	_runner.assert_not_null(ext2.get_node("Interior").get_node_or_null("Props"), "补齐 Props")
	# 建层带序：_nc 按 LAYER_Z 表赋 z（L1~L5 + Floor/Props 同一契约）
	var holder: Node = _runner.track_node(Node2D.new())
	var z_expect := {"L1_BackWall": 0, "L2_BackItems": 1, "Floor": 4, "L3_FrontItems": 5,
			"L4_FrontWall": 10, "L5_Roof": 11}
	for layer_name: String in z_expect:
		var n: Node2D = ext2._nc(layer_name, holder)
		_runner.assert_equal(n.z_index, z_expect[layer_name], "%s z=%d" % [layer_name, z_expect[layer_name]])
	# 表外名字不赋 z（默认 0）
	var unknown: Node2D = ext2._nc("NotALayer", holder)
	_runner.assert_equal(unknown.z_index, 0, "表外名字保持默认 z")
