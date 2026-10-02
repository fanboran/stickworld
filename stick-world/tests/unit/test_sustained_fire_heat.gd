extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：连射散布热度在真实射速下不钉顶（诊断 §1.4 根因三的回归门）。
##
## 背景：热度机制语义是"连射变散、停火收敛"（RWR sustained_fire），但弓手实战
## 射速 ~0.26 发/s（冷却 2.0s + 持瞄窗），旧参数（增长 0.40/发、恢复 0.10/s 且
## sim 模式恢复链不跑）使热度数学必然顶格 1.2 → 散布 σ 常驻 ×2.2，命中率对半砍。
## 本测试以真实节奏步进 add_sustained_fire_heat / _recover_sustained_fire 一对
## 时间常数，断言：①实战射速 30s 热度均值 < 0.6×上限；②满热度一个射击间隔内
## 可观恢复；③极限射速（冷却 2.0s = 0.5 发/s）持续 30s 仍不钉顶。
##
## 纯逻辑（batch 准入）：不进场景树、不碰 autoload、时间由测试完全控制。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
## 显式 preload：headless 批量模式下 weapon_mount.gd 引用的全局类名须已注册
const WeaponMountScript := preload("res://modules/units/scripts/entity/weapon_mount.gd")

const W_BOW := 2  # WeaponMount.WeaponType.BOW（整数键，避开 class_name 依赖）
const DT := 1.0 / 60.0
## 弓手实战射速（诊断实测 0.26~0.30 发/s；取保守慢速 = 最容易堆积的节奏之一下限）
const REAL_FIRE_RATE := 0.26
## 冷却 2.0s 给出的极限射速（持瞄窗只会更慢）
const MAX_FIRE_RATE := 0.5
const SIM_SEC := 30.0

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("连射热度: 实战 0.26发/s×30s 均值<0.6×上限且不钉顶", _test_real_rate_not_pinned)
	_runner.add_test("连射热度: 满热度一个射击间隔内可观恢复", _test_recover_within_interval)
	_runner.add_test("连射热度: 极限 0.5发/s×30s 仍不钉顶", _test_max_rate_not_pinned)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


## 组装离树 WeaponMount（不进树：无 deferred 重挂，时间全由测试步进）
func _make_bow_mount() -> Node:
	var mount: Node = WeaponMountScript.new()
	mount.weapon_type = W_BOW
	return mount


## 按射速模拟持续射击：返回 {"mean": 全程热度均值, "fire_mean": 出手时（增长前）
## 热度均值, "peak": 峰值, "pinned_sec": 热度≥上限的时长}
func _simulate(fire_rate: float) -> Dictionary:
	var mount: Node = _make_bow_mount()
	var interval: float = 1.0 / fire_rate
	var t := 0.0
	var next_fire := 0.0
	var sum := 0.0
	var fire_sum := 0.0
	var fire_n := 0
	var peak := 0.0
	var pinned := 0.0
	var ticks := 0
	while t < SIM_SEC:
		if t >= next_fire:
			fire_sum += float(mount._sustained_fire_heat)
			fire_n += 1
			mount.add_sustained_fire_heat()
			next_fire += interval
		mount._recover_sustained_fire(DT)
		var h: float = float(mount._sustained_fire_heat)
		sum += h
		ticks += 1
		peak = maxf(peak, h)
		if h >= float(mount.SUSTAINED_FIRE_HEAT_MAX) - 0.001:
			pinned += DT
		t += DT
	mount.free()
	return {
		"mean": sum / float(ticks),
		"fire_mean": fire_sum / float(fire_n),
		"peak": peak,
		"pinned_sec": pinned,
	}


func _test_real_rate_not_pinned() -> void:
	var mount: Node = _make_bow_mount()
	var cap: float = float(mount.SUSTAINED_FIRE_HEAT_MAX)
	mount.free()
	var r := _simulate(REAL_FIRE_RATE)
	_runner.assert_true(r["mean"] < 0.6 * cap,
			"热度均值 %.3f 应 < 0.6×上限 %.3f" % [r["mean"], 0.6 * cap])
	_runner.assert_true(r["fire_mean"] < 0.6 * cap,
			"出手时热度均值 %.3f 应 < 0.6×上限 %.3f（散布 σ 乘数回到 ~1.x）" % [r["fire_mean"], 0.6 * cap])
	_runner.assert_true(r["peak"] <= cap + 0.001, "峰值 %.3f 不超上限 %.3f" % [r["peak"], cap])
	_runner.assert_true(r["pinned_sec"] < 0.5, "钉顶时长 %.2fs 应≈0（不数学必然顶格）" % r["pinned_sec"])


func _test_recover_within_interval() -> void:
	var mount: Node = _make_bow_mount()
	var cap: float = float(mount.SUSTAINED_FIRE_HEAT_MAX)
	# 满热度起步，步进一个射击间隔（0.26 发/s → 3.85s），断言可观恢复（<10% 上限）
	mount._sustained_fire_heat = cap
	var interval: float = 1.0 / REAL_FIRE_RATE
	var t := 0.0
	while t < interval:
		mount._recover_sustained_fire(DT)
		t += DT
	var h: float = float(mount._sustained_fire_heat)
	_runner.assert_true(h < 0.1 * cap,
			"满热度 %.1f 经一个间隔（%.2fs）应回落到 <0.1×上限，实测 %.3f" % [cap, interval, h])
	mount.free()


func _test_max_rate_not_pinned() -> void:
	var mount: Node = _make_bow_mount()
	var cap: float = float(mount.SUSTAINED_FIRE_HEAT_MAX)
	mount.free()
	# 冷却 bound 的极限射速下也不钉顶——热度机制在任何可达节奏都不再数学必然顶格
	var r := _simulate(MAX_FIRE_RATE)
	_runner.assert_true(r["mean"] < 0.6 * cap,
			"极限射速热度均值 %.3f 应 < 0.6×上限 %.3f" % [r["mean"], 0.6 * cap])
	_runner.assert_true(r["pinned_sec"] < 0.5, "极限射速钉顶时长 %.2fs 应≈0" % r["pinned_sec"])
