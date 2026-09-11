extends Node
## 集成测试：工作场所运转（批次 3）——WorkSlots 真槽位消费 / 建筑被毁降级
## 占位工位 / 工作-休息节律收工回岗。
##
## 验收门（交接档批次 3）：
##   1. 摆真建筑（def=smithy_lv1 + Interior/WorkSlots 槽位）→ 铁匠上班走真槽位
##      （BehaviorHarvest.worksite 模式 + 工位建筑引用命中摆点）且槽位上产出锭；
##   2. 建筑拆毁 → 铁匠降级占位工位（X=1120）继续营业（不打断营业）；
##   3. 游戏 time_of_day 调 23 点 → 全体村民收工（无 harvest）；调回 12 点 →
##      铁匠回岗继续劳作（完整节律往返）。
##
## 稳定性设计：测试显式管理游戏时钟（白天段轮询回拨防自然推进过 19 点收工线）；
## 建筑摆村民右侧净空带（1350，槽位 1320），与仓库 PassageBarrier / 天然资源点
## 隔离；铁匠原料预置 300 矿（4s/拍耗 10，分钟级测试供给充裕）。
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_town_life_worksite.tscn
## 退出码：0 全部通过，1 有失败

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const ScriptBuilding := preload("res://modules/building_gen/scripts/building.gd")

## 时间预算（真实秒；并行 CPU 争用下游戏逻辑最慢 ~2.5x，预算留足余量）
const POLL_INTERVAL := 0.5
const ARRIVE_TIMEOUT := 60.0
const DEMOLISH_REGROUP_TIMEOUT := 40.0
const NIGHT_SETTLE_SEC := 6.0
const DAY_RETURN_TIMEOUT := 40.0
## 摆点（村民出生区 1050/1250 右侧净空带；建筑无 PassageBarrier 不挡路）
const SHOP_ORIGIN_X := 1350.0
const SLOT_OFFSET := Vector2(-30.0, 0.0)
## 预期工位 X
const REAL_SLOT_X := SHOP_ORIGIN_X + SLOT_OFFSET.x   # 1320
const PLACEHOLDER_X := 1120.0
## 铁匠原料预置量
const ORE_SEED_STOCK := 300.0
## 节律工作时段下限（回拨线：防自然推进过 19 点收工干扰白天段断言）
const CLOCK_REWIND_HOUR := 18.5
const CLOCK_RESET_HOUR := 8.0

var _runner: TestRunner
var _game_root: Node = null
var _shop: Building = null


func _ready() -> void:
	SaveManager.set_auto_save_enabled(false)
	_runner = TestRunner.new()
	_runner.add_test("WorkSlots 真槽位: 铁匠上班+槽位产出", Callable(self, "_test_real_slot"), true)
	_runner.add_test("建筑被毁: 降级占位工位继续营业", Callable(self, "_test_demolish_fallback"), true)
	_runner.add_test("节律: 夜间收工/白天回岗", Callable(self, "_test_rhythm"), true)
	await _setup_world()
	await _runner.run_async()
	print(_runner.summary())
	get_tree().quit(0 if _runner.all_passed() else 1)


func _setup_world() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	for i in 10:
		await get_tree().process_frame
	# 调慢游戏时钟（默认 60s=1 游戏日，工作日仅 27.5 真实秒，套件中途就会撞
	# 19 点收工线）：600s=1 日后 90s 窗口只推进 3.6h；节律断言用 set_time_of_day
	# 显式拨针不受影响（_keep_daytime 仅作白天段兜底）
	var env := _env()
	if env != null and env.has_method("set_seconds_per_day"):
		env.set_seconds_per_day(600.0)
	# 移除 village_a 的真铁匠铺（建筑与美术升级线批次 1 配置，cell -17）：
	# 本套件专测「建筑被毁 → 降级占位工位」路径，真铺在场时铁匠拆铺后会
	# 投奔真铺 WorkSlots 而非占位工位，降级路径被绕开
	var host: Node2D = _map().get("building_host") if "building_host" in _map() else null
	if host != null:
		for b in host.get_children():
			if b != null and is_instance_valid(b) and String(b.get("def_id")) == "smithy_lv1":
				b.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


