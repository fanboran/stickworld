extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：EnvironmentSystem 昼夜时钟与光照节点（environment 模块）。
##
## 覆盖面：
##   - 时钟回绕：set_time_of_day 任意输入 fposmod 包 0..24
##   - set_seconds_per_day 下限钳制
##   - _process 推进：hours_per_second × sim_delta 步长精确、跨 24 点回绕、
##     WorldState.game_time 双向同步
##   - reset_to_new_run_clock：同进程重开一局回清晨 8 点并写回全局
##   - 读档对齐：_on_game_loaded 回读存档时刻；game_time==0（旧档缺字段）
##     维持当前时钟不跳 0 点；_ready 已连 game_loaded 信号
##   - 光照联动：CanvasModulate 色 == 采样值、清屏色 == 天空底色采样值、
##     夜/昼亮度档
##   - 营火光：默认关（energy 恒 0）；开启后光强随夜色爬升、位置经注入的
##     player_query 追踪玩家、查询无果/失效时光静止不炸
##   - 装配面：_ready 采纳已有 game_time（读档后新建节点恢复时刻）、
##     无时间信息时播种清晨并写回、CanvasModulate/CampLight 自动补齐
##
## batch 准入：⚠️ 照 test_work_slots_rhythm 先例的准入豁免——EnvironmentSystem
## 的数据源是 WorldState.game_time / EventBus.game_loaded（autoload 读 + 注入），
## 写入前后快照恢复（_saved_game_time），清屏色全局态同样快照恢复；
## EventBus 只做 is_connected 读检查，不发射全局信号。
## 所有 sys 夹具 set_process(false)：防自动 _process 在批次后续帧污染全局时钟，
## 断言一律手工调 sys._process(delta) 驱动（确定性步长）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptEnvSystem := preload("res://modules/environment/scripts/environment_system.gd")
const EnvAPI := preload("res://modules/environment/api.gd")

## 玩家实体查询桩（set_player_query 注入面；current_player 返回 Node2D 或 null）
class PlayerOracle extends Node2D:
	var player: Node2D = null

	func current_player() -> Node2D:
		return player


var _runner: TestRunner
var _case_root: Node = null
## 进入用例前的全局时钟快照（sys._ready/_process 会写 WorldState.game_time）
var _saved_game_time: float = -1.0
## 套件开始前的清屏色快照（_update_lighting 写 RenderingServer 全局态）
var _saved_clear_color: Color


func _ready() -> void:
	_saved_clear_color = RenderingServer.get_default_clear_color()
	_runner = TestRunner.new()
	_runner.add_test("时钟: set_time_of_day 任意值回绕 0..24", _test_clock_wrap)
	_runner.add_test("参数: set_seconds_per_day 下限钳制", _test_seconds_per_day_clamp)
	_runner.add_test("推进: _process 步长精确 + 跨日回绕 + 全局同步", _test_process_advance)
	_runner.add_test("重开: reset_to_new_run_clock 回清晨并写回全局", _test_new_run_reset)
	_runner.add_test("读档: 时钟对齐存档时刻 / 旧档缺字段不跳 0 点", _test_game_loaded_align)
	_runner.add_test("光照: CanvasModulate 与清屏色随时间采样", _test_lighting_sampling)
	_runner.add_test("营火光: 默认关/夜色爬升/追踪玩家/查询失效静止", _test_camp_light)
	_runner.add_test("装配: _ready 采纳/播种全局时钟 + 子节点补齐", _test_assembly)
	_runner.run()
	print(_runner.summary())
	_cleanup()
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _cleanup() -> void:
	if _case_root != null and is_instance_valid(_case_root):
		remove_child(_case_root)
		_case_root.free()
	_case_root = null
	# 全局态恢复（先拆夹具再回写，防夹具 teardown 再写全局）
	if _saved_game_time >= 0.0:
		WorldState.game_time = _saved_game_time
		_saved_game_time = -1.0
	RenderingServer.set_default_clear_color(_saved_clear_color)


func _new_case() -> void:
	_cleanup()
	_saved_game_time = WorldState.game_time
	_case_root = Node.new()
	_case_root.name = "CaseRoot"
	add_child(_case_root)


## 环境系统夹具：禁用自动 _process（防批次后续帧污染全局时钟），入树触发 _ready
func _make_sys() -> Node:
	var sys: Node = ScriptEnvSystem.new()
	sys.set_process(false)
	_case_root.add_child(sys)
	return sys


