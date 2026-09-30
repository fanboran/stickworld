#ifndef RL_CORE_TRAINER_H
#define RL_CORE_TRAINER_H
// rl_core · RLTrainer 纯核心 v2（对齐 tests/dev/rl/selfplay_trainer.gd 训练协议真相源）
//
// ── 训练协议（创始人 2026-09-30 修正版，逐项对齐 selfplay_trainer.gd）──
//   种子：全局种子 + 迭代数 → rng.seed(hash("20260930|iter"))（hash = Godot djb2）；
//   对阵：gen_matchup（总兵力 {16,32,48}、35%~65% 不对称、5 兵种 Dirichlet² 配比、
//         最大余数法、SQUAD_SPLIT 拆班、占位独立随机）；正反两局整体换边；
//   奖励：±1 + 0.5×(己存活比−敌存活比) + 0.5×(己夺点−敌夺点)/3（4 视角进同一批）；
//   REINFORCE：优势 = (R−baseline) 跨批标准化（零均值/max(std,1e-4)）；
//     dlogits = (−adv·(onehot−π) + β·π·(H+logπ)) / T（β=0.02，只填活动班切片）；
//     SGD lr = max(0.002, 0.02×0.995^iter)，全局范数裁剪 5.0；
//   温度：T = max(0.7, 1.1×0.995^iter)；baseline：4 视角均值 R 的 EMA 0.05；
//   checkpoint：每 10 轮（阿尔法 JSON 契约）；评估：每 50 轮，NN greedy vs 军师
//   规划器镜像，3 组 ×（正局+反局）组间换边，胜 1 平 0.5 负 0；
//   CSV：train_log.csv / eval_log.csv 追加（读-改-写，格式与 GDScript 版一致）。
//
// 文件 I/O 经 FileHooks 注入（绑定层用 Godot FileAccess 实现——中文路径由 Godot
// 处理，纯核心零 WinAPI/编码依赖）。路径语义由绑定层 translate（user:// → 绝对）。

#include <functional>
#include <string>
#include <vector>

#include "rl_env.h"
#include "rl_net.h"

namespace rl {

struct FileHooks {
	// 读全文本（不存在返回 false）；写全文本（覆盖）
	std::function<bool(const std::string &, std::string *)> read;
	std::function<bool(const std::string &, const std::string &)> write;
};

struct IterRecord {
	long iter = 0;
	double rewards[4] = { 0, 0, 0, 0 }; // r_f1_g1, r_f2_g1, r_f1_g2, r_f2_g2
	double mean_r = 0, baseline = 0, entropy = 0, temp = 0, grad_norm = 0;
	int winner_g1 = 0, winner_g2 = 0;
	double dur_g1 = 0, dur_g2 = 0;
	int n_a = 0, n_b = 0;
	double wall_s = 0;
};

struct EvalRecord {
	long iter = 0;
	int games = 0;
	double score = 0, win_rate = 0;
	std::vector<double> detail;
};

class RLTrainer {
public:
	// 超参（对齐 selfplay_trainer.gd 常量区；可被 config 覆盖）
	double lr_start = 0.02, lr_decay = 0.995, lr_floor = 0.002;
	double grad_clip = 5.0;
	double entropy_beta = 0.02;
	double temp_start = 1.1, temp_decay = 0.995, temp_min = 0.7;
	double baseline_ema = 0.05;
	long checkpoint_every = 10, eval_every = 50;
	int eval_groups = 3;
	uint64_t global_seed = 20260930;

	RLNet net;
	BattleEnv env;
	FileHooks hooks;

	long iteration = 0;
	double baseline = 0.0;

	// 路径（绝对路径或 user:// 语义由绑定层保证；hooks 实际读写）
	std::string checkpoint_path, train_csv_path, eval_csv_path;

	// 进度回调（每轮一行 stdout 由绑定层接管时用；可空）
	std::function<void(const IterRecord &)> on_iteration;
	std::function<void(const EvalRecord &)> on_evaluation;

	void configure(const JsonPtr &config); // null = 全默认
	void apply_checkpoint_state(long iter, double base);

	void train(long n_iterations);

	// 评估（独立可调；协议同 _run_evaluation）
	EvalRecord run_evaluation();

	// checkpoint（阿尔法 JSON 契约；load 只取 net/iteration/baseline/超参指纹）
	bool save_checkpoint() const;
	bool load_checkpoint(); // 无文件/损坏/维度不符 → false（调用方决定从头训）
	bool has_checkpoint_file() const;

	// 吞吐基准用：单 episode 无梯度（greedy 或采样）
	struct EpisodeOut {
		double reward_f1;
		int winner;
		double duration;
		int decisions;
	};
	EpisodeOut run_episode_bench(uint32_t seed, bool swap, bool greedy);

	IterRecord last_record;

private:
	struct TrajStep {
		std::vector<double> obs;
		int actions[3];
		int mask[3];
	};
	struct AgentTraj {
		std::vector<TrajStep> steps;
		double entropy_sum = 0.0;
		int entropy_beats = 0;
		RngPcg rng;
		double temp = 1.0;
		bool greedy = false;
	};

	void play_battle(const Matchup &m, bool swap, AgentTraj &ag1, AgentTraj &ag2,
			EnvResult *res_out);
	double train_batch(const std::vector<double> &rewards, const std::vector<AgentTraj *> &agents, double temp);
	void append_csv_line(const std::string &path, const std::string &header, const std::string &line) const;
};

} // namespace rl

#endif // RL_CORE_TRAINER_H