# ─────────────────────────────── 环境辅助 ────────────────────────────────

func _map() -> Node2D:
	return _game_root.get_current_map()


func _env() -> Node:
	return _game_root.get_node_or_null("EnvironmentSystem")


## 白天段时钟管理：自然推进接近收工线则回拨（保持村民在工作时段）
func _keep_daytime() -> void:
	var env := _env()
	if env != null and env.has_method("get_time_of_day"):
		var h: float = env.get_time_of_day()
		if h >= CLOCK_REWIND_HOUR or h < ProfessionRegistry.WORK_HOUR_START:
			env.set_time_of_day(CLOCK_RESET_HOUR)


## 摆一栋带 WorkSlots 槽位的运营中建筑（真 Building，_ready 进 building 组）
func _spawn_shop() -> Building:
	var map := _map()
	var b: Building = ScriptBuilding.new()
	b.def_id = "smithy_lv1"
	b.position = Vector2(SHOP_ORIGIN_X, map.ground_y)
	var interior := Node2D.new()
	interior.name = "Interior"
	b.add_child(interior)
	var slots := Node2D.new()
	slots.name = "WorkSlots"
	interior.add_child(slots)
	var m := Marker2D.new()
	m.position = SLOT_OFFSET
	slots.add_child(m)
	map.add_child(b)
	b.set_state(Building.State.OPERATIONAL)
	return b


## 铁匠（真实 NPC index0）
func _blacksmith() -> Node2D:
	for npc in _villagers():
		if String(npc.get_profession()) == "blacksmith":
			return npc
	return null


## 村民列表（EntityHost 内非附身、有职业的实体）
func _villagers() -> Array:
	var result: Array = []
	var map := _map()
	var host: Node = map.get_node_or_null("EntityHost") if map != null else null
	if host == null:
		return result
	for u in host.get_children():
		if u is Node2D and is_instance_valid(u) \
				and u.has_method("get_profession") and not String(u.get_profession()).is_empty() \
				and u.has_method("is_possessed") and not u.is_possessed():
			result.append(u)
	return result


## 村民当前行为名
func _behavior(npc: Node2D) -> String:
	var ctl: Node = npc.get_ai_controller() if npc.has_method("get_ai_controller") else null
	return ctl.get_current_behavior() if ctl != null else ""


## 轮询直到判定命中或超时；on_poll 每圈调用（时钟管理）
func _poll_until(seconds: float, check: Callable) -> bool:
	var elapsed := 0.0
	while elapsed < seconds:
		await get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL
		if check.call():
			return true
	return check.call()


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_real_slot() -> void:
	var map := _map()
	_runner.assert_true(map != null, "村庄地图加载")
	if map == null:
		return
	var api: Node = _game_root.get_resources_api()
	_runner.assert_true(api != null, "ResourcesApi 就绪")
	var smith: Node2D = _blacksmith()
	_runner.assert_true(smith != null, "铁匠 NPC 存在（真实 index0）")
	if map == null or api == null or smith == null:
		return

	# 时钟归位白天 + 摆建筑 + 预置原料
	var env := _env()
	if env != null and env.has_method("set_time_of_day"):
		env.set_time_of_day(CLOCK_RESET_HOUR)
	_shop = _spawn_shop()
	_runner.assert_true(_shop.is_in_group("building"), "摆点建筑进 building 组")
	api.produce("res_metal_ore", ORE_SEED_STOCK, "test_region", "测试预置")

	# 铁匠应走到真槽位上班（worksite 模式 + 建筑引用 = 摆点）
	var hv: Node = null
	var on_slot := func() -> bool:
		if _behavior(smith) != "harvest":
			return false
		var ctl: Node = smith.get_ai_controller()
		var sm: Node = ctl.get_state_machine()
		var b: Node = sm.get_node_or_null("BehaviorHarvest")
		if b == null or b.get_mode_name() != "worksite":
			return false
		hv = b
		return b.get_worksite_building() == _shop
	var arrived: bool = await _poll_until(ARRIVE_TIMEOUT, on_slot)
	_runner.assert_true(arrived, "铁匠应寻到真槽位上班（%.0fs 内）" % ARRIVE_TIMEOUT)
	if not arrived or hv == null:
		return
	_runner.assert_approx(smith.global_position.x, REAL_SLOT_X, 60.0,
			"铁匠站位应贴近槽位 X=1320（实 %.0f）" % smith.global_position.x)

	# 槽位上真实产出（≥1 拍 6 锭）
	var ingot0: float = api.get_stock("res_iron_ingot")
	var grew: bool = await _poll_until(30.0, func() -> bool:
		_keep_daytime()
		return api.get_stock("res_iron_ingot") >= ingot0 + 6.0)
	_runner.assert_true(grew, "真槽位劳作应产出铁锭（%.0fs 内 +6，实 +%.1f）"
			% [30.0, api.get_stock("res_iron_ingot") - ingot0])