func _camp_light(sys: Node) -> PointLight2D:
	return sys.get_node("CampLight") as PointLight2D


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_clock_wrap() -> void:
	_new_case()
	var sys := _make_sys()
	var cases := {
		-3.0: 21.0,    # 前夜回卷
		0.0: 0.0,
		8.0: 8.0,
		24.0: 0.0,     # 24 点归 0
		25.0: 1.0,
		-0.25: 23.75,  # 负小数回卷
		47.5: 23.5,    # 跨多天
	}
	for raw: float in cases:
		sys.set_time_of_day(raw)
		_runner.assert_approx(sys.get_time_of_day(), cases[raw], 0.0001,
				"set_time_of_day(%.2f) 回绕为 %.2f" % [raw, cases[raw]])


func _test_seconds_per_day_clamp() -> void:
	_new_case()
	var sys := _make_sys()
	sys.set_seconds_per_day(600.0)
	_runner.assert_approx(sys.seconds_per_day, 600.0, 0.0001, "正常值原样保留")
	sys.set_seconds_per_day(0.2)
	_runner.assert_approx(sys.seconds_per_day, 1.0, 0.0001, "过小值钳到下限 1 秒")
	sys.set_seconds_per_day(0.0)
	_runner.assert_approx(sys.seconds_per_day, 1.0, 0.0001, "0 同样钳到下限（防除零）")


func _test_process_advance() -> void:
	_new_case()
	# 前置：批次运行器保证 X1 档（speed_factor=1 才有下述步长语义）
	_runner.assert_false(TimeManager.is_paused(), "前置：批次内时间流速应为 X1")
	var sys := _make_sys()
	# 1 模拟秒 = 1 游戏小时（seconds_per_day=24）
	sys.set_seconds_per_day(24.0)
	sys.set_time_of_day(10.0)
	sys._process(1.0)
	_runner.assert_approx(sys.get_time_of_day(), 11.0, 0.0001, "推进 1 模拟秒 = +1 小时")
	_runner.assert_approx(WorldState.game_time, 11.0, 0.0001, "推进后同步 WorldState.game_time")
	# 小步长：半秒推进半小时
	sys._process(0.5)
	_runner.assert_approx(sys.get_time_of_day(), 11.5, 0.0001, "0.5 模拟秒 = +0.5 小时")
	# 跨 24 点回绕且全局同步跟着回绕
	sys.set_time_of_day(23.5)
	sys._process(1.0)
	_runner.assert_approx(sys.get_time_of_day(), 0.5, 0.0001, "23.5 + 1h 回绕 0.5")
	_runner.assert_approx(WorldState.game_time, 0.5, 0.0001, "回绕值同步全局")
	# 一昼夜整周期：24 模拟秒恰好回原点（600s=一昼夜的缩比不变量）
	sys.set_time_of_day(8.0)
	for i in 24:
		sys._process(1.0)
	_runner.assert_approx(sys.get_time_of_day(), 8.0, 0.0001, "24 模拟秒整周期回原点")


func _test_new_run_reset() -> void:
	_new_case()
	var sys := _make_sys()
	# 上一局残留时刻（深夜）+ 全局脏值
	sys.set_time_of_day(23.0)
	WorldState.game_time = 3.0
	sys.reset_to_new_run_clock()
	_runner.assert_approx(sys.get_time_of_day(), 8.0, 0.0001, "重开回清晨 8 点（MORNING_HOUR）")
	_runner.assert_approx(WorldState.game_time, 8.0, 0.0001,
			"写回全局（防 GameRoot 归零值在中间帧被读成黑夜）")


func _test_game_loaded_align() -> void:
	_new_case()
	var sys := _make_sys()
	# _ready 已挂 game_loaded 监听（读档不重载本场景的对齐入口）
	_runner.assert_true(EventBus.game_loaded.is_connected(Callable(sys, "_on_game_loaded")),
			"_ready 连接 game_loaded（对齐入口在位）")
	# 存档时刻恢复 → 本地时钟回读对齐
	WorldState.game_time = 15.5
	sys._on_game_loaded(1)
	_runner.assert_approx(sys.get_time_of_day(), 15.5, 0.0001, "读档时钟对齐存档时刻")
	# 旧档缺时间字段（game_time==0 哨兵）：维持当前时钟不跳 0 点
	WorldState.game_time = 0.0
	sys._on_game_loaded(0)
	_runner.assert_approx(sys.get_time_of_day(), 15.5, 0.0001, "无时间信息维持当前时钟")


