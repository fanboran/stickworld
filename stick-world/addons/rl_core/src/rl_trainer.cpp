#include "rl_trainer.h"

#include <chrono>
#include <cmath>

namespace rl {

void RLTrainer::configure(const JsonPtr &config) {
	if (!config || config->type != Json::OBJ) return;
	lr_start = config->get_num("lr_start", lr_start);
	lr_decay = config->get_num("lr_decay", lr_decay);
	lr_floor = config->get_num("lr_floor", lr_floor);
	grad_clip = config->get_num("grad_clip", grad_clip);
	entropy_beta = config->get_num("entropy_beta", entropy_beta);
	temp_start = config->get_num("temp_start", temp_start);
	temp_decay = config->get_num("temp_decay", temp_decay);
	temp_min = config->get_num("temp_min", temp_min);
	baseline_ema = config->get_num("baseline_ema", baseline_ema);
	checkpoint_every = config->get_int("checkpoint_every", (int)checkpoint_every);
	eval_every = config->get_int("eval_every", (int)eval_every);
	eval_groups = config->get_int("eval_groups", eval_groups);
	global_seed = (uint64_t)(int64_t)config->get_num("global_seed", (double)(int64_t)global_seed);
	if (config->has("env")) env.load_config(config->get("env"));
}

void RLTrainer::apply_checkpoint_state(long iter, double base) {
	iteration = iter;
	baseline = base;
}

// ── 一场（正局/反局；两个指挥视角轨迹）──

void RLTrainer::play_battle(const Matchup &m, bool swap, AgentTraj &ag1, AgentTraj &ag2,
		EnvResult *res_out) {
	env.reset(m, swap);
	std::vector<double> obs;
	int mask1[3], mask2[3], acts1[3], acts2[3];
	double logits[15];
	while (!env.done) {
		// faction 1
		env.active_mask(1, mask1);
		env.observe(1, obs);
		net.forward(obs.data(), logits, nullptr);
		if (ag1.greedy) {
			net.greedy_actions(logits, mask1, acts1);
		} else {
			double lp, ent;
			int na;
			net.sample_actions(logits, ag1.temp, mask1, ag1.rng, acts1, &lp, &ent, &na);
			ag1.entropy_sum += ent;
			ag1.entropy_beats++;
			TrajStep st;
			st.obs = obs;
			for (int k = 0; k < 3; k++) {
				st.actions[k] = acts1[k];
				st.mask[k] = mask1[k];
			}
			ag1.steps.push_back(std::move(st));
		}
		// faction 2
		env.active_mask(2, mask2);
		env.observe(2, obs);
		net.forward(obs.data(), logits, nullptr);
		if (ag2.greedy) {
			net.greedy_actions(logits, mask2, acts2);
		} else {
			double lp, ent;
			int na;
			net.sample_actions(logits, ag2.temp, mask2, ag2.rng, acts2, &lp, &ent, &na);
			ag2.entropy_sum += ent;
			ag2.entropy_beats++;
			TrajStep st;
			st.obs = obs;
			for (int k = 0; k < 3; k++) {
				st.actions[k] = acts2[k];
				st.mask[k] = mask2[k];
			}
			ag2.steps.push_back(std::move(st));
		}
		env.step(acts1, acts2);
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
	std::vector<double> obs_f(57), logits(15), probs(5), dlogits(15);
	for (size_t ei = 0; ei < n_ep; ei++) {
		double adv = (raw[ei] - mean) / (stdv > 1e-4 ? stdv : 1e-4);
		for (const TrajStep &st : agents[ei]->steps) {
			net.forward(st.obs.data(), logits.data(), nullptr);
			dlogits.assign(15, 0.0);
			for (int s = 0; s < 3; s++) {
				if (st.mask[s] == 0) continue;
				net.softmax_slice(logits.data(), s, temp, probs.data());
				double h = entropy5(probs.data());
				int base = s * 5;
				for (int a = 0; a < 5; a++) {
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
		Matchup m = env.gen_matchup(rng);
		double temp = temp_start * std::pow(temp_decay, (double)iteration);
		if (temp < temp_min) temp = temp_min;
		// 正局：a 攻西 / b 守东；反局整体交换（每局独立建 agent，独立子 RNG）
		auto make_agent = [&](AgentTraj &ag) {
			ag.steps.clear();
			ag.entropy_sum = 0.0;
			ag.entropy_beats = 0;
			ag.greedy = false;
			ag.temp = temp;
			ag.rng.seed(rng.next());
		};
		for (int i = 0; i < 4; i++) make_agent(ag[i]);
		int w1 = 0, w2 = 0;
		double d1 = 0, d2 = 0;
		EnvResult r1, r2;
		play_battle(m, false, ag[0], ag[1], &r1);
		play_battle(m, true, ag[2], ag[3], &r2);
		w1 = r1.winner;
		w2 = r2.winner;
		d1 = r1.duration;
		d2 = r2.duration;
		std::vector<AgentTraj *> agents = { &ag[0], &ag[1], &ag[2], &ag[3] };
		double grad_norm = train_batch({ r1.reward_f1, r1.reward_f2, r2.reward_f1, r2.reward_f2 }, agents, temp);
		// 记录
		IterRecord rec;
		rec.iter = iteration;
		rec.rewards[0] = r1.reward_f1;
		rec.rewards[1] = r1.reward_f2;
		rec.rewards[2] = r2.reward_f1;
		rec.rewards[3] = r2.reward_f2;
		rec.mean_r = (rec.rewards[0] + rec.rewards[1] + rec.rewards[2] + rec.rewards[3]) / 4.0;
		rec.baseline = baseline;
		double ent_sum = 0;
		int ent_beats = 0;
		for (auto *a : agents) {
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
		rec.n_a = m.side_a.n_total;
		rec.n_b = m.side_b.n_total;
		// baseline EMA（4 视角均值）
		baseline += baseline_ema * (rec.mean_r - baseline);
		rec.baseline = baseline;
		iteration += 1;
		auto t1 = std::chrono::steady_clock::now();
		rec.wall_s = std::chrono::duration<double>(t1 - t0).count();
		last_record = rec;
		// CSV 追加（格式对齐 _log_iteration）
		if (!train_csv_path.empty() && hooks.write) {
			char line[512];
			std::snprintf(line, sizeof(line),
					"%ld,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%d,%d,%.1f,%.1f,%.4f,%.1f",
					rec.iter, rec.rewards[0], rec.rewards[1], rec.rewards[2], rec.rewards[3],
					rec.mean_r, rec.baseline, rec.entropy, rec.temp,
					rec.winner_g1, rec.winner_g2, rec.dur_g1, rec.dur_g2, rec.grad_norm, rec.wall_s);
			append_csv_line(train_csv_path,
					"iter,r_f1_g1,r_f2_g1,r_f1_g2,r_f2_g2,mean_r,baseline,entropy,temp,"
					"winner_g1,winner_g2,dur_g1,dur_g2,grad_norm,wall_s",
					line);
		}
		if (on_iteration) on_iteration(rec);
		if (checkpoint_every > 0 && iteration % checkpoint_every == 0 && !checkpoint_path.empty()) {
			save_checkpoint();
		}
		if (eval_every > 0 && iteration % eval_every == 0) {
			EvalRecord er = run_evaluation();
			if (on_evaluation) on_evaluation(er);
		}
	}
}

// ── 评估（NN greedy vs 军师规划器镜像；协议对齐 _run_evaluation）──

EvalRecord RLTrainer::run_evaluation() {
	EvalRecord er;
	er.iter = iteration;
	RngPcg rng;
	rng.seed(hash_djb2(std::to_string(global_seed) + "|eval|" + std::to_string(iteration)));
	double score = 0.0;
	AgentTraj nn_agent;
	for (int g = 0; g < eval_groups; g++) {
		int nn_faction = (g % 2 == 0) ? 1 : 2;
		Matchup m = env.gen_matchup(rng);
		for (int swap_i = 0; swap_i < 2; swap_i++) {
			bool swap = swap_i == 1;
			nn_agent.steps.clear();
			nn_agent.greedy = true;
			nn_agent.temp = 1.0;
			// NN 在 nn_faction；对侧 = 规划器（env.step 时由本类产规划器意图）
			env.reset(m, swap);
			while (!env.done) {
				int mask1[3], mask2[3], acts1[3], acts2[3];
				double logits[15];
				std::vector<double> obs;
				env.active_mask(1, mask1);
				env.observe(1, obs);
				net.forward(obs.data(), logits, nullptr);
				if (nn_faction == 1) net.greedy_actions(logits, mask1, acts1);
				else net.greedy_actions(logits, mask1, acts1);
				env.active_mask(2, mask2);
				env.observe(2, obs);
				net.forward(obs.data(), logits, nullptr);
				if (nn_faction == 2) net.greedy_actions(logits, mask2, acts2);
				else net.greedy_actions(logits, mask2, acts2);
				// 对侧 = 军师规划器意图
				if (nn_faction == 1) env.planner_intents(2, acts2);
				else env.planner_intents(1, acts1);
				env.step(acts1, acts2);
			}
			EnvResult res = env.result();
			double s = 0.5;
			if (res.winner == nn_faction) s = 1.0;
			else if (res.winner == 3 - nn_faction) s = 0.0;
			score += s;
			er.games++;
			er.detail.push_back(s);
		}
	}
	er.score = score;
	er.win_rate = er.games > 0 ? score / (double)er.games : 0.0;
	if (!eval_csv_path.empty() && hooks.write) {
		std::string det = "[";
		for (size_t i = 0; i < er.detail.size(); i++) {
			double v = er.detail[i];
			if (i > 0) det += ", ";
			det += v == 0.5 ? "0.5" : (v == 1.0 ? "1" : "0");
		}
		det += "]";
		char line[128];
		std::snprintf(line, sizeof(line), "%ld,%d,%.1f,%.4f,%s",
				er.iter, er.games, er.score, er.win_rate, det.c_str());
		append_csv_line(eval_csv_path, "iter,games,score,win_rate,detail", line);
	}
	return er;
}

// ── checkpoint（阿尔法 JSON 契约）──

bool RLTrainer::save_checkpoint() const {
	if (!hooks.write) return false;
	auto root = Json::make(Json::OBJ);
	root->set("iteration", Json::num_of((double)iteration));
	root->set("seed", Json::num_of((double)(int64_t)global_seed));
	root->set("baseline", Json::num_of(baseline));
	auto hyper = Json::make(Json::OBJ);
	hyper->set("lr_decay", Json::num_of(lr_decay));
	hyper->set("temp_decay", Json::num_of(temp_decay));
	hyper->set("beta", Json::num_of(entropy_beta));
	root->set("hyper", hyper);
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
	return true;
}

// ── 吞吐基准：单 episode 无梯度 ──

RLTrainer::EpisodeOut RLTrainer::run_episode_bench(uint32_t seed, bool swap, bool greedy) {
	RLTrainer tr_bench;
	// 复用本对象的 net/env（greedy 基准）
	AgentTraj a1, a2;
	a1.greedy = a2.greedy = greedy;
	a1.temp = a2.temp = 1.0;
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
