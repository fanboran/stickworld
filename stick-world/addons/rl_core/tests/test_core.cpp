// rl_core 纯核心测试（无 Godot，直接 g++ 编译运行）
//
// 用法：
//   test_core.exe smoke                 —— 确定性 + checkpoint 往返 + 训练冒烟（200 轮）
//   test_core.exe bench [episodes]      —— 吞吐：episodes/sec（默认 20）
//   test_core.exe verify <dump.json>    —— 对拍门：回放 GDScript 镜像 dump，逐步对齐
//
// 对拍判定（verify）：
//   comp 抽样一致（int）、初始/逐步观察 max|Δ| ≤ 1e-6、结果奖励 |Δ| ≤ 1e-6、
//   网络前向 logits max|Δ| ≤ 1e-6（GDScript 与 C++ 的 exp/sqrt 可能差 1 ULP，
//   不做逐位相等，做容差相等）。

#include <cstdio>
#include <cstring>
#include <chrono>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>

#include "../src/rl_net.h"
#include "../src/rl_env.h"
#include "../src/rl_trainer.h"

using namespace rl;

static std::string read_file(const std::string &path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) return "";
	std::stringstream ss;
	ss << f.rdbuf();
	return ss.str();
}

static bool check(bool ok, const char *what) {
	std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
	return ok;
}

static double vec_max_diff(const std::vector<double> &a, const std::vector<double> &b, size_t count) {
	double m = 0.0;
	for (size_t i = 0; i < count && i < a.size() && i < b.size(); i++) {
		double d = std::fabs(a[i] - b[i]);
		if (d > m) m = d;
	}
	return m;
}

