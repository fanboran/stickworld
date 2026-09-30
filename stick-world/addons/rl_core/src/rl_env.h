#ifndef RL_CORE_ENV_H
#define RL_CORE_ENV_H
// rl_core · RLBattleEnv 纯核心：紧凑指挥层战斗环境（零 Godot 依赖；绑定见 rl_env_gd.cpp）
//
// ─────────────────────────────────────────────────────────────────────────────
// 【诚实预期·迁移差距】本环境是对真实 Godot 战斗（battle_arena + formation/tactics/
// units 全链路）的指挥层紧凑抽象，不是逐帧复刻：无弹道/格挡/HITSTOP/击退/治疗/溅射，
// 伤害=命中即扣血；行为语义压成 5 个班级意图。观察/动作编码规格两边（本文件与
// tests/gdscript_mirror/ 的 GDScript 镜像）逐字一致——两版互为对拍参照；但紧凑环境
// 的进步不是真相源，真实进步唯一裁判仍是「nn_brain 在真实 Godot Benchmark
// （tests/dev/diag_arena_benchmark_driver.gd）里打手调规划器」的评估协议。
// C++ 环境是吞吐引擎，不是真相源。
// ─────────────────────────────────────────────────────────────────────────────
//
// ── 场地与数值（默认值镜像真实系统；JSON config 可逐项覆盖）──
//   场地：x ∈ [−2000, +2000]，y ∈ [−400, +400]（attacker 在左、前进方向 +x）。
//   3 旗（左/中/右）：(−500,−200) (0,0) (+500,+200)，占领半径 180（真实 CAPTURE_RADIUS）。
//   占领：半径内单方独占 → 进度 += 20/s（真实 CAPTURE_RATE_PER_SECOND=20，0→100）；
//         双方同在 → 争夺冻结（进度不动）；无人 → 不动（无衰减，同真实 CapturePoint）；
//         满 100 → 易主，进度清 0。初始全中立 0 进度。
//   武器表（镜像 config/units/stickmen.tres SWL 校准行 + weapon_mount.WEAPON_RANGE）：
//     0 剑 SWORD: hp80  dmg12 cd1.0s range80
//     1 矛 SPEAR: hp440 dmg15 cd2.0s range200
//     2 弓 BOW:   hp70  dmg10 cd2.0s range1400
//     3 杖 STAFF: hp150 dmg50 cd7.0s range600
//   移速：walk 160 / run 320 px/s（真实 WALK_SPEED/RUN_SPEED）；分离半径 42（真实
//   formation_spacing 40.5，任务书口径 42）、分离力 1.6（真实 SEPARATION_FORCE）；
//   近战自动接敌触发 600px（近战=range≤250）；旗内驻停：攻旗 60 / 驻防 90。
//   节拍：dt=0.1s 战斗步；决策每 5 步一次（0.5s，同真实规划器节拍）；超时 120 决策（60s）。
//   编制（随机不对称）：每方 3 班——矛班∈{8,16} 剑班∈{4,10,20} 杖∈{1,2,4}+弓∈{0,3,8}；
//     班质心 x = ±(1400 − 班号×150)（矛前剑中火力后），y = 班号×150−150；班内网格
//     8 列间距 70。治疗（MERIC）不进紧凑环境（治疗语义复杂、仅火力班 1 员纯增益）。
//
// ── 动作空间 ── 每班 5 意图：0 攻左旗 / 1 攻中旗 / 2 攻右旗 / 3 驻防最近己旗 /
//   4 接敌推进（ENGAGE，全速冲最近敌）。每步双方各交 actions[3]。
//
// ── 单位级行为（每 tick 按 id 序贯执行，顺序即规格，两版逐字一致）──
//   对存活单位 i（attacker 全体 → defender 全体，id 升序）：
//   1. 就当前位形找最近敌（id 序平手取先）d0；
//   2. 移动决策：
//      · 意图 ENGAGE → 目标=最近敌位、run；
//      · d0 ≤ 射程 → 原地站桩射击；
//      · 近战 且 d0 ≤ 600 → 追击最近敌、run（冲脸，镜像兵种行为档案）；
//      · 攻旗 f → 目标=旗 f，距旗 ≤60 驻停；
//      · 驻防 → 最近己方旗（无则最近中立旗，再无则中旗），距 ≤90 驻停；
//   3. 位移：dir=normalize(target−pos)（驻停=0）；push=Σ近邻(存活、<42px)
//      (pos−o)/d·(1−d/42)；step=dir+1.6·push，非零则 pos += normalize(step)·speed·dt；
//      场地钳制；
//   4. 攻击：cd=max(0,cd−dt)；就新位形重找最近敌 d1；cd≤0 且 d1≤射程 →
//      敌 hp−=dmg（≤0 即亡）、cd=武器cd。
//   每 tick 单位轮之后结算 3 旗占领（用终局位形）。
//
// ── 观察编码 v1（47 维，己方视角；side=0 attacker / 1 defender，forward=±1 镜像）──
//   [0]  己方 HP 战力比 = Σhp(己存活)/(Σhp 双方存活)（双 0 → 0.5）
//   [1]  存活比 = n(己存活)/(n(双方存活))（双 0 → 0.5）
//   旗 f（f=0 左 1 中 2 右，基址 2+f×5，共 15）：
//     +0 归属（己 +1 / 中立 0 / 敌 −1）
//     +1 进度（争夺方向己方 +p/100、敌方 −p/100、无争夺 0）
//     +2 己方最近存活单位距旗 /1000（截 2；己全灭 → 2）
//     +3 敌方最近存活单位距旗 /1000（截 2；敌全灭 → 2）
//     +4 己方全军存活质心距旗 /1000（截 2；全灭 → 2）
//   班 k（基址 17+k×10，共 30）：
//     +0,+1 班存活质心 (cx/1500·forward, cy/400)（全灭 → (0,0)）
//     +2 存活人数比 = alive/init
//     +3 班 HP 比 = Σhp/初始Σhp
//     +4 质心到最近敌距 /1000（截 2；全灭 → 0）
//     +5..+9 当前意图 one-hot（5；全灭仍报当前意图）
//   维度是布局表的推论，别拍脑袋定 40——GDScript 镜像按本表逐格对齐。
//
// ── 奖励（零和）── R_攻 = 胜负(胜+1/负−1/平0) + 0.5×(存活比攻−存活比守)
//   + 0.5×(旗数攻−旗数守)/3；R_守 = −R_攻。超时按剩余 HP 比判胜负（等则平），
//   对齐 diag_arena_benchmark_driver 的「超时按剩余战力」口径。
//
// ── RNG 规格 ── xorshift32（rl_math.h）；reset(seed) 装 seed（0→0x9E3779B9），
//   仅编制抽样消耗 RNG：顺序 = 攻方(矛,剑,杖,弓) → 守方同序；step 全程零 RNG
//   （确定性引擎，同种子同轨迹）。

