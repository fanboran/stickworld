extends RefCounted
## RL 策略网络 —— 纯 GDScript 小 MLP，AlphaGo 式自博弈指挥官的大脑（训练设施 v1）。
##
## 结构：输入 51 维自视角观察 → 隐层 24 ReLU → 输出 15 logits（3 班 × 5 意图，
## 按班各做 5 类 softmax）。参数量 51×24+24+15×24+15 = 1599，GDScript 手写
## 前向/反向毫无压力，热路径全部 PackedFloat32Array、零 Dictionary/Array 分配。
##
## 训练算法（REINFORCE 策略梯度，带 baseline 均值）：
##   L = −Σ_t Σ_s logπ(a_t,s|s_t) × (R − baseline) − β × Σ_t Σ_s H(π_s)
##   梯度经 dlogits 反传：dlogπ/dz = onehot(a) − π；熵项 dH/dz = −π(H + logπ)。
##   本类只负责"给 dlogits 就能平均出梯度并走一步 SGD"，奖励→优势的换算在
##   selfplay_trainer 里做（职责分离：网络=可微算子，训练器=协议）。
##
## 探索：softmax 温度采样（温度在训练器侧衰减、保熵下限）；评估走 argmax（greedy）。
## 存取：to_dict/from_dict 对接 checkpoint JSON（断点续训），浮点直存十进制文本。
##
## 依赖纪律：RefCounted 零出向——不依赖任何模块 / autoload，纯算子。

# ─────────────────────────────── 维度常量 ────────────────────────────────
## 观察向量维度（布局见 battle_env.gd _encode_obs：全局 6 + 每旗 7×3 + 每班 10×3）
const INPUT_DIM: int = 57
## 隐层宽度（ReLU）
const HIDDEN_DIM: int = 24
## 班数（先锋/中坚/火力）
const N_SQUADS: int = 3
## 每班意图数（攻左旗/攻中旗/攻右旗/驻防己方最近旗/接敌推进）
const N_ACTIONS: int = 5
## 输出 logits 维度 = 班 × 意图
const OUT_DIM: int = N_SQUADS * N_ACTIONS

# ─────────────────────────────── 权重 ────────────────────────────────
## 隐层权重（H×I 行主序）与偏置
var w1: PackedFloat32Array = PackedFloat32Array()
var b1: PackedFloat32Array = PackedFloat32Array()
## 输出层权重（A×H 行主序）与偏置
var w2: PackedFloat32Array = PackedFloat32Array()
var b2: PackedFloat32Array = PackedFloat32Array()


func _init() -> void:
	randomize_weights(20260930)