static int test_verify(const std::string &path) {
	std::string text = read_file(path);
	if (text.empty()) {
		std::printf("FAIL 无法读取 dump: %s\n", path.c_str());
		return 1;
	}
	std::string err;
	JsonPtr dump = Json::parse(text, &err);
	if (!dump) {
		std::printf("FAIL dump 解析失败: %s\n", err.c_str());
		return 1;
	}
	uint32_t seed = (uint32_t)dump->get_int("seed", 0);
	JsonPtr comp_a = dump->get("comp_attacker");
	JsonPtr comp_b = dump->get("comp_defender");

	BattleEnv env;
	env.reset_fixed(seed,
			{ comp_a->get_int("spear", 8), comp_a->get_int("sword", 4),
					comp_a->get_int("staff", 1), comp_a->get_int("bow", 3) },
			{ comp_b->get_int("spear", 8), comp_b->get_int("sword", 4),
					comp_b->get_int("staff", 1), comp_b->get_int("bow", 3) });

	std::vector<double> obs, want;
	int all_ok = 1;

	// 编制对齐
	all_ok &= check(
			env.comp_att.spear == comp_a->get_int("spear", -1) && env.comp_att.sword == comp_a->get_int("sword", -1)
					&& env.comp_att.staff == comp_a->get_int("staff", -1) && env.comp_att.bow == comp_a->get_int("bow", -1)
					&& env.comp_def.spear == comp_b->get_int("spear", -1) && env.comp_def.sword == comp_b->get_int("sword", -1)
					&& env.comp_def.staff == comp_b->get_int("staff", -1) && env.comp_def.bow == comp_b->get_int("bow", -1),
			"编制抽样一致（同种子同 RNG 序列）");

	// 初始观察
	env.observe(0, obs);
	JsonPtr want_obs = dump->get("initial_obs_attacker");
	want.clear();
	for (auto &v : want_obs->arr) want.push_back(v->num);
	{
		double md = vec_max_diff(obs, want, obs.size());
		char buf[128];
		std::snprintf(buf, sizeof(buf), "初始观察(攻方视角) max|Δ|=%.3g ≤ 1e-6", md);
		all_ok &= check(md <= 1e-6, buf);
	}
	env.observe(1, obs);
	want_obs = dump->get("initial_obs_defender");
	want.clear();
	for (auto &v : want_obs->arr) want.push_back(v->num);
	{
		double md = vec_max_diff(obs, want, obs.size());
		char buf[128];
		std::snprintf(buf, sizeof(buf), "初始观察(守方视角) max|Δ|=%.3g ≤ 1e-6", md);
		all_ok &= check(md <= 1e-6, buf);
	}

	// 逐步决策对齐（镜像侧用固定意图循环表，C++ 同表回放）
	JsonPtr decisions = dump->get("decisions");
	std::vector<double> obsA(BattleEnv::OBS_DIM), obsB(BattleEnv::OBS_DIM);
	double worst = 0.0;
	int steps_cmp = 0;
	for (int d = 0; d < (int)decisions->arr.size(); d++) {
		JsonPtr rec = decisions->arr[d];
		int a_att[3], a_def[3];
		for (int g = 0; g < 3; g++) {
			a_att[g] = rec->get("actions_attacker")->arr[g]->num;
			a_def[g] = rec->get("actions_defender")->arr[g]->num;
		}
		env.step(a_att, a_def);
		if (env.done) break;
		env.observe(0, obsA);
		env.observe(1, obsB);
		JsonPtr ra = rec->get("obs_attacker");
		JsonPtr rb = rec->get("obs_defender");
		for (int i = 0; i < BattleEnv::OBS_DIM; i++) {
			double da = std::fabs(obsA[i] - ra->arr[i]->num);
			double db = std::fabs(obsB[i] - rb->arr[i]->num);
			if (da > worst) worst = da;
			if (db > worst) worst = db;
		}
		steps_cmp++;
	}
	{
		char buf[128];
		std::snprintf(buf, sizeof(buf), "逐步观察对齐 %d 步 max|Δ|=%.3g ≤ 1e-6", steps_cmp, worst);
		all_ok &= check(worst <= 1e-6, buf);
	}

	// 结果对齐
	JsonPtr res_j = dump->get("result");
	EnvResult res = env.result();
	{
		double md = std::fabs(res.reward_attacker - res_j->get_num("reward_attacker", 0));
		char buf[160];
		std::snprintf(buf, sizeof(buf), "终局奖励对齐 |Δ|=%.3g ≤ 1e-6（winner %d/%d 决策数 %d/%d）",
				md, res.winner, (int)res_j->get_num("winner", -1), res.decisions, (int)res_j->get_num("decisions", -1));
		bool ok = md <= 1e-6 && res.winner == (int)res_j->get_num("winner", -1)
				&& res.decisions == (int)res_j->get_num("decisions", -1);
		all_ok &= check(ok, buf);
	}
	all_ok &= check(std::fabs(res.reward_attacker + res.reward_defender) < 1e-12, "奖励零和（R攻+R守=0）");

	// 网络前向对齐（同一批观察喂两版网络）
	RLNet net;
	net.alloc(BattleEnv::OBS_DIM, 24, 15);
	net.init_weights(20260930u);
	JsonPtr probes = dump->get("net_probes");
	double worst_l = 0.0;
	for (auto &p : probes->arr) {
		std::vector<double> x, lg(15);
		for (auto &v : p->get("obs")->arr) x.push_back(v->num);
		net.forward(x.data(), lg.data(), nullptr);
		JsonPtr want_lg = p->get("logits");
		for (int i = 0; i < 15; i++) {
			double dd = std::fabs(lg[i] - want_lg->arr[i]->num);
			if (dd > worst_l) worst_l = dd;
		}
	}
	{
		char buf[128];
		std::snprintf(buf, sizeof(buf), "网络前向 logits max|Δ|=%.3g ≤ 1e-6", worst_l);
		all_ok &= check(worst_l <= 1e-6, buf);
	}

	std::printf("verify %s： %s\n", path.c_str(), all_ok ? "ALL PASS" : "HAS FAILURES");
	return all_ok ? 0 : 1;
}

