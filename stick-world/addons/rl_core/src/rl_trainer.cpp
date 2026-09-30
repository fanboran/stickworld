#include "rl_trainer.h"

#include <chrono>
#include <cmath>

namespace rl {

void RLTrainer::init(uint32_t seed, const JsonPtr &config) {
	if (config && config->type == Json::OBJ) {
		env.load_config(config);
		lr = config->get_num("learning_rate", lr);
	}
	net.alloc(BattleEnv::OBS_DIM, 24, 15);
	net.init_weights(seed);
	rng.seed(seed ^ 0x3C6EF372u);
	metrics = TrainerMetrics();
	recent_returns.clear();
	recent_wins.clear();
	batch.clear();
}

double RLTrainer::run_episode(uint32_t seed, bool swap_sides, int *winner_out) {
	if (swap_sides) seed ^= 0x9E3779B9u;
	env.reset(seed);
	std::vector<double> obs_a(BattleEnv::OBS_DIM), obs_b(BattleEnv::OBS_DIM);
	std::vector<double> logits(15), probs(5);
	while (!env.done) {
		env.observe(0, obs_a);
		env.observe(1, obs_b);
		int act_a[3], act_b[3];
		net.forward(obs_a.data(), logits.data(), nullptr);
		for (int g = 0; g < 3; g++) {
			softmax5(logits.data(), g, probs.data());
			act_a[g] = sample_categorical(probs.data(), rng);
		}
		net.forward(obs_b.data(), logits.data(), nullptr);
		for (int g = 0; g < 3; g++) {
			softmax5(logits.data(), g, probs.data());
			act_b[g] = sample_categorical(probs.data(), rng);
		}
		env.step(act_a, act_b);
	}
	EnvResult res = env.result();
	if (winner_out != nullptr) *winner_out = res.winner;
	return res.reward_attacker;
}

void RLTrainer::train(long n_iterations) {
	auto t0 = std::chrono::steady_clock::now();
	std::vector<double> logits(15), probs(5);
	std::vector<double> obs_a(BattleEnv::OBS_DIM), obs_b(BattleEnv::OBS_DIM);

	long start_episodes = metrics.episodes;
	for (long it = 0; it < n_iterations; it++) {
		batch.clear();

		for (int half = 0; half < 2; half++) {
			uint32_t seed = rng.next();
			if (half == 0) {
				env.reset(seed); // 正局：攻 A / 守 B（reset 内部抽编制）
			} else {
				// 反局：同一对阵换边（攻 B / 守 A），seed 独立抽作局内抖动
				env.reset_fixed(rng.next(), env.comp_def, env.comp_att);
			}
			// 记录结构：每决策步 (obsA, actA, obsB, actB)，局末定奖励再算 advantage
			std::vector<double> obs_store;
			std::vector<int> act_store;
			while (!env.done) {
				env.observe(0, obs_a);
				env.observe(1, obs_b);
				int act_a[3], act_b[3];
				net.forward(obs_a.data(), logits.data(), nullptr);
				for (int g = 0; g < 3; g++) {
					softmax5(logits.data(), g, probs.data());
					act_a[g] = sample_categorical(probs.data(), rng);
				}
				net.forward(obs_b.data(), logits.data(), nullptr);
				for (int g = 0; g < 3; g++) {
					softmax5(logits.data(), g, probs.data());
					act_b[g] = sample_categorical(probs.data(), rng);
				}
				obs_store.insert(obs_store.end(), obs_a.begin(), obs_a.end());
				obs_store.insert(obs_store.end(), obs_b.begin(), obs_b.end());
				for (int g = 0; g < 3; g++) act_store.push_back(act_a[g]);
				for (int g = 0; g < 3; g++) act_store.push_back(act_b[g]);
				env.step(act_a, act_b);
			}
			EnvResult res = env.result();
			metrics.episodes++;
			net.baseline_count++;
			net.baseline += (res.reward_attacker - net.baseline)
					/ (double)(net.baseline_count < 100 ? net.baseline_count : 100);
			recent_returns.push_back(res.reward_attacker);
			recent_wins.push_back(res.winner);
			// 半局 = 两个 episode 记录（攻侧 + 守侧）
			int steps = (int)act_store.size() / 6;
			for (int t = 0; t < steps; t++) {
				for (int s = 0; s < 2; s++) {
					Rec rec;
					const double *o = &obs_store[(size_t)t * 2 * BattleEnv::OBS_DIM + (size_t)s * BattleEnv::OBS_DIM];
					rec.obs.assign(o, o + BattleEnv::OBS_DIM);
					for (int g = 0; g < 3; g++) rec.actions[g] = act_store[(size_t)t * 6 + (size_t)s * 3 + g];
					rec.advantage = (s == 0 ? res.reward_attacker : res.reward_defender) - net.baseline;
					batch.push_back(std::move(rec));
				}
			}
		}

		// 批均值梯度 + Adam 一步
		double n = (double)batch.size();
		for (const Rec &rec : batch)
			net.accumulate_grad(rec.obs.data(), rec.actions, rec.advantage);
		double gnorm = 0.0;
		for (double v : net.g1) gnorm += v * v;
		for (double v : net.gb1) gnorm += v * v;
		for (double v : net.g2) gnorm += v * v;
		for (double v : net.gb2) gnorm += v * v;
		metrics.grad_norm_last = std::sqrt(gnorm) / n;
		net.adam_step(lr, n);

		metrics.iterations++;
		// 滑窗指标
		if ((long)recent_returns.size() > recent_window) {
			recent_returns.erase(recent_returns.begin(), recent_returns.end() - recent_window);
			recent_wins.erase(recent_wins.begin(), recent_wins.end() - recent_window);
		}
		double sum = 0.0;
		for (double v : recent_returns) sum += v;
		metrics.mean_return_recent = sum / (double)recent_returns.size();
		double wsum = 0.0;
		for (int w : recent_wins) wsum += w == 1 ? 1.0 : (w == 0 ? 0.5 : 0.0);
		metrics.attacker_win_rate_recent = wsum / (double)recent_wins.size();
		metrics.baseline = net.baseline;
		metrics.baseline_count = net.baseline_count;

		auto t1 = std::chrono::steady_clock::now();
		metrics.elapsed_sec = std::chrono::duration<double>(t1 - t0).count();
		long eps = metrics.episodes - start_episodes;
		metrics.episodes_per_sec = metrics.elapsed_sec > 0.0 ? (double)eps / metrics.elapsed_sec : 0.0;
	}
}

JsonPtr RLTrainer::checkpoint_json() const {
	auto j = Json::make(Json::OBJ);
	j->set("format", Json::str_of("rl_core.checkpoint"));
	j->set("version", Json::num_of(1));
	j->set("net", net.to_json());
	j->set("rng_state", Json::num_of((double)rng.s));
	j->set("iterations", Json::num_of((double)metrics.iterations));
	j->set("episodes", Json::num_of((double)metrics.episodes));
	j->set("learning_rate", Json::num_of(lr));
	return j;
}

bool RLTrainer::load_checkpoint_json(const JsonPtr &j, std::string *err_out) {
	if (!j || j->type != Json::OBJ) {
		if (err_out != nullptr) *err_out = "not an object";
		return false;
	}
	if (j->get_str("format") != "rl_core.checkpoint") {
		if (err_out != nullptr) *err_out = "format mismatch";
		return false;
	}
	if (!net.from_json(j->get("net"), err_out)) return false;
	rng.s = (uint32_t)j->get_num("rng_state", (double)rng.s);
	metrics.iterations = j->get_int("iterations", 0);
	metrics.episodes = j->get_int("episodes", 0);
	lr = j->get_num("learning_rate", lr);
	metrics.baseline = net.baseline;
	metrics.baseline_count = net.baseline_count;
	return true;
}

} // namespace rl
