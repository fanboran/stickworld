#include "rl_trainer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>

namespace rl {

void RLTrainer::configure(const JsonPtr &config) {
	if (!config || config->type != Json::OBJ) return;
	lr_start = config->get_num("lr_start", lr_start);
	lr_decay = config->get_num("lr_decay", lr_decay);
	lr_floor = config->get_num("lr_floor", lr_floor);
	grad_clip = config->get_num("grad_clip", grad_clip);
	entropy_beta = config->get_num("entropy_beta", entropy_beta);
	// v2 防退化超参
	entropy_target = config->get_num("entropy_target", entropy_target);
	entropy_beta_min = config->get_num("entropy_beta_min", entropy_beta_min);
	entropy_beta_max = config->get_num("entropy_beta_max", entropy_beta_max);
	temp_start = config->get_num("temp_start", temp_start);
	temp_decay = config->get_num("temp_decay", temp_decay);
	temp_min = config->get_num("temp_min", temp_min);
	baseline_ema = config->get_num("baseline_ema", baseline_ema);
	checkpoint_every = config->get_int("checkpoint_every", (int)checkpoint_every);
	eval_every = config->get_int("eval_every", (int)eval_every);
	eval_groups = config->get_int("eval_groups", eval_groups);
	pool_every = config->get_int("pool_every", (int)pool_every);
	pool_size = config->get_int("pool_size", pool_size);
	pool_prob = config->get_num("pool_prob", pool_prob);
	eval_pool_groups = config->get_int("eval_pool_groups", eval_pool_groups);
	// 课程学习（17→49→97 三阶段阈值；负值 = 关闭随机抽档）
	curriculum_c1_end = config->get_int("curriculum_c1_end", (int)curriculum_c1_end);
	curriculum_c2_end = config->get_int("curriculum_c2_end", (int)curriculum_c2_end);
	global_seed = (uint64_t)(int64_t)config->get_num("global_seed", (double)(int64_t)global_seed);
	if (config->has("env")) env.load_config(config->get("env"));
}

// 课程阶段（v2.1 断层修复采样见 rl_env.h curriculum_stage 注释）：
// iter < c1_end → 0（C1）；< c2_end → 1（C2）；否则 2（C3）；阈值负值 = 关闭
static int curriculum_stage_for(long iteration, long c1_end, long c2_end) {
	if (c1_end < 0 || c2_end < 0) return -1;
	if (iteration < c1_end) return 0;
	if (iteration < c2_end) return 1;
	return 2;
}

// 阶段主档（评估锁档用）：C1=17 / C2=49 / C3=97
static int stage_main_tier(int stage) {
	return stage <= 0 ? 0 : (stage == 1 ? 1 : 2);
}

void RLTrainer::apply_checkpoint_state(long iter, double base) {
	iteration = iter;
	baseline = base;
}

// ── 一场（正局/反局；两个指挥视角轨迹）──
// 每视角三选一：ag.net 执掌（当前 self 或池成员）/ ag.planner=true 走军师规划器
// 镜像；ag.record=false 的视角（对手）只产对局，不记轨迹不计熵——不进梯度批。

void RLTrainer::play_battle(const Matchup &m, bool swap, AgentTraj &ag1, AgentTraj &ag2,
		EnvResult *res_out) {
	env.reset(m, swap);
	std::vector<double> obs;
	int mask1[BattleEnv::N_SQUADS], mask2[BattleEnv::N_SQUADS];
	int acts1[BattleEnv::N_SQUADS], acts2[BattleEnv::N_SQUADS];
	double logits[BattleEnv::N_ACTIONS];
	const int NS = BattleEnv::N_SQUADS;
	int beat = 0;
	while (!env.done) {
		// faction 1
		env.active_mask(1, mask1);
		if (ag1.planner) {
			// 天梯陪练（v2.2 药一）：每 every_n_beats 拍重新决策，其余拍沿用缓存
			double noise = 0.0;
			double eps = 0.0;
			int every_n = 1;
			if (ag1.planner_level >= 0) handicap_knobs(ag1.planner_level, noise, every_n, eps);
			if (beat % every_n == 0) {
				if (ag1.planner_level >= 0)
					env.planner_intents_handicap(1, acts1, noise, eps, ag1.rng);
				else
					env.planner_intents(1, acts1);
				for (int k = 0; k < NS; k++) ag1.last_planner_intents[k] = acts1[k];
			} else {
				for (int k = 0; k < NS; k++) acts1[k] = ag1.last_planner_intents[k];
			}
		} else {
			env.observe(1, obs);
			ag1.net->forward(obs.data(), logits, nullptr);
			if (ag1.greedy) {
				ag1.net->greedy_actions(logits, mask1, acts1);
			} else {
				double lp, ent;
				int na;
				ag1.net->sample_actions(logits, ag1.temp, mask1, ag1.rng, acts1, &lp, &ent, &na);
				if (ag1.record) {
					ag1.entropy_sum += ent;
					ag1.entropy_beats++;
					TrajStep st;
					st.obs = obs;
					for (int k = 0; k < NS; k++) {
						st.actions[k] = acts1[k];
						st.mask[k] = mask1[k];
					}
					ag1.steps.push_back(std::move(st));
				}
			}
		}
		// faction 2
		env.active_mask(2, mask2);
		if (ag2.planner) {
			double noise = 0.0;
			double eps = 0.0;
			int every_n = 1;
			if (ag2.planner_level >= 0) handicap_knobs(ag2.planner_level, noise, every_n, eps);
			if (beat % every_n == 0) {
				if (ag2.planner_level >= 0)
					env.planner_intents_handicap(2, acts2, noise, eps, ag2.rng);
				else
					env.planner_intents(2, acts2);
				for (int k = 0; k < NS; k++) ag2.last_planner_intents[k] = acts2[k];
			} else {
				for (int k = 0; k < NS; k++) acts2[k] = ag2.last_planner_intents[k];
			}
		} else {
			env.observe(2, obs);
			ag2.net->forward(obs.data(), logits, nullptr);
			if (ag2.greedy) {
				ag2.net->greedy_actions(logits, mask2, acts2);
			} else {
				double lp, ent;
				int na;
				ag2.net->sample_actions(logits, ag2.temp, mask2, ag2.rng, acts2, &lp, &ent, &na);
				if (ag2.record) {
					ag2.entropy_sum += ent;
					ag2.entropy_beats++;
					TrajStep st;
					st.obs = obs;
					for (int k = 0; k < NS; k++) {
						st.actions[k] = acts2[k];
						st.mask[k] = mask2[k];
					}
					ag2.steps.push_back(std::move(st));
				}
			}
		}
		env.step(acts1, acts2);
		beat++;
	}
	*res_out = env.result();
}

// ── REINFORCE 合批一步（逐字对齐 _train_batch）──

double RLTrainer::train_batch(const std::vector<double> &rewards,
		const std::vector<AgentTraj *> &agents, double temp) {
	size_t n_ep = rewards.size();
	std::vector<double> raw(n_ep);
	double mean = 0.0;
	for (size_t i = 0; i < n_ep; i++) {
		raw[i] = rewards[i] - baseline;
		mean += raw[i];
	}
	mean /= (double)n_ep;
	double var_sum = 0.0;
	for (double v : raw) var_sum += (v - mean) * (v - mean);
	double stdv = std::sqrt(var_sum / (double)n_ep);
	std::vector<RLNet::Sample> samples;
	const int OBS_D = net.input_dim, OUT_D = net.out_dim, NS = RLNet::N_SQUADS, NA = RLNet::N_ACTIONS;
	std::vector<double> logits(OUT_D), probs(NA), dlogits(OUT_D);
	for (size_t ei = 0; ei < n_ep; ei++) {
		double adv = (raw[ei] - mean) / (stdv > 1e-4 ? stdv : 1e-4);
		for (const TrajStep &st : agents[ei]->steps) {
			net.forward(st.obs.data(), logits.data(), nullptr);
			dlogits.assign(OUT_D, 0.0);
			for (int s = 0; s < NS; s++) {
				if (st.mask[s] == 0) continue;
				net.softmax_slice(logits.data(), s, temp, probs.data());
				double h = entropy5(probs.data());
				int base = s * NA;
				for (int a = 0; a < NA; a++) {
					// β = entropy_beta（v2：熵目标自适应演化，见 adapt_entropy）
					double g = -adv * ((a == st.actions[s] ? 1.0 : 0.0) - probs[a])
							+ entropy_beta * probs[a] * (h + std::log(probs[a] > 1e-9 ? probs[a] : 1e-9));
					dlogits[base + a] = g / temp;
				}
			}
			RLNet::Sample sp;
			sp.obs = st.obs;
			sp.dlogits = dlogits;
			samples.push_back(std::move(sp));
		}
	}
	double lr = lr_start * std::pow(lr_decay, (double)iteration);
	if (lr < lr_floor) lr = lr_floor;
	return net.train_step(samples, lr, grad_clip);
}

void RLTrainer::train(long n_iterations) {
	long end = iteration + n_iterations;
	AgentTraj ag[4];
	auto t0 = std::chrono::steady_clock::now();
	while (iteration < end) {
		RngPcg rng;
		rng.seed(hash_djb2(std::to_string(global_seed) + "|" + std::to_string(iteration)));
		// 课程学习（v2.1 断层修复）：训练抽档按阶段占比（env.pick_curriculum_tier 内实现）
		env.curriculum_stage = curriculum_stage_for(iteration, curriculum_c1_end, curriculum_c2_end);
		env.eval_lock_tier = -1;
		Matchup m = env.gen_matchup(rng);
		double temp = temp_start * std::pow(temp_decay, (double)iteration);
		if (temp < temp_min) temp = temp_min;
		// ── 对手抽签（v3 诊断修订）：每轮抽一种对手，正反两局同一种对手下成对打。
		//    [0, pool_prob) 历史池随机一份（池空回落规划器）→
		//    [pool_prob, pool_prob+planner_prob) 军师规划器镜像 → 其余镜像自博弈。
		//    抽签走本轮种子 rng，确定性可复现。──
		int valid[16], nvalid = 0;
		for (int s = 0; s < (int)pool.size() && nvalid < 16; s++)
			if (pool_iter[s] >= 0) valid[nvalid++] = s;
		double roll = rng.randf();
		int opp_kind = 0; // 0=self 1=pool 2=planner
		int pool_slot = -1;
		if (nvalid > 0 && roll < pool_prob) {
			opp_kind = 1;
			pool_slot = valid[rng.randi_range(0, nvalid - 1)];
		} else if (roll < pool_prob + planner_prob) {
			opp_kind = 2;
		}
		// 正局：a 攻西 / b 守东；反局整体交换（每局独立建 agent，独立子 RNG）。
		// 对手局中当前网络在正局执 faction1、反局执 faction2——换边结构保持
		// （当前网仍体验己方编制的西/东两侧点位），对手补位另一侧。
		auto make_agent = [&](AgentTraj &a, RLNet *net_ptr, bool record, bool is_planner) {
			a.steps.clear();
			a.entropy_sum = 0.0;
			a.entropy_beats = 0;
			a.greedy = false;
			a.temp = temp;
			a.rng.seed(rng.next());
			a.net = net_ptr;
			a.record = record;
			a.planner = is_planner;
		};
		make_agent(ag[0], &net, true, false); // 正局 faction1 = 当前网
		if (opp_kind == 1)
			make_agent(ag[1], &pool[pool_slot], false, false); // 正局 faction2 = 池对手
		else if (opp_kind == 2) {
			make_agent(ag[1], &net, false, true); // 正局 faction2 = 军师规划器陪练（天梯档）
			ag[1].planner_level = handicap_level[m.side_a.tier];
		} else
			make_agent(ag[1], &net, true, false); // 正局 faction2 = 当前网（镜像自博弈）
		if (opp_kind == 1)
			make_agent(ag[2], &pool[pool_slot], false, false); // 反局 faction1 = 池对手
		else if (opp_kind == 2) {
			make_agent(ag[2], &net, false, true); // 反局 faction1 = 军师规划器陪练（天梯档）
			ag[2].planner_level = handicap_level[m.side_a.tier];
		} else
			make_agent(ag[2], &net, true, false); // 反局 faction1 = 当前网
		make_agent(ag[3], &net, true, false); // 反局 faction2 = 当前网
		int w1 = 0, w2 = 0;
		double d1 = 0, d2 = 0;
		EnvResult r1, r2;
		play_battle(m, false, ag[0], ag[1], &r1);
		play_battle(m, true, ag[2], ag[3], &r2);
		w1 = r1.winner;
		w2 = r2.winner;
		d1 = r1.duration;
		d2 = r2.duration;
		// 梯度批只收当前网轨迹（record=true）；池对手视角不进批
		AgentTraj *all[4] = { &ag[0], &ag[1], &ag[2], &ag[3] };
		double rews4[4] = { r1.reward_f1, r1.reward_f2, r2.reward_f1, r2.reward_f2 };
		std::vector<AgentTraj *> trained;
		std::vector<double> rews;
		for (int i = 0; i < 4; i++) {
			if (all[i]->record) {
				trained.push_back(all[i]);
				rews.push_back(rews4[i]);
			}
		}
		double grad_norm = train_batch(rews, trained, temp);
		// 记录
		IterRecord rec;
		rec.iter = iteration;
		for (int i = 0; i < 4; i++) rec.rewards[i] = rews4[i];
		double mean_r = 0.0;
		for (double v : rews) mean_r += v;
		mean_r /= (double)rews.size();
		rec.mean_r = mean_r;
		rec.baseline = baseline;
		double ent_sum = 0;
		int ent_beats = 0;
		for (auto *a : trained) { // 熵只计当前网（池对手熵与本策略无关）
			ent_sum += a->entropy_sum;
			ent_beats += a->entropy_beats;
		}
		rec.entropy = ent_beats > 0 ? ent_sum / ent_beats : 0.0;
		rec.temp = temp;
		rec.grad_norm = grad_norm;
		rec.winner_g1 = w1;
		rec.winner_g2 = w2;
		rec.dur_g1 = d1;
		rec.dur_g2 = d2;
		rec.n_a = m.total; // 实际总实体（tier3 = Σ班 5~6 人 + 指挥官，41~49 浮动）
		rec.n_b = m.total;
		std::string opp_tag = opp_kind == 0 ? "self"
				: (opp_kind == 2 ? "planner" : "pool" + std::to_string(pool_slot));
		rec.opp_g1 = opp_tag;
		rec.opp_g2 = opp_tag;
		// 天梯窗口更新（v2.2 药一）：planner 局按 NN 视角计分并判升降
		if (opp_kind == 2) {
			double s1 = r1.winner == 1 ? 1.0 : (r1.winner == 0 ? 0.5 : 0.0); // 正局 NN=f1
			double s2 = r2.winner == 2 ? 1.0 : (r2.winner == 0 ? 0.5 : 0.0); // 反局 NN=f2
			update_handicap(m.side_a.tier, s1);
			update_handicap(m.side_a.tier, s2);
		}
		// baseline EMA（训练视角均值；池局只计本人轨迹）
		baseline += baseline_ema * (rec.mean_r - baseline);
		rec.baseline = baseline;
		// 熵目标自适应（改造3）：本轮熵喂给 β，下一轮生效
		adapt_entropy(rec.entropy);
		rec.entropy_beta = entropy_beta;
		iteration += 1;
		auto t1 = std::chrono::steady_clock::now();
		rec.wall_s = std::chrono::duration<double>(t1 - t0).count();
		last_record = rec;
		// CSV 追加（旧 15 列语义不变；行尾追加对手类型标记，改造6）
		if (!train_csv_path.empty() && hooks.write) {
			char line[640];
			std::snprintf(line, sizeof(line),
					"%ld,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%d,%d,%.1f,%.1f,%.4f,%.1f,%s,%s",
					rec.iter, rec.rewards[0], rec.rewards[1], rec.rewards[2], rec.rewards[3],
					rec.mean_r, rec.baseline, rec.entropy, rec.temp,
					rec.winner_g1, rec.winner_g2, rec.dur_g1, rec.dur_g2, rec.grad_norm, rec.wall_s,
					rec.opp_g1.c_str(), rec.opp_g2.c_str());
			append_csv_line(train_csv_path,
					"iter,r_f1_g1,r_f2_g1,r_f1_g2,r_f2_g2,mean_r,baseline,entropy,temp,"
					"winner_g1,winner_g2,dur_g1,dur_g2,grad_norm,wall_s,opp_g1,opp_g2",
					line);
		}
		if (on_iteration) on_iteration(rec);
		if (checkpoint_every > 0 && iteration % checkpoint_every == 0 && !checkpoint_path.empty()) {
			save_checkpoint();
		}
		// 对手池快照（改造1）：每 pool_every 轮一份，滚动覆盖（池上限 pool_size）
		if (pool_every > 0 && iteration % pool_every == 0 && !checkpoint_path.empty()) {
			save_pool_snapshot();
		}
		if (eval_every > 0 && iteration % eval_every == 0) {
			EvalRecord er = run_evaluation();
			if (on_evaluation) on_evaluation(er);
		}
	}
}

// ── 评估（两组对手分列：vs 军师镜像 = 泛化裁判；vs 历史池 = 真实策略进步裁判）──

EvalRecord RLTrainer::run_evaluation() {
	EvalRecord er;
	er.iter = iteration;
	RngPcg rng;
	rng.seed(hash_djb2(std::to_string(global_seed) + "|eval|" + std::to_string(iteration)));
	// 评估随训练所在课程阶段，恒锁阶段主档（win_rate 口径与历史连续：C1=17/C2=49/C3=97）
	int stage = curriculum_stage_for(iteration, curriculum_c1_end, curriculum_c2_end);
	env.curriculum_stage = stage;
	env.eval_lock_tier = stage_main_tier(stage);
	// ── 第 1 组：NN greedy vs 军师规划器镜像（协议不变：3 组 ×（正局+反局）换边）──
	double score = 0.0;
	for (int g = 0; g < eval_groups; g++) {
		int nn_faction = (g % 2 == 0) ? 1 : 2;
		Matchup m = env.gen_matchup(rng);
		er.detail_tiers.push_back(m.side_a.tier);
		for (int swap_i = 0; swap_i < 2; swap_i++) {
			double s = eval_one_game(m, swap_i == 1, nn_faction, nullptr);
			score += s;
			er.games++;
			er.games_mirror++;
			er.detail.push_back(s);
		}
	}
	er.score = score;
	er.win_rate = er.games > 0 ? score / (double)er.games : 0.0;
	er.win_rate_mirror = er.win_rate;
	// ── 第 2 组：NN greedy vs 历史池（池空跳过；同一份 rng 续抽，确定性）──
	int valid[16], nvalid = 0;
	for (int s = 0; s < (int)pool.size() && nvalid < 16; s++)
		if (pool_iter[s] >= 0) valid[nvalid++] = s;
	if (nvalid > 0) {
		double score_pool = 0.0;
		for (int g = 0; g < eval_pool_groups; g++) {
			int nn_faction = (g % 2 == 0) ? 1 : 2;
			Matchup m = env.gen_matchup(rng);
			er.detail_tiers.push_back(m.side_a.tier);
			int slot = valid[rng.randi_range(0, nvalid - 1)]; // 每组一份池对手，组内正反共用
			for (int swap_i = 0; swap_i < 2; swap_i++) {
				double s = eval_one_game(m, swap_i == 1, nn_faction, &pool[slot]);
				score_pool += s;
				er.games_pool++;
			}
		}
		er.win_rate_pool = er.games_pool > 0 ? score_pool / (double)er.games_pool : 0.0;
	}
	// ── 第 3 组（v2.1 断层修复）：8 班小队档抽查（vs 军师规划器，1 组 × 正反 2 场）——
	//    8 个班动作头/排长层的独立裁判曲线，归因“主档胜率是否因班槽欠开发被拖累”
	double score_small = 0.0;
	env.eval_lock_tier = 3;
	for (int swap_i = 0; swap_i < 2; swap_i++) {
		Matchup m = env.gen_matchup(rng);
		er.detail_tiers.push_back(m.side_a.tier);
		double s = eval_one_game(m, swap_i == 1, 1, nullptr);
		score_small += s;
		er.games_small++;
	}
	er.win_rate_small = er.games_small > 0 ? score_small / (double)er.games_small : 0.0;
	env.eval_lock_tier = -1;
	// ── 第 4 组（v2.2 审计补装·下界裁判）：NN greedy vs 纯随机（主档，1 组 × 正反 2 场）——
	//    实测规划器镜像在 8 班档位弱于随机（随机 0.70 胜它），mirror_wr 已不能单独
	//    定性 NN 战力；本组 NN 应 ≥0.5，低于 = argmax 收敛到了烂过随机的恒定策略。
	double score_rand = 0.0;
	env.eval_lock_tier = stage_main_tier(stage > 0 ? stage : 0);
	RngPcg rrng;
	rrng.seed((uint64_t)(hash_djb2(std::to_string(global_seed) + "|rand|" + std::to_string(iteration))));
	for (int swap_i = 0; swap_i < 2; swap_i++) {
		Matchup m = env.gen_matchup(rng);
		er.detail_tiers.push_back(m.side_a.tier);
		int nn_faction = swap_i == 0 ? 1 : 2;
		env.reset(m, false);
		const int NS = BattleEnv::N_SQUADS;
		int mask1[NS], mask2[NS], acts1[NS], acts2[NS];
		double logits[BattleEnv::N_ACTIONS];
		std::vector<double> obs;
		while (!env.done) {
			env.active_mask(1, mask1);
			env.observe(1, obs);
			if (nn_faction == 1) {
				net.forward(obs.data(), logits, nullptr);
				net.greedy_actions(logits, mask1, acts1);
			} else
				for (int k = 0; k < NS; k++) acts1[k] = mask1[k] ? rrng.randi_range(0, 4) : 0;
			env.active_mask(2, mask2);
			env.observe(2, obs);
			if (nn_faction == 2) {
				net.forward(obs.data(), logits, nullptr);
				net.greedy_actions(logits, mask2, acts2);
			} else
				for (int k = 0; k < NS; k++) acts2[k] = mask2[k] ? rrng.randi_range(0, 4) : 0;
			env.step(acts1, acts2);
		}
		EnvResult res = env.result();
		double sc = res.winner == nn_faction ? 1.0 : (res.winner == 0 ? 0.5 : 0.0);
		score_rand += sc;
		er.games_rand++;
	}
	er.win_rate_rand = er.games_rand > 0 ? score_rand / (double)er.games_rand : 0.0;
	env.eval_lock_tier = -1;
	if (!eval_csv_path.empty() && hooks.write) {
		std::string det = "[";
		for (size_t i = 0; i < er.detail.size(); i++) {
			double v = er.detail[i];
			if (i > 0) det += ", ";
			det += v == 0.5 ? "0.5" : (v == 1.0 ? "1" : "0");
		}
		det += "]";
		std::string tiers = "[";
		for (size_t i = 0; i < er.detail_tiers.size(); i++) {
			if (i > 0) tiers += ",";
			tiers += std::to_string(ARMY_TIERS[er.detail_tiers[i]]);
		}
		tiers += "]";
		char line[560];
		// 旧 8 列语义不变（mirror 组）；行尾追加逐场档位 + 小档抽查组（v2.1）+ 随机下界组（v2.2）
		std::snprintf(line, sizeof(line), "%ld,%d,%.1f,%.4f,%s,%.4f,%.4f,%d,%s,%.4f,%d,%.4f,%d",
				er.iter, er.games, er.score, er.win_rate, det.c_str(),
				er.win_rate_mirror, er.win_rate_pool, er.games_pool,
				tiers.c_str(), er.win_rate_small, er.games_small,
				er.win_rate_rand, er.games_rand);
		append_csv_line(eval_csv_path,
				"iter,games,score,win_rate,detail,mirror_wr,pool_wr,pool_games,tier_detail,small_wr,small_games,rand_wr,rand_games",
				line);
	}
	return er;
}

double RLTrainer::eval_one_game(const Matchup &m, bool swap, int nn_faction, const RLNet *opp_net) {
	env.reset(m, swap);
	const int NS = BattleEnv::N_SQUADS;
	int mask1[NS], mask2[NS], acts1[NS], acts2[NS];
	double logits[BattleEnv::N_ACTIONS];
	std::vector<double> obs;
	while (!env.done) {
		env.active_mask(1, mask1);
		if (nn_faction == 1 || opp_net != nullptr) env.observe(1, obs);
		// faction 1 = NN 时走当前网 greedy；faction 1 = 对手时走对手网 greedy 或规划器
		if (nn_faction == 1) {
			net.forward(obs.data(), logits, nullptr);
			net.greedy_actions(logits, mask1, acts1);
		} else if (opp_net != nullptr) {
			opp_net->forward(obs.data(), logits, nullptr);
			opp_net->greedy_actions(logits, mask1, acts1);
		} else {
			for (int k = 0; k < NS; k++) acts1[k] = 0; // 军师镜像在下面统一下发
		}
		env.active_mask(2, mask2);
		if (nn_faction == 2 || opp_net != nullptr) env.observe(2, obs);
		if (nn_faction == 2) {
			net.forward(obs.data(), logits, nullptr);
			net.greedy_actions(logits, mask2, acts2);
		} else if (opp_net != nullptr) {
			opp_net->forward(obs.data(), logits, nullptr);
			opp_net->greedy_actions(logits, mask2, acts2);
		} else {
			for (int k = 0; k < NS; k++) acts2[k] = 0;
		}
		// 对侧 = 军师规划器意图（仅镜像组）
		if (opp_net == nullptr) {
			if (nn_faction == 1) env.planner_intents(2, acts2);
			else env.planner_intents(1, acts1);
		}
		env.step(acts1, acts2);
	}
	EnvResult res = env.result();
	if (res.winner == nn_faction) return 1.0;
	if (res.winner == 3 - nn_faction) return 0.0;
	return 0.5;
}

// ── 对手池（改造1，fictitious self-play）──

int RLTrainer::pool_occupied() const {
	int n = 0;
	for (int s = 0; s < (int)pool_iter.size(); s++)
		if (pool_iter[s] >= 0) n++;
	return n;
}

std::string RLTrainer::pool_slot_path(int slot) const {
	// checkpoint 同目录：checkpoint_pool_<槽>.json（主档语义不变，改造6）
	std::string dir = checkpoint_path;
	size_t p = dir.find_last_of("/\\");
	dir = (p == std::string::npos) ? std::string() : dir.substr(0, p + 1);
	return dir + "checkpoint_pool_" + std::to_string(slot) + ".json";
}

bool RLTrainer::save_pool_snapshot() {
	if (pool_size <= 0) return false;
	if (pool.empty()) { // 首次快照：按池上限建槽（全部标记无效）
		pool.resize(pool_size);
		pool_iter.assign(pool_size, -1);
	}
	if (!hooks.write || checkpoint_path.empty()) return false;
	int slot = (int)(pool_count % (long)pool_size);
	if (slot < 0) slot = 0;
	pool[slot] = net; // 拷贝当前网络快照
	pool_iter[slot] = iteration;
	pool_count++;
	// 落盘（同阿尔法 JSON 契约 → 旧工具可读；仅文件名不同）
	auto root = Json::make(Json::OBJ);
	root->set("iteration", Json::num_of((double)iteration));
	root->set("seed", Json::num_of((double)(int64_t)global_seed));
	root->set("baseline", Json::num_of(baseline));
	root->set("pool_slot", Json::num_of((double)slot));
	auto hyper = Json::make(Json::OBJ);
	hyper->set("lr_decay", Json::num_of(lr_decay));
	hyper->set("temp_decay", Json::num_of(temp_decay));
	hyper->set("beta", Json::num_of(entropy_beta));
	root->set("hyper", hyper);
	root->set("net", net.net_to_json());
	return hooks.write(pool_slot_path(slot), root->dump());
}

void RLTrainer::load_pool() {
	pool.clear();
	pool_iter.clear();
	if (!hooks.read || pool_size <= 0) return;
	pool.resize(pool_size);
	pool_iter.assign(pool_size, -1);
	for (int s = 0; s < pool_size; s++) {
		std::string text;
		if (!hooks.read(pool_slot_path(s), &text) || text.empty()) continue;
		std::string err;
		JsonPtr root = Json::parse(text, &err);
		if (!root || root->type != Json::OBJ) continue;
		RLNet tmp;
		if (!tmp.net_from_json(root->get("net"), &err)) continue;
		pool[s] = tmp;
		pool_iter[s] = (long)root->get_num("iteration", 0.0);
	}
}

// ── 熵目标自适应（改造3，entropy target regularization）──
// H < 目标 → β 翻倍（加强熵奖励把策略分布推回目标）；
// H > 目标×1.1 → β 减半（探索够用就放松）；
// 目标 ~ 目标×1.1 之间不动。β 夹在 [beta_min, beta_max] 防爆炸/消失。

void RLTrainer::adapt_entropy(double mean_entropy) {
	if (mean_entropy < entropy_target) {
		entropy_beta = std::min(entropy_beta * 2.0, entropy_beta_max);
	} else if (mean_entropy > entropy_target * 1.1) {
		entropy_beta = std::max(entropy_beta * 0.5, entropy_beta_min);
	}
}

// ── 对手难度天梯（v2.2 药一，self-paced 教师课表）──
// 档 0 最弱：打分噪声 60（候选分满级 ~85）/ 3 拍一决策（1.5s）/ ε0.35
// 档 1：40 / 2 拍 / 0.20    档 2：20 / 2 拍 / 0.10    档 3：全强度
void RLTrainer::handicap_knobs(int level, double &score_noise, int &every_n_beats, double &epsilon) {
	switch (level) {
	case 0: score_noise = 60.0; every_n_beats = 3; epsilon = 0.35; break;
	case 1: score_noise = 40.0; every_n_beats = 2; epsilon = 0.20; break;
	case 2: score_noise = 20.0; every_n_beats = 2; epsilon = 0.10; break;
	default: score_noise = 0.0; every_n_beats = 1; epsilon = 0.0; break;
	}
}

void RLTrainer::update_handicap(int tier, double nn_score) {
	if (tier < 0 || tier >= 4) return;
	auto &h = handicap_hist[tier];
	h.push_back(nn_score);
	while ((int)h.size() > handicap_window) h.erase(h.begin());
	if ((int)h.size() < handicap_window / 2) return; // 样本不足不动
	double mean = 0.0;
	for (double v : h) mean += v;
	mean /= (double)h.size();
	if (mean > handicap_promote && handicap_level[tier] < 3) {
		handicap_level[tier] += 1;
		h.clear(); // 升降后重开窗口（新档位重新积累）
	} else if (mean < handicap_demote && handicap_level[tier] > 0) {
		handicap_level[tier] -= 1;
		h.clear();
	}
}

// ── checkpoint（阿尔法 JSON 契约 + v2 增量键；旧档语义不变）──

bool RLTrainer::save_checkpoint() const {
	if (!hooks.write) return false;
	auto root = Json::make(Json::OBJ);
	root->set("iteration", Json::num_of((double)iteration));
	root->set("seed", Json::num_of((double)(int64_t)global_seed));
	root->set("baseline", Json::num_of(baseline));
	auto hyper = Json::make(Json::OBJ);
	hyper->set("lr_decay", Json::num_of(lr_decay));
	hyper->set("temp_decay", Json::num_of(temp_decay));
	hyper->set("beta", Json::num_of(entropy_beta)); // v2：自适应后的当前值
	root->set("hyper", hyper);
	root->set("pool_count", Json::num_of((double)pool_count)); // v2：池滚动游标
	auto harr = Json::make(Json::ARR); // v2.2：天梯档位（续训衔接）
	for (int t = 0; t < 4; t++) harr->arr.push_back(Json::num_of((double)handicap_level[t]));
	root->set("handicap", harr);
	root->set("net", net.net_to_json());
	return hooks.write(checkpoint_path, root->dump());
}

bool RLTrainer::has_checkpoint_file() const {
	if (!hooks.read) return false;
	std::string text;
	return hooks.read(checkpoint_path, &text) && !text.empty();
}

bool RLTrainer::load_checkpoint() {
	if (!hooks.read) return false;
	std::string text;
	if (!hooks.read(checkpoint_path, &text) || text.empty()) return false;
	std::string err;
	JsonPtr root = Json::parse(text, &err);
	if (!root || root->type != Json::OBJ) return false;
	if (!net.net_from_json(root->get("net"), &err)) return false;
	iteration = root->get_int("iteration", 0);
	baseline = root->get_num("baseline", 0.0);
	// v2 增量（旧档无这些键 → 走当前默认，语义不变）：
	// β 读回自适应值（续训不重置熵维护）；pool_count 读回滚动游标。
	JsonPtr hyper = root->get("hyper");
	if (hyper && hyper->type == Json::OBJ && hyper->has("beta")) {
		double b = hyper->get_num("beta", entropy_beta);
		if (b > 0.0) entropy_beta = b;
	}
	pool_count = (long)root->get_num("pool_count", 0.0);
	// v2.2：天梯档位读回（旧档无键走默认全强度）
	JsonPtr harr = root->get("handicap");
	if (harr && harr->type == Json::ARR && (int)harr->arr.size() == 4)
		for (int t = 0; t < 4; t++)
			handicap_level[t] = (int)harr->arr[t]->num;
	load_pool();
	// 池游标兜底：主档无 pool_count 时按已装载的最大槽位推进，避免回卷覆写
	for (int s = 0; s < (int)pool_iter.size(); s++)
		if (pool_iter[s] >= 0 && pool_iter[s] + 1 > pool_count) pool_count = pool_iter[s] + 1;
	return true;
}

// ── 吞吐基准：单 episode 无梯度 ──

RLTrainer::EpisodeOut RLTrainer::run_episode_bench(uint32_t seed, bool swap, bool greedy) {
	RLTrainer tr_bench;
	// 复用本对象的 net/env（greedy 基准）
	AgentTraj a1, a2;
	a1.greedy = a2.greedy = greedy;
	a1.temp = a2.temp = 1.0;
	a1.net = a2.net = &net;
	RngPcg rng;
	rng.seed(seed);
	Matchup m = env.gen_matchup(rng);
	EnvResult res;
	play_battle(m, swap, a1, a2, &res);
	EpisodeOut o;
	o.reward_f1 = res.reward_f1;
	o.winner = res.winner;
	o.duration = res.duration;
	o.decisions = res.decisions;
	return o;
}

// ── CSV 追加（读-改-写，对齐 _append_csv_line）──

void RLTrainer::append_csv_line(const std::string &path, const std::string &header, const std::string &line) const {
	if (!hooks.read || !hooks.write) return;
	std::string body;
	std::string existing;
	if (hooks.read(path, &existing) && !existing.empty()) body = existing;
	if (body.empty()) body = header + "\n";
	body += line + "\n";
	hooks.write(path, body);
}

} // namespace rl
