#ifndef RL_CORE_TRAINER_H
#define RL_CORE_TRAINER_H
// rl_core · RLTrainer 纯核心：自博弈训练主循环（零 Godot 依赖；绑定见 rl_trainer_gd.cpp）
//
// 一次 iteration = 一对正反局：
//   局 1：攻方编制 A / 守方编制 B（env.reset(seed1) 内部抽样）；
//   局 2：编制互换（攻 B / 守 A，seed2 独立抽），同一直播网络执掌双方。
//   每决策步双方各取 47 维观察（己方视角）→ 网络前向 → 3 班各采样 1 意图
//   （采样流：A 班0..2 → B 班0..2，共用 trainer 主 RNG 流）。
//   梯度：REINFORCE，A = R_side − baseline（R_side = 该局该侧奖励）；
//   一对局的所有 (s,a) 记录累积梯度后按记录数取均值 → Adam 一步。
//   baseline 每 episode 收尾后滚动更新（b += (R−b)/min(count,100)）。
//
// 吞吐设计：train(n_iterations) 在 C++ 内跑完整 episode 循环，GDScript 只调大颗粒
// 接口（init/train/save/load/get_metrics），零跨语言每步调用。
//
// 【诚实预期】见 rl_env.h 头注释——吞吐引擎不是真相源。

#include <string>
#include <vector>

#include "rl_env.h"
#include "rl_net.h"

namespace rl {

struct TrainerMetrics {
	long iterations = 0;
	long episodes = 0;
	double mean_return_recent = 0.0;   // 最近 50 episode 的攻方视角奖励均值
	double attacker_win_rate_recent = 0.0; // 最近 50 episode 攻方胜率（平局记 0.5）
	double baseline = 0.0;
	long baseline_count = 0;
	double grad_norm_last = 0.0;
	double episodes_per_sec = 0.0;     // 全程平均
	double elapsed_sec = 0.0;
};

class RLTrainer {
public:
	RLNet net;
	BattleEnv env;
	RngXs32 rng;
	double lr = 3e-3;
	int recent_window = 50;

	TrainerMetrics metrics;

	void init(uint32_t seed, const JsonPtr &config); // config 可为 null → 全默认

	// 主循环：n_iterations 对正反局；progress_out 非空则每 iteration 后回调（进度用）
	void train(long n_iterations);

	// 单 episode 无梯度跑法（吞吐基准用；训练路径在 train() 内）
	// swap_sides=false：reset(seed) 抽编制；true：同种子但攻守编制互换无意义（同 seed
	// 抽样序列一致），故 true 时 seed^0x9E3779B9 错开。返回该局攻方奖励。
	double run_episode(uint32_t seed, bool swap_sides, int *winner_out);

	// checkpoint：net + baseline + rng + 进度计数（JSON）
	JsonPtr checkpoint_json() const;
	bool load_checkpoint_json(const JsonPtr &j, std::string *err_out = nullptr);

private:
	struct Rec {
		std::vector<double> obs;
		int actions[3];
		double advantage;
	};
	std::vector<Rec> batch;
	std::vector<double> recent_returns;
	std::vector<int> recent_wins; // 1 攻胜 2 守胜 0 平
};

} // namespace rl

#endif // RL_CORE_TRAINER_H