static int test_smoke() {
	int ok = 1;
	std::printf("== 确定性 ==\n");
	{
		BattleEnv e1, e2;
		e1.reset(777);
		e2.reset(777);
		std::vector<double> o1(47), o2(47);
		bool same = true;
		int act_a[3] = { 0, 1, 2 }, act_b[3] = { 4, 3, 4 };
		for (int d = 0; d < 40 && !e1.done; d++) {
			e1.step(act_a, act_b);
			e2.step(act_a, act_b);
			e1.observe(0, o1);
			e2.observe(0, o2);
			if (vec_max_diff(o1, o2, 47) > 0.0) same = false;
			act_a[0] = (act_a[0] + 1) % 5;
			act_b[1] = (act_b[1] + 1) % 5;
		}
		EnvResult r1 = e1.result(), r2 = e2.result();
		same = same && r1.winner == r2.winner && r1.decisions == r2.decisions
				&& std::fabs(r1.reward_attacker - r2.reward_attacker) == 0.0;
		ok &= check(same, "同种子两次运行轨迹逐位一致");
		e1.reset(778);
		e2.reset(779);
		e1.step(act_a, act_b);
		e2.step(act_a, act_b);
		e1.observe(0, o1);
		e2.observe(0, o2);
		ok &= check(vec_max_diff(o1, o2, 47) > 0.0, "不同种子轨迹分叉（RNG 生效）");
	}

	std::printf("== 训练冒烟（200 轮迭代）==\n");
	RLTrainer tr;
	tr.init(42, nullptr);
	auto t0 = std::chrono::steady_clock::now();
	tr.train(200);
	double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	{
		char buf[256];
		std::snprintf(buf, sizeof(buf), "200 轮无崩（%.2fs，%.1f episodes/s，共 %ld 局）",
				secs, tr.metrics.episodes_per_sec, tr.metrics.episodes);
		ok &= check(true, buf);
		std::snprintf(buf, sizeof(buf), "指标：mean_return_recent=%.4f attacker_win_rate=%.3f baseline=%.4f grad_norm=%.3g",
				tr.metrics.mean_return_recent, tr.metrics.attacker_win_rate_recent,
				tr.metrics.baseline, tr.metrics.grad_norm_last);
		std::printf("  %s\n", buf);
		ok &= check(tr.metrics.episodes == 400, "episode 计数 = 200×2（正反局）");
		ok &= check(tr.metrics.grad_norm_last >= 0.0 && std::isfinite(tr.metrics.grad_norm_last), "梯度范数有限");
	}
	// checkpoint 往返
	{
		std::printf("== checkpoint 往返 ==\n");
		JsonPtr cp = tr.checkpoint_json();
		std::string s1 = cp->dump();
		std::string err;
		JsonPtr back = Json::parse(s1, &err);
		RLTrainer tr2;
		tr2.init(999, nullptr); // 不同初始状态
		bool ld = tr2.load_checkpoint_json(back, &err);
		ok &= check(ld, "checkpoint 读回成功");
		if (ld) {
			std::string s2 = tr2.checkpoint_json()->dump();
			ok &= check(s1 == s2, "存→读→存 字节级一致");
			// 权重逐位一致 + 前向一致
			std::vector<double> x(47, 0.3), l1(15), l2(15);
			for (int i = 0; i < 47; i++) x[i] = 0.1 * (i % 7) - 0.3;
			tr.net.forward(x.data(), l1.data(), nullptr);
			tr2.net.forward(x.data(), l2.data(), nullptr);
			ok &= check(vec_max_diff(l1, l2, 15) == 0.0, "往返后前向 logits 逐位一致");
			// 恢复后继续训练不崩
			tr2.train(3);
			ok &= check(true, "恢复后继续训练 3 轮无崩");
		}
	}
	// 奖励曲线抽样（每 40 轮打印）
	{
		std::printf("== 奖励曲线（重训 200 轮，每 40 轮打点）==\n");
		RLTrainer tr3;
		tr3.init(7, nullptr);
		for (int seg = 0; seg < 5; seg++) {
			tr3.train(40);
			std::printf("  iter %3d: mean_return_recent=%+.4f win_rate(攻)=%.3f baseline=%+.4f\n",
					(seg + 1) * 40, tr3.metrics.mean_return_recent,
					tr3.metrics.attacker_win_rate_recent, tr3.metrics.baseline);
		}
		ok &= check(std::isfinite(tr3.metrics.mean_return_recent), "奖励曲线数值有限");
	}
	std::printf("smoke %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

static int test_bench(int episodes) {
	RLTrainer tr;
	tr.init(1, nullptr);
	// 预热 2 局（页/缓存）
	tr.run_episode(1, false, nullptr);
	tr.run_episode(2, false, nullptr);
	auto t0 = std::chrono::steady_clock::now();
	double ret_acc = 0.0;
	for (int i = 0; i < episodes; i++) {
		ret_acc += tr.run_episode((uint32_t)(100 + i), i % 2 == 1, nullptr);
	}
	double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	std::printf("[C++] episodes=%d 耗时=%.3fs episodes/sec=%.2f 平均奖励=%.4f\n",
			episodes, secs, episodes / secs, ret_acc / episodes);
	// GDScript 镜像按同口径出数，倍率在对拍报告里算
	return 0;
}

int main(int argc, char **argv) {
	if (argc >= 2 && std::strcmp(argv[1], "smoke") == 0) return test_smoke();
	if (argc >= 2 && std::strcmp(argv[1], "bench") == 0)
		return test_bench(argc >= 3 ? std::atoi(argv[2]) : 20);
	if (argc >= 3 && std::strcmp(argv[1], "verify") == 0) return test_verify(argv[2]);
	std::printf("用法: test_core.exe smoke | bench [n] | verify <dump.json>\n");
	return 2;
}