func _test_lighting_sampling() -> void:
	_new_case()
	var sys := _make_sys()
	# CanvasModulate 色 == 环境光采样值（_ready 即点亮，首帧不白屏）
	sys.set_time_of_day(8.0)
	sys._process(0.0)  # delta=0 只刷新光照不推时钟
	_runner.assert_true(sys.get_current_light_color().is_equal_approx(EnvAPI.sample_light_color(8.0)),
			"CanvasModulate 色 = 环境光采样")
	# 清屏色 == 天空底色采样值（星/月不被 CanvasModulate 压暗的轨道）
	_runner.assert_true(RenderingServer.get_default_clear_color()
			.is_equal_approx(EnvAPI.sample_sky_bg_color(8.0)), "清屏色 = 天空底色采样")
	# 夜晚档：地表压至剪影量级，天空最黑
	sys.set_time_of_day(0.0)
	sys._process(0.0)
	_runner.assert_lt(sys.get_current_light_color().get_luminance(), 0.1, "午夜环境光剪影量级")
	_runner.assert_true(RenderingServer.get_default_clear_color()
			.is_equal_approx(EnvAPI.sample_sky_bg_color(0.0)), "午夜清屏色最黑档")
	# 白天档
	sys.set_time_of_day(12.0)
	sys._process(0.0)
	_runner.assert_gt(sys.get_current_light_color().get_luminance(), 0.9, "正午环境光接近全亮")
	# 未触达 _update_lighting 前 get_current_light_color 不会自己变（显式步进语义）
	sys.set_time_of_day(19.0)
	_runner.assert_gt(sys.get_current_light_color().get_luminance(), 0.9,
			"set 之后未步进不刷新（推时钟与刷新同帧的合同）")


func _test_camp_light() -> void:
	_new_case()
	var sys := _make_sys()
	var light := _camp_light(sys)
	_runner.assert_not_null(light, "_ready 补齐 CampLight")
	# 默认关：光强恒 0（2026-09 用户口径：夜晚无随身光源）
	for i in 3:
		sys._process(0.016)
	_runner.assert_approx(light.energy, 0.0, 0.0001, "默认关闭时 energy 恒 0")
	# 开启 + 夜色：光强爬升（亮度反相映射），位置追踪注入的玩家
	sys.camp_light_enabled = true
	var oracle := PlayerOracle.new()
	var player := CharacterBody2D.new()
	player.position = Vector2(100, 200)
	oracle.player = player
	_case_root.add_child(oracle)
	_case_root.add_child(player)
	sys.set_player_query(Callable(oracle, "current_player"))
	sys.set_time_of_day(0.0)  # 午夜最暗 → 目标光强最大
	sys._process(0.0)
	_runner.assert_gt(light.energy, 0.0, "夜色下开启即起光")
	var px := light.global_position.x
	_runner.assert_true(px > 0.0 and px < 100.0, "光心朝玩家 X 侧移动（lerp 0.12）")
	for i in 12:
		sys._process(0.016)
	_runner.assert_gt(light.energy, 0.5, "持续步进向目标光强收敛")
	_runner.assert_gt(light.global_position.x, 50.0, "光心持续逼近玩家")
	# 查询无果（玩家不在场：主菜单/战斗空场）→ 光静止不炸
	var frozen := light.global_position
	oracle.player = null
	sys._process(0.016)
	_runner.assert_true(light.global_position.is_equal_approx(frozen), "玩家不在场光心静止")
	# 查询持有者失效（oracle 已释放）→ is_valid 守卫，静止不炸
	var oracle2 := PlayerOracle.new()
	_case_root.add_child(oracle2)
	sys.set_player_query(Callable(oracle2, "current_player"))
	oracle2.free()
	sys._process(0.016)
	_runner.assert_true(light.global_position.is_equal_approx(frozen), "查询失效光心静止不炸")


func _test_assembly() -> void:
	_new_case()
	# 全局已有时刻（读档后新建节点）：_ready 采纳存档时刻
	WorldState.game_time = 15.5
	var sys := _make_sys()
	_runner.assert_approx(sys.get_time_of_day(), 15.5, 0.0001, "已有 game_time 被 _ready 采纳")
	# 全局无时间信息（==0 哨兵）：播种清晨并写回
	WorldState.game_time = 0.0
	var sys2 := _make_sys()
	_runner.assert_approx(sys2.get_time_of_day(), 8.0, 0.0001, "无时间信息播种清晨 8 点")
	_runner.assert_approx(WorldState.game_time, 8.0, 0.0001, "播种写回全局")
	# 子节点自动补齐：CanvasModulate + CampLight，营火初始熄灭
	_runner.assert_not_null(sys2.get_node_or_null("CanvasModulate"), "自动补齐 CanvasModulate")
	var light := _camp_light(sys2)
	_runner.assert_not_null(light, "自动补齐 CampLight")
	_runner.assert_approx(light.energy, 0.0, 0.0001, "营火初始熄灭")
