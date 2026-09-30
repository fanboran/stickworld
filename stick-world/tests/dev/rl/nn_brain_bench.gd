extends Node
## NN 选手 Benchmark 对打器 —— nn_brain.gd 的验收配套 runner（训练设施 v1）。
##
## 为什么不直接用 diag_arena_benchmark_driver：训练/对打要与标准 driver 解耦——
## 本 runner 按同一协议（观察面 ctx 注入 + 0.5s 决策节拍 + 换边轮换）自带对打
## 循环，额外具备：battle.duration_limit 硬超时注入（大场纯歼灭打不完时按剩余
## 战力收束）、墙钟超时（headless 帧率不可靠）、常驻 driver（场景切换 free 不掉
## 协程）、周期状态行。战力口径 = 活着未离场（溃逃布尔态已退役：未死即算）。
## nn_brain 实现 bench_brain_base 协议，跑标准 driver 亦可无缝换回。
##
## 用法（headless）：
##   godot --headless --path stick-world res://tests/dev/rl/nn_brain_bench.tscn
## 可选用户参数：--n=2（场数，换边轮换） --brain-b=<路径>（对手选手，空=内嵌规划器）
## 结果：stdout 报分 + JSON 落 user://rl/nn_bench_last.json

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const NN_BRAIN_PATH := "res://tests/dev/benchmark_brains/nn_brain.gd"
## 决策节拍（帧数，与标准 driver 的 TICK_EVERY 同口径 ~0.5s）
const TICK_EVERY: int = 30
## 单场墙钟超时（ms）：headless 帧率不可靠（受同机负载/渲染管线影响），
## 超时判定一律按墙钟，不按帧数
const BATTLE_WALL_TIMEOUT_MS: int = 210_000
## 开机等待上限（帧）：battle_arena 的 boot 序列实测可到 ~30s
const BOOT_FRAMES: int = 3600
## 战斗硬超时（游戏秒）：注入 battle.duration_limit，48v48 大场纯歼灭打不完时
## 由 battle 自行按剩余战力收束（口径同训练侧）

var _n_battles: int = 2
var _brain_b_path: String = ""
## 报分板（nn/foe/draw）
var _score: Dictionary = {"nn": 0, "foe": 0, "draw": 0}


func _ready() -> void:
	# 直启时本节点就是 current_scene，_one_battle 的 change_scene_to_file 会把它
	# free（协程随之死亡，进程挂在 arena 场景永不退出）——复制一份挂到 root 做
	# 常驻 driver（diag_arena_benchmark_shots 启动器同款手法），本节点等死
	if get_tree().current_scene == self:
		var driver := Node.new()
		driver.set_script(get_script())
		get_tree().root.add_child.call_deferred(driver)
		return
	for a in OS.get_cmdline_user_args():
		var kv := String(a).trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		if kv[0] == "n":
			_n_battles = maxi(int(kv[1]), 1)
		elif kv[0] == "brain-b":
			_brain_b_path = kv[1]
	_run()


func _run() -> void:
	print("[NNBench] === NN 选手对打：%d 场换边轮换 | 对手 = %s ===" % [
		_n_battles, _brain_b_path.get_file() if not _brain_b_path.is_empty() else "内嵌军师规划器"])
	var results: Array = []
	for i in _n_battles:
		var a_side := i % 2   # 0 = NN 在攻方（左），1 = NN 在守方（右）
		var r: Dictionary = await _one_battle(a_side)
		results.append(r)
		print("[NNBench] 第%d场 NN在%s：%s 胜（时长 %.0fs，终局战力 攻%d : 守%d）" % [
			i + 1, "攻方" if a_side == 0 else "守方", r["winner"],
			r["duration_s"], r["str_a"], r["str_b"]])
	# 报分
	for r_v in results:
		var r: Dictionary = r_v
		match r["winner"]:
			"NN": _score["nn"] += 1
			"FOE": _score["foe"] += 1
			_: _score["draw"] += 1
	print("[NNBench] === 总分：NN %d 胜 / 对手 %d 胜 / 平 %d（共 %d 场）===" % [
		_score["nn"], _score["foe"], _score["draw"], results.size()])
	_save_json(results)
	get_tree().quit(0)


