#ifndef RL_CORE_TRAINER_H
#define RL_CORE_TRAINER_H
// rl_core · RLTrainer 纯核心 v3（v2 对齐协议之上叠加行业标准防退化改造 + 诊断修订）
//
// ── 训练协议（创始人 2026-09-30 基线 + v3 防退化修正，逐项注明）──
//   种子：全局种子 + 迭代数 → rng.seed(hash("20260930|iter"))（hash = Godot djb2）；
//   对阵：gen_matchup（编制定稿三档 17/49/97 含指挥官，兵种配比按 87c2c110 预设
//         固定表；真镜像 = 一套编制/占位两侧共用；随机性 = 档位抽取 + 出生带/班
//         错位占位）；正反两局整体换边（真镜像下换边自动满足）；
//   课程学习【v2 定稿】：iter < 5000 → 17 档（C1）；< 15000 → 49 档（C2）；
//         之后 → 97 档（C3）。维度不变，同一网络跨阶段连续训；评估随阶段同档。
//         新维度从头训（C1 期起）属预期内。
//   训练对手配比（v3·诊断修订：镜像自博弈的胜负分量被对阵侧优势决定论淹没——
//         同阵营跨局奖励相关 −0.90、双局同胜者率仅 5~6%、批内零和精确抵消，胜负
//         梯度 ≈ 纯噪声。混入非镜像对手让优势里出现指向"打赢"的信号）：
//         每轮抽一种对手【50% 军师规划器镜像 / 30% 历史池随机一份 / 20% 镜像自
//         博弈】，正反两局在同一种对手下成对打（换边对称保留：当前网正局执 f1、
//         反局执 f2）；池空时池份额回落规划器。规划器/池对手只产对局不进梯度批。
//         对手池（fictitious self-play 防单点过拟合）：每 pool_every=2000 轮把当前
//         网络快照入池（checkpoint_pool_0..4.json，上限 5 份滚动覆盖）；
//   奖励：±1 + 0.2×(己存活比−敌存活比) + 0.5×(己夺点−敌夺点)/3（训练视角进批）；
//         【v3·改造2】存活差 0.5→0.2（零和下诱导保守化；诊断证实 shaped 分量被侧
//         优势主导 −0.858，降权正确）、夺点维持 0.5，详见 rl_env.h faction_reward
//         注释（GDScript 真相源仍 0.5/0.5，两版奖励口径分叉）；
//   REINFORCE：优势 = (R−baseline) 跨批标准化（零均值/max(std,1e-4)）；
//     dlogits = (−adv·(onehot−π) + β·π·(H+logπ)) / T（只填活动班切片）；
//     SGD lr = max(0.006, 0.02×0.995^iter)【v3：保底 0.002→0.006，诊断指出 lr 长期
//     趴初始 10% 的下限是恢复能力瓶颈】，全局范数裁剪 5.0；
//   熵维护【v3·诊断修订】：诊断否定熵塌缩（H 全程 4.0~4.13 = 上限 85%），β=0.02
//         的均匀拉力是无约束随机游走的帮凶之一 → β 固定降为 0.005（防坍缩底线，
//         拉力弱到不压学习信号）；熵目标自适应（H<ln(5³)×0.85≈4.104 → β 翻倍至
//         上限 1.0；H>目标×1.1 → 减半至下限 0.005）保留实现、默认关
//         （entropy_adaptive=true 可开；开时 β 随 checkpoint 存取）；
//   温度【v3·改造4】：T = max(0.85, 1.1×0.995^iter)（下限 0.7→0.85，训练采样保留
//         更多探索；评估 greedy 不走温度，口径不变）；
//   baseline：训练视角均值 R 的 EMA 0.05（对手局只计本人轨迹——非镜像局奖励非
//         零和，baseline 从此真正动起来，不再恒 0）；
//   checkpoint：每 10 轮（阿尔法 JSON 契约，旧档语义不变；另存 pool_count）；池快照
//         每 2000 轮（同契约独立文件）；评估：每 50 轮，先军师镜像 3 组×（正反），
//         再历史池 3 组×（正反，池空跳过）；
//   CSV：train_log.csv 行尾追加 opp_g1,opp_g2（对手标记 self/pool<槽>/planner）；
//         eval_log.csv 行尾追加 mirror_wr,pool_wr,pool_games——旧列语义不变
//         （games/score/win_rate/detail = vs 军师镜像，与历史口径连续）。
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
	double rewards[4] = { 0, 0, 0, 0 }; // r_f1_g1, r_f2_g1, r_f1_g2, r_f2_g2（两局双方视角原始值）
	double mean_r = 0, baseline = 0, entropy = 0, temp = 0, grad_norm = 0;
	int winner_g1 = 0, winner_g2 = 0;
	double dur_g1 = 0, dur_g2 = 0;
	int n_a = 0, n_b = 0;
	double wall_s = 0;
	// v3 防退化：对手类型标记（"self" / "pool<槽>" / "planner"）与当轮 β
	std::string opp_g1 = "self", opp_g2 = "self";
	double entropy_beta = 0.005;
};

struct EvalRecord {
	long iter = 0;
	// 旧列语义（向后兼容）：games/score/win_rate/detail = vs 军师镜像组
	int games = 0;
	double score = 0, win_rate = 0;
	std::vector<double> detail;
	// v3 分组报告：vs 军师镜像（泛化）与 vs 历史池（真实策略进步）两组胜率分列
	int games_mirror = 0, games_pool = 0;
	double win_rate_mirror = 0, win_rate_pool = 0;
};

