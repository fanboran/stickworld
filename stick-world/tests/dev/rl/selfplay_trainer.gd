extends Node
## 自博弈训练器 —— AlphaGo 式无限循环 RL 训练（观察场 AI 训练设施 v1 主控）。
##
## 运行（无头）：
##   godot --headless --path stick-world res://tests/dev/rl/selfplay_trainer.tscn
## 协议（创始人 2026-09-30 修正版，详见 rl/README.md）：
##   - 一个网络执掌双方全部指挥决策（自博弈：同一网络同时当攻守两方指挥官）；
##   - 每轮迭代随机抽一个对阵（双方兵种比例与占位独立随机、可不对称），打正反两局
##     （第二局交换双方编制与点位），四份指挥视角一起进同一个梯度批；
##   - 奖励 = 终局 ±1 + 0.5×(己存活比−敌存活比) + 0.5×(己夺点−敌夺点)/旗数；
##   - REINFORCE（baseline=滚动均值）+ softmax 温度采样（温度衰减、保熵下限）；
##   - 每 50 轮评估：当前网络（greedy）vs 军师手调意图规划器（SquadIntentPlanner），
##     正反两局为一组打 3 组——评估胜率是"有没有真的变强"的唯一硬指标；
##   - checkpoint 每 10 轮落 user://rl/checkpoint.json（权重+baseline+迭代数+种子），
##     启动时存在即续训（无限循环可断可续）。
##
## 日志：每轮一行 stdout + user://rl/train_log.csv 全量；评估追加 user://rl/eval_log.csv。

const PolicyNetScript: GDScript = preload("res://tests/dev/rl/policy_net.gd")
const BattleEnvScript: GDScript = preload("res://tests/dev/rl/battle_env.gd")

# ─────────────────────────────── 超参数 ────────────────────────────────
## 全局随机种子（可复现；checkpoint 随存）
const GLOBAL_SEED: int = 20260930
## 学习率（SGD；随迭代衰减，保底防死）
const LR_START: float = 0.02
const LR_DECAY: float = 0.995
const LR_FLOOR: float = 0.002
## 梯度全局范数裁剪
const GRAD_CLIP: float = 5.0
## 熵奖励系数（保探索；配合温度下限双保险防塌缩成确定性）
const ENTROPY_BETA: float = 0.02
## 采样温度：T = max(TEMP_MIN, TEMP_START × TEMP_DECAY^iter)（保熵下限）
const TEMP_START: float = 1.1
const TEMP_DECAY: float = 0.995
const TEMP_MIN: float = 0.7
## baseline 滚动均值系数
const BASELINE_EMA: float = 0.05
## checkpoint / 评估周期（迭代轮数）
const CHECKPOINT_EVERY: int = 10
const EVAL_EVERY: int = 50
## 评估规模：3 组 ×（正局+反局）
const EVAL_GROUPS: int = 3

# ─────────────────────────────── 路径 ────────────────────────────────
const CHECKPOINT_PATH: String = "user://rl/checkpoint.json"
const TRAIN_CSV: String = "user://rl/train_log.csv"
const EVAL_CSV: String = "user://rl/eval_log.csv"

# ─────────────────────────────── 运行时 ────────────────────────────────
var _net: RefCounted = null
var _env: Node = null
var _iteration: int = 0
var _baseline: float = 0.0
var _resumed: bool = false


func _ready() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("rl"):
		dir.make_dir("rl")
	# 加速档：headless 下 time_scale 5.0（60s 战斗压到 12s 墙钟；物理步/帧上限 8 兜得住）
	Engine.time_scale = 5.0
	_net = PolicyNetScript.new()
	_load_checkpoint()
	_run_loop()


