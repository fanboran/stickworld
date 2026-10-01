#ifndef RL_CORE_ENV_H
#define RL_CORE_ENV_H
// rl_core · BattleEnv 纯核心 v2 定稿（指挥层紧凑战斗环境；零 Godot 依赖）
//
// ── 规格 v2（维度定稿唯一输入 = 编制定稿，游戏内 87c2c110 已落地）──
//   BEATS_MAX 250（0.5s/拍 × 250 = 125s 超时；超时按剩余存活判胜，等则平——
//   _collect_result 兜底口径）；N_SQUADS 8（班数上限；空班 active_mask=0）；
//   N_PLATOONS 4（排数上限）；OBS_DIM 125（6 + 7×3 + 10×8 + 4×4 + 2）；
//   N_ACTIONS_PER_SQUAD 5（40 = 8 班 × 5 意图）；
//   ARMY_TIERS [17,49,97]（含指挥官；士兵 16/48/96）。
//
// ── 编制定稿（87c2c110 三预设逐班镜像；WeaponType：1矛 0剑 2弓 4杖 5祭司）──
//   17 档：2 班×8   ＝ 矛8 ／ 剑4杖1弓2祭1，1 排
//   49 档：4 班×12 ＝ 矛12 ／ 矛4剑8 ／ 剑12 ／ 杖4弓8，2 排
//   97 档：8 班×12 ＝ 矛12×2 ／ 矛4剑8 ／ 剑12×3 ／ 杖4弓8×2，4 排
//   每排恒 2 班（platoon p = 班 2p、2p+1）。兵种配比固定（定稿表），随机性保留
//   在档位抽取（课程锁定时除外）与占位（出生带/班错位）——v1 的 Dirichlet²
//   随机配比协议随编制定稿退役。
//
// ── 真镜像（创始人裁决）──
//   每轮只抽一套编制/占位，守方 = 攻方的 x 镜射（x→−x、y 同值）——兵力数、
//   兵种配比、班占位全同，"侧优势"噪声源从根上消失。旗布位 f0(−500,−200)/
//   f1(0,0)/f2(+500,−200)（x 镜射对称；旧布位 f2 y=+200 只旋转对称，已修）。
//
// ── 军衔四层（v2 定稿）──
//   rank0 兵 ／ rank1 班长（每班班首兵；阵亡免费轮转零信号——观察/奖励均不出现）
//   ／ rank2 排长（每排首班班首兵；避战奖励载体：存活 +0.15、阵亡持续小罚、
//   贴敌质心惩罚）／ rank3 指挥官（独立实体，±1780 后方留守，不移动不攻击、
//   可被打击/治疗；被端 = 斩首立即判负）。
//
// ── 武器表（镜像 stickmen.tres SWL 校准行；紧凑层单目标直伤，无弹道/格挡）──
//   剑 0:  hp80  dmg12 cd1.0 range80    矛 1: hp440 dmg15 cd2.0 range200
//   弓 2:  hp70  dmg10 cd2.0 range1400  镐 3: 不参战（指挥官占号：不攻击）
//   杖 4:  hp150 dmg50 cd7.0 range600   祭司 5: hp150 不攻击、治疗 30/3s/400px
//   移速 160/320（近战 600px 冲脸 run）；分离 42/1.6。
//
// ── 奖励（全差分，r_f1 + r_f2 ≡ 0）──
//   ±1 胜负 + 0.2×存活比差（v3 防退化降权：0.5 零和下诱导保守化）+ 0.5×旗数差/3
//   + 排长三件（差分形式，权重挂 EnvConfig）：0.15×排长存活比差 − 0.003×缺口拍
//   差 − 贴敌罚差（单排长全程上限 0.05，阈值 800px）。

#include <string>
#include <vector>

#include "rl_json.h"
#include "rl_math.h"

namespace rl {

struct EnvConfig {
	static EnvConfig from_json(const JsonPtr &j);

