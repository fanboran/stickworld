// rl_core 纯核心测试 v2 定稿（无 Godot，直接 g++ 编译运行）
//
// 子命令：
//   test_core.exe smoke                    —— 确定性 + checkpoint 往返 + 训练冒烟 + 零和
//   test_core.exe mirror [games/tier]      —— 镜像不变式：17/49/97 档各 N 局同策略
//                                             greedy 自博弈，胜率 ≈ 50%（真镜像对称）
//   test_core.exe decap                    —— 斩首路径冒烟（指挥官被端 → 立即判负）
//   test_core.exe bench [episodes]         —— 吞吐（episodes/sec）
//   test_core.exe dump-fixture <seed> <out.json> [every] —— 观察对拍夹具（v3 格式）
//   test_core.exe verify-obs <fixture> <gate_out>        —— 对拍门（状态注入，逐步 125 维）
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

static const int NET_IN = 125, NET_HID = 64, NET_OUT = 40;

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
	std::printf("== 确定性（17 档 + 97 档）==\n");
	{
		for (int tier = 0; tier <= 2; tier += 2) {
			RngPcg rng;
			rng.seed(777);
			BattleEnv env0;
			env0.eval_lock_tier = tier;
			Matchup m = env0.gen_matchup(rng);
			BattleEnv e1, e2;
			e1.eval_lock_tier = tier;
			e2.eval_lock_tier = tier;
			e1.reset(m, false);
			e2.reset(m, false);
			std::vector<double> o1, o2;
			bool same = true;
			int act_a[BattleEnv::N_SQUADS], act_b[BattleEnv::N_SQUADS];
			for (int d = 0; d < 40 && !e1.done; d++) {
				for (int g = 0; g < BattleEnv::N_SQUADS; g++) {
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
			char buf[80];
			std::snprintf(buf, sizeof(buf), "同种子同对阵两次运行轨迹一致（%d 档）", ARMY_TIERS[tier]);
			ok &= check(same, buf);
		}
	}

	std::printf("== 观察规格 ==\n");
	{
		BattleEnv env;
		RngPcg rng;
		rng.seed(1);
		env.eval_lock_tier = 0; // 17 档
		Matchup m = env.gen_matchup(rng);
		env.reset(m, false);
		std::vector<double> o;
		env.observe(1, o);
		ok &= check((int)o.size() == 125, "观察维度 = 125");
		ok &= check(env.n_squads == 2 && env.n_platoons == 1 && env.side_init[0] == 16,
				"17 档编制：2 班 / 1 排 / 16 兵");
		int cmd1 = env.find_commander(1), cmd2 = env.find_commander(2);
		bool cmd_ok = cmd1 >= 0 && cmd2 >= 0 && env.units[cmd1].rank == 3 && env.units[cmd1].is_commander
				&& std::fabs(env.units[cmd1].x + env.cfg.commander_x) < 1e-9
				&& std::fabs(env.units[cmd2].x - env.cfg.commander_x) < 1e-9;
		ok &= check(cmd_ok, "指挥官出生 ±1780 后方，rank3");
		// 军衔：17 档班0 班首 = 排长(rank2)，班1 班首 = 班长(rank1)
		ok &= check(env.units[0].rank == 2 && env.units[8].rank == 1, "军衔：排首班首=排长 rank2 / 次班班首=班长 rank1");
		// 指挥官不入存活计数
		ok &= check(env.side_init[0] == 16 && env.side_init[1] == 16, "存活计数不含指挥官");
	}

	std::printf("== 训练冒烟（200 轮迭代，自 0 起）==\n");
	RLTrainer tr;
	tr.configure(nullptr);
	tr.net.alloc(NET_IN, NET_HID, NET_OUT);
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
		ok &= check(std::fabs(tr.last_record.rewards[0] + tr.last_record.rewards[1]) < 1e-9
						&& std::fabs(tr.last_record.rewards[2] + tr.last_record.rewards[3]) < 1e-9,
				"奖励零和（同局双方视角 r_f1 + r_f2 = 0）");
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
		tr2.net.alloc(NET_IN, NET_HID, NET_OUT);
		tr2.net.init_weights(999);
		tr2.hooks = hooks;
		tr2.checkpoint_path = "mem://ckpt";
		bool ld = tr2.load_checkpoint();
		ok &= check(ld, "checkpoint 读回");
		if (ld) {
			ok &= check(tr2.iteration == 200 && std::fabs(tr2.baseline - tr.baseline) < 1e-12, "迭代/baseline 一致");
			std::vector<double> x(NET_IN), l1(NET_OUT), l2(NET_OUT);
			for (int i = 0; i < NET_IN; i++) x[i] = 0.1 * (i % 7) - 0.3;
			tr.net.forward(x.data(), l1.data(), nullptr);
			tr2.net.forward(x.data(), l2.data(), nullptr);
			ok &= check(vec_max_diff(l1, l2, NET_OUT) == 0.0, "往返后前向 logits 逐位一致");
			tr2.train(3);
			ok &= check(true, "恢复后继续训练 3 轮无崩");
		}
	}
	// 评估对手通路（含混对手评估：军师镜像组 + 池组[空则跳过]）
	{
		std::printf("== 评估对手通路 ==\n");
		RLTrainer tr4;
		tr4.configure(nullptr);
		tr4.net.alloc(NET_IN, NET_HID, NET_OUT);
		tr4.net.init_weights(1);
		EvalRecord er = tr4.run_evaluation();
		char buf[160];
		std::snprintf(buf, sizeof(buf), "评估 6 场无崩：score=%.1f win_rate=%.2f", er.score, er.win_rate);
		ok &= check(er.games == 6, buf);
	}
	std::printf("smoke %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

// ── 镜像不变式：真镜像 + 同策略 greedy 自博弈 → 胜率 ≈ 50% ──
// 真镜像下双方观察点对称、同网络 → 动作对称 → 演化保持点对称：理想输出是
// 全平局（125s 超时存活相等）；任何一边倒都是对称性破损信号。

static int test_mirror(int games_per_tier) {
	int ok = 1;
	RLNet net;
	net.alloc(NET_IN, NET_HID, NET_OUT);
	net.init_weights(20260930);
	const int NS = BattleEnv::N_SQUADS;
	int mask1[NS], mask2[NS], acts1[NS], acts2[NS];
	double logits[BattleEnv::N_ACTIONS];
	std::vector<double> obs;
	for (int tier = 0; tier < 4; tier++) { // 0..3 含 tier3 8班小队档（8 头全激活的最强对称检验）
		BattleEnv env;
		env.eval_lock_tier = tier;
		double score = 0.0;
		int draws = 0;
		auto t0 = std::chrono::steady_clock::now();
		for (int i = 0; i < games_per_tier; i++) {
			RngPcg rng;
			rng.seed((uint32_t)(910000 + tier * 100000 + i));
			Matchup m = env.gen_matchup(rng);
			env.reset(m, false);
			while (!env.done) {
				env.active_mask(1, mask1);
				env.observe(1, obs);
				net.forward(obs.data(), logits, nullptr);
				net.greedy_actions(logits, mask1, acts1);
				env.active_mask(2, mask2);
				env.observe(2, obs);
				net.forward(obs.data(), logits, nullptr);
				net.greedy_actions(logits, mask2, acts2);
				env.step(acts1, acts2);
			}
			EnvResult res = env.result();
			if (res.winner == 1) score += 1.0;
			else if (res.winner == 0) {
				score += 0.5;
				draws++;
			}
		}
		double wr = score / (double)games_per_tier;
		double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
		char buf[192];
		std::snprintf(buf, sizeof(buf),
				"tier%d（%d 档）%d 局同策略自博弈：胜率=%.3f（平局 %d，门 [0.45,0.55]）%.1fs",
				tier, ARMY_TIERS[tier], games_per_tier, wr, draws, secs);
		ok &= check(wr >= 0.45 && wr <= 0.55, buf);
	}
	std::printf("mirror %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

// ── 斩首路径冒烟：指挥官被端 → 立即判负（reason=1）+ 斩首奖励零和 ──

static int test_decap() {
	int ok = 1;
	std::printf("== 斩首：守方指挥官被打 → 攻方立即胜 ==\n");
	{
		BattleEnv env;
		RngPcg rng;
		rng.seed(42);
		env.eval_lock_tier = 0; // 17 档 // 17 档
		Matchup m = env.gen_matchup(rng);
		env.reset(m, false);
		int c2 = env.find_commander(2);
		int atk = 0; // 攻方班0班首（矛兵，射程 200）
		env.units[c2].hp = 1.0; // 打到残血
		env.units[atk].x = env.units[c2].x - 30.0; // 贴脸
		env.units[atk].y = env.units[c2].y;
		env.units[atk].cd = 0.0;
		int acts[BattleEnv::N_SQUADS] = { 0 };
		int beats = 0;
		while (!env.done && beats < BattleEnv::BEATS_MAX) {
			env.step(acts, acts);
			beats++;
		}
		EnvResult r = env.result();
		ok &= check(r.reason == 1 && r.winner == 1, "斩首结算：reason=1 攻方胜（立即判负）");
		ok &= check(beats < 10, "斩首在数拍内触发（非超时）");
		ok &= check(std::fabs(r.reward_f1 + r.reward_f2) < 1e-9, "斩首奖励零和");
		std::printf("  局况：beats=%d winner=%d r=(%+.3f, %+.3f)\n",
				beats, r.winner, r.reward_f1, r.reward_f2);
	}
	std::printf("== 排长分层奖励：存活比差分项在终局结算中出现 ==\n");
	{
		BattleEnv env;
		RngPcg rng;
		rng.seed(7);
		env.eval_lock_tier = 0; // 17 档
		Matchup m = env.gen_matchup(rng);
		env.reset(m, false);
		// 守方排长直接判死（rank2 阵亡 → 缺口拍 + 存活差双重差分信号）
		for (auto &u : env.units)
			if (u.rank == 2 && u.side == 1) {
				u.hp = 0.0;
				u.alive = false;
				env.squad_alive[u.side][u.squad] -= 1;
				env.officer_death_beat[u.side][u.platoon] = 0;
			}
		int acts[BattleEnv::N_SQUADS] = { 0 };
		int beats = 0;
		while (!env.done && beats < 30) {
			env.step(acts, acts);
			beats++;
		}
		EnvResult r = env.result();
		ok &= check(r.officer_alive[0] == 1 && r.officer_alive[1] == 0, "排长存活统计（1:0）");
		ok &= check(r.gap_beats[1] > 0, "守方排长缺口拍累计 > 0");
		// 攻方全存活 + 守方排长缺口 → 攻方奖励应含 +0.15 存活差分 + 缺口差分
		bool zero_sum = std::fabs(r.reward_f1 + r.reward_f2) < 1e-9;
		ok &= check(zero_sum, "排长奖励差分下仍零和");
		std::printf("  局况：officer_alive=(%d,%d) gap=(%ld,%ld) r=(%+.4f, %+.4f)\n",
				r.officer_alive[0], r.officer_alive[1], r.gap_beats[0], r.gap_beats[1],
				r.reward_f1, r.reward_f2);
	}
	std::printf("decap %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

// ── bench ──

static int test_bench(int episodes) {
	RLTrainer tr;
	tr.configure(nullptr);
	tr.net.alloc(NET_IN, NET_HID, NET_OUT);
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
	int wf = -1, wk = -1;
	int bad_dims_reported = 0;
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
			if (d1 > worst1) {
				worst1 = d1;
				wf = (int)i;
				wk = k;
			}
			if (d2 > worst2) worst2 = d2;
			// 诊断：打印前 12 个差异 > 1e-9 的（帧,维,两侧值）
			if ((d1 > 1e-7 || d2 > 1e-7) && bad_dims_reported < 12) {
				std::printf("  [diff] 帧%2zu 维%3d: cpp_f1=%.6f gd_f1=%.6f cpp_f2=%.6f gd_f2=%.6f\n",
						i, k, cf1->arr[k]->num, gf1->arr[k]->num, cf2->arr[k]->num, gf2->arr[k]->num);
				bad_dims_reported++;
			}
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
		std::vector<double> x, lg(net.out_dim);
		for (auto &v : p->get("obs")->arr) x.push_back(v->num);
		net.forward(x.data(), lg.data(), nullptr);
		JsonPtr want = p->get("logits");
		if ((int)want->arr.size() != net.out_dim) {
			std::printf("FAIL logits 维度不符（probe=%zu net=%d）\n", want->arr.size(), net.out_dim);
			return 1;
		}
		for (int k = 0; k < net.out_dim; k++) {
			double dd = std::fabs(lg[k] - want->arr[k]->num);
			if (dd > worst) worst = dd;
		}
		n++;
	}
	char buf[160];
	std::snprintf(buf, sizeof(buf), "权重衔接：checkpoint 装载 + %d 组观察前向 logits max|Δ|=%.3g（门 1e-3）", n, worst);
	bool ok = check(worst <= 1e-3, buf);
	std::printf("verify-net %s\n", ok ? "ALL PASS" : "HAS FAILURES");
	return ok ? 0 : 1;
}

// ── gen-net-probe：随机权重 checkpoint + 确定性观察输入（权重衔接门第 1 步）──
// GDScript 侧 policy_net_probe.gd 装同一 checkpoint 用 mirror_net 前向 →
// verify-net 比对两侧 logits（门 1e-3；实测应逐位级一致）。

static int gen_net_probe(uint32_t seed, const std::string &ckpt_path, const std::string &input_path) {
	RLNet net;
	net.alloc(NET_IN, NET_HID, NET_OUT);
	net.init_weights(seed);
	// checkpoint（阿尔法契约全文）
	auto root = Json::make(Json::OBJ);
	root->set("iteration", Json::num_of(0.0));
	root->set("seed", Json::num_of((double)seed));
	root->set("baseline", Json::num_of(0.0));
	auto hyper = Json::make(Json::OBJ);
	hyper->set("lr_decay", Json::num_of(0.995));
	hyper->set("temp_decay", Json::num_of(0.995));
	hyper->set("beta", Json::num_of(0.005));
	root->set("hyper", hyper);
	root->set("net", net.net_to_json());
	{
		std::ofstream f(ckpt_path, std::ios::binary);
		if (!f) {
			std::printf("FAIL 无法写 %s\n", ckpt_path.c_str());
			return 1;
		}
		f << root->dump();
	}
	// 确定性观察 8 组（sin 公式，与旧探针同风格）
	auto probes = Json::make(Json::ARR);
	for (int pi = 0; pi < 8; pi++) {
		auto po = Json::make(Json::OBJ);
		auto xs = Json::make(Json::ARR);
		for (int j = 0; j < NET_IN; j++)
			xs->arr.push_back(Json::num_of(std::sin((double)(pi * 13 + j * 7) * 0.37) * 0.9));
		po->set("obs", xs);
		probes->arr.push_back(po);
	}
	auto in_root = Json::make(Json::OBJ);
	in_root->set("probes", probes);
	std::ofstream f(input_path, std::ios::binary);
	if (!f) {
		std::printf("FAIL 无法写 %s\n", input_path.c_str());
		return 1;
	}
	f << in_root->dump();
	std::printf("[gen-net-probe] checkpoint=%s input=%s（%d→%d→%d，8 组 sin 观察）\n",
			ckpt_path.c_str(), input_path.c_str(), NET_IN, NET_HID, NET_OUT);
	return 0;
}

int main(int argc, char **argv) {
	if (argc >= 2 && std::strcmp(argv[1], "smoke") == 0) return test_smoke();
	if (argc >= 2 && std::strcmp(argv[1], "mirror") == 0)
		return test_mirror(argc >= 3 ? std::atoi(argv[2]) : 200);
	if (argc >= 2 && std::strcmp(argv[1], "decap") == 0) return test_decap();
	if (argc >= 2 && std::strcmp(argv[1], "bench") == 0)
		return test_bench(argc >= 3 ? std::atoi(argv[2]) : 20);
	if (argc >= 5 && std::strcmp(argv[1], "gen-net-probe") == 0)
		return gen_net_probe((uint32_t)std::strtoul(argv[2], nullptr, 10), argv[3], argv[4]);
	if (argc >= 4 && std::strcmp(argv[1], "dump-fixture") == 0)
		return dump_fixture((uint32_t)std::strtoul(argv[2], nullptr, 10), argv[3], argc >= 5 ? std::atoi(argv[4]) : 5);
	if (argc >= 4 && std::strcmp(argv[1], "verify-obs") == 0) return verify_obs(argv[2], argv[3]);
	if (argc >= 4 && std::strcmp(argv[1], "verify-net") == 0) return verify_net(argv[2], argv[3]);
	std::printf("用法: test_core.exe smoke | mirror [n/tier] | decap | bench [n] | gen-net-probe <seed> <ckpt_out> <input_out> | dump-fixture <seed> <out> [every] | verify-obs <f> <g> | verify-net <ckpt> <probe>\n");
	return 2;
}