#include <string>
#include <vector>

#include "rl_json.h"
#include "rl_math.h"

namespace rl {

struct EnvConfig {
	// 场地
	double arena_half_x = 2000.0;
	double band_half_y = 400.0;
	double team_offset_x = 1400.0;
	double flag_x[3] = { -500.0, 0.0, 500.0 };
	double flag_y[3] = { -200.0, 0.0, 200.0 };
	double flag_radius = 180.0;
	double capture_rate = 20.0;
	// 节拍
	double dt = 0.1;
	int ticks_per_decision = 5;
	int max_decisions = 120;
	// 行为
	double separation_radius = 42.0;
	double separation_force = 1.6;
	double walk_speed = 160.0;
	double run_speed = 320.0;
	double engage_trigger = 600.0;
	double attack_flag_hold = 60.0;
	double garrison_hold = 90.0;
	// 武器表 [0剑 1矛 2弓 3杖]
	double w_hp[4] = { 80.0, 440.0, 70.0, 150.0 };
	double w_dmg[4] = { 12.0, 15.0, 10.0, 50.0 };
	double w_cd[4] = { 1.0, 2.0, 2.0, 7.0 };
	double w_range[4] = { 80.0, 200.0, 1400.0, 600.0 };
	// 编制候选
	int spear_opts[2] = { 8, 16 };
	int sword_opts[3] = { 4, 10, 20 };
	int staff_opts[3] = { 1, 2, 4 };
	int bow_opts[3] = { 0, 3, 8 };

	static EnvConfig from_json(const JsonPtr &j); // 缺键保持默认
};

struct Unit {
	double x = 0.0, y = 0.0;
	double hp = 1.0, max_hp = 1.0;
	int weapon = 0;   // 0剑 1矛 2弓 3杖
	double cd = 0.0;
	bool alive = true;
	int side = 0;     // 0 attacker 1 defender
	int squad = 0;    // 0矛 1剑 2火力
};

struct Comp {
	int spear = 8, sword = 4, staff = 1, bow = 3; // 人数
	int total() const { return spear + sword + staff + bow; }
};

struct EnvResult {
	int winner = 0;              // 0 平 1 攻 2 守
	double reward_attacker = 0.0;
	double reward_defender = 0.0;
	int decisions = 0;
	int attacker_alive = 0;
	int defender_alive = 0;
	int flags_attacker = 0;
	int flags_defender = 0;
	bool timeout = false;
};

class BattleEnv {
public:
	EnvConfig cfg;

	std::vector<Unit> units;
	int squad_alive[2][3] = {};        // [side][squad]
	int squad_init[2][3] = {};
	double squad_init_hp[2][3] = {};
	double flag_owner[3] = {};         // 0 中立 1 攻 2 守（double 存，GDScript 镜像同）
	double flag_prog[3] = {};          // 0..100
	int flag_capturing[3] = {};        // 0 无 1 攻 2 守
	bool flag_contested[3] = {};
	int intents[2][3] = {};            // 当前意图 [side][squad]
	int decisions_made = 0;
	bool done = true;
	RngXs32 rng;
	Comp comp_att, comp_def;

	void load_config(const JsonPtr &j);
	void reset(uint32_t seed);         // 随机不对称编制
	void reset_fixed(uint32_t seed, const Comp &att, const Comp &def);
	// 推进一个决策节拍：actions_att/actions_def 各 3 个意图（0..4）
	void step(const int *actions_att, const int *actions_def);
	// 观察编码（47 维，side 0 攻 1 守）
	void observe(int side, std::vector<double> &out) const;
	EnvResult result() const;

	static const int OBS_DIM = 47;
	static const int NUM_GROUPS = 3;
	static const int APG = 5;

private:
	void tick();
	void capture_tick();
	int nearest_enemy(int idx, double *dist_out) const;
};

} // namespace rl

#endif // RL_CORE_ENV_H
