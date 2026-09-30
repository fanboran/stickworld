#ifndef RL_CORE_ENV_H
#define RL_CORE_ENV_H
// rl_core · RLBattleEnv 纯核心 v2（指挥层紧凑战斗环境，观察/协议对齐 tests/dev/rl/battle_env.gd 真相源）
//
// ─────────────────────────────────────────────────────────────────────────────
// 【诚实预期·迁移差距（不变）】阿尔法 battle_env 是真实 Godot 战斗宿主（真单位 /
// battle_instance / FormationSystem / TacticalOrders / 兵种行为档案全链路），网络
// 只做 0.5s 节拍的班级意图决策；本 C++ env 是指挥层紧凑抽象——自己模拟单位运动/
// 攻击/治疗，无弹道/格挡/HITSTOP/击退/号令节流，动力学保真度差照旧。对齐的部分：
// 57 维观察编码（逐行镜像 _encode_obs）、动作词汇与翻译语义、随机对阵生成协议
// （randi/randi_range 逐位同源）、旗点结算规则、奖励三项、终局判定。观察编码的
// 对拍走状态注入（见 tests/obs_gate.gd + dump_obs_fixture）：同状态下 C++ observe
// 与阿尔法原版 _encode_obs 逐步比对。紧凑环境是吞吐引擎，不是真相源；真实进步
// 唯一裁判 = nn_brain 在真实 Godot Benchmark 打手调规划器。
// ─────────────────────────────────────────────────────────────────────────────
//
// ── 对齐真相源的常量（battle_env.gd 顶部常量区）──
//   BEAT 0.5s（决策/旗点结算节拍）；BATTLE_TIME_LIMIT 125s（硬超时，超时按剩余
//   存活判胜，等则平——_collect_result 兜底口径）；OBS_DIM 57（6 + 7×3 + 10×3）；
//   WEAPON_POOL [1,0,2,4,5]（WeaponType：1矛 0剑 2弓 4杖 5祭司；镐 3 不参战）；
//   SQUAD_SPLIT [0.45,0.35,0.20]（先锋/中坚/火力）；ARMY_TIERS [16,32,48]；
//   SIDE_SPLIT 0.35~0.65（clamp [6, total−6]）；旗 ±500/±200 半径 180；
//   出生带 900~1500 / 侧 y ±350 / 班错位 ±250 / 班纵深 260×序 / 行 8 列间距
//   (110, 90)；驻防到位 60px。紧凑场地：x ∈ ±2000、y ∈ ±450（真实行走带的等效带）。
//
// ── 武器表（镜像 stickmen.tres SWL 校准行；紧凑层单目标直伤，无弹道/格挡）──
//   剑 0:  hp80  dmg12 cd1.0 range80    矛 1: hp440 dmg15 cd2.0 range200
//   弓 2:  hp70  dmg10 cd2.0 range1400  杖 4: hp150 dmg50 cd7.0 range600
//   祭司 5: hp150 不攻击；治疗 heal30 / cd3.0 / range400（heal_amount/heal_cooldown
//   镜像 behavior_profiles meric 档；紧凑层每物理步给射程内最伤未满友军瞬时 +30）
//
// ── 意图 → 行为（动作词汇与 battle_env._apply_intents 同语义，无号令节流层）──
//   0/1/2 攻自视角左/中/右旗（世界坐标 = 自视角序旗位）；3 驻防最近己旗
//   （无己旗退化攻中旗；班质心距目标 ≤60 停）；4 接敌推进（最近敌班质心，run 320）。
//   单位级：射程内站桩射击；近战（range≤250）敌近 600px 冲脸（run）；否则按意图走（160）。

#include <string>
#include <vector>

#include "rl_json.h"
#include "rl_math.h"

