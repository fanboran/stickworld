#ifndef RL_CORE_NET_H
#define RL_CORE_NET_H
// rl_core · RLPolicyNet 纯核心（零 Godot 依赖；Godot 绑定见 rl_net_gd.cpp）
//
// ── 网络规格 v1（与 GDScript 版两版逐字一致，改一处必改两处）──
//   结构：全连接 MLP，输入 in(=47，环境观察维度) → 隐 hid(=24, ReLU) → 输出 out(=15)。
//   输出按 3 班 × 5 意图分组：组 g 的 logits = out[g*5 .. g*5+5)，组内 softmax（减最大值稳定化）。
//   采样：每组独立按累计概率取意图（u < cum[k] → k，兜底 4）。
//   前向：h = relu(b1 + W1·x)；logits = b2 + W2·h。W1 行主序 [hid][in]，W2 行主序 [out][hid]。
//   训练：REINFORCE，L = −Σ_t Σ_g logπ_g(a_{t,g}|s_t) · A_t，A = R − baseline
//        （Monte Carlo 整局回报，逐决策步同用 A）。梯度按批均值，Adam(l=3e-3, β1=.9, β2=.999, ε=1e-8)。
//   baseline：滚动均值（窗口 100）：b += (R−b)/min(count,100)，count 每 episode +1。
//   初始化：Glorot 均匀 U(±sqrt(6/(fan_in+fan_out)))，顺序 w1（行主序）→ w2（行主序），偏置置 0；
//        初始化用独立 xorshift32（种子 = 主种子 ^ 0x5BD1E995）。
//
// ── JSON 存取契约 v1（GDScript 版必须产出可互读的同格式）──
//   {
//     "format": "rl_core.policy_net", "version": 1,
//     "input_size": 47, "hidden_size": 24, "output_size": 15,
//     "output_groups": 3, "actions_per_group": 5, "activation": "relu",
//     "w1": [[hid×in 行主序二维数组]], "b1": [hid],
//     "w2": [[out×hid 行主序二维数组]], "b2": [out],
//     "baseline": 0.0, "baseline_count": 0
//   }
//   两版互通判据：format/version 一致 + 维度一致，权重按上表读。

#include <string>
#include <vector>

#include "rl_json.h"
#include "rl_math.h"

namespace rl {

struct RLNet {
	int in = 47, hid = 24, out = 15, groups = 3, apg = 5;
	std::vector<double> w1, b1, w2, b2;           // 参数
	std::vector<double> g1, gb1, g2, gb2;         // 梯度累积
	std::vector<double> m1, mb1, m2, mb2;         // Adam 一阶矩
	std::vector<double> v1, vb1, v2, vb2;         // Adam 二阶矩
	long adam_t = 0;
	double baseline = 0.0;
	long baseline_count = 0;

	void alloc(int in_dim, int hid_dim, int out_dim);
	void init_weights(uint32_t seed);

	// 前向：obs[in] → logits[out]，同时返回隐层（backward 用；可传 nullptr 丢弃）
	void forward(const double *obs, double *logits, double *hidden_out) const;

	// softmax 后按组采样动作（actions[3]），并累计整条动作的 logπ
	void sample_actions(const double *logits, RngXs32 &rng, int *actions, double *logprob_out) const;
	void probs_for(const double *logits, int group, double *probs5) const;

	// REINFORCE 梯度累积：对一条 (obs, actions, advantage) 记录累加 ∂(−A·logπ)/∂θ
	void accumulate_grad(const double *obs, const int *actions, double advantage);

	// 批收尾：梯度除以样本数 → Adam 步 → 清零梯度
	void adam_step(double lr, double batch_count);

	JsonPtr to_json() const;
	bool from_json(const JsonPtr &j, std::string *err_out = nullptr);
};

} // namespace rl

#endif // RL_CORE_NET_H
