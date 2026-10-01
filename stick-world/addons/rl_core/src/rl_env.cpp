#include "rl_env.h"

#include <cmath>
#include <cstdlib>

namespace rl {

// ── 编制定稿表（87c2c110 三预设逐班镜像；维度定稿唯一输入）──
// WeaponType：1矛 0剑 2弓 4杖 5祭司
//   17 档：2 班×8   ＝ 矛8 ／ 剑4杖1弓2祭1，1 排
//   49 档：4 班×12 ＝ 矛12 ／ 矛4剑8 ／ 剑12 ／ 杖4弓8，2 排
//   97 档：8 班×12 ＝ 矛12×2 ／ 矛4剑8 ／ 剑12×3 ／ 杖4弓8×2，4 排
const int ARMY_TIERS[4] = { 17, 49, 97, 49 }; // 含指挥官；tier 3 逐班 5~6 人（41~49 浮动）

static const TierDef kTierDefs[4] = {
	// 17 档：班0 矛×8；班1 剑4 杖1 弓2 祭1
	{ 16, 2, 1,
		{ 8, 8, 0, 0, 0, 0, 0, 0 },
		{
			{ 1, 1, 1, 1, 1, 1, 1, 1 },
			{ 0, 0, 0, 0, 4, 2, 2, 5 },
		} },
	// 49 档：班0 矛×12；班1 矛4剑8；班2 剑×12；班3 杖4弓8
	{ 48, 4, 2,
		{ 12, 12, 12, 12, 0, 0, 0, 0 },
		{
			{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
			{ 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
			{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
			{ 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2 },
		} },
	// 97 档：班0/1 矛×12；班2 矛4剑8；班3/4/5 剑×12；班6/7 杖4弓8
	{ 96, 8, 4,
		{ 12, 12, 12, 12, 12, 12, 12, 12 },
		{
			{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
			{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
			{ 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
			{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
			{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
			{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
			{ 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2 },
			{ 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2, 2 },
		} },
	// tier 3 = 8 班小队档（v2.1 课程断层修复）：97 档结构逐班砍到 6 人模板
	//（实际逐班 5~6 人在 gen_matchup 随机定，存 SideComp.squad_n）——
	// 8 个班动作头 + 4 排排长层全激活，复杂度 ≈ 49 档，供 C2 预热/C3 回访
	{ 48, 8, 4,
		{ 6, 6, 6, 6, 6, 6, 6, 6 },
		{
			{ 1, 1, 1, 1, 1, 1 },
			{ 1, 1, 1, 1, 1, 1 },
			{ 1, 1, 0, 0, 0, 0 },
			{ 0, 0, 0, 0, 0, 0 },
			{ 0, 0, 0, 0, 0, 0 },
			{ 0, 0, 0, 0, 0, 0 },
			{ 4, 4, 2, 2, 2, 2 },
			{ 4, 4, 2, 2, 2, 2 },
		} },
};

const TierDef &tier_def(int idx) {
	if (idx < 0) idx = 0;
	if (idx > 3) idx = 3;
	return kTierDefs[idx];
}

EnvConfig EnvConfig::from_json(const JsonPtr &j) {
	EnvConfig c;
	if (!j || j->type != Json::OBJ) return c;
	c.arena_half_x = j->get_num("arena_half_x", c.arena_half_x);
	c.band_half_y = j->get_num("band_half_y", c.band_half_y);
	c.beat = j->get_num("beat", c.beat);
	c.internal_ticks_per_beat = j->get_int("internal_ticks_per_beat", c.internal_ticks_per_beat);
	c.internal_dt = j->get_num("internal_dt", c.internal_dt);
	c.time_limit = j->get_num("time_limit", c.time_limit);
	c.flag_radius = j->get_num("flag_radius", c.flag_radius);
	c.capture_rate = j->get_num("capture_rate", c.capture_rate);
	c.separation_radius = j->get_num("separation_radius", c.separation_radius);
	c.separation_force = j->get_num("separation_force", c.separation_force);
	c.walk_speed = j->get_num("walk_speed", c.walk_speed);
	c.run_speed = j->get_num("run_speed", c.run_speed);
	c.engage_trigger = j->get_num("engage_trigger", c.engage_trigger);
	c.garrison_arrive = j->get_num("garrison_arrive", c.garrison_arrive);
	c.attack_flag_hold = j->get_num("attack_flag_hold", c.attack_flag_hold);
	c.reward_survive_w = j->get_num("reward_survive_w", c.reward_survive_w);
	c.reward_flag_w = j->get_num("reward_flag_w", c.reward_flag_w);
	c.commander_hp = j->get_num("commander_hp", c.commander_hp);
	c.commander_x = j->get_num("commander_x", c.commander_x);
	c.officer_survive_w = j->get_num("officer_survive_w", c.officer_survive_w);
	c.officer_gap_per_beat = j->get_num("officer_gap_per_beat", c.officer_gap_per_beat);
	c.officer_avoid_max = j->get_num("officer_avoid_max", c.officer_avoid_max);
	c.officer_avoid_radius = j->get_num("officer_avoid_radius", c.officer_avoid_radius);
	return c;
}

void BattleEnv::load_config(const JsonPtr &j) {
	cfg = EnvConfig::from_json(j);
}

// 课程阶段采样（v2.1 断层修复，见 rl_env.h curriculum_stage 注释）
int BattleEnv::pick_curriculum_tier(RngPcg &rng) const {
	if (eval_lock_tier >= 0) return eval_lock_tier; // 评估锁档恒主档
	if (curriculum_stage < 0) return rng.randi_range(0, 2);
	if (curriculum_stage == 0) return 0; // C1：恒 17 档
	double roll = rng.randf();
	if (curriculum_stage == 1) // C2：30% 8班小档 / 35% 49 / 35% 17
		return roll < 0.30 ? 3 : (roll < 0.65 ? 1 : 0);
	// C3：80% 97 / 10% 17 / 10% 8班小档（小档回访防遗忘）
	return roll < 0.10 ? 0 : (roll < 0.20 ? 3 : 2);
}

// ── 随机对阵（真镜像：一套编制/占位两侧共用；课程阶段采样）──
// 随机性保留：档位抽取（按阶段占比）、出生带、班错位——兵种配比按编制定稿
// 表固定（tier 3 逐班 5~6 人数随机、班型取 6 人模板前缀）。
Matchup BattleEnv::gen_matchup(RngPcg &rng) const {
	Matchup m;
	int tier = pick_curriculum_tier(rng);
	const TierDef &td = tier_def(tier);
	m.side_a.tier = tier;
	// 出生带收窄 [800,1100]：8 班 4 排纵深（3×240 + 行 110）最深 ≈1930 ≤ arena 2000
	m.side_a.band_x = rng.randf_range(800.0, 1100.0);
	m.side_a.side_y = rng.randf_range(-350.0, 350.0);
	int total = 0;
	for (int si = 0; si < td.n_squads; si++) {
		m.side_a.squad_x[si] = rng.randf_range(-60.0, 60.0);
		m.side_a.squad_y[si] = rng.randf_range(-80.0, 80.0);
		// tier 3 逐班人数 5~6 随机（其余档查定稿表）；总人数 = Σ班 + 指挥官
		m.side_a.squad_n[si] = (tier == 3) ? rng.randi_range(5, 6) : td.squad_n[si];
		total += m.side_a.squad_n[si];
	}
	m.total = total + 1;
	m.side_b = m.side_a;
	return m;
}

// ── 出生（紧凑版；真镜像 x 镜射、y 同值）──
// 占位按排聚合：排 p 纵深 = p×240×side_sign（同排两班沿 y 错开 ±140 基准）、
// 班内 12 人 = 2 行（行纵深 110）×8 列（列间距 90）。
// 军衔（两军对称）：每班班首兵 = 班长 rank1（阵亡免费轮转零信号）；每排首班
// 班首 = 排长 rank2（避战奖励 + 阵亡持续惩罚载体）。
void BattleEnv::spawn_side(const SideComp &comp, int faction) {
	int side = faction - 1;
	double side_sign = (faction == 1) ? -1.0 : 1.0; // 攻西(−) 守东(+)
	const TierDef &td = tier_def(comp.tier);
	for (int si = 0; si < td.n_squads; si++) {
		int p = si / 2;                       // 每排恒 2 班：班 2p、2p+1
		double depth = (double)p * 240.0 * side_sign;
		double col_off = (si % 2 == 0) ? -140.0 : 140.0; // 同排两班 y 错开
		double sx = side_sign * (comp.band_x + comp.squad_x[si]) + depth;
		double sy = clampd(comp.side_y + col_off + comp.squad_y[si],
				-cfg.band_half_y + 80.0, cfg.band_half_y - 80.0);
		// 逐班人数以 SideComp.squad_n 为准（gen_matchup 时定：定稿档查表 / tier3 随机 5~6）
		int n = comp.squad_n[si] > 0 ? comp.squad_n[si] : td.squad_n[si];
		bool is_lead_squad = (si % 2 == 0); // 排首班 = 排长所在班
		for (int k = 0; k < n; k++) {
			int row = k / 8, col = k % 8;
			double uy = clampd(sy + ((double)col - 3.5) * 90.0, -cfg.band_half_y + 80.0, cfg.band_half_y - 80.0);
			double ux = sx + (double)row * 110.0 * side_sign;
			Unit u;
			u.x = ux;
			u.y = uy;
			u.weapon = td.squad_weapons[si][k];
			u.max_hp = cfg.w_hp[u.weapon];
			u.hp = u.max_hp;
			u.cd = 0.0;
			u.alive = true;
			u.side = side;
			u.squad = si;
			u.platoon = p;
			u.rank = k == 0 ? (is_lead_squad ? 2 : 1) : 0;
			units.push_back(u);
			squad_init[side][si] += 1;
			side_init[side] += 1;
			if (k == 0 && is_lead_squad) officer_idx[side][p] = (int)units.size() - 1;
		}
	}
	for (int si = 0; si < td.n_squads; si++) squad_alive[side][si] = squad_init[side][si];
}

// 指挥官出生（斩首维度）：双方后方 (±commander_x, 0) 各一名——x 镜射、y 同值，
// 真镜像对称严格成立；斩首胜负不受侧优势影响（谁端谁赢，天然对称）。
// 不移动不攻击（internal_tick 首行跳过）、可被打击/治疗；weapon=3 镐位占号。
void BattleEnv::spawn_commander(int faction) {
	int side = faction - 1;
	double side_sign = (faction == 1) ? -1.0 : 1.0;
	Unit c;
	c.x = side_sign * cfg.commander_x;
	c.y = 0.0;
	c.weapon = 3; // 镐位占号：不参战武器表（不攻击）
	c.max_hp = cfg.commander_hp;
	c.hp = c.max_hp;
	c.cd = 0.0;
	c.alive = true;
	c.side = side;
	c.squad = -1;   // 不入班聚合/旧观察特征（存活计数/质心/旗近邻/班块全不含指挥官）
	c.platoon = -1;
	c.rank = 3; // rank3 指挥官 = 斩首层（军衔四层最上层）
	c.is_commander = true;
	units.push_back(c);
	commander_idx[side] = (int)units.size() - 1;
}

void BattleEnv::reset(const Matchup &m, bool swap) {
	cur_matchup = m;
	cur_swap = swap;
	units.clear();
	for (int s = 0; s < 2; s++)
		for (int k = 0; k < N_SQUADS; k++) {
			squad_alive[s][k] = 0;
			squad_init[s][k] = 0;
		}
	side_init[0] = side_init[1] = 0;
	commander_idx[0] = commander_idx[1] = -1;
	for (int s = 0; s < 2; s++)
		for (int p = 0; p < N_PLATOONS; p++) {
			officer_idx[s][p] = -1;
			officer_death_beat[s][p] = -1;
		}
	decap_winner = 0;
	officer_pen_accum[0] = officer_pen_accum[1] = 0.0;
	const TierDef &td = tier_def(m.side_a.tier);
	n_squads = td.n_squads;
	n_platoons = td.n_platoons;
	for (int f = 0; f < 3; f++) {
		flag_owner[f] = 0.0;
		flag_prog[f] = 0.0;
		flag_capturing[f] = 0;
		flag_contested[f] = false;
	}
	for (int s = 0; s < 2; s++)
		for (int k = 0; k < N_SQUADS; k++) last_intent[s][k] = -1;
	decisions_made = 0;
	done = false;
	t = 0.0;
	// 正局：a 攻西(f1) / b 守东(f2)；反局整体交换。
	// 真镜像下 side_b = side_a，换边自动满足（世界已 x 镜射对称）——协议保留。
	const SideComp &comp_f1 = swap ? m.side_b : m.side_a;
	const SideComp &comp_f2 = swap ? m.side_a : m.side_b;
	spawn_side(comp_f1, 1);
	spawn_side(comp_f2, 2);
	spawn_commander(1);
	spawn_commander(2);
}

// ── 旗点结算（每拍一次；CapturePoint 语义：单方独占积分 / 双方冻结 / 无人不动）──

void BattleEnv::capture_beat() {
	const int n = (int)units.size();
	for (int f = 0; f < 3; f++) {
		double fx = flag_world_x(f);
		double fy = flag_world_y(f); // 真镜像布位（f0/f2 同 y，x 镜射对称）
		int a = 0, b = 0;
		for (int i = 0; i < n; i++) {
			if (!units[i].alive || units[i].is_commander) continue; // 指挥官不参占
			double dx = units[i].x - fx, dy = units[i].y - fy;
			if (dx * dx + dy * dy > cfg.flag_radius * cfg.flag_radius) continue;
			if (units[i].side == 0) a++;
			else b++;
		}
		flag_contested[f] = a > 0 && b > 0;
		flag_capturing[f] = 0;
		if (flag_contested[f]) continue;
		if (a > 0) {
			if (flag_owner[f] != 1.0) {
				flag_capturing[f] = 1;
				flag_prog[f] += cfg.capture_rate * cfg.beat;
				if (flag_prog[f] >= 100.0) {
					flag_owner[f] = 1.0;
					flag_prog[f] = 0.0;
					flag_capturing[f] = 0;
				}
			}
		} else if (b > 0) {
			if (flag_owner[f] != 2.0) {
				flag_capturing[f] = 2;
				flag_prog[f] += cfg.capture_rate * cfg.beat;
				if (flag_prog[f] >= 100.0) {
					flag_owner[f] = 2.0;
					flag_prog[f] = 0.0;
					flag_capturing[f] = 0;
				}
			}
		}
	}
}

int BattleEnv::nearest_enemy_unit(int idx, double *dist_out) const {
	// 基于 tick 快照几何（对称性：同 tick 内双方判定同一战场，见 snap_x 注释）
	return nearest_enemy_pos(snap_x[idx], snap_y[idx], units[idx].side, dist_out);
}

int BattleEnv::nearest_enemy_pos(double px, double py, int side, double *dist_out) const {
	int best = -1;
	double bd = 0.0;
	for (int j = 0; j < (int)units.size(); j++) {
		if (!units[j].alive || units[j].side == side) continue;
		double dx = snap_x[j] - px, dy = snap_y[j] - py;
		double d = std::sqrt(dx * dx + dy * dy);
		if (best < 0 || d < bd) {
			best = j;
			bd = d;
		}
	}
	if (dist_out) *dist_out = best >= 0 ? bd : -1.0;
	return best;
}

void BattleEnv::squad_centroid(int side, int squad, double *cx, double *cy, int *alive_n, double *hp_sum) const {
	double sx = 0, sy = 0, shp = 0;
	int cnt = 0;
	for (const Unit &u : units) {
		if (!u.alive || u.side != side || u.squad != squad) continue;
		sx += u.x;
		sy += u.y;
		shp += u.hp / u.max_hp;
		cnt++;
	}
	*cx = cnt > 0 ? sx / cnt : 0.0;
	*cy = cnt > 0 ? sy / cnt : 0.0;
	*alive_n = cnt;
	*hp_sum = cnt > 0 ? shp / cnt : 0.0;
}

// ── 内部物理步（紧凑动力学，指挥层抽象）──
// 指挥官：不移动不攻击（首行跳过），可被敌方选中打击、可被己方祭司治疗。
//
// 真镜像对称性（三件套，缺一即破）：① tick 快照几何（移动目标/射程判定/
// 分离力/治疗距离全用 tick 开始位置，处理顺序零影响）；② 伤害双相结算
//（同 tick 伤害同快照统一生效，击杀抢跑消失）；③ tie-break 自视角化
//（等距选择按自视角序，两侧镜像对应）。

void BattleEnv::internal_tick() {
	const double dt = cfg.internal_dt;
	const int n = (int)units.size();
	pending_dmg.clear();
	// tick 开始位置快照：移动目标/射程判定/分离力/治疗距离全部基于同一几何——
	// 单循环顺序无关（所有输入 = 快照，输出 = 独立的新位置与伤害登记），
	// 处理顺序/先手对动力学零影响（对称性由此成立，见 snap_x 注释）
	snap_x.resize(n);
	snap_y.resize(n);
	for (int i = 0; i < n; i++) {
		snap_x[i] = units[i].x;
		snap_y[i] = units[i].y;
	}
	for (int i = 0; i < n; i++) {
		Unit &u = units[i];
		if (!u.alive) continue;
		if (u.is_commander) continue; // 指挥官留守：不动不攻击（可被打可被治）
		int w = u.weapon;
		bool healer = (w == 5);
		bool melee = (!healer) && cfg.w_range[w] <= 250.0;
		double d0 = -1.0;
		int e0 = nearest_enemy_unit(i, &d0);
		// 班目标（意图语义翻译）
		int intent = u.squad >= 0 ? last_intent[u.side][u.squad] : 4;
		if (intent < 0) intent = 4; // 开局未下令：默认接敌
		double tx = 0, ty = 0, speed = 0;
		bool move = false;
		if (healer) {
			// 祭司：跟班质心（落在班群内），不开火
			double cx, cy;
			int an;
			double hs;
			squad_centroid(u.side, u.squad, &cx, &cy, &an, &hs);
			if (an > 0) {
				tx = cx;
				ty = cy;
				speed = cfg.walk_speed;
				move = std::sqrt((tx - u.x) * (tx - u.x) + (ty - u.y) * (ty - u.y)) > 20.0;
			}
		} else if (intent == 4 && e0 >= 0) {
			tx = snap_x[e0]; // 接敌目标用 tick 快照位置（对称几何）
			ty = snap_y[e0];
			speed = cfg.run_speed;
			move = true;
		} else if (e0 >= 0 && d0 <= cfg.w_range[w]) {
			move = false; // 射程内站桩输出
		} else if (melee && e0 >= 0 && d0 <= cfg.engage_trigger) {
			tx = snap_x[e0]; // 冲脸目标用 tick 快照位置（对称几何）
			ty = snap_y[e0];
			speed = cfg.run_speed;
			move = true;
		} else if (intent <= 2) {
			// 自视角旗 idx → 世界坐标（真镜像布位）
			int world_f = (u.side == 0) ? intent : 2 - intent;
			double fx = flag_world_x(world_f);
			double fy = flag_world_y(world_f);
			if (std::sqrt((fx - u.x) * (fx - u.x) + (fy - u.y) * (fy - u.y)) > cfg.attack_flag_hold) {
				tx = fx;
				ty = fy;
				speed = cfg.walk_speed;
				move = true;
			}
		} else { // intent == 3 驻防最近己旗 → 无己旗退化攻自视角中旗
			int my = u.side == 0 ? 1 : 2;
			int pick = -1;
			double pd = 0.0;
			// 按自视角左中右序遍历（等距 tie 保留先者）——镜像 tie 对称的关鍵：
			// 世界下标序在 f2 侧不自视角翻转，等距双己旗时两侧驻防点会破镜像
			for (int sv = 0; sv < 3; sv++) {
				int f = (u.side == 0) ? sv : 2 - sv;
				if (flag_owner[f] != (double)my) continue;
				double fx = flag_world_x(f);
				double fy = flag_world_y(f);
				double d = std::sqrt((fx - u.x) * (fx - u.x) + (fy - u.y) * (fy - u.y));
				if (pick < 0 || d < pd) {
					pick = f;
					pd = d;
				}
			}
			int selfview_idx = pick >= 0 ? (u.side == 0 ? pick : 2 - pick) : 1;
			// 自视角下标 → 世界旗下标（f2 自视角左右翻转）——旧实现漏了这层换算，
			// f2 驻防兵会走向敌半场的镜像旗（真镜像对拍 113 拍破缺定位）
			int wf = (u.side == 0) ? selfview_idx : 2 - selfview_idx;
			double fx = flag_world_x(wf);
			double fy = flag_world_y(wf);
			if (std::sqrt((fx - u.x) * (fx - u.x) + (fy - u.y) * (fy - u.y)) > cfg.garrison_arrive) {
				tx = fx;
				ty = fy;
				speed = cfg.walk_speed;
				move = true;
			}
		}
		// 位移（dir + 分离力，同紧凑核心 v1 口径）
		double dirx = 0, diry = 0;
		if (move) {
			double dx = tx - u.x, dy = ty - u.y;
			double len = std::sqrt(dx * dx + dy * dy);
			if (len > 1e-9) {
				dirx = dx / len;
				diry = dy / len;
			}
		}
		double pushx = 0, pushy = 0;
		for (int j = 0; j < n; j++) {
			if (j == i || !units[j].alive) continue;
			double dx = snap_x[i] - snap_x[j], dy = snap_y[i] - snap_y[j]; // 快照几何（对称受力）
			double d = std::sqrt(dx * dx + dy * dy);
			if (d >= cfg.separation_radius || d <= 1e-9) continue;
			double wgt = 1.0 - d / cfg.separation_radius;
			pushx += dx / d * wgt;
			pushy += dy / d * wgt;
		}
		double stepx = dirx + cfg.separation_force * pushx;
		double stepy = diry + cfg.separation_force * pushy;
		double slen = std::sqrt(stepx * stepx + stepy * stepy);
		if (slen > 1e-9) {
			u.x += stepx / slen * speed * dt;
			u.y += stepy / slen * speed * dt;
		}
		u.x = clampd(u.x, -cfg.arena_half_x, cfg.arena_half_x);
		u.y = clampd(u.y, -cfg.band_half_y, cfg.band_half_y);
		// 攻击 / 治疗
		u.cd = u.cd > 0.0 ? u.cd - dt : 0.0;
		if (healer) {
			if (u.cd <= 0.0) {
				int best = -1;
				double best_ratio = 1.0;
				for (int j = 0; j < n; j++) {
					if (j == i || !units[j].alive || units[j].side != u.side) continue;
					double dx = units[j].x - u.x, dy = units[j].y - u.y;
					if (dx * dx + dy * dy > 400.0 * 400.0) continue; // 治疗 400px（SWL 口径）
					double ratio = units[j].hp / units[j].max_hp;
					if (ratio < 1.0 && ratio < best_ratio) {
						best_ratio = ratio;
						best = j;
					}
				}
				if (best >= 0) {
					units[best].hp += 30.0;
					if (units[best].hp > units[best].max_hp) units[best].hp = units[best].max_hp;
					u.cd = 3.0;
				}
			}
		} else {
			double d1 = -1.0;
			int e1 = nearest_enemy_unit(i, &d1);
			if (u.cd <= 0.0 && e1 >= 0 && d1 <= cfg.w_range[w]) {
				// 伤害只登记（tick 末双相统一结算——见 pending_dmg 注释）
				pending_dmg.push_back({ e1, cfg.w_dmg[w] });
				u.cd = cfg.w_cd[w];
			}
		}
		} // per-unit
	flush_pending_damage();
}

// 伤害双相结算（tick 末）：统一扣血 + 死亡登记（斩首/排长缺口/班存活）。
// 双方指挥官同 tick 被端 → 相互斩首判平局（winner=0、reason=1）。
void BattleEnv::flush_pending_damage() {
	for (const auto &pd : pending_dmg) {
		Unit &t = units[pd.target];
		if (!t.alive) continue; // 同拍多重打击不复活已死者
		t.hp -= pd.dmg;
		if (t.hp > 0.0) continue;
		t.alive = false;
		if (t.is_commander) {
			int killer_side = 1 - t.side; // 凶手侧 = 受害者对侧
			if (decap_winner == 0) {
				decap_winner = killer_side + 1;
			} else if (decap_winner != killer_side + 1) {
				decap_winner = 0; // 同拍双方斩首 → 平局
			}
			done = true;
		} else {
			squad_alive[t.side][t.squad] -= 1;
			// 排长阵亡：记缺口起点拍（班长 rank1 阵亡免费轮转零信号）
			if (t.rank == 2 && t.platoon >= 0
					&& officer_death_beat[t.side][t.platoon] < 0)
				officer_death_beat[t.side][t.platoon] = decisions_made;
		}
	}
	pending_dmg.clear();
}

// 排长贴敌连续惩罚（每拍一次；敌军质心 = 敌方存活士兵质心，不含指挥官）：
// 单排长每拍最多 officer_avoid_max/BEATS_MAX，全程满贴 = officer_avoid_max/排长。
void BattleEnv::accumulate_officer_penalties() {
	for (int side = 0; side < 2; side++) {
		int foe = 1 - side;
		// 敌军存活士兵质心
		double cx = 0, cy = 0;
		int cnt = 0;
		for (const Unit &u : units) {
			if (!u.alive || u.is_commander || u.side != foe) continue;
			cx += u.x;
			cy += u.y;
			cnt++;
		}
		if (cnt == 0) continue; // 无敌存活：无从贴起
		cx /= cnt;
		cy /= cnt;
		double per_beat = cfg.officer_avoid_max / (double)BEATS_MAX;
		for (int p = 0; p < n_platoons; p++) {
			int oi = officer_idx[side][p];
			if (oi < 0 || !units[oi].alive) continue;
			double dx = units[oi].x - cx, dy = units[oi].y - cy;
			double d = std::sqrt(dx * dx + dy * dy);
			if (d >= cfg.officer_avoid_radius) continue;
			officer_pen_accum[side] += (1.0 - d / cfg.officer_avoid_radius) * per_beat;
		}
	}
}

void BattleEnv::step(const int *actions_f1, const int *actions_f2) {
	if (done) return;
	// 只更新存活班的意图（空班/全灭班保持 -1 → 观察 one-hot 全 0，无假信号）
	for (int si = 0; si < n_squads; si++) {
		if (squad_alive[0][si] > 0) last_intent[0][si] = actions_f1[si];
		if (squad_alive[1][si] > 0) last_intent[1][si] = actions_f2[si];
	}
	capture_beat();
	for (int t_i = 0; t_i < cfg.internal_ticks_per_beat; t_i++) {
		if (done) break; // 斩首立即终止本拍剩余物理步
		internal_tick();
	}
	if (!done) accumulate_officer_penalties();
	t += cfg.beat;
	decisions_made++;
	int a0 = 0, a1 = 0;
	for (const Unit &u : units) {
		if (!u.alive || u.is_commander) continue; // 歼灭判定只数士兵
		if (u.side == 0) a0++;
		else a1++;
	}
	if (a0 == 0 || a1 == 0) done = true;
	if (decisions_made >= BEATS_MAX) done = true;
}

// ── 125 维观察（faction 1/2，全特征己方视角镜像；布局表见 README）──
//
//   [0..5]    全局 6：己存活比/敌存活比/存活计数差(−1..1)/己均血/敌均血/剩余时间
//             （存活统计不含指挥官；initial = 16/48/96）
//   [6..26]   旗×3（自视角左中右 = 镜像 x 升序）stride 7：归属 one-hot(己/敌/中立)
//             + 进度/100 + 己近旗人数比 + 敌近旗人数比 + 全军质心距/2500
//   [27..106] 班×8（编制槽序）stride 10：镜像位置(x/2000, y/400) + 存活比 + 均血
//             + 最近敌班质心距/1500 + 上拍意图 one-hot(5)
//             （空班/全灭班：位置/计数/均血置 0、意图 one-hot 全 0（last_intent=-1），
//             近敌距照算且空班/空敌班质心回落 (mid_x, spawn_y)=(0,0)）
//   [107..122] 排×4 stride 4：排长存活(0/1) + 排长镜像位置(2) + 排存活比
//             （空排全 0；排长阵亡位置置 0 只留存活标志 0）
//   [123..124] 指挥官 2：己方血量比 + 敌方血量比（01；阵亡 → 0，但斩首即终局）

void BattleEnv::observe(int faction, std::vector<double> &out) const {
	out.assign(OBS_DIM, 0.0);
	int side = faction - 1;
	int foe_side = 1 - side;
	int foe = 3 - faction;
	double mir = (faction == 1) ? 1.0 : -1.0;
	// 全局块 [0..5]（存活统计不含指挥官）
	int my_alive = 0, foe_alive = 0;
	double my_hp = 0.0, foe_hp = 0.0;
	for (const Unit &u : units) {
		if (!u.alive || u.is_commander) continue;
		double ratio = u.hp / u.max_hp;
		if (u.side == side) {
			my_alive += 1;
			my_hp += ratio;
		} else {
			foe_alive += 1;
			foe_hp += ratio;
		}
	}
	int my_init = side_init[side] > 0 ? side_init[side] : 1;
	int foe_init = side_init[foe_side] > 0 ? side_init[foe_side] : 1;
	out[0] = norm01((double)my_alive / (double)my_init);
	out[1] = norm01((double)foe_alive / (double)foe_init);
	out[2] = clampd((double)my_alive / (double)(my_alive + foe_alive > 0 ? my_alive + foe_alive : 1) * 2.0 - 1.0, -1.0, 1.0);
	out[3] = norm01(my_alive > 0 ? my_hp / (double)my_alive : 0.0);
	out[4] = norm01(foe_alive > 0 ? foe_hp / (double)foe_alive : 0.0);
	out[5] = clampd(1.0 - t / cfg.time_limit, 0.0, 1.0);
	// 己方全军质心（士兵）
	double ccx = 0, ccy = 0;
	if (my_alive > 0) {
		for (const Unit &u : units) {
			if (!u.alive || u.is_commander || u.side != side) continue;
			ccx += u.x;
			ccy += u.y;
		}
		ccx /= my_alive;
		ccy /= my_alive;
	}
	// 旗块 [6..26]：自视角左中右 = 镜像 x 升序 → f=0(midx−500) 恒为双方的自视角左
	for (int fi = 0; fi < 3; fi++) {
		int f = (side == 0) ? fi : 2 - fi; // 世界旗下标
		double fx = flag_world_x(f);
		double fy = flag_world_y(f);
		int base = 6 + fi * 7;
		out[base + 0] = (flag_owner[f] == (double)faction) ? 1.0 : 0.0;
		out[base + 1] = (flag_owner[f] == (double)foe) ? 1.0 : 0.0;
		out[base + 2] = (flag_owner[f] == 0.0) ? 1.0 : 0.0;
		out[base + 3] = norm01(flag_prog[f] / 100.0);
		int my_near = 0, foe_near = 0;
		double my_total = (double)(my_alive > 0 ? my_alive : 1);
		double foe_total = (double)(foe_alive > 0 ? foe_alive : 1);
		for (const Unit &u : units) {
			if (!u.alive || u.is_commander) continue;
			double dx = u.x - fx, dy = u.y - fy;
			if (dx * dx + dy * dy > cfg.flag_radius * cfg.flag_radius) continue;
			if (u.side == side) my_near += 1;
			else foe_near += 1;
		}
		out[base + 4] = norm01((double)my_near / my_total);
		out[base + 5] = norm01((double)foe_near / foe_total);
		out[base + 6] = norm01(std::sqrt((ccx - fx) * (ccx - fx) + (ccy - fy) * (ccy - fy)) / 2500.0);
	}
	// 班块 [27..106]：8 槽编制序；镜像位置；上拍意图 one-hot
	for (int si = 0; si < N_SQUADS; si++) {
		int base = 27 + si * 10;
		double cx = 0, cy = 0, hp_avg = 0;
		int alive_n = 0;
		squad_centroid(side, si, &cx, &cy, &alive_n, &hp_avg);
		if (alive_n > 0) {
			out[base + 0] = clampd(mir * (cx - 0.0) / 2000.0, -1.0, 1.0);
			out[base + 1] = clampd((cy - 0.0) / 400.0, -1.0, 1.0);
		}
		out[base + 2] = norm01((double)alive_n / (double)(squad_init[side][si] > 0 ? squad_init[side][si] : 1));
		out[base + 3] = norm01(hp_avg > 0.0 ? hp_avg : 0.0);
		// 最近敌班质心距（无条件计算——空班质心回落 (mid_x, spawn_y)=(0,0)、
		// 空敌班质心同样回落参与比较；无敌 → 3000 → norm01=1）
		double best = 3000.0;
		for (int fs = 0; fs < N_SQUADS; fs++) {
			double ecx = 0, ecy = 0;
			int en = 0;
			double ehp = 0;
			squad_centroid(foe_side, fs, &ecx, &ecy, &en, &ehp);
			// 空班（en<=0）质心已回落 (0,0)，照算
			double d = std::sqrt((ecx - cx) * (ecx - cx) + (ecy - cy) * (ecy - cy));
			if (d < best) best = d;
		}
		out[base + 4] = norm01(best / 1500.0);
		int li = last_intent[side][si];
		if (li >= 0 && li < N_ACTIONS_PER_SQUAD)
			out[base + 5 + li] = 1.0;
	}
	// 排层 [107..122]：4 槽 stride 4
	for (int p = 0; p < N_PLATOONS; p++) {
		int base = 107 + p * 4;
		if (p >= n_platoons) continue; // 空排全 0
		int oi = officer_idx[side][p];
		if (oi < 0) continue;
		const Unit &off = units[oi];
		if (off.alive) {
			out[base + 0] = 1.0;
			out[base + 1] = clampd(mir * off.x / 2000.0, -1.0, 1.0);
			out[base + 2] = clampd(off.y / 400.0, -1.0, 1.0);
		}
		// 排存活比 = 排内两班存活和 / 初始和
		int s0 = p * 2, s1 = p * 2 + 1;
		int ini = squad_init[side][s0] + squad_init[side][s1];
		int alv = squad_alive[side][s0] + squad_alive[side][s1];
		out[base + 3] = norm01((double)alv / (double)(ini > 0 ? ini : 1));
	}
	// 指挥官 [123..124]：双方血量比（阵亡 → 0；斩首即终局）
	for (int s = 0; s < 2; s++) {
		int ci = commander_idx[s];
		if (ci < 0) continue;
		const Unit &c = units[ci];
		double ratio = c.alive ? c.hp / c.max_hp : 0.0;
		out[123 + s] = norm01(ratio);
	}
}

void BattleEnv::active_mask(int faction, int *mask8) const {
	int side = faction - 1;
	for (int k = 0; k < N_SQUADS; k++) mask8[k] = squad_alive[side][k] > 0 ? 1 : 0;
}

EnvResult BattleEnv::result() const {
	EnvResult r;
	r.decisions = decisions_made;
	r.duration = t;
	r.initial[0] = side_init[0];
	r.initial[1] = side_init[1];
	r.n_platoons = n_platoons;
	for (const Unit &u : units) {
		if (!u.alive || u.is_commander) continue;
		r.alive[u.side] += 1;
	}
	for (int f = 0; f < 3; f++) {
		if (flag_owner[f] == 1.0) r.flags_owned[0]++;
		else if (flag_owner[f] == 2.0) r.flags_owned[1]++;
	}
	r.timeout = decisions_made >= BEATS_MAX && decap_winner == 0;
	// 排长终局统计（存活数 / 缺口拍数 / 贴敌罚）
	for (int s = 0; s < 2; s++) {
		r.officer_pen[s] = officer_pen_accum[s];
		for (int p = 0; p < n_platoons; p++) {
			int oi = officer_idx[s][p];
			if (oi < 0) continue;
			if (units[oi].alive) r.officer_alive[s] += 1;
			if (officer_death_beat[s][p] >= 0)
				r.gap_beats[s] += (long)(decisions_made - officer_death_beat[s][p]);
		}
	}
	if (decap_winner != 0) {
		r.winner = decap_winner;
		r.reason = 1; // 斩首（结算优先级最高）
	} else if (r.alive[0] == 0 && r.alive[1] == 0) {
		r.winner = 0; // 同归于尽 → 平局（v1 遗留 tie-break 判 f2 是真镜像下的系统性偏向，已修）
	} else if (r.alive[0] == 0 || r.alive[1] == 0) {
		r.winner = r.alive[0] == 0 ? 2 : 1;
	} else if (r.timeout || t >= cfg.time_limit) {
		// 超时按剩余存活判胜（_collect_result 兜底口径）；等则平
		r.winner = r.alive[0] > r.alive[1] ? 1 : (r.alive[1] > r.alive[0] ? 2 : 0);
	}
	r.reward_f1 = faction_reward(r, 1);
	r.reward_f2 = faction_reward(r, 2);
	return r;
}

// 奖励装配（v3 防退化塑形 + 排长分层；全差分 → r_f1 + r_f2 ≡ 0）：
//   终局 ±1（胜负主信号）。
//   存活比差 0.2（旧 0.5：零和下诱导保守化——缩着不打等超时；降权后积极性项占优）。
//   夺点差 0.5（推进/接敌的直接信号，权重不低于存活差）。
//   排长三件（避战奖励挂 rank2 层，权重可 config 覆盖）：
//     +officer_survive_w × 排长存活比差（保排长 + 端敌排长双向激励）
//     −officer_gap_per_beat × 缺口拍差（阵亡持续小罚，梯度比一次性罚平滑）
//     −贴敌罚差（排长冲脸的连续惩罚，单排长全程上限 officer_avoid_max）
double BattleEnv::faction_reward(const EnvResult &r, int faction) const {
	int foe = 3 - faction;
	int fi = faction - 1, fe = foe - 1;
	double np = (double)(r.n_platoons > 0 ? r.n_platoons : 1);
	double rw = 0.0;
	if (r.winner == faction) rw += 1.0;
	else if (r.winner == foe) rw -= 1.0;
	rw += cfg.reward_survive_w * ((double)r.alive[fi] / (double)(r.initial[fi] > 0 ? r.initial[fi] : 1)
			- (double)r.alive[fe] / (double)(r.initial[fe] > 0 ? r.initial[fe] : 1));
	rw += cfg.reward_flag_w * (double)(r.flags_owned[fi] - r.flags_owned[fe]) / 3.0;
	// 排长三件（差分）
	rw += cfg.officer_survive_w * ((double)r.officer_alive[fi] - (double)r.officer_alive[fe]) / np;
	rw -= cfg.officer_gap_per_beat * ((double)r.gap_beats[fi] - (double)r.gap_beats[fe]) / np;
	rw -= r.officer_pen[fi] - r.officer_pen[fe];
	return rw;
}

// ── 评估对手（军师规划器打分镜像；打分表见 squad_intent_planner.gd 常量区）──
//
//   ratio = clamp(own/max(foe,1), 0.1, 2)；dist_factor = clamp(1−d/3000, 0.05, 1)
//   CAPTURE(未占/敌占旗) = 85 × dist_factor × ratio − 40(重复) + 30(惯性)
//   GARRISON(己占旗)    = 50 × (重复?0.3:1) × dist_factor + 30(惯性)
//   INTERCEPT(敌班近己旗<600, 需己有旗) = 90 × (1+(1−threat/600)) × dist_factor × ratio
//                                        − 40(重复) + 30(惯性)
//   argmax 严格大于（基线 0，全负不动）；翻译：CAPTURE→意图0/1/2（自视角），
//   GARRISON→3，INTERCEPT→4。
void BattleEnv::planner_intents(int faction, int *intents8) {
	const double SCORE_CAPTURE = 85.0, SCORE_INTERCEPT = 90.0, SCORE_GARRISON = 50.0;
	const double INERTIA = 30.0, DUP = 40.0, DECAY = 3000.0, TRIGGER = 600.0;
	const double RATIO_FLOOR = 0.1, RATIO_CEIL = 2.0, DF_FLOOR = 0.05, STACK = 0.3;
	int side = faction - 1;
	int own_total = 0, foe_total = 0;
	for (const Unit &x : units) {
		if (!x.alive || x.is_commander) continue;
		if (x.side == side) own_total++;
		else foe_total++;
	}
	for (int k = 0; k < N_SQUADS; k++) intents8[k] = -1; // -1 = 不动（保持上拍）
	if (own_total <= 0) return;
	double ratio = clampd((double)own_total / (double)(foe_total > 0 ? foe_total : 1), RATIO_FLOOR, RATIO_CEIL);
	// 己方旗质心（INTERCEPT 威胁距离用）
	bool has_home = false;
	double home_fx[3], home_fy[3];
	int home_n = 0;
	for (int f = 0; f < 3; f++) {
		if (flag_owner[f] == (double)faction) {
			has_home = true;
			home_fx[home_n] = flag_world_x(f);
			home_fy[home_n] = flag_world_y(f);
			home_n++;
		}
	}
	// 敌班聚合（质心 + 存活数）
	double e_cx[N_SQUADS], e_cy[N_SQUADS];
	int e_n[N_SQUADS];
	for (int fs = 0; fs < N_SQUADS; fs++) {
		double hp;
		squad_centroid(1 - side, fs, &e_cx[fs], &e_cy[fs], &e_n[fs], &hp);
	}
	int assigned_flag[3] = { 0, 0, 0 };
	int assigned_enemy[N_SQUADS] = { 0 };
	for (int si = 0; si < n_squads; si++) {
		double cx, cy, hp;
		int an;
		squad_centroid(side, si, &cx, &cy, &an, &hp);
		if (an <= 0) continue; // 全灭班不动
		struct Cand {
			double score;
			int intent; // 0/1/2 攻旗(自视角) 3 驻防 4 接敌
			int target; // 旗世界下标 或 敌班序
		};
		Cand cands[8 + 3];
		int nc = 0;
		double df_arr[3];
		for (int f = 0; f < 3; f++) {
			double fx = flag_world_x(f);
			double fy = flag_world_y(f);
			double df = clampd(1.0 - std::sqrt((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)) / DECAY, DF_FLOOR, 1.0);
			df_arr[f] = df;
			if (flag_owner[f] != (double)faction) {
				double sc = SCORE_CAPTURE * df * ratio;
				if (assigned_flag[f] > 0) sc -= DUP;
				// 惯性：上拍同意图同目标
				int selfview = (side == 0) ? f : 2 - f;
				if (last_intent[side][si] == selfview) sc += INERTIA;
				cands[nc].score = sc;
				cands[nc].intent = selfview;
				cands[nc].target = f;
				nc++;
			} else {
				double deficit = assigned_flag[f] > 0 ? STACK : 1.0;
				double sc = SCORE_GARRISON * deficit * df;
				if (last_intent[side][si] == 3) sc += INERTIA;
				cands[nc].score = sc;
				cands[nc].intent = 3;
				cands[nc].target = f;
				nc++;
			}
		}
		if (has_home) {
			for (int es = 0; es < N_SQUADS; es++) {
				if (e_n[es] <= 0) continue;
				double threat = 1e18;
				for (int h = 0; h < home_n; h++) {
					double d = std::sqrt((e_cx[es] - home_fx[h]) * (e_cx[es] - home_fx[h])
							+ (e_cy[es] - home_fy[h]) * (e_cy[es] - home_fy[h]));
					if (d < threat) threat = d;
				}
				if (threat >= TRIGGER) continue;
				double urgency = 1.0 + (1.0 - threat / TRIGGER);
				double df = clampd(1.0 - std::sqrt((e_cx[es] - cx) * (e_cx[es] - cx) + (e_cy[es] - cy) * (e_cy[es] - cy)) / DECAY, DF_FLOOR, 1.0);
				double sc = SCORE_INTERCEPT * urgency * df * ratio;
				if (assigned_enemy[es] > 0) sc -= DUP;
				if (last_intent[side][si] == 4) sc += INERTIA;
				cands[nc].score = sc;
				cands[nc].intent = 4;
				cands[nc].target = es;
				nc++;
			}
		}
		// argmax 严格大于（基线 0）
		double best_score = 0.0;
		Cand best;
		bool has = false;
		for (int c = 0; c < nc; c++) {
			if (cands[c].score > best_score) {
				best_score = cands[c].score;
				best = cands[c];
				has = true;
			}
		}
		if (!has) continue;
		intents8[si] = best.intent;
		if (best.intent <= 2) assigned_flag[best.target]++;
		else if (best.intent == 3) assigned_flag[best.target]++;
		else assigned_enemy[best.target]++;
	}
	// 未决策班保持上拍意图（无 → 接敌）；全灭班 -1（step 不覆写，观察 one-hot 全 0）
	for (int k = 0; k < N_SQUADS; k++)
		if (intents8[k] < 0 && squad_alive[side][k] > 0)
			intents8[k] = last_intent[side][k] >= 0 ? last_intent[side][k] : 4;
}

int BattleEnv::find_commander(int faction) const {
	return commander_idx[faction - 1];
}

// ── 对拍夹具：状态帧 dump（v3 格式：新维度 GDScript 镜像编码器消费）──
// 帧内 units 含 rank/is_commander、root 含 squad_initial/platoons 分组——
// 镜像侧不依赖 C++ 内部，仅凭帧数据独立重算 125 维观察，帧对帧对拍。
JsonPtr BattleEnv::dump_obs_fixture(uint32_t seed, int sample_every, int max_frames) const {
	// 复制一份跑（const 方法内不改 this）
	BattleEnv tmp = *this;
	RngPcg rng;
	rng.seed(seed);
	Matchup m = tmp.gen_matchup(rng);
	tmp.reset(m, false);
	const TierDef &td = tier_def(m.side_a.tier);
	auto frames = Json::make(Json::ARR);
	int frames_n = 0;
	int beat = 0;
	// 帧 0（reset 后，未决策未结算）
	while (!tmp.done && frames_n < max_frames) {
		if (beat % sample_every == 0) {
			auto fr = Json::make(Json::OBJ);
			fr->set("t", Json::num_of(tmp.t));
			auto li = Json::make(Json::OBJ);
			for (int f = 1; f <= 2; f++) {
				auto arr = Json::make(Json::ARR);
				for (int k = 0; k < N_SQUADS; k++) arr->arr.push_back(Json::num_of(tmp.last_intent[f - 1][k]));
				li->set(std::to_string(f), arr);
			}
			fr->set("last_intent", li);
			auto flags = Json::make(Json::ARR);
			for (int f = 0; f < 3; f++) {
				auto fo = Json::make(Json::OBJ);
				fo->set("owner", Json::num_of(tmp.flag_owner[f]));
				fo->set("progress", Json::num_of(tmp.flag_prog[f]));
				flags->arr.push_back(fo);
			}
			fr->set("flags", flags);
			auto us = Json::make(Json::ARR);
			for (const Unit &u : tmp.units) {
				auto uo = Json::make(Json::OBJ);
				uo->set("side", Json::num_of(u.side));
				uo->set("squad", Json::num_of(u.squad));
				uo->set("rank", Json::num_of(u.rank));
				uo->set("is_commander", Json::bool_of(u.is_commander));
				uo->set("x", Json::num_of(u.x));
				uo->set("y", Json::num_of(u.y));
				uo->set("ratio", Json::num_of(u.alive ? u.hp / u.max_hp : 0.0));
				uo->set("alive", Json::bool_of(u.alive));
				us->arr.push_back(uo);
			}
			fr->set("units", us);
			// C++ 侧同状态编码（verify 与 GDScript 侧输出帧对帧比对）
			std::vector<double> o1, o2;
			tmp.observe(1, o1);
			tmp.observe(2, o2);
			auto of1 = Json::make(Json::ARR);
			auto of2 = Json::make(Json::ARR);
			for (double v : o1) of1->arr.push_back(Json::num_of(v));
			for (double v : o2) of2->arr.push_back(Json::num_of(v));
			fr->set("obs_f1", of1);
			fr->set("obs_f2", of2);
			frames->arr.push_back(fr);
			frames_n++;
		}
		// 固定意图循环（无 RNG，可复现）
		int af1[N_SQUADS], af2[N_SQUADS];
		for (int g = 0; g < N_SQUADS; g++) {
			af1[g] = (beat + g) % N_ACTIONS_PER_SQUAD;
			af2[g] = (beat * 2 + g * 3 + 1) % N_ACTIONS_PER_SQUAD;
		}
		tmp.step(af1, af2);
		beat++;
	}
	auto root = Json::make(Json::OBJ);
	root->set("format", Json::str_of("rl_core.obs_fixture.v3"));
	root->set("seed", Json::num_of((double)seed));
	root->set("obs_dim", Json::num_of((double)OBS_DIM));
	root->set("n_squads", Json::num_of((double)N_SQUADS));
	root->set("n_platoons_max", Json::num_of((double)N_PLATOONS));
	root->set("n_squads_actual", Json::num_of((double)tmp.n_squads));
	root->set("n_platoons_actual", Json::num_of((double)tmp.n_platoons));
	root->set("army_tier", Json::num_of((double)ARMY_TIERS[m.side_a.tier]));
	root->set("tier", Json::num_of((double)m.side_a.tier)); // 0/1/2/3（tier3 与 tier1 同 49 典型值）
	root->set("time_limit", Json::num_of(cfg.time_limit));
	root->set("mid_x", Json::num_of(0.0));
	root->set("spawn_y", Json::num_of(0.0));
	// 初始班人数（存活比分母；[side][squad]）
	auto si_root = Json::make(Json::ARR);
	for (int s = 0; s < 2; s++) {
		auto arr = Json::make(Json::ARR);
		for (int k = 0; k < N_SQUADS; k++) arr->arr.push_back(Json::num_of((double)tmp.squad_init[s][k]));
		si_root->arr.push_back(arr);
	}
	root->set("squad_initial", si_root);
	// 排分组（班下标对；编制定稿每排恒 2 班）
	auto pl_root = Json::make(Json::ARR);
	for (int p = 0; p < tmp.n_platoons; p++) {
		auto arr = Json::make(Json::ARR);
		arr->arr.push_back(Json::num_of((double)(p * 2)));
		arr->arr.push_back(Json::num_of((double)(p * 2 + 1)));
		pl_root->arr.push_back(arr);
	}
	root->set("platoons", pl_root);
	// 旗几何（世界序 f0/f1/f2）
	root->set("flags", []() {
		auto arr = Json::make(Json::ARR);
		for (int f = 0; f < 3; f++) {
			auto fo = Json::make(Json::OBJ);
			fo->set("x", Json::num_of(flag_world_x(f)));
			fo->set("y", Json::num_of(flag_world_y(f)));
			fo->set("radius", Json::num_of(180.0));
			arr->arr.push_back(fo);
		}
		return arr;
	}());
	root->set("frames", frames);
	return root;
}

} // namespace rl