	double arena_half_x = 2000.0;
	double band_half_y = 450.0;
	double beat = 0.5;
	int internal_ticks_per_beat = 5;
	double internal_dt = 0.1;
	double time_limit = 125.0;
	double flag_radius = 180.0;
	double capture_rate = 20.0; // 分/s（20 分/s × 0.5s 拍）
	double separation_radius = 42.0;
	double separation_force = 1.6;
	double walk_speed = 160.0;
	double run_speed = 320.0;
	double engage_trigger = 600.0;
	double garrison_arrive = 60.0;
	double attack_flag_hold = 60.0;
	// 奖励塑形权重（v3 防退化修正）：存活差 0.5 → 0.2（零和下诱导保守化）；
	// 夺点差维持 0.5（战术积极性直接信号）。GDScript 真相源
	// selfplay_trainer._faction_reward 仍为 0.5/0.5（只读不改），两版奖励口径分叉。
	double reward_survive_w = 0.2;
	double reward_flag_w = 0.5;
	// 指挥官规则（v3·斩首维度）：
	double commander_hp = 150.0; // 指挥官血量（杖级身板，可被击杀 → 立即战败）
	double commander_x = 1780.0; // 指挥官距中线距离（±双侧镜像，y=0 恒镜像对称）
	// 排长分层奖励（差分零和；数值全部待实测校准）：
	double officer_survive_w = 0.15;     // 排长存活到终局 +0.15（差分形式保零和）
	double officer_gap_per_beat = 0.003; // 排长阵亡持续状态惩罚/拍（指挥链缺口代价；
	                                     //  均值94拍对局中局阵亡≈0.14总罚，量级对齐一次性
	                                     //  0.15 而梯度更平滑——v3.1 裁决改持续制）
	double officer_avoid_max = 0.05;     // 单排长近敌连续惩罚上限（累计时夹取）
	double officer_avoid_radius = 800.0; // 排长距敌军质心阈值（进入即按 (1−d/r) 比例扣）
	// 武器表（下标 = WeaponType：0剑 1矛 2弓 3镐(不参战) 4杖 5祭司）
	double w_hp[6] = { 80.0, 440.0, 70.0, 1.0, 150.0, 150.0 };
	double w_dmg[6] = { 12.0, 15.0, 10.0, 0.0, 50.0, 0.0 };
	double w_cd[6] = { 1.0, 2.0, 2.0, 1.0, 7.0, 3.0 };
	double w_range[6] = { 80.0, 200.0, 1400.0, 1.0, 600.0, 400.0 };
};

// 编制定稿（87c2c110 三预设逐班镜像；维度定稿唯一输入）
struct TierDef {
	int soldiers;             // 士兵数（不含指挥官）
	int n_squads;             // 2/4/8
	int n_platoons;           // 1/2/4（每排恒 2 班 = 班 2p、2p+1）
	int squad_n[8];           // 每班人数 8~12
	int squad_weapons[8][12]; // WeaponType 逐班
};

// 档位定义（tier 0/1/2 → 17/49/97）
const TierDef &tier_def(int idx);
extern const int ARMY_TIERS[3]; // {17, 49, 97} 含指挥官

// 旗点世界 y（真镜像布位）：f0(−500,−200) / f1(0,0) / f2(+500,−200)。
// x 镜射对称（x→−x 时 f0↔f2、f1 不动）。
inline double flag_world_y(int world_flag) {
	return world_flag == 1 ? 0.0 : -200.0;
}
inline double flag_world_x(int world_flag) {
	return (double)(world_flag - 1) * 500.0;
}

// 一侧编制 = 档位 + 占位随机（编制本体查 TierDef 表，两侧共用 → 真镜像）
struct SideComp {
	int tier = 0;
	double band_x = 0, side_y = 0;
	double squad_x[8] = { 0 }, squad_y[8] = { 0 }; // 班错位随机
};

struct Matchup {
	int total = 0;
	SideComp side_a, side_b; // 真镜像：side_b = side_a（同一套编制/占位，两侧全同）
};

struct Unit {
	double x = 0, y = 0;
	double hp = 1, max_hp = 1;
	int weapon = 0;
	double cd = 0;
	bool alive = true;
	int side = 0;   // 0 = faction 1（攻/西），1 = faction 2（守/东）
	int squad = -1; // 班槽 0..7；指挥官 = -1（不入任何班聚合/旧观察特征）
	int rank = 0;   // 军衔：0 兵 1 班长（阵亡免费轮转零信号）2 排长（避战奖励载体）
	                // 3 指挥官（斩首层）
	int platoon = -1; // 所属排（指挥官 = -1）
	bool is_commander = false; // 最高指挥（±commander_x, 0）：不移动不攻击、可被打击/
	                           // 治疗；被端 = 该方立即战败（斩首维度）
};

struct EnvResult {
	int winner = 0; // 0 平 1 攻(faction1) 2 守(faction2)
	double reward_f1 = 0, reward_f2 = 0;
	int decisions = 0;
	int alive[2] = { 0, 0 };      // 存活士兵数（不含指挥官）
	int initial[2] = { 0, 0 };
	int flags_owned[2] = { 0, 0 };
	double duration = 0.0;
	bool timeout = false;
	int reason = 0;                  // 0=正常（歼灭/超时判定）1=斩首（指挥官被端）
	int n_platoons = 0;              // 本局排数（分层奖励归一分母）
	int officer_alive[2] = { 0, 0 }; // 终局排长(rank2)存活数
	long gap_beats[2] = { 0, 0 };    // 排长阵亡起的缺口拍数（各排累计）
	double officer_pen[2] = { 0, 0 }; // 排长近敌连续惩罚（累计时夹上限）
};

class BattleEnv {
public:
	static const int OBS_DIM = 125; // 6 全局 + 3×7 旗 + 8×10 班块 + 4×4 排层 + 2 指挥官
	static const int N_SQUADS = 8;
	static const int N_PLATOONS = 4;
	static const int N_ACTIONS_PER_SQUAD = 5;
	static const int N_ACTIONS = N_SQUADS * N_ACTIONS_PER_SQUAD; // 40
	static const int BEATS_MAX = 250; // 125s / 0.5s