class RLTrainer {
public:
	// 超参（基线对齐 selfplay_trainer.gd 常量区；v3 修正项见注释；可被 config 覆盖）
	double lr_start = 0.02, lr_decay = 0.995;
	double lr_floor = 0.006; // 【v3 诊断修订】0.002 → 0.006（lr 长期趴初始 10% 是恢复瓶颈）
	double grad_clip = 5.0;
	double entropy_beta = 0.005; // 【v3】0.02 → 0.005：熵未塌缩（H≈上限85%），均匀拉力是漂移帮凶
	bool entropy_adaptive = false; // 熵目标自适应默认关（诊断降级为可选）；开时 β 演化并随档存取
	// 熵目标自适应参数（entropy_adaptive=true 时生效）：目标 = ln(5³)×0.85 ≈ 4.104
	double entropy_target = 3.0 * 1.6094379124341003 * 0.85; // ln(5)×3×0.85
	double entropy_beta_min = 0.005, entropy_beta_max = 1.0;
	double temp_start = 1.1, temp_decay = 0.995;
	double temp_min = 0.85; // 【改造4】0.7 → 0.85（评估 greedy 不变，训练采样保留探索）
	double baseline_ema = 0.05;
	long checkpoint_every = 10, eval_every = 50;
	int eval_groups = 3;
	// 训练对手配比（v3·诊断修订，按轮抽签；三者和可 <1，余量归规划器）
	double planner_prob = 0.5; // 军师规划器镜像（非噪声胜负梯度的头号来源）
	double pool_prob = 0.3;    // 历史池随机一份（防对规划器单点过拟合）
	//                           其余 20% = 镜像自博弈（零和正则 + 自我改进空间）
	// 对手池：每 2000 轮快照、上限 5 份滚动
	long pool_every = 2000;
	int pool_size = 5;
	int eval_pool_groups = 3;
	// 课程学习（17→49→97 三阶段；iter 阈值可 config 覆盖，负值 = 关闭随机抽档）：
	//   iter < curriculum_c1_end → 17 档；< curriculum_c2_end → 49 档；否则 97 档。
	//   评估随训练所在阶段同档。维度不变，跨阶段连续训同一网络。
	long curriculum_c1_end = 5000;  // C1：17 档期
	long curriculum_c2_end = 15000; // C2：49 档期（之后 C3 = 97 档至终）
	uint64_t global_seed = 20260930;

	RLNet net;
	BattleEnv env;
	FileHooks hooks;

	long iteration = 0;
	double baseline = 0.0;

	// 对手池状态（滚动槽；槽 i 有效 ⇔ pool_iter[i] ≥ 0；pool_count = 历史快照总数，
	// 决定下一个滚动槽 = pool_count % pool_size，随 checkpoint 存取）
	std::vector<RLNet> pool;
	std::vector<long> pool_iter;
	long pool_count = 0;

	// 路径（绝对路径或 user:// 语义由绑定层保证；hooks 实际读写）
	// 池文件 = checkpoint_path 同目录 checkpoint_pool_<槽>.json（向后兼容：主档不变）
	std::string checkpoint_path, train_csv_path, eval_csv_path;

	// 进度回调（每轮一行 stdout 由绑定层接管时用；可空）
	std::function<void(const IterRecord &)> on_iteration;
	std::function<void(const EvalRecord &)> on_evaluation;

	void configure(const JsonPtr &config); // null = 全默认
	void apply_checkpoint_state(long iter, double base);

	void train(long n_iterations);

	// 评估（独立可调；先军师镜像组再历史池组，EvalRecord 分列两组胜率）
	EvalRecord run_evaluation();

	// checkpoint（阿尔法 JSON 契约；load 只取 net/iteration/baseline + v3 增量
	// [pool_count / 自适应 β]，旧档无增量键走默认 → 语义不变）
	bool save_checkpoint() const;
	bool load_checkpoint(); // 无文件/损坏/维度不符 → false（调用方决定从头训）
	bool has_checkpoint_file() const;

	// 对手池（改造1）
	int pool_occupied() const;          // 有效槽位数（可抽的对手份数）
	bool save_pool_snapshot();          // 当前网络快照入池（滚动覆盖 + 落盘）
	void load_pool();                   // 从 checkpoint 目录装池（尽力而为，缺文件跳过）

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
		int actions[BattleEnv::N_SQUADS];
		int mask[BattleEnv::N_SQUADS];
	};
	// 一个视角的指挥官：三选一——net 执掌（self/池成员）或 planner=true 走军师
	// 规划器镜像；record = 是否记录轨迹/熵（对手视角 false——只产对局，不进梯度批）
	struct AgentTraj {
		std::vector<TrajStep> steps;
		double entropy_sum = 0.0;
		int entropy_beats = 0;
		RngPcg rng;
		double temp = 1.0;
		bool greedy = false;
		RLNet *net = nullptr;
		bool planner = false;
		bool record = false;
	};

	void play_battle(const Matchup &m, bool swap, AgentTraj &ag1, AgentTraj &ag2,
			EnvResult *res_out);
	double train_batch(const std::vector<double> &rewards, const std::vector<AgentTraj *> &agents, double temp);
	// 评估一局：NN greedy 在 nn_faction；对手 = opp_net（nullptr = 军师规划器镜像）。
	// 返回 NN 得分（胜 1 平 0.5 负 0）。
	double eval_one_game(const Matchup &m, bool swap, int nn_faction, const RLNet *opp_net);
	// 熵目标自适应（可选）：按本轮平均熵调 β（翻倍/减半/不动，夹上下限）
	void adapt_entropy(double mean_entropy);
	std::string pool_slot_path(int slot) const;
	void append_csv_line(const std::string &path, const std::string &header, const std::string &line) const;
};

} // namespace rl

#endif // RL_CORE_TRAINER_H