func _test_demolish_fallback() -> void:
	var smith: Node2D = _blacksmith()
	var api: Node = _game_root.get_resources_api()
	if smith == null or api == null or _shop == null or not is_instance_valid(_shop):
		_runner.assert_true(false, "前置状态丢失（铁匠/建筑/资源 API）")
		return
	# 拆毁建筑：铁匠应重寻位 → 降级占位工位（X=1120）继续营业
	_shop.demolish()
	var regrouped := func() -> bool:
		_keep_daytime()
		if _behavior(smith) != "harvest":
			return false
		var ctl: Node = smith.get_ai_controller()
		var b: Node = ctl.get_state_machine().get_node_or_null("BehaviorHarvest")
		if b == null or b.get_mode_name() != "worksite":
			return false
		return b.get_worksite_building() == null and absf(smith.global_position.x - PLACEHOLDER_X) < 60.0
	var ok: bool = await _poll_until(DEMOLISH_REGROUP_TIMEOUT, regrouped)
	_runner.assert_true(ok, "建筑被毁后铁匠应降级占位工位（X=%.0f，%.0fs 内）"
			% [PLACEHOLDER_X, DEMOLISH_REGROUP_TIMEOUT])

	# 占位工位上继续产出（营业不中断）
	var ingot0: float = api.get_stock("res_iron_ingot")
	var grew: bool = await _poll_until(20.0, func() -> bool:
		_keep_daytime()
		return api.get_stock("res_iron_ingot") >= ingot0 + 6.0)
	_runner.assert_true(grew, "占位工位应继续产出铁锭（+%.1f）"
			% [api.get_stock("res_iron_ingot") - ingot0])


func _test_rhythm() -> void:
	var env := _env()
	_runner.assert_true(env != null and env.has_method("set_time_of_day"),
			"EnvironmentSystem 可用（节律时钟源）")
	if env == null or not env.has_method("set_time_of_day"):
		return

	# 夜间：全体村民收工（无 harvest；idle/wander 休息态）
	env.set_time_of_day(23.0)
	await get_tree().create_timer(NIGHT_SETTLE_SEC).timeout
	var any_working := false
	for npc in _villagers():
		if _behavior(npc) == "harvest":
			any_working = true
	_runner.assert_false(any_working, "23 点全体村民应收工（无 harvest）")

	# 白天：铁匠回岗（重寻位占位工位继续打铁）
	env.set_time_of_day(12.0)
	var smith: Node2D = _blacksmith()
	if smith == null:
		_runner.assert_true(false, "铁匠 NPC 存在")
		return
	var back := func() -> bool:
		if _behavior(smith) != "harvest":
			return false
		var ctl: Node = smith.get_ai_controller()
		var b: Node = ctl.get_state_machine().get_node_or_null("BehaviorHarvest")
		return b != null and b.is_working()
	var ok: bool = await _poll_until(DAY_RETURN_TIMEOUT, back)
	_runner.assert_true(ok, "白天铁匠应回岗劳作（%.0fs 内）" % DAY_RETURN_TIMEOUT)
