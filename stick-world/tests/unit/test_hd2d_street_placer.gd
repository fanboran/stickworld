extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：HD-2D 摆街域组件（hd2d_street_placer）纯计算段。
##
## 摆街的"什么卡摆在哪"求解逻辑是纯函数，宿主门面 w 用 duck 替身注入即可驱动
## （不入树、不装配 3D 世界、零渲染——投影/关节图集/小地图已有套件，不重复）：
##   1. _gaps 占用区间补集（排序归并 + 0.5 格以下碎缝过滤）
##   2. _median 层基线采样（空表/奇数/偶数上中位）
##   3. _resolve_front_row 整格吸附 + 画面宽推挤（重叠不可能发生不变量）
##   4. 卡元数据缺失兜底（画面宽 <1 → 8.0）
##   5. _pick_card 顺位旋转取第一张放得下的卡（全放不下返回空串）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const StreetPlacer := preload("res://modules/hd2d/scripts/placer/hd2d_street_placer.gd")

var _runner: TestRunner


## 卡画面宽表替身：键→格宽；查不到的卡返回 0.0（驱动 placer 缺失兜底分支）
class FakeCards:
	var widths := {}
	func _cw(card: String) -> float:
		return float(widths.get(card, 0.0))


## 宿主门面替身（placer.w 声明为 Node3D，替身必须同基类）
class FakeWorld extends Node3D:
	var cards := FakeCards.new()


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("摆街: _gaps 占用区间补集", _test_gaps)
	_runner.add_test("摆街: _median 层基线采样", _test_median)
	_runner.add_test("摆街: _resolve_front_row 整格吸附与推挤不变量", _test_resolve_front_row)
	_runner.add_test("摆街: 卡宽缺失兜底 8.0", _test_missing_card_fallback)
	_runner.add_test("摆街: _pick_card 顺位取卡与放不下回退", _test_pick_card)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 建一个挂好替身门面的 placer（FakeWorld 登记 fixture，用例结束自动释放）
func _make_placer(widths: Dictionary) -> StreetPlacer:
	var p: StreetPlacer = StreetPlacer.new()
	var fw := FakeWorld.new()
	fw.cards.widths = widths
	p.w = _runner.track_node(fw)
	return p


# ── 用例 ────────────────────────────────────────────────────

## 用例 1：[x0,x1] 占用的补集 = 背景「缝」账本（bg2/bg3 吸缝插楼的数据源）
func _test_gaps() -> void:
	var p := _make_placer({})
	# 空占用 → 整段都是缝
	_runner.assert_equal(p._gaps([], -10.0, 10.0), [[-10.0, 10.0]], "无占用 → 整段为缝")
	# 中段占用 → 左右两缝
	_runner.assert_equal(p._gaps([[-2.0, 2.0]], -10.0, 10.0),
			[[-10.0, -2.0], [2.0, 10.0]], "中段占用 → 左右两缝")
	# 乱序 + 重叠占用先归并再取补（不产生碎缝）
	_runner.assert_equal(p._gaps([[5.0, 8.0], [0.0, 6.0]], -10.0, 10.0),
			[[-10.0, 0.0], [8.0, 10.0]], "乱序重叠占用应归并")
	# < 0.5 格的碎缝不算缝（过滤阈值）
	_runner.assert_equal(p._gaps([[0.0, 10.0], [10.2, 20.0]], 0.0, 20.0),
			[], "0.2 格碎缝应被过滤")
	# 占用贴左缘：不留 0 宽假缝
	_runner.assert_equal(p._gaps([[0.0, 5.0]], 0.0, 10.0),
			[[5.0, 10.0]], "贴缘占用不留 0 宽缝")


## 用例 2：层基线取中位数（bg 层结束写 w._bg_base_z 的采样口径）
func _test_median() -> void:
	var p := _make_placer({})
	_runner.assert_approx(p._median([]), 0.0, 0.0001, "空表应返回 0")
	_runner.assert_approx(p._median([3.0, 1.0, 2.0]), 2.0, 0.0001, "奇数个应取排序中位")
	_runner.assert_approx(p._median([1.0, 2.0, 3.0, 4.0]), 3.0, 0.0001, "偶数个应取上中位（size/2）")


