extends Node
## 集成测试：武器动画音效桥（弓射/镐击命中帧 → SFX_EVENTS）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_weapon_sfx_bridge.tscn
##
## 覆盖：
##   - 弓：attack_bow_release 的 Hit 命中帧 → weapon_bow_fire 起播（走生产链：
##     WeaponMount._on_rig_anim_event 转发 → 桥映射 → AudioManager.play_event）
##   - 镐：attack_pickaxe 的 Hit 命中帧 → weapon_pick_hit 起播
##   - 护栏：无映射动画的 Hit 不触发桥；非 Hit 事件不触发桥
##   - 数据侧让位：触发时刻若动画已自带 Sound 元数据，桥不发声（防未来 Spine 源
##     补上 Sound 后双发声）——用 in-memory Animation 资源换装验证
##
## headless 下没有音频设备，播放调用是安全空操作，出声无副作用。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
## 被桥发现的宿主类型（生产链的事件源；tests 不受模块审计约束，可直连内部路径）
const WeaponMountScript := preload("res://modules/units/scripts/entity/weapon_mount.gd")
## 被测对象
const BridgeScript := preload("res://modules/world/scripts/weapon_anim_sfx_bridge.gd")
## 动画库（数据侧让位用例的 rigless 直读出口）
const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT

var _runner: TestRunner
var _bridge: Node = null
var _mount: Node2D = null


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("弓: attack_bow_release 的 Hit → weapon_bow_fire", _test_bow_fire, true)
	_runner.add_test("镐: attack_pickaxe 的 Hit → weapon_pick_hit", _test_pick_hit, true)
	_runner.add_test("护栏: 无映射动画与非 Hit 事件不触发", _test_guard, true)
	_runner.add_test("数据侧让位: 动画自带 Sound 时桥静默", _test_data_guard, true)
	_run_tests_async()


func _run_tests_async() -> void:
	await _runner.run_async()
	_cleanup()
	await get_tree().process_frame
	await get_tree().process_frame
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _cleanup() -> void:
	AudioManager.reset_runtime_state()
	if _mount != null and is_instance_valid(_mount):
		_mount.queue_free()
	_mount = null
	if _bridge != null and is_instance_valid(_bridge):
		_bridge.queue_free()
	_bridge = null


## 每个用例一套干净的桥 + 独立 WeaponMount（无宿主实体：桥只认信号，不需要实体）。
## 桥经树级 node_added 发现挂载点——先挂桥再挂载具，顺序即生产装配序。
func _spawn_bridge_and_mount() -> void:
	AudioManager.reset_runtime_state()
	if _bridge != null and is_instance_valid(_bridge):
		_bridge.queue_free()
	_bridge = BridgeScript.new()
	_bridge.name = "TestBridge"
	add_child(_bridge)
	await get_tree().process_frame
	_mount = WeaponMountScript.new()
	_mount.name = "TestMount"
	add_child(_mount)
	await get_tree().process_frame


func _wait_ms(ms: int) -> void:
	await get_tree().create_timer(float(ms) / 1000.0, true, false, true).timeout


func _test_bow_fire() -> void:
	await _spawn_bridge_and_mount()
	# 生产链入口：rig 的动画事件 → WeaponMount 转发信号（放箭帧 Hit@0.5333）
	_mount._on_rig_anim_event("attack_bow_release", "Hit", "")
	# weapon_bow_fire 非 instant：合并窗口（30ms）收尾后起播
	await _wait_ms(90)
	_runner.assert_gt(float(AudioManager.get_play_count("weapon_bow_fire")), 0.0,
		"弓释放段 Hit 命中帧应触发 weapon_bow_fire")


func _test_pick_hit() -> void:
	await _spawn_bridge_and_mount()
	_mount._on_rig_anim_event("attack_pickaxe", "Hit", "")
	await _wait_ms(90)
	_runner.assert_gt(float(AudioManager.get_play_count("weapon_pick_hit")), 0.0,
		"镐攻击 Hit 命中帧应触发 weapon_pick_hit")


func _test_guard() -> void:
	await _spawn_bridge_and_mount()
	# 无映射动画（剑 attack 的 Sound 数据在册，由 WeaponMount 自己播）→ 桥不发声
	_mount._on_rig_anim_event("attack", "Hit", "")
	await _wait_ms(90)
	_runner.assert_equal(AudioManager.get_play_count("weapon_bow_fire"), 0,
		"无映射动画的 Hit 不应触发弓声")
	_runner.assert_equal(AudioManager.get_play_count("weapon_pick_hit"), 0,
		"无映射动画的 Hit 不应触发镐声")
	# 非 Hit 事件（如 Drawn/ Sound）不走桥——Sound 由 WeaponMount 自己的表映射
	AudioManager.reset_runtime_state()
	_mount._on_rig_anim_event("attack_bow_release", "Drawn", "")
	await _wait_ms(90)
	_runner.assert_equal(AudioManager.get_play_count("weapon_bow_fire"), 0,
		"非 Hit 事件不应经桥发声")


func _test_data_guard() -> void:
	await _spawn_bridge_and_mount()
	# 给 attack_pickaxe 临时塞一条 Sound 元数据（模拟"Spine 源补上 Sound"之后的
	# 世界状态）：rigless_anim_event_time 直读 .tres，这里用运行期 set_meta 改写
	var res: Animation = load("res://modules/stick_rig/animations/attack_pickaxe.tres")
	var original: Array = res.get_meta("anim_events")
	res.set_meta("anim_events", original + [{"name": "Sound", "time": 0.3, "string": "Swoosh"}])
	_mount._on_rig_anim_event("attack_pickaxe", "Hit", "")
	await _wait_ms(90)
	_runner.assert_equal(AudioManager.get_play_count("weapon_pick_hit"), 0,
		"动画已自带 Sound 数据时桥应让位（防双发声）")
	# 还原元数据（.tres 是共享资源，污染会泄漏到后续加载）
	res.set_meta("anim_events", original)
	res.set_meta("sound_events", [])
