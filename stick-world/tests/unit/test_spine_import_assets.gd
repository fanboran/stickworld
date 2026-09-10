extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：Spine 逆向重建批次 A 产物看门狗（93 动画 .tres + 56 骨骨架表）。
##
## 回归背景：动画资产由 tools/spine_importer.py 从 APK Spine JSON 导入（批次 A），
## 是渲染重标（批次 B）/数值验收（批次 C）/视觉验收（批次 D）的数据地基。
## 本套件锁定：
##   1. 93 个 .tres 全部可加载且轨道非空（文本格式/逗号/布局错误立刻红）
##   2. 事件元数据 52 处全量（metadata/anim_events，消费端 animation_event 依赖）
##   3. 循环标记抽样（walk 循环 / attack 一次性）
##   4. bezier 数值 spot check：与导入器内独立 Spine 语义求值器对账（度→弧度）
##   5. 骨架表 56 骨 + setup 基准值（rest=setup 姿态）
##
## 期望值来源：tools/ 下独立 Python 求值（解 x(u)=t 得 u 再取 y(u)，二分 50 次），
## 与 Godot bezier 轨道的几何控制点四边形求值数学等价（tests/dev/bezier_*_probe.gd 实验证实）。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")

const ANIM_DIR := "res://modules/units/animations/spine/"
const EXPECT_ANIM_COUNT := 93
const EXPECT_EVENT_COUNT := 52

## spot check 期望值（Spine 原始键 → 导入器 Godot 域换算 -(setup+delta) → 独立求值，单位：度）
## 键 = "<动画>/<全相对轨道路径>"（Bone2D 嵌套，路径必须含祖先链；扁平骨名解析不到）
const SPOT_EXPECT := {
	"Swordwrath-Attack1/RigRoot/root/bone/minertorso1/bone2/bone3/minerarm3/minerarm4/pickaxe1:rotation": {
		0.1: -103.82,          # 首键 t=0.5，之前 hold 首键值（setup 103.82 + delta 0）
		0.3: -89.89043015,
		0.5: -65.92,
		0.7: -87.274479211,
		0.9: -60.861139674,
		1.2: -63.875709387,
	},
	"Swordwrath-Attack1/RigRoot/root/bone/minertorso1:rotation": {
		0.2: -82.949986049,
		0.5: -84.4,
		0.8: -88.06099562,
		1.1: -86.894509002,
	},
	"Swordwrath-Walk/RigRoot/root/bone/minerleg2:rotation": {
		0.0: 63.18,
		0.3: 78.415,
		0.6: 97.400011539,
		0.9: 109.456064787,
	},
}

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("动画资产: %d 个 .tres 全部可加载且轨道非空" % EXPECT_ANIM_COUNT, _test_all_load)
	_runner.add_test("事件元数据: 全库 %d 处 + Swordwrath-Attack1 Hit@1.0" % EXPECT_EVENT_COUNT, _test_events)
	_runner.add_test("循环标记: Walk 循环 / Attack 一次性", _test_loop_flags)
	_runner.add_test("bezier 数值 spot check（3 轨道 × 采样点）", _test_bezier_values)
	_runner.add_test("骨架表: 56 骨 + setup 基准", _test_skeleton_data)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


func _test_all_load() -> void:
	var loaded := 0
	var dir := DirAccess.open(ANIM_DIR)
	if dir == null:
		_runner.assert_true(false, "动画目录不存在: %s" % ANIM_DIR)
		return
	for f in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		var anim := ResourceLoader.load(ANIM_DIR + f) as Animation
		if anim == null:
			_runner.assert_true(false, "加载失败: %s" % f)
			continue
		if anim.get_track_count() == 0:
			_runner.assert_true(false, "轨道为空: %s" % f)
			continue
		loaded += 1
	_runner.assert_equal(loaded, EXPECT_ANIM_COUNT, "可加载动画数应为 %d" % EXPECT_ANIM_COUNT)


func _test_events() -> void:
	var dir := DirAccess.open(ANIM_DIR)
	var total := 0
	var attack1_hit: Array = []
	for f in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		var anim := ResourceLoader.load(ANIM_DIR + f) as Animation
		if anim == null or not anim.has_meta("anim_events"):
			continue
		var events: Array = anim.get_meta("anim_events")
		total += events.size()
		if f == "Swordwrath-Attack1.tres":
			attack1_hit = events
	_runner.assert_equal(total, EXPECT_EVENT_COUNT, "事件元数据总数应全量入库")
	var found := false
	for e in attack1_hit:
		if str(e.get("name")) == "Hit" and absf(float(e.get("time")) - 1.0) < 0.01:
			found = true
	_runner.assert_true(found, "Swordwrath-Attack1 应含 Hit@1.0（命中帧真值，weapon_mount 消费）")


func _test_loop_flags() -> void:
	var walk := ResourceLoader.load(ANIM_DIR + "Swordwrath-Walk.tres") as Animation
	var attack := ResourceLoader.load(ANIM_DIR + "Swordwrath-Attack1.tres") as Animation
	_runner.assert_true(walk != null and walk.loop_mode == Animation.LOOP_LINEAR,
			"持续类动画（Walk/Stand/Run/Idle…）应 LOOP_LINEAR")
	_runner.assert_true(attack != null and attack.loop_mode == Animation.LOOP_NONE,
			"一次性动画（Attack/Death/Hit…）应 LOOP_NONE（rig._is_oneshot 依赖）")


func _test_bezier_values() -> void:
	var dir := DirAccess.open(ANIM_DIR)
	# 预加载动画 → 轨道索引表（NodePath 字符串 → track idx）
	var track_map := {}
	for f in dir.get_files():
		if not f.ends_with(".tres"):
			continue
		var anim := ResourceLoader.load(ANIM_DIR + f) as Animation
		if anim == null:
			continue
		for i in anim.get_track_count():
			track_map["%s/%s" % [f.get_basename(), String(anim.track_get_path(i))]] = [anim, i]
	for key in SPOT_EXPECT:
		if not track_map.has(key):
			_runner.assert_true(false, "spot 轨道缺失: %s" % key)
			continue
		var anim: Animation = track_map[key][0]
		var idx: int = track_map[key][1]
		for t in SPOT_EXPECT[key]:
			var want_rad: float = deg_to_rad(float(SPOT_EXPECT[key][t]))
			var got: float = anim.bezier_track_interpolate(idx, float(t))
			var err: float = absf(got - want_rad)
			# 阈值对齐方案 §5.3 角度 ≤0.5°；实测应达浮点噪声级（~1e-7 rad）
			if err > 0.0087:
				_runner.assert_true(false, "%s t=%.2f: godot=%.6f want=%.6f err=%.10f rad" % [key, t, got, want_rad, err])
	_runner.assert_true(_runner.all_passed(), "bezier 采样与 Spine 语义求值一致（≤0.5°）")


func _test_skeleton_data() -> void:
	var bones: Dictionary = SpineSkeletonData.BONES
	_runner.assert_equal(bones.size(), 56, "骨架表应 56 骨全量")
	_runner.assert_true(bones.has("minertorso1"), "脊柱链骨 minertorso1 应在表")
	var torso: Dictionary = bones.get("minertorso1", {})
	_runner.assert_equal(float(torso.get("rot", 0.0)), 90.0, "minertorso1 setup 旋转应为 90°（沿轴语义）")
	_runner.assert_equal(float(bones.get("minerleg2", {}).get("len", 0.0)), 79.52, "minerleg2 骨长应保留 79.52")