## 主循环（无限迭代；外部杀进程即断点，重启续训）
func _run_loop() -> void:
	if not await _setup_env():
		get_tree().quit(1)
		return
	var mode_label: String = "续训（从第 %d 轮起）" % _iteration if _resumed else "新训练（种子 %d）" % GLOBAL_SEED
	print("[RL] ===== 自博弈训练启动：%s | time_scale=%.1f =====" % [mode_label, Engine.time_scale])
	print("[RL] 超参：lr=%.3f→%.3f temp=%.2f→%.2f beta=%.3f clip=%.1f batch=4局/轮" % [
		LR_START, LR_FLOOR, TEMP_START, TEMP_MIN, ENTROPY_BETA, GRAD_CLIP])
	while true:
		var t0: int = Time.get_ticks_msec()
		var iter_record := await _run_iteration(_iteration)
		var wall: float = float(Time.get_ticks_msec() - t0) / 1000.0
		_log_iteration(iter_record, wall)
		_iteration += 1
		if _iteration % CHECKPOINT_EVERY == 0:
			_save_checkpoint()
		if _iteration % EVAL_EVERY == 0:
			await _run_evaluation()


## 环境装配（一次）：boot 战场图（HD-2D 异步开机，等待上限 ~60s）
func _setup_env() -> bool:
	_env = BattleEnvScript.new()
	add_child(_env)
	var ok: bool = await _env.setup_async()
	if not ok:
		push_error("[RL] 战场环境装配失败，退出")
	return ok