func _one_battle(nn_side: int) -> Dictionary:
	get_tree().change_scene_to_file(ARENA_SCENE)
	# 等战场开机 + 战斗实例出现（boot 异步，死等帧数会撞在装配前）
	var battle: Node = null
	for i in BOOT_FRAMES:
		await get_tree().process_frame
		battle = _find_battle_instance()
		if battle != null and battle.is_active():
			break
		if i % 600 == 599:
			print("[NNBench] boot 等待中：frame=%d battle=%s active=%s" % [i + 1,
				"有" if battle != null else "无",
				str(battle.is_active()) if battle != null else "-"])
	if battle == null:
		push_error("[NNBench] 战场未启动（boot 超时）")
		return {"winner": "error", "duration_s": 0.0, "str_a": 0, "str_b": 0}
	# 大场纯歼灭打不完：注入硬超时，battle 到点自行按剩余战力收束
	battle.set("duration_limit", 125.0)
	var fac_nn := nn_side            # bench 协议阵营 0/1（0=攻）
	var fac_foe := 1 - nn_side
	var brain_nn: RefCounted = _make_brain(NN_BRAIN_PATH, fac_nn)
	var brain_foe: RefCounted = _make_brain(_brain_b_path, fac_foe)
	var frames := 0
	var t0_ms: int = Time.get_ticks_msec()
	var last_report_ms: int = t0_ms
	# 战力逐拍缓存：战斗收束瞬间实例即 free，赛后清点只能拿到 0:0（误判平局）
	var last_sa := 0
	var last_sb := 0
	while Time.get_ticks_msec() - t0_ms < BATTLE_WALL_TIMEOUT_MS:
		await get_tree().process_frame
		frames += 1
		if frames % TICK_EVERY == 0:
			var dt := TICK_EVERY / 60.0
			if brain_nn != null:
				brain_nn.tick(dt)
			if brain_foe != null:
				brain_foe.tick(dt)
			if is_instance_valid(battle):
				last_sa = _strength_of(battle, 0)
				last_sb = _strength_of(battle, 1)
			# 战斗收敛即止（实例结束会 queue_free）
			if not is_instance_valid(battle) or not battle.is_active():
				break
		# 周期状态（诊断：battle 游戏时/物理是否在走、帧率、双方战力）
		var now_ms: int = Time.get_ticks_msec()
		if now_ms - last_report_ms >= 30_000:
			last_report_ms = now_ms
			var state_label: String = "freed" if not is_instance_valid(battle) \
					else ("active dur=%.0f 攻%d 守%d" % [battle.get_duration(),
						_strength_of(battle, 0), _strength_of(battle, 1)])
			print("[NNBench] …%ds elapsed frames=%d battle=%s" % [
				(now_ms - t0_ms) / 1000, frames, state_label])
	var sa := last_sa
	var sb := last_sb
	var winner: String = "draw"
	if sa == 0 and sb == 0:
		winner = "draw"
	elif sb == 0:
		winner = "NN" if fac_nn == 0 else "FOE"
	elif sa == 0:
		winner = "NN" if fac_nn == 1 else "FOE"
	else:
		winner = "draw" if absf(sa - sb) <= 0.1 * maxf(sa, sb) else ("NN" if _side_won(sa, sb, fac_nn) else "FOE")
	return {"winner": winner, "duration_s": frames / 60.0, "str_a": sa, "str_b": sb}


func _side_won(sa: int, sb: int, fac_nn: int) -> bool:
	var a_wins: bool = sa > sb
	return a_wins if fac_nn == 0 else not a_wins


func _make_brain(path: String, faction: int) -> RefCounted:
	if path.is_empty():
		return null
	var script: GDScript = load(path)
	var brain: RefCounted = script.new()
	brain.ctx = {"battle": _find_battle_instance(), "arena": get_tree().current_scene, "faction": faction}
	brain.setup()
	print("[NNBench] 选手上场：%s（阵营 %s）" % [brain.brain_name(), "攻" if faction == 0 else "守"])
	return brain


## 崩溃安全战力：活着且未离场（溃逃布尔态已退役：未死即算，避战者算存活）
## battle 传场内引用（结束即 free，不能再按查找——会误判 0:0 平局）
func _strength_of(battle_v: Variant, faction: int) -> int:
	# battle 在收束瞬间会被 free（这正是循环退出的原因），Variant 接防类型化参数拒收
	if battle_v == null or not is_instance_valid(battle_v):
		return 0
	var battle: Node = battle_v
	var arr: Array = battle.get("_units_attacker" if faction == 0 else "_units_defender")
	if arr == null:
		return 0
	var n := 0
	for u in arr:
		if not is_instance_valid(u):
			continue
		var hp_v: Variant = u.get_health() if u.has_method("get_health") else null
		if hp_v != null and is_instance_valid(hp_v) and hp_v.is_dead():
			continue
		if bool(u.get("departed")):
			continue
		n += 1
	return n


func _save_json(results: Array) -> void:
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("rl"):
		dir.make_dir("rl")
	var f := FileAccess.open("user://rl/nn_bench_last.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"results": results, "score": _score}))
		f.close()


## battle_instance 挂在地图装配深处（口径同 diag_arena_metrics_driver）
func _find_battle_instance() -> Node:
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == null:
			continue
		if n.get_script() != null \
				and String(n.get_script().resource_path).ends_with("battle_instance.gd"):
			return n
		stack.append_array(n.get_children())
	return null
