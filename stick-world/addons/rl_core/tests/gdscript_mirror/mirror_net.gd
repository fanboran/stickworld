extends RefCounted
## rl_core · 125→64→40 MLP 前向 GDScript 镜像（v2 定稿维度）。
##
## 与 C++ RLNet::forward 互为独立实现（阿尔法 policy_net.gd 是 57→24→15 旧维度
## 且只读）：装 checkpoint JSON 的平铺权重，手写前向——权重衔接门
##（test_core.exe gen-net-probe → policy_net_probe.gd → verify-net）的 GDScript 侧。
## GDScript float = 64 位，累加顺序与 C++ 同序 → 前向 logits 应逐位一致。

var input_dim: int = 125
var hidden_dim: int = 64
var out_dim: int = 40
var w1: Array = [] # 平铺 [hidden×input]，行主序
var b1: Array = []
var w2: Array = [] # 平铺 [out×hidden]
var b2: Array = []


## net_obj = checkpoint 的 "net" 字典（或字典全文）。维度不符/形状不符 → false
func from_json(net_obj: Dictionary) -> bool:
	input_dim = int(net_obj.get("input_dim", 0))
	hidden_dim = int(net_obj.get("hidden_dim", 0))
	out_dim = int(net_obj.get("out_dim", 0))
	if input_dim <= 0 or hidden_dim <= 0 or out_dim <= 0:
		return false
	w1 = net_obj.get("w1", [])
	b1 = net_obj.get("b1", [])
	w2 = net_obj.get("w2", [])
	b2 = net_obj.get("b2", [])
	return w1.size() == hidden_dim * input_dim and b1.size() == hidden_dim \
			and w2.size() == out_dim * hidden_dim and b2.size() == out_dim


## 前向：h = relu(b1 + W1·x)；logits = b2 + W2·h（累加顺序 = C++ 同款 j 内层）
func forward(x: Array) -> Array:
	var h: Array = []
	h.resize(hidden_dim)
	for j in hidden_dim:
		var s: float = 0.0
		var off: int = j * input_dim
		for i in input_dim:
			s += w1[off + i] * x[i]
		var v: float = s + b1[j]
		h[j] = v if v > 0.0 else 0.0
	var logits: Array = []
	logits.resize(out_dim)
	for k in out_dim:
		var s2: float = 0.0
		var off2: int = k * hidden_dim
		for j in hidden_dim:
			s2 += w2[off2 + j] * h[j]
		logits[k] = s2 + b2[k]
	return logits
