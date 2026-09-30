extends Node
## 自对弈 Benchmark driver —— 「下一版算法必须稳定战胜上一版」的迭代闭环设施。
## 规则（创始人 2026-09-30 定）：
##   1. 选手 = benchmark_brains/ 下实现 bench_brain_base 协议的脚本（输入战场观察，
##      输出个人级/编制级决策）；空路径 = 内嵌默认 AI（现状系统）下场当卫冕者。
##   2. 换边轮换：一半场次挑战者在攻方（左），一半在守方（右），消除左右占位对胜率的影响。
##   3. 胜负 = 有效战力（未死未溃）先归零方负；超时按剩余战力判，持平算平。
##   4. 「稳定战胜」= 挑战者胜率 ≥ WIN_RATE_LINE（两边合计），否则迭代不通过。
## 用法：godot --headless --path stick-world res://tests/dev/diag_arena_benchmark_shots.tscn
## 改挑战者：把下面 BRAIN_A 换成 res://tests/dev/benchmark_brains/<你的选手>.gd

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const BRAIN_A := ""    # 挑战者脚本路径；空 = 内嵌默认 AI（基线自检模式）
const BRAIN_B := ""    # 卫冕者脚本路径；空 = 内嵌默认 AI
const N_BATTLES := 6   # 6 场 = 3 换边对（奇数场次报分时注明换边对称）
const SETTLE_FRAMES := 90
const TICK_EVERY := 30          # 选手决策节拍 ~0.5s
const TIMEOUT_FRAMES := 60 * 150
const WIN_RATE_LINE := 0.65     # 稳定战胜线


func run() -> void:
	print("[Bench] === 自对弈 Benchmark：A=%s vs B=%s，%d 场换边轮换 ===" % [
		_brain_label(BRAIN_A), _brain_label(BRAIN_B), N_BATTLES])
	var results: Array = []
	for i in N_BATTLES:
		var a_side := i % 2     # 0 = A 在攻方（左），1 = A 在守方（右）
		var r := await _one_battle(a_side)
		results.append(r)
		print("[Bench] 第%d场 A在%s：%s 胜（时长 %.0fs，终局战力 攻%d : 守%d）" % [
			i + 1, "攻方" if a_side == 0 else "守方", r["winner"], r["duration_s"],
			r["str_a"], r["str_b"]])
	_report(results)
	get_tree().quit(0)


func _one_battle(a_side: int) -> Dictionary:
	get_tree().change_scene_to_file(ARENA_SCENE)
	await _frames(SETTLE_FRAMES)
	var battle := _find_battle_instance()
	if battle == null:
		return {"winner": "error", "duration_s": 0.0, "str_a": 0, "str_b": 0}
	var fac_a := 0 if a_side == 0 else 1
	var fac_b := 1 - fac_a
	var brain_a: RefCounted = _make_brain(BRAIN_A, fac_a)
	var brain_b: RefCounted = _make_brain(BRAIN_B, fac_b)
	var frames := 0
	while frames < TIMEOUT_FRAMES:
		await _frames(TICK_EVERY)
		frames += TICK_EVERY
		var dt := TICK_EVERY / 60.0
		if brain_a != null:
			brain_a.tick(dt)
		if brain_b != null:
			brain_b.tick(dt)
		var sa := _strength(battle, fac_a)
		var sb := _strength(battle, fac_b)
		if sa == 0 or sb == 0:
			return {"winner": _judge(sa, sb, frames), "duration_s": frames / 60.0,
				"str_a": sa, "str_b": sb}
	return {"winner": _judge(_strength(battle, fac_a), _strength(battle, fac_b), frames),
		"duration_s": frames / 60.0,
		"str_a": _strength(battle, fac_a), "str_b": _strength(battle, fac_b)}


## 胜负：有效战力先归零方负；超时按剩余战力，差 ≤10% 算平（防擦边判胜）
func _judge(sa: int, sb: int, frames: int) -> String:
	if sa == 0 and sb == 0:
		return "draw"
	if sa == 0:
		return "B"
	if sb == 0:
		return "A"
	if frames >= TIMEOUT_FRAMES:
		if absf(sa - sb) <= 0.1 * maxf(sa, sb):
			return "draw"
		return "A" if sa > sb else "B"
	return "A" if sa > sb else "B"


func _make_brain(path: String, faction: int) -> RefCounted:
	if path.is_empty():
		return null
	var script: GDScript = load(path)
	var brain: RefCounted = script.new()
	brain.ctx = {"battle": _find_battle_instance(), "arena": get_tree().current_scene, "faction": faction}
	if brain.ctx.battle == null:
		push_error("[Bench] 战场未找到，选手 %s 无观察源" % path)
	brain.setup()
	return brain


func _strength(battle: Node, faction: int) -> int:
	var arr: Array = battle.get("_units_attacker" if faction == 0 else "_units_defender")
	if arr == null:
		return 0
	var n := 0
	for u in arr:
		if is_instance_valid(u):
			var hp: Node = u.get_health() if u.has_method("get_health") else null
			if hp != null and not hp.is_dead() and not hp.is_routed():
				n += 1
	return n


func _report(results: Array) -> void:
	var a := 0
	var b := 0
	var d := 0
	for r in results:
		match r["winner"]:
			"A": a += 1
			"B": b += 1
			"draw": d += 1
			_: print("[Bench] 有场次报错，结果不可信")
	var total := a + b + d
	print("[Bench] === 总分：挑战者A %d 胜 / 卫冕者B %d 胜 / 平 %d（共 %d 场）===" % [a, b, d, total])
	if BRAIN_A.is_empty():
		print("[Bench] 基线自检模式（默认 AI 对默认 AI）：胜差应接近各半，偏离大 = 左右占位或先手不平衡")
	else:
		var rate := float(a) / maxf(total, 1)
		print("[Bench] 挑战者胜率 %.0f%%，稳定战胜线 %d%% → %s" % [
			rate * 100.0, int(WIN_RATE_LINE * 100.0),
			"✅ 迭代通过，可接替卫冕者" if rate >= WIN_RATE_LINE else "❌ 迭代不通过，继续调"])


func _brain_label(path: String) -> String:
	return path.get_file() if not path.is_empty() else "内嵌默认AI"


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _find_battle_instance() -> Node:
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_script() != null \
				and String(n.get_script().resource_path).ends_with("battle_instance.gd"):
			return n
		stack.append_array(n.get_children())
	return null