## Xavier 均匀初始化（固定种子保证新档可复现；from_dict 后即被覆盖）
func randomize_weights(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_fill_xavier(w1, HIDDEN_DIM, INPUT_DIM, rng)
	_fill_const(b1, HIDDEN_DIM, 0.0)
	_fill_xavier(w2, OUT_DIM, HIDDEN_DIM, rng)
	_fill_const(b2, OUT_DIM, 0.0)


func _fill_xavier(arr: PackedFloat32Array, rows: int, cols: int, rng: RandomNumberGenerator) -> void:
	arr.resize(rows * cols)
	var limit: float = sqrt(6.0 / float(rows + cols))
	for i in arr.size():
		arr[i] = rng.randf_range(-limit, limit)


func _fill_const(arr: PackedFloat32Array, n: int, v: float) -> void:
	arr.resize(n)
	for i in n:
		arr[i] = v


# ─────────────────────────────── 前向 ────────────────────────────────

## 前向：obs(INPUT_DIM) → logits(OUT_DIM)。 obs 长度不符按零填充/截断（防御）。
func forward(obs: PackedFloat32Array) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(HIDDEN_DIM)
	for j in HIDDEN_DIM:
		var s: float = 0.0
		var base: int = j * INPUT_DIM
		for i in INPUT_DIM:
			s += w1[base + i] * obs[i]
		h[j] = maxf(s + b1[j], 0.0)
	var out := PackedFloat32Array()
	out.resize(OUT_DIM)
	for k in OUT_DIM:
		var s: float = 0.0
		var base: int = k * HIDDEN_DIM
		for j in HIDDEN_DIM:
			s += w2[base + j] * h[j]
		out[k] = s + b2[k]
	return out


## 单班 softmax（带温度；返回长度 N_ACTIONS 的概率数组）
func softmax_slice(logits: PackedFloat32Array, squad_idx: int, temp: float) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(N_ACTIONS)
	var base: int = squad_idx * N_ACTIONS
	var t: float = maxf(temp, 0.05)
	var mx: float = -INF
	for a in N_ACTIONS:
		mx = maxf(mx, logits[base + a])
	var sum: float = 0.0
	for a in N_ACTIONS:
		var e: float = exp((logits[base + a] - mx) / t)
		p[a] = e
		sum += e
	if sum <= 0.0:
		var uniform: float = 1.0 / float(N_ACTIONS)
		for a in N_ACTIONS:
			p[a] = uniform
		return p
	for a in N_ACTIONS:
		p[a] /= sum
	return p


## 温度采样一拍：mask_active 按班 1/0（空班不采样不进 logprob）。
## 返回 {actions: PackedInt32Array(3), logprob: float, entropy: float, n_active: int}
## entropy = 各活动班熵之和（nats，监控塌缩用）。
func sample_actions(logits: PackedFloat32Array, temp: float,
		mask_active: PackedInt32Array, rng: RandomNumberGenerator) -> Dictionary:
	var actions := PackedInt32Array()
	actions.resize(N_SQUADS)
	var logprob: float = 0.0
	var entropy: float = 0.0
	var n_active: int = 0
	for s in N_SQUADS:
		if mask_active[s] == 0:
			actions[s] = 0
			continue
		var p := softmax_slice(logits, s, temp)
		var roll: float = rng.randf()
		var acc: float = 0.0
		var picked: int = N_ACTIONS - 1
		for a in N_ACTIONS:
			acc += p[a]
			if roll <= acc:
				picked = a
				break
		actions[s] = picked
		logprob += log(maxf(p[picked], 1e-9))
		var h: float = 0.0
		for a in N_ACTIONS:
			if p[a] > 1e-9:
				h -= p[a] * log(p[a])
		entropy += h
		n_active += 1
	return {"actions": actions, "logprob": logprob, "entropy": entropy, "n_active": n_active}


## 贪心一拍（评估用）：每班取 logits argmax，平局取小下标（确定性）
func greedy_actions(logits: PackedFloat32Array, mask_active: PackedInt32Array) -> PackedInt32Array:
	var actions := PackedInt32Array()
	actions.resize(N_SQUADS)
	for s in N_SQUADS:
		if mask_active[s] == 0:
			actions[s] = 0
			continue
		var base: int = s * N_ACTIONS
		var best: int = 0
		for a in range(1, N_ACTIONS):
			if logits[base + a] > logits[base + best]:
				best = a
		actions[s] = best
	return actions


# ─────────────────────────────── 反向（REINFORCE 一步）────────────────────────────────

## 一批样本走一步 SGD。samples = [{obs: PackedFloat32Array, dlogits: PackedFloat32Array}]
## dlogits 由调用方按 −adv×(onehot−π) + β×π×(H+logπ) 组装（只填活动班切片）。
## 流程：逐样本累加梯度 → 取均值 → 全局范数裁剪 → 应用；返回裁剪前梯度范数（日志用）。
func train_step(samples: Array, lr: float, clip_norm: float) -> float:
	var gw1 := PackedFloat32Array()
	gw1.resize(w1.size())
	var gb1 := PackedFloat32Array()
	gb1.resize(b1.size())
	var gw2 := PackedFloat32Array()
	gw2.resize(w2.size())
	var gb2 := PackedFloat32Array()
	gb2.resize(b2.size())
	var n: int = samples.size()
	if n == 0:
		return 0.0
	for sample_v in samples:
		var sample: Dictionary = sample_v
		var obs: PackedFloat32Array = sample["obs"]
		var dlogits: PackedFloat32Array = sample["dlogits"]
		# 前向缓存（反向要用 h 与 z1 符号）
		var z1 := PackedFloat32Array()
		z1.resize(HIDDEN_DIM)
		var h := PackedFloat32Array()
		h.resize(HIDDEN_DIM)
		for j in HIDDEN_DIM:
			var s: float = 0.0
			var base: int = j * INPUT_DIM
			for i in INPUT_DIM:
				s += w1[base + i] * obs[i]
			z1[j] = s
			h[j] = maxf(s, 0.0)
		# 反传：gh = W2^T dlogits（ReLU 处截断）；gw2 += outer(dlogits, h)
		var gh := PackedFloat32Array()
		gh.resize(HIDDEN_DIM)
		for k in OUT_DIM:
			var gk: float = dlogits[k]
			if gk == 0.0:
				continue
			var base: int = k * HIDDEN_DIM
			for j in HIDDEN_DIM:
				gw2[base + j] += gk * h[j]
				gh[j] += w2[base + j] * gk
		for j in HIDDEN_DIM:
			if z1[j] <= 0.0:
				gh[j] = 0.0
				continue
			var gj: float = gh[j]
			if gj == 0.0:
				continue
			var base: int = j * INPUT_DIM
			for i in INPUT_DIM:
				gw1[base + i] += gj * obs[i]
			gb1[j] += gj
		# 输出层偏置梯度 = dlogits 本身（每样本一次，勿放进循环）
		for k in OUT_DIM:
			gb2[k] += dlogits[k]
	# 均值 + 全局范数裁剪 + 应用
	var total: int = w1.size() + b1.size() + w2.size() + b2.size()
	var norms := PackedFloat32Array()
	norms.resize(4)
	norms[0] = _mean_sq(gw1, n)
	norms[1] = _mean_sq(gb1, n)
	norms[2] = _mean_sq(gw2, n)
	norms[3] = _mean_sq(gb2, n)
	var sq: float = 0.0
	for v in norms:
		sq += v
	var grad_norm: float = sqrt(sq)
	var scale: float = lr
	if clip_norm > 0.0 and grad_norm > clip_norm:
		scale = lr * clip_norm / maxf(grad_norm, 1e-9)
	_scale_into(w1, gw1, n, scale)
	_scale_into(b1, gb1, n, scale)
	_scale_into(w2, gw2, n, scale)
	_scale_into(b2, gb2, n, scale)
	return grad_norm


func _mean_sq(grad: PackedFloat32Array, n: int) -> float:
	var s: float = 0.0
	for v in grad:
		var m: float = v / float(n)
		s += m * m
	return s


func _scale_into(param: PackedFloat32Array, grad: PackedFloat32Array, n: int, scale: float) -> void:
	for i in param.size():
		param[i] -= grad[i] / float(n) * scale


# ─────────────────────────────── 存取（checkpoint JSON）────────────────────────────────

## 序列化为可 JSON.stringify 的字典（权重转普通 Array）
func to_dict() -> Dictionary:
	return {
		"input_dim": INPUT_DIM,
		"hidden_dim": HIDDEN_DIM,
		"out_dim": OUT_DIM,
		"w1": _packed_to_array(w1),
		"b1": _packed_to_array(b1),
		"w2": _packed_to_array(w2),
		"b2": _packed_to_array(b2),
	}


## 从 checkpoint 字典恢复；维度不符返回 false（调用方按新档处理）
func from_dict(data: Dictionary) -> bool:
	if int(data.get("input_dim", -1)) != INPUT_DIM \
			or int(data.get("hidden_dim", -1)) != HIDDEN_DIM \
			or int(data.get("out_dim", -1)) != OUT_DIM:
		return false
	if not _load_into(w1, data.get("w1")) or not _load_into(b1, data.get("b1")) \
			or not _load_into(w2, data.get("w2")) or not _load_into(b2, data.get("b2")):
		return false
	return true


func _packed_to_array(packed: PackedFloat32Array) -> Array:
	var out: Array = []
	out.resize(packed.size())
	for i in packed.size():
		out[i] = packed[i]
	return out


func _load_into(target: PackedFloat32Array, src: Variant) -> bool:
	if not (src is Array):
		return false
	var arr: Array = src
	target.resize(arr.size())
	for i in arr.size():
		target[i] = float(arr[i])
	return true