	EnvConfig cfg;
	int squad_init[2][N_SQUADS] = { { 0 }, { 0 } };
	int squad_alive[2][N_SQUADS] = { { 0 }, { 0 } };
	int side_init[2] = { 0, 0 };
	int n_squads = 0, n_platoons = 0; // 本局实际班/排数（随档位）
	int last_intent[2][N_SQUADS] = { { -1 }, { -1 } };
	double flag_owner[3] = { 0, 0, 0 };
	double flag_prog[3] = { 0, 0, 0 };
	int flag_capturing[3] = { 0, 0, 0 };
	bool flag_contested[3] = { false, false, false };
	std::vector<Unit> units;
	double t = 0.0;
	int decisions_made = 0;
	bool done = false;
	Matchup cur_matchup;
	bool cur_swap = false;
	// 指挥官/军衔/课程状态（reset 时随阵重建）
	int commander_idx[2] = { -1, -1 };     // 指挥官单位下标（斩首判定目标）
	int officer_idx[2][N_PLATOONS];        // 排长(rank2)单位下标（避战奖励载体）
	int officer_death_beat[2][N_PLATOONS]; // 排长阵亡拍号（-1 在世；缺口拍数 = 终局拍−此值）
	int decap_winner = 0;                  // 斩首胜者（0=未发生；同拍双斩 → 0=平局）
	double officer_pen_accum[2] = { 0, 0 }; // 排长贴敌罚累计（拍级累积，result 读出）
	int curriculum_tier = -1;              // 课程锁定档（-1 = 随机三档；trainer 每轮设置）

	// 伤害双相结算缓冲（真镜像配套：同 tick 内双方伤害基于同一快照统一生效，
	// 先手方"先扣血"的击杀抢跑从根上消失；tick 末 flush_pending_damage 结算）
	struct PendingDmg {
		int target;
		double dmg;
	};
	std::vector<PendingDmg> pending_dmg;
	// tick 开始位置快照（真镜像配套：移动/攻击判定全部基于同一几何快照，
	// 先动方改变战场地形导致后动方射程判定漂移的非对称从根上消失）
	std::vector<double> snap_x, snap_y;

	BattleEnv()
		: officer_idx{ { -1, -1, -1, -1 }, { -1, -1, -1, -1 } },
		  officer_death_beat{ { -1, -1, -1, -1 }, { -1, -1, -1, -1 } } {}

	void load_config(const JsonPtr &j);

	// 随机对阵（真镜像：只抽一套编制/占位，两侧共用；档位可被课程锁定）
	Matchup gen_matchup(RngPcg &rng) const;
	void reset(const Matchup &m, bool swap);

	// 一个决策节拍：旗结算 → 内部物理步 → 斩首/歼灭/超时判定 → 时间推进
	void step(const int *actions_f1, const int *actions_f2);

	// 125 维观察（faction 1/2，全特征己方视角镜像；布局见 README 维度表）
	void observe(int faction, std::vector<double> &out) const;
	void active_mask(int faction, int *mask8) const;
	EnvResult result() const;
	double faction_reward(const EnvResult &r, int faction) const;

	// 评估对手（军师规划器打分逻辑的 C++ 镜像，见 squad_intent_planner._choose_intent）
	void planner_intents(int faction, int *intents8);

	// 指挥官单位下标（斩首冒烟/调试用；无 = -1）
	int find_commander(int faction) const;

	// 对拍夹具：跑一局（固定意图循环），每 sample_every 拍 dump 一帧完整状态
	// （v3 格式：含 rank/is_commander/squad_initial/platoons 分组，供新维度
	// GDScript 镜像编码器独立重算 125 维观察）
	JsonPtr dump_obs_fixture(uint32_t seed, int sample_every, int max_frames) const;

private:
	void spawn_side(const SideComp &comp, int faction);
	void spawn_commander(int faction);
	void capture_beat();
	void physics_tick();
	void internal_tick();
	void flush_pending_damage();
	void accumulate_officer_penalties();
	int nearest_enemy_unit(int idx, double *dist_out) const;
	int nearest_enemy_pos(double px, double py, int side, double *dist_out) const;
	void squad_centroid(int side, int squad, double *cx, double *cy, int *alive_n, double *hp_sum) const;
};

} // namespace rl

#endif // RL_CORE_ENV_H
