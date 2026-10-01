#ifndef RL_CORE_NET_H
#define RL_CORE_NET_H
// rl_core · RLPolicyNet 纯核心 v2（对齐 tests/dev/rl/policy_net.gd 真相源；零 Godot 依赖）
//
// ── 网络规格（改一处必改两处：C++ 默认值 ↔ trainer/测试的 alloc 调用）──
//   结构：MLP 125 → 64(ReLU) → 40 logits（8 班 × 5 意图，按班组内 softmax）。
//   前向：h = relu(b1 + W1·x)；logits = b2 + W2·h。W1 行主序 [24][57]，W2 行主序 [15][24]。
//   softmax 带温度：p = softmax((logits−max)/T)，T = max(temp, 0.05)；sum≤0 → 均匀。
//   采样：roll = rng.randf()；acc 累加，roll <= acc 即取（初始兜底 = 4）——与
//         policy_net.sample_actions 的边界语义一致（<= 而非 <）。
//   贪心：argmax，平局取小下标。
//   训练（REINFORCE 一步，SGD）：
//     dlogits 由训练器组装：g = (−adv·(onehot(a)−π) + β·π·(H+logπ)) / T（只填活动班）。
//     train_step：逐样本反传累加梯度 → 各参数取均值 → 全局范数（均值化后）→
//     超限按 clip 缩放 → param −= mean_grad × scale；返回裁剪前梯度范数。
//   初始化：Xavier 均匀 U(±sqrt(6/(rows+cols)))，顺序 w1 → w2，偏置置 0（seed 可复现）。
//
// ── checkpoint JSON 契约 v1（真相源 = selfplay_trainer._save_checkpoint /
//    policy_net.to_dict；nn_brain.gd 按此装载——两版互操作的生命线）──
//   {
//     "iteration": N, "seed": GLOBAL_SEED, "baseline": f,
//     "hyper": {"lr_decay":0.995,"temp_decay":0.995,"beta":0.005},
//     "saved_at": "...",
//     "net": {"input_dim":125,"hidden_dim":64,"out_dim":40,
//             "w1":[平铺 64×125],"b1":[64],"w2":[平铺 40×64],"b2":[40]}
//   }
//   注意：权重是平铺一维数组（旧 rl_core 的二维嵌套格式已废弃）。
//   存取浮点直存十进制文本（GDScript JSON.stringify 同形）。

#include <string>
#include <vector>

#include "rl_json.h"
#include "rl_math.h"

namespace rl {

struct RLNet {
	// v2 定稿维度：MLP 125 → 64(ReLU) → 40 logits（8 班 × 5 意图，按班组内 softmax）
	int input_dim = 125, hidden_dim = 64, out_dim = 40;
	static const int N_SQUADS = 8;
	static const int N_ACTIONS = 5; // 每班动作数（意图词汇 5）

	std::vector<double> w1, b1, w2, b2;

	void alloc(int in_dim, int hid_dim, int out_dim);
	void init_weights(uint64_t seed);

	void forward(const double *obs, double *logits, double *hidden_out) const;
	void softmax_slice(const double *logits, int squad, double temp, double *probs5) const;

	// 温度采样一拍（mask 按班 1/0；空班 action=0 不进 logprob）
	void sample_actions(const double *logits, double temp, const int *mask_active,
			RngPcg &rng, int *actions, double *logprob_out, double *entropy_out, int *n_active_out) const;
	void greedy_actions(const double *logits, const int *mask_active, int *actions) const;

	// REINFORCE 一步（samples: obs 与 dlogits 等长平行数组）
	struct Sample {
		std::vector<double> obs;
		std::vector<double> dlogits;
	};
	double train_step(const std::vector<Sample> &samples, double lr, double clip_norm);

	JsonPtr net_to_json() const;
	bool net_from_json(const JsonPtr &net_obj, std::string *err_out = nullptr);
	int param_count() const { return (int)(w1.size() + b1.size() + w2.size() + b2.size()); }
};

} // namespace rl

#endif // RL_CORE_NET_H
