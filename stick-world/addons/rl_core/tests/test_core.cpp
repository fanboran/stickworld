// rl_core 纯核心测试 v2（无 Godot，直接 g++ 编译运行）
//
// 子命令：
//   test_core.exe smoke                    —— 确定性 + checkpoint 往返 + 训练冒烟
//   test_core.exe bench [episodes]         —— 吞吐（episodes/sec）
//   test_core.exe dump-fixture <seed> <out.json> [every] —— 观察对拍夹具
//   test_core.exe verify-obs <fixture> <gate_out>        —— 对拍门（状态注入，逐步 57 维）
//   test_core.exe verify-net <checkpoint> <probe_out>    —— 权重衔接（前向 logits 一致）
//
// 路径一律走 argv（源码内中文路径字面量过不了 Windows ANSI 文件 API）。

#include <cstdio>
#include <cstring>
#include <chrono>
#include <cmath>
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

// ── smoke ──

static int test_smoke() {
	int ok = 1;
	std::printf("== 确定性 ==\n");
	{
		RngPcg rng;
		rng.seed(777);
		Matchup m = rl::BattleEnv().gen_matchup(rng);
		BattleEnv e1, e2;
		e1.reset(m, false);
		e2.reset(m, false);
		std::vector<double> o1, o2;
		bool same = true;
		int act_a[3], act_b[3];
		for (int d = 0; d < 40 && !e1.done; d++) {
			for (int g = 0; g < 3; g++) {
				act_a[g] = (d + g) % 5;
				act_b[g] = (d * 2 + g * 3 + 1) % 5;
			}
			e1.step(act_a, act_b);
			e2.step(act_a, act_b);
			e1.observe(1, o1);
			e2.observe(1, o2);
			if (vec_max_diff(o1, o2, BattleEnv::OBS_DIM) > 0.0) same = false;
		}
		EnvResult r1 = e1.result(), r2 = e2.result();
		same = same && r1.winner == r2.winner && r1.decisions == r2.decisions;
		ok &= check(same, "同种子同对阵两次运行轨迹一致");
	}

	std::printf("== 训练冒烟（200 轮迭代，自 0 起）==\n");
	RLTrainer tr;
	tr.configure(nullptr);
	tr.net.alloc(57, 24, 15);
	tr.net.init_weights(20260930);
	auto t0 = std::chrono::steady_clock::now();
	tr.train(200);
	double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	{
		char buf[256];
		std::snprintf(buf, sizeof(buf), "200 轮无崩（%.2fs，%.1f episodes/s，共 %ld 局）",
				secs, 800.0 / secs, tr.iteration * 4);
		ok &= check(true, buf);
		std::snprintf(buf, sizeof(buf), "指标：mean_r=%.4f baseline=%.4f H=%.3f T=%.3f grad=%.3g",
				tr.last_record.mean_r, tr.baseline, tr.last_record.entropy,
				tr.last_record.temp, tr.last_record.grad_norm);
		std::printf("  %s\n", buf);
		ok &= check(tr.iteration == 200, "迭代计数 = 200");
		ok &= check(std::isfinite(tr.baseline), "baseline 有限");
	}
	// checkpoint 往返
	{
		std::printf("== checkpoint 往返 ==\n");
		rl::FileHooks hooks;
		std::string blob;
		hooks.read = [&](const std::string &, std::string *out) -> bool {
			*out = blob;
			return !blob.empty();
		};
		hooks.write = [&](const std::string &, const std::string &c) -> bool {
			blob = c;
			return true;
		};
		tr.hooks = hooks;
		tr.checkpoint_path = "mem://ckpt";
		ok &= check(tr.save_checkpoint(), "checkpoint 序列化");
		RLTrainer tr2;
		tr2.configure(nullptr);
		tr2.net.alloc(57, 24, 15);
		tr2.net.init_weights(999);
		tr2.hooks = hooks;
		tr2.checkpoint_path = "mem://ckpt";
		bool ld = tr2.load_checkpoint();
		ok &= check(ld, "checkpoint 读回");
		if (ld) {
			ok &= check(tr2.iteration == 200 && std::fabs(tr2.baseline - tr.baseline) < 1e-12, "迭代/baseline 一致");
			std::vector<double> x(57), l1(15), l2(15);
			for (int i = 0; i < 57; i++) x[i] = 0.1 * (i % 7) - 0.3;
			tr.net.forward(x.data(), l1.data(), nullptr);
			tr2.net.forward(x.data(), l2.data(), nullptr);
			ok &= check(vec_max_diff(l1, l2, 15) == 0.0, "往返后前向 logits 逐位一致");
			tr2.train(3);
			ok &= check(true, "恢复后继续训练 3 轮无崩");
		}
	}
	// 奖励曲线
	{
		std::printf("== 奖励曲线（重训 200 轮，每 40 轮打点）==\n");
		RLTrainer tr3;
		tr3.configure(nullptr);
		tr3.net.alloc(57, 24, 15);
		tr3.net.init_weights(7);
		for (int seg = 0; seg < 5; seg++) {
			tr3.train(40);
			std::printf("  iter %4d: mean_r=%+.4f baseline=%+.4f H=%.3f T=%.3f\n",
					tr3.iteration, tr3.last_record.mean_r, tr3.baseline,
					tr3.last_record.entropy, tr3.last_record.temp);
		}
		ok &= check(std::isfinite(tr3.baseline), "奖励曲线数值有限");
	}
	// 评估对手通路
	{
		std::printf("== 评估对手通路 ==\n");
		RLTrainer tr4;
		tr4.configure(nullptr);
		tr4.net.alloc(57, 24, 15);
		tr4.net.init_weights(1);
		EvalRecord er = tr4.run_evaluation();
		char buf[160];
		std::snprintf(buf, sizeof(buf), "评估 6 场无崩：score=%.1f win_rate=%.2f", er.score, er.win_rate);
		ok &= check(er.games == 6, buf);
	}
	std::printf("smoke %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

// ── bench ──

static int test_bench(int episodes) {
	RLTrainer tr;
	tr.configure(nullptr);
	tr.net.alloc(57, 24, 15);
	tr.net.init_weights(1);
	tr.run_episode_bench(1, false, false);
	tr.run_episode_bench(2, false, false);
	auto t0 = std::chrono::steady_clock::now();
	double acc = 0;
	for (int i = 0; i < episodes; i++) {
		acc += tr.run_episode_bench((uint32_t)(100 + i), i % 2 == 1, false).reward_f1;
	}
	double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
	std::printf("[C++] episodes=%d 耗时=%.3fs episodes/sec=%.2f 平均奖励=%.4f\n",
			episodes, secs, episodes / secs, acc / episodes);
	return 0;
}

// ── dump-fixture ──

static int dump_fixture(uint32_t seed, const std::string &out_path, int every) {
	BattleEnv env;
	rl::JsonPtr j = env.dump_obs_fixture(seed, every, 40);
	std::ofstream f(out_path, std::ios::binary);
	if (!f) {
		std::printf("FAIL 无法写 %s\n", out_path.c_str());
		return 1;
	}
	f << j->dump();
	f.close();
	std::printf("[fixture] 写出 %s（frames=%zu）\n", out_path.c_str(), j->get("frames")->arr.size());
	return 0;
}

// ── verify-obs ──

static int verify_obs(const std::string &fixture_path, const std::string &gate_path) {
	auto fixture = Json::parse(read_file(fixture_path), nullptr);
	auto gate = Json::parse(read_file(gate_path), nullptr);
	if (!fixture || !gate) {
		std::printf("FAIL fixture/gate 解析失败\n");
		return 1;
	}
	JsonPtr frames = fixture->get("frames");
	JsonPtr gframes = gate->get("frames");
	if (!frames || !gframes || frames->arr.size() != gframes->arr.size()) {
		std::printf("FAIL 帧数不一致（fixture=%zu gate=%zu）\n",
				frames ? frames->arr.size() : 0, gframes ? gframes->arr.size() : 0);
		return 1;
	}
	double worst1 = 0.0, worst2 = 0.0;
	for (size_t i = 0; i < frames->arr.size(); i++) {
		JsonPtr fr = frames->arr[i];
		JsonPtr gf = gframes->arr[i];
		JsonPtr cf1 = fr->get("obs_f1"), cf2 = fr->get("obs_f2");
		JsonPtr gf1 = gf->get("obs_f1"), gf2 = gf->get("obs_f2");
		if (!cf1 || !gf1 || !cf2 || !gf2) {
			std::printf("FAIL 第 %zu 帧缺 obs 字段\n", i);
			return 1;
		}
		for (int k = 0; k < BattleEnv::OBS_DIM; k++) {
			double d1 = std::fabs(cf1->arr[k]->num - gf1->arr[k]->num);
			double d2 = std::fabs(cf2->arr[k]->num - gf2->arr[k]->num);
			if (d1 > worst1) worst1 = d1;
			if (d2 > worst2) worst2 = d2;
		}
	}
	char buf[160];
	std::snprintf(buf, sizeof(buf), "观察对拍 %zu 帧 × 双视角：F1 max|Δ|=%.3g F2 max|Δ|=%.3g（门 1e-6）",
			frames->arr.size(), worst1, worst2);
	bool ok = check(worst1 <= 1e-6 && worst2 <= 1e-6, buf);
	// 观察值域 sanity：全部落在 [-1,1]
	bool in_range = true;
	for (size_t i = 0; i < frames->arr.size(); i++) {
		for (auto key : { "obs_f1", "obs_f2" }) {
			JsonPtr c = frames->arr[i]->get(key);
			for (auto &v : c->arr)
				if (v->num < -1.0000001 || v->num > 1.0000001) in_range = false;
		}
	}
	ok &= check(in_range, "观察值域 ⊆ [-1,1]");
	std::printf("verify-obs %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

// ── verify-net（权重衔接）──

static int verify_net(const std::string &ckpt_path, const std::string &probe_path) {
	auto probe = Json::parse(read_file(probe_path), nullptr);
	if (!probe) {
		std::printf("FAIL probe 解析失败\n");
		return 1;
	}
	RLNet net;
	std::string err;
	JsonPtr net_obj = probe->get("net");
	if (!net.net_from_json(net_obj, &err)) {
		std::printf("FAIL checkpoint 装载失败：%s\n", err.c_str());
		return 1;
	}
	JsonPtr probes = probe->get("probes");
	double worst = 0.0;
	int n = 0;
	for (auto &p : probes->arr) {
		std::vector<double> x, lg(15);
		for (auto &v : p->get("obs")->arr) x.push_back(v->num);
		net.forward(x.data(), lg.data(), nullptr);
		JsonPtr want = p->get("logits");
		for (int k = 0; k < 15; k++) {
			double dd = std::fabs(lg[k] - want->arr[k]->num);
			if (dd > worst) worst = dd;
		}
		n++;
	}
	char buf[160];
	std::snprintf(buf, sizeof(buf), "权重衔接：checkpoint 装载 + % 组观察前向 logits max|Δ|=%.3g（门 1e-3）", n, worst);
	bool ok = check(worst <= 1e-3, buf);
	std::printf("verify-net %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

int main(int argc, char **argv) {
	if (argc >= 2 && std::strcmp(argv[1], "smoke") == 0) return test_smoke();
	if (argc >= 2 && std::strcmp(argv[1], "bench") == 0)
		return test_bench(argc >= 3 ? std::atoi(argv[2]) : 20);
	if (argc >= 4 && std::strcmp(argv[1], "dump-fixture") == 0)
		return dump_fixture((uint32_t)std::strtoul(argv[2], nullptr, 10), argv[3], argc >= 5 ? std::atoi(argv[4]) : 5);
	if (argc >= 4 && std::strcmp(argv[1], "verify-obs") == 0) return verify_obs(argv[2], argv[3]);
	if (argc >= 4 && std::strcmp(argv[1], "verify-net") == 0) return verify_net(argv[2], argv[3]);
	std::printf("用法: test_core.exe smoke | bench [n] | dump-fixture <seed> <out> [every] | verify-obs <f> <g> | verify-net <ckpt> <probe>\n");
	return 2;
}