## 一轮迭代：抽对阵 → 正反两局 → 4 份视角合批训练一步。返回日志记录。
func _run_iteration(iter: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|%d" % [GLOBAL_SEED, iter])
	var matchup: Dictionary = _env.gen_matchup(rng)
	var temp: float = maxf(TEMP_MIN, TEMP_START * pow(TEMP_DECAY, float(iter)))
	# 正局：a 攻西 / b 守东；反局：整体交换。faction→agent 各局独立建（每局一份轨迹）
	var ep_a1 := TrainAgent.new()
	var ep_a2 := TrainAgent.new()
	ep_a1.init_agent(_net, temp, _child_rng(rng), false)
	ep_a2.init_agent(_net, temp, _child_rng(rng), false)
	var r1: Dictionary = await _env.play_battle(matchup, false, ep_a1, ep_a2)
	var ep_b1 := TrainAgent.new()
	var ep_b2 := TrainAgent.new()
	ep_b1.init_agent(_net, temp, _child_rng(rng), false)
	ep_b2.init_agent(_net, temp, _child_rng(rng), false)
	var r2: Dictionary = await _env.play_battle(matchup, true, ep_b1, ep_b2)
	# 四份视角的奖励（faction 1 视角 = 正局攻方 + 反局守方，以此类推）
	var episodes: Array = [
		{"agent": ep_a1, "r": _faction_reward(r1, 1)},
		{"agent": ep_a2, "r": _faction_reward(r1, 2)},
		{"agent": ep_b1, "r": _faction_reward(r2, 1)},
		{"agent": ep_b2, "r": _faction_reward(r2, 2)},
	]
	var grad_norm: float = _train_batch(episodes, temp)
	var mean_r: float = 0.0
	var entropy: float = 0.0
	var steps: int = 0
	for ep_v in episodes:
		var ep: Dictionary = ep_v
		mean_r += float(ep["r"])
		entropy += float(ep["agent"].entropy_sum)
		steps += int(ep["agent"].entropy_beats)
	mean_r /= float(episodes.size())
	entropy /= float(maxi(steps, 1))
	# baseline 滚动更新（四份视角均值）
	_baseline += BASELINE_EMA * (mean_r - _baseline)
	return {
		"iter": iter, "matchup": matchup, "temp": temp,
		"r1": r1, "r2": r2,
		"rewards": [episodes[0]["r"], episodes[1]["r"], episodes[2]["r"], episodes[3]["r"]],
		"mean_r": mean_r, "entropy": entropy, "grad_norm": grad_norm,
		"baseline": _baseline,
	}


## 单视角终局奖励（faction f 视角）：±1 + 0.5×存活差 + 0.5×夺点差/旗数
func _faction_reward(result: Dictionary, faction: int) -> float:
	var foe: int = 3 - faction
	var alive: Dictionary = result["alive"]
	var initial: Dictionary = result["initial"]
	var flags: Dictionary = result["flags_owned"]
	var r: float = 0.0
	var winner: int = int(result["winner"])
	if winner == faction:
		r += 1.0
	elif winner == foe:
		r -= 1.0
	r += 0.5 * (float(alive[faction]) / float(maxi(int(initial[faction]), 1))
		- float(alive[foe]) / float(maxi(int(initial[foe]), 1)))
	# env 恒布 3 面旗
	r += 0.5 * float(flags[faction] - flags[foe]) / 3.0
	return r


## REINFORCE 合批一步：优势 = R − baseline（跨批标准化），dlogits = −A(onehot−π)/T
## + β·π(H+logπ)/T（温度采样策略的 score function 带因子 1/T）。
func _train_batch(episodes: Array, temp: float) -> float:
	# 优势标准化（零均值单位方差；baseline 已扣均值，这里只稳尺度）
	var raw: Array = []
	for ep_v in episodes:
		raw.append(float(ep_v["r"]) - _baseline)
	var mean: float = 0.0
	for v in raw:
		mean += v
	mean /= float(raw.size())
	var var_sum: float = 0.0
	for v in raw:
		var_sum += (v - mean) * (v - mean)
	var std: float = sqrt(var_sum / float(raw.size()))
	var samples: Array = []
	for ei in episodes.size():
		var ep: Dictionary = episodes[ei]
		var adv: float = (raw[ei] - mean) / maxf(std, 1e-4)
		for step_v in ep["agent"].steps:
			var step: Dictionary = step_v
			var obs: PackedFloat32Array = step["obs"]
			var actions: PackedInt32Array = step["actions"]
			var mask: PackedInt32Array = step["mask"]
			var logits: PackedFloat32Array = _net.forward(obs)
			var dlogits := PackedFloat32Array()
			dlogits.resize(logits.size())
			for s in mask.size():
				if mask[s] == 0:
					continue
				var p: PackedFloat32Array = _net.softmax_slice(logits, s, temp)
				var h: float = 0.0
				for a in p.size():
					if p[a] > 1e-9:
						h -= p[a] * log(p[a])
				var base: int = s * _net.N_ACTIONS
				for a in p.size():
					# REINFORCE 主项 −A(onehot−π)/T + 熵奖励 β·π(H+logπ)/T
					var g: float = -adv * ((1.0 if a == actions[s] else 0.0) - p[a]) \
							+ ENTROPY_BETA * p[a] * (h + log(maxf(p[a], 1e-9)))
					dlogits[base + a] = g / temp
			samples.append({"obs": obs, "dlogits": dlogits})
	var lr: float = maxf(LR_FLOOR, LR_START * pow(LR_DECAY, float(_iteration)))
	return _net.train_step(samples, lr, GRAD_CLIP)


func _child_rng(parent: RandomNumberGenerator) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = parent.randi()
	return rng


# ─────────────────────────────── 评估协议 ────────────────────────────────

## 每 50 轮：当前网络（greedy）vs 军师手调意图规划器，3 组 ×（正局+反局）。
## 胜=1 平=0.5 负=0；胜率 = 6 场均值。组间换边（奇数组 NN 在攻，偶数组在守）。
func _run_evaluation() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d|eval|%d" % [GLOBAL_SEED, _iteration])
	var score: float = 0.0
	var games: int = 0
	var detail: Array = []
	print("[RL] ── 评估开始（iter=%d，NN greedy vs 军师规划器，%d 组×正反）──" % [_iteration, EVAL_GROUPS])
	for g in EVAL_GROUPS:
		var nn_faction: int = 1 if g % 2 == 0 else 2
		var matchup: Dictionary = _env.gen_matchup(rng)
		for swap in [false, true]:
			var nn_agent := TrainAgent.new()
			nn_agent.init_agent(_net, 1.0, _child_rng(rng), true)
			var pl_agent := PlannerAgent.new()
			var agents: Dictionary = {}
			agents[nn_faction] = nn_agent
			agents[3 - nn_faction] = pl_agent
			var result: Dictionary = await _env.play_battle(matchup, swap, agents[1], agents[2])
			var s: float = 0.5
			if int(result["winner"]) == nn_faction:
				s = 1.0
			elif int(result["winner"]) == 3 - nn_faction:
				s = 0.0
			score += s
			games += 1
			detail.append(s)
			print("[RL]   评估第%d组%s：NN(F%d) %s（战损 攻%d/%d 守%d/%d，旗 攻%d:守%d，%.0fs，%s）" % [
				g + 1, "正局" if not swap else "反局", nn_faction,
				"胜" if s == 1.0 else ("平" if s == 0.5 else "负"),
				result["alive"][1], result["initial"][1],
				result["alive"][2], result["initial"][2],
				result["flags_owned"][1], result["flags_owned"][2],
				result["duration"], result["reason"]])
	var win_rate: float = score / float(maxi(games, 1))
	print("[RL] ── 评估结果：iter=%d 胜率 %.1f%%（%d 场：%s）──" % [
		_iteration, win_rate * 100.0, games, str(detail)])
	_append_eval_csv(win_rate, detail)


# ─────────────────────────────── 日志与断点 ────────────────────────────────

## CSV 追加（读-改-写：Godot 的 WRITE_READ 打开即截断，直接 seek_end 追加
## 会吃掉历史行——曲线是长期资产，必须全量保）
func _append_csv_line(path: String, header: String, line: String) -> void:
	var body: String = ""
	if FileAccess.file_exists(path):
		var rf := FileAccess.open(path, FileAccess.READ)
		if rf != null:
			body = rf.get_as_text()
			rf.close()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[RL] CSV 打不开（写不进）：" + path)
		return
	if body.is_empty():
		f.store_string(header + "\n")
	f.store_string(line + "\n")
	f.close()


## 每轮一行日志（stdout）+ CSV 追加（曲线数据源）
func _log_iteration(rec: Dictionary, wall: float) -> void:
	var r1: Dictionary = rec["r1"]
	var r2: Dictionary = rec["r2"]
	var comp: Dictionary = rec["matchup"]
	var rewards: Array = rec["rewards"]
	print(("[RL] iter=%d 阵=%dv%d r=(%.2f|%.2f|%.2f|%.2f) mean=%.3f base=%.3f H=%.2f T=%.2f | "
		+ "局1 胜F%d %.0fs %s | 局2(换边) 胜F%d %.0fs %s | grad=%.2f %.1fs") % [
			rec["iter"], comp["side_a"]["n_total"], comp["side_b"]["n_total"],
			rewards[0], rewards[1], rewards[2], rewards[3],
			rec["mean_r"], rec["baseline"], rec["entropy"], rec["temp"],
			r1["winner"], r1["duration"], r1["reason"],
			r2["winner"], r2["duration"], r2["reason"],
			rec["grad_norm"], wall])
	_append_csv_line(TRAIN_CSV,
		"iter,r_f1_g1,r_f2_g1,r_f1_g2,r_f2_g2,mean_r,baseline,entropy,temp,"
		+ "winner_g1,winner_g2,dur_g1,dur_g2,grad_norm,wall_s",
		"%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%d,%d,%.1f,%.1f,%.4f,%.1f" % [
			rec["iter"], rewards[0], rewards[1], rewards[2], rewards[3],
			rec["mean_r"], rec["baseline"], rec["entropy"], rec["temp"],
			r1["winner"], r2["winner"], r1["duration"], r2["duration"],
			rec["grad_norm"], wall])


func _append_eval_csv(win_rate: float, detail: Array) -> void:
	var score: float = 0.0
	for s_v in detail:
		score += float(s_v)
	_append_csv_line(EVAL_CSV, "iter,games,score,win_rate,detail",
		"%d,%d,%.1f,%.4f,%s" % [_iteration, detail.size(), score, win_rate, str(detail)])


## 断点续训：权重 + baseline + 迭代数 + 种子 + 超参指纹（防换参后错续）
func _save_checkpoint() -> void:
	var data: Dictionary = {
		"iteration": _iteration,
		"seed": GLOBAL_SEED,
		"baseline": _baseline,
		"hyper": {"lr_decay": LR_DECAY, "temp_decay": TEMP_DECAY, "beta": ENTROPY_BETA},
		"net": _net.to_dict(),
		"saved_at": Time.get_datetime_string_from_system(),
	}
	var f := FileAccess.open(CHECKPOINT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[RL] checkpoint 写入失败：" + CHECKPOINT_PATH)
		return
	f.store_string(JSON.stringify(data))
	f.close()
	print("[RL] checkpoint 已存（iter=%d → %s）" % [_iteration, CHECKPOINT_PATH])


func _load_checkpoint() -> void:
	if not FileAccess.file_exists(CHECKPOINT_PATH):
		print("[RL] 无 checkpoint，从头训练")
		return
	var f := FileAccess.open(CHECKPOINT_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_warning("[RL] checkpoint 损坏，从头训练")
		return
	var data: Dictionary = parsed
	if _net.from_dict(data.get("net", {})):
		_iteration = int(data.get("iteration", 0))
		_baseline = float(data.get("baseline", 0.0))
		_resumed = true
	else:
		push_warning("[RL] checkpoint 维度不符（网络改构），从头训练")


# ─────────────────────────────── Agent 内部类 ────────────────────────────────

## 训练/评估用 NN 指挥官：每拍前向 → 采样（或 greedy）→ 记录轨迹。
## 意图翻译成号令由 env 统一做（_apply_intents），本类只产意图。
class TrainAgent:
	extends RefCounted

	var net: RefCounted = null
	var temp: float = 1.0
	var rng: RandomNumberGenerator = null
	var greedy: bool = false
	var steps: Array = []
	var entropy_sum: float = 0.0
	var entropy_beats: int = 0

	func init_agent(p_net: RefCounted, p_temp: float, p_rng: RandomNumberGenerator, p_greedy: bool) -> void:
		net = p_net
		temp = p_temp
		rng = p_rng
		greedy = p_greedy
		steps = []
		entropy_sum = 0.0
		entropy_beats = 0

	func beat(_dt: float, view: Dictionary) -> PackedInt32Array:
		var logits: PackedFloat32Array = net.forward(view["obs"])
		var mask: PackedInt32Array = view["active_mask"]
		if greedy:
			return net.greedy_actions(logits, mask)
		var r: Dictionary = net.sample_actions(logits, temp, mask, rng)
		steps.append({"obs": view["obs"], "actions": r["actions"], "mask": mask,
			"logprob": r["logprob"]})
		entropy_sum += float(r["entropy"])
		entropy_beats += 1
		return r["actions"]


## 评估侧军师指挥官：包一台 SquadIntentPlanner（旗点/编班就绪后经 attach 装配），
## 号令由规划器自行经 TacticalOrders 下发（beat 返回空数组 = env 不做意图翻译）。
class PlannerAgent:
	extends RefCounted

	var planner: Object = null

	func attach(env: Node, faction: int) -> void:
		planner = env.make_intent_planner(faction, env.get_squad_ids(faction))

	func beat(dt: float, _view: Dictionary) -> PackedInt32Array:
		if planner != null:
			planner.tick(dt)
		return PackedInt32Array()