namespace rl {

struct EnvConfig {
	double arena_half_x = 2000.0;
	double band_half_y = 450.0;
	double beat = 0.5;
	int internal_ticks_per_beat = 5;
	double internal_dt = 0.1;
	double time_limit = 125.0;
	double flag_radius = 180.0;
	double capture_rate = 20.0;
	double separation_radius = 42.0;
	double separation_force = 1.6;
	double walk_speed = 160.0;
	double run_speed = 320.0;
	double engage_trigger = 600.0;
	double garrison_arrive = 60.0;
	double attack_flag_hold = 60.0;
	double heal_amount = 30.0;
	double heal_cooldown = 3.0;
	double heal_range = 400.0;
	// 武器表（下标 = WeaponType：0剑 1矛 2弓 3镐(不参战) 4杖 5祭司）
	double w_hp[6] = { 80.0, 440.0, 70.0, 1.0, 150.0, 150.0 };
	double w_dmg[6] = { 12.0, 15.0, 10.0, 0.0, 50.0, 0.0 };
	double w_cd[6] = { 1.0, 2.0, 2.0, 1.0, 7.0, 3.0 };
	double w_range[6] = { 80.0, 200.0, 1400.0, 1.0, 600.0, 400.0 };

	static EnvConfig from_json(const JsonPtr &j);
};

// 随机对阵（结构对齐 battle_env.gen_matchup / _gen_side_comp 的产物）
struct SideComp {
	int n_total = 0;
	double band_x = 0.0;
	double side_y = 0.0;
	double squad_x[3] = { 0, 0, 0 };
	double squad_y[3] = { 0, 0, 0 };
	std::vector<int> squad_weapons[3]; // 班内武器交错排（编制序）
};

struct Matchup {
	int total = 0;
	SideComp side_a, side_b;
};

struct Unit {
	double x = 0, y = 0;
	double hp = 1, max_hp = 1;
	int weapon = 0;
	double cd = 0;
	bool alive = true;
	int side = 0;   // 0 = faction 1（攻/西），1 = faction 2（守/东）
	int squad = 0;  // 编制序 0/1/2
};

struct EnvResult {
	int winner = 0; // 0 平 1 攻(faction1) 2 守(faction2)
	double reward_f1 = 0, reward_f2 = 0;
	int decisions = 0;
	int alive[2] = { 0, 0 };
	int initial[2] = { 0, 0 };
	int flags_owned[2] = { 0, 0 };
	double duration = 0.0;
	bool timeout = false;
};

class BattleEnv {
public:
	static const int OBS_DIM = 57;
	static const int N_SQUADS = 3;
	static const int N_ACTIONS = 5;
	static const int BEATS_MAX = 250; // 125s / 0.5s

	EnvConfig cfg;
	std::vector<Unit> units;
	int squad_alive[2][3] = {};
	int squad_init[2][3] = {};
	int side_init[2] = { 0, 0 };
	double flag_owner[3] = { 0, 0, 0 };   // 0 无主 1 faction1 2 faction2
	double flag_prog[3] = { 0, 0, 0 };
	int flag_capturing[3] = { 0, 0, 0 };
	bool flag_contested[3] = {};
	int last_intent[2][3] = { { -1, -1, -1 }, { -1, -1, -1 } };
	int decisions_made = 0;
	bool done = true;
	double t = 0.0;
	Matchup cur_matchup;
	bool cur_swap = false;

	void load_config(const JsonPtr &j);

	// 随机对阵（对齐 gen_matchup：PCG 抽 tier/切分/Dirichlet²配比/最大余数法/拆班/占位）
	Matchup gen_matchup(RngPcg &rng) const;
	void reset(const Matchup &m, bool swap);

	// 一个决策节拍：旗结算 → 内部物理步 → 时间推进 → 终局判定
	void step(const int *actions_f1, const int *actions_f2);

	// 57 维观察（faction 1/2，全特征己方视角镜像；逐行镜像 _encode_obs）
	void observe(int faction, std::vector<double> &out) const;
	void active_mask(int faction, int *mask3) const;
	EnvResult result() const;
	static double faction_reward(const EnvResult &r, int faction);

	// 评估对手（军师规划器打分逻辑的 C++ 镜像，见 squad_intent_planner._choose_intent）
	void planner_intents(int faction, int *intents3);

	// 对拍夹具：跑一局（固定意图循环），每 sample_every 拍 dump 一帧完整状态
	JsonPtr dump_obs_fixture(uint32_t seed, int sample_every, int max_frames) const;

private:
	void spawn_side(const SideComp &comp, int faction);
	void capture_beat();
	void physics_tick();
	void internal_tick();
	int nearest_enemy_unit(int idx, double *dist_out) const;
	void squad_centroid(int side, int squad, double *cx, double *cy, int *alive_n, double *hp_sum) const;
};

} // namespace rl

#endif // RL_CORE_ENV_H