## 用例 3：摆位求解器不变量——意图锚点只是「想要的位置」：
##   输出 x 一律整格（中心吸附 + 左→右整格步进），相邻卡画面区间不重叠
##   且保底间隙 ≥ 0.6 格（整格步进兑现为 ≥1）。
func _test_resolve_front_row() -> void:
	var p := _make_placer({"house_w8": 9.0, "cottage_w6": 9.1})
	var out: Array = p._resolve_front_row([
		{"card": "house_w8", "x": 10.4, "z": 0.7, "door": true},
		{"card": "cottage_w6", "x": 11.0, "z": 2.4},
	])
	_runner.assert_equal(out.size(), 2, "输出应与意图一一对应")
	var x0: float = float(out[0]["x"])
	var x1: float = float(out[1]["x"])
	# 第一栋：10.4 吸附整格 → 10.0（首位不受推挤）
	_runner.assert_equal(x0, 10.0, "首位应中心吸附整格")
	# 第二栋：意图 11 距前栋右缘(14.5)过近，推挤到「右缘 + 0.6 缝 + 半宽 4.55」
	# = 19.65 的上整格 → 20.0
	_runner.assert_equal(x1, 20.0, "重叠意图应推挤到不重叠的整格")
	# 不变量：画面区间不重叠 + 间隙 ≥ 0.6
	var gap: float = (x1 - 9.1 * 0.5) - (x0 + 9.0 * 0.5)
	_runner.assert_true(gap >= 0.6, "推挤后保底间隙应 ≥ 0.6（实测 %s）" % gap)
	# z / door 契约透传（缺省 door=false、z=0.6）
	_runner.assert_equal(bool(out[0]["door"]), true, "door 应透传")
	_runner.assert_approx(float(out[0]["z"]), 0.7, 0.0001, "z 应透传")
	_runner.assert_equal(bool(out[1]["door"]), false, "缺省 door 应为 false")
	_runner.assert_approx(float(out[1]["z"]), 2.4, 0.0001, "z 应透传")


## 用例 4：卡元数据缺失（画面宽 <1）兜底 8.0——摆位求解不因缺卡数据而崩/漂
func _test_missing_card_fallback() -> void:
	# ghost 不在卡宽表 → cw 取兜底 8.0（半宽 4）：第二栋推挤落点 9+0.6+4=13.6 → 14
	var p := _make_placer({})
	var out: Array = p._resolve_front_row([
		{"card": "ghost_a", "x": 5.0},
		{"card": "ghost_b", "x": 6.0},
	])
	_runner.assert_equal(float(out[0]["x"]), 5.0, "首位缺失兜底应照常整格吸附")
	_runner.assert_equal(float(out[1]["x"]), 14.0, "缺失卡宽应按兜底 8.0 推挤（13.6 上整格）")


## 用例 5：背景取卡——从 ci 起顺位找第一张画面宽 ≤ room 的卡；
## 全放不下返回空串（调用方补洞兜底）；元数据缺失的卡直接可用
func _test_pick_card() -> void:
	var p := _make_placer({"a": 5.0, "b": 12.0, "c": 7.0})
	_runner.assert_equal(p._pick_card(["a", "b", "c"], 0, 6.0), "a", "首张放得下即取")
	_runner.assert_equal(p._pick_card(["b", "a"], 0, 6.0), "a", "过宽卡应跳过取下一张")
	_runner.assert_equal(p._pick_card(["b"], 0, 6.0), "", "全放不下应返回空串")
	_runner.assert_equal(p._pick_card(["a", "b", "c"], 1, 20.0), "b", "ci 应顺位旋转起点")
	_runner.assert_equal(p._pick_card(["zz"], 0, 20.0), "zz", "元数据缺失的卡应直接可用")
