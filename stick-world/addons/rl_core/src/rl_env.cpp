#include "rl_env.h"

#include <cmath>

namespace rl {

EnvConfig EnvConfig::from_json(const JsonPtr &j) {
	EnvConfig c; // 默认值已在声明处
	if (!j || j->type != Json::OBJ) return c;
	c.arena_half_x = j->get_num("arena_half_x", c.arena_half_x);
	c.band_half_y = j->get_num("band_half_y", c.band_half_y);
	c.team_offset_x = j->get_num("team_offset_x", c.team_offset_x);
	c.flag_radius = j->get_num("flag_radius", c.flag_radius);
	c.capture_rate = j->get_num("capture_rate", c.capture_rate);
	c.dt = j->get_num("dt", c.dt);
	c.ticks_per_decision = j->get_int("ticks_per_decision", c.ticks_per_decision);
	c.max_decisions = j->get_int("max_decisions", c.max_decisions);
	c.separation_radius = j->get_num("separation_radius", c.separation_radius);
	c.separation_force = j->get_num("separation_force", c.separation_force);
	c.walk_speed = j->get_num("walk_speed", c.walk_speed);
	c.run_speed = j->get_num("run_speed", c.run_speed);
	c.engage_trigger = j->get_num("engage_trigger", c.engage_trigger);
	c.attack_flag_hold = j->get_num("attack_flag_hold", c.attack_flag_hold);
	c.garrison_hold = j->get_num("garrison_hold", c.garrison_hold);
	JsonPtr fx = j->get("flag_x");
	if (fx && fx->type == Json::ARR && fx->arr.size() == 3)
		for (int i = 0; i < 3; i++) c.flag_x[i] = fx->arr[i]->num;
	JsonPtr fy = j->get("flag_y");
	if (fy && fy->type == Json::ARR && fy->arr.size() == 3)
		for (int i = 0; i < 3; i++) c.flag_y[i] = fy->arr[i]->num;
	// 武器表：[[hp,dmg,cd,range]×4]（顺序 0剑 1矛 2弓 3杖）
	JsonPtr wep = j->get("weapons");
	if (wep && wep->type == Json::ARR && wep->arr.size() == 4) {
		for (int i = 0; i < 4; i++) {
			JsonPtr row = wep->arr[i];
			if (row && row->type == Json::ARR && row->arr.size() == 4) {
				c.w_hp[i] = row->arr[0]->num;
				c.w_dmg[i] = row->arr[1]->num;
				c.w_cd[i] = row->arr[2]->num;
				c.w_range[i] = row->arr[3]->num;
			}
		}
	}
	return c;
}

// 编制 → 武器映射：矛班=1 剑班=0 火力班=杖(3)在前弓(2)在后
static int squad_weapon(int squad, int idx_in_squad, const Comp &c) {
	if (squad == 0) return 1;
	if (squad == 1) return 0;
	return idx_in_squad < c.staff ? 3 : 2;
}

static int squad_size(int squad, const Comp &c) {
	if (squad == 0) return c.spear;
	if (squad == 1) return c.sword;
	return c.staff + c.bow;
}

void BattleEnv::load_config(const JsonPtr &j) {
	cfg = EnvConfig::from_json(j);
}

void BattleEnv::reset(uint32_t seed) {
	rng.seed(seed);
	Comp ca, cd;
	// 抽样顺序即规格：矛(2选) 剑(3选) 杖(3选) 弓(3选)，攻方先守方后
	ca.spear = cfg.spear_opts[rng.below(2)];
	ca.sword = cfg.sword_opts[rng.below(3)];
	ca.staff = cfg.staff_opts[rng.below(3)];
	ca.bow = cfg.bow_opts[rng.below(3)];
	cd.spear = cfg.spear_opts[rng.below(2)];
	cd.sword = cfg.sword_opts[rng.below(3)];
	cd.staff = cfg.staff_opts[rng.below(3)];
	cd.bow = cfg.bow_opts[rng.below(3)];
	reset_fixed(seed, ca, cd);
}

void BattleEnv::reset_fixed(uint32_t seed, const Comp &att, const Comp &def) {
	rng.seed(seed);
	comp_att = att;
	comp_def = def;
	units.clear();
	intents[0][0] = intents[0][1] = intents[0][2] = 4; // 默认接敌推进
	intents[1][0] = intents[1][1] = intents[1][2] = 4;
	decisions_made = 0;
	done = false;
	for (int f = 0; f < 3; f++) {
		flag_owner[f] = 0.0;
		flag_prog[f] = 0.0;
		flag_capturing[f] = 0;
		flag_contested[f] = false;
	}
	const Comp comps[2] = { att, def };
	for (int side = 0; side < 2; side++) {
		double forward = (side == 0) ? 1.0 : -1.0; // 攻左进 +x
		for (int k = 0; k < 3; k++) {
			int n = squad_size(k, comps[side]);
			squad_alive[side][k] = n;
			squad_init[side][k] = n;
			double cx = -forward * (cfg.team_offset_x - (double)k * 150.0); // 攻 x<0，守 x>0
			double cy = (double)k * 150.0 - 150.0;
			int cols = n < 8 ? (n > 0 ? n : 1) : 8;
			int rows = (n + cols - 1) / cols;
			double hp_sum = 0.0;
			for (int i = 0; i < n; i++) {
				Unit u;
				int r = i / cols, c = i % cols;
				u.x = cx + ((double)c - (double)(cols - 1) * 0.5) * 70.0;
				u.y = cy + ((double)r - (double)(rows - 1) * 0.5) * 70.0;
				u.weapon = squad_weapon(k, i, comps[side]);
				u.max_hp = cfg.w_hp[u.weapon];
				u.hp = u.max_hp;
				u.side = side;
				u.squad = k;
				u.cd = 0.0;
				u.alive = true;
				hp_sum += u.max_hp;
				units.push_back(u);
			}
			squad_init_hp[side][k] = hp_sum;
		}
	}
}

int BattleEnv::nearest_enemy(int idx, double *dist_out) const {
	const Unit &u = units[idx];
	int best = -1;
	double bd = 0.0;
	for (int j = 0; j < (int)units.size(); j++) {
		if (j == idx || !units[j].alive || units[j].side == u.side) continue;
		double dx = units[j].x - u.x, dy = units[j].y - u.y;
		double d = std::sqrt(dx * dx + dy * dy);
		if (best < 0 || d < bd) {
			best = j;
			bd = d;
		}
	}
	if (dist_out != nullptr) *dist_out = best >= 0 ? bd : -1.0;
	return best;
}

void BattleEnv::tick() {
	const double dt = cfg.dt;
	const int n = (int)units.size();
	for (int i = 0; i < n; i++) {
		Unit &u = units[i];
		if (!u.alive) continue;
		int w = u.weapon;
		bool melee = cfg.w_range[w] <= 250.0;
		double d0 = -1.0;
		int e0 = nearest_enemy(i, &d0);
		// ── 移动决策（顺序即规格）──
		double tx = 0.0, ty = 0.0, speed = 0.0;
		bool move = false;
		int intent = intents[u.side][u.squad];
		if (intent == 4 && e0 >= 0) {
			// 接敌推进：全速冲最近敌
			tx = units[e0].x;
			ty = units[e0].y;
			speed = cfg.run_speed;
			move = true;
		} else if (e0 >= 0 && d0 <= cfg.w_range[w]) {
			// 射程内：站桩射击
			move = false;
		} else if (melee && e0 >= 0 && d0 <= cfg.engage_trigger) {
			// 近战冲脸（镜像兵种行为档案）
			tx = units[e0].x;
			ty = units[e0].y;
			speed = cfg.run_speed;
			move = true;
		} else if (intent <= 2) {
			// 攻旗
			double fx = cfg.flag_x[intent], fy = cfg.flag_y[intent];
			double dx = fx - u.x, dy = fy - u.y;
			if (std::sqrt(dx * dx + dy * dy) > cfg.attack_flag_hold) {
				tx = fx;
				ty = fy;
				speed = cfg.walk_speed;
				move = true;
			}
		} else if (intent == 3) {
			// 驻防最近己旗 → 无己旗取最近中立 → 再取中旗
			int my = u.side == 0 ? 1 : 2;
			int pick = -1;
			double pd = 0.0;
			for (int pass = 0; pass < 2 && pick < 0; pass++) {
				for (int f = 0; f < 3; f++) {
					bool ok = pass == 0 ? (flag_owner[f] == (double)my) : (flag_owner[f] == 0.0);
					if (!ok) continue;
					double dx = cfg.flag_x[f] - u.x, dy = cfg.flag_y[f] - u.y;
					double d = std::sqrt(dx * dx + dy * dy);
					if (pick < 0 || d < pd) {
						pick = f;
						pd = d;
					}
				}
			}
			if (pick < 0) pick = 1;
			double dx = cfg.flag_x[pick] - u.x, dy = cfg.flag_y[pick] - u.y;
			if (std::sqrt(dx * dx + dy * dy) > cfg.garrison_hold) {
				tx = cfg.flag_x[pick];
				ty = cfg.flag_y[pick];
				speed = cfg.walk_speed;
				move = true;
			}
		}
		// ── 位移 ──
		double dirx = 0.0, diry = 0.0;
		if (move) {
			double dx = tx - u.x, dy = ty - u.y;
			double len = std::sqrt(dx * dx + dy * dy);
			if (len > 1e-9) {
				dirx = dx / len;
				diry = dy / len;
			}
		}
		double pushx = 0.0, pushy = 0.0;
		for (int j = 0; j < n; j++) {
			if (j == i || !units[j].alive) continue;
			double dx = u.x - units[j].x, dy = u.y - units[j].y;
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
		// ── 攻击（新位形重找最近敌）──
		u.cd = u.cd > 0.0 ? u.cd - dt : 0.0;
		double d1 = -1.0;
		int e1 = nearest_enemy(i, &d1);
		if (u.cd <= 0.0 && e1 >= 0 && d1 <= cfg.w_range[w]) {
			units[e1].hp -= cfg.w_dmg[w];
			if (units[e1].hp <= 0.0) {
				units[e1].alive = false;
				squad_alive[units[e1].side][units[e1].squad]--;
			}
			u.cd = cfg.w_cd[w];
		}
	}
	capture_tick();
}

void BattleEnv::capture_tick() {
	const int n = (int)units.size();
	for (int f = 0; f < 3; f++) {
		double fx = cfg.flag_x[f], fy = cfg.flag_y[f];
		int a = 0, b = 0;
		for (int i = 0; i < n; i++) {
			if (!units[i].alive) continue;
			double dx = units[i].x - fx, dy = units[i].y - fy;
			if (dx * dx + dy * dy > cfg.flag_radius * cfg.flag_radius) continue;
			if (units[i].side == 0) a++;
			else b++;
		}
		flag_contested[f] = a > 0 && b > 0;
		flag_capturing[f] = 0;
		if (flag_contested[f]) continue; // 冻结互消
		if (a > 0) {
			if (flag_owner[f] != 1.0) {
				flag_capturing[f] = 1;
				flag_prog[f] += cfg.capture_rate * cfg.dt;
				if (flag_prog[f] >= 100.0) {
					flag_owner[f] = 1.0;
					flag_prog[f] = 0.0;
					flag_capturing[f] = 0;
				}
			}
		} else if (b > 0) {
			if (flag_owner[f] != 2.0) {
				flag_capturing[f] = 2;
				flag_prog[f] += cfg.capture_rate * cfg.dt;
				if (flag_prog[f] >= 100.0) {
					flag_owner[f] = 2.0;
					flag_prog[f] = 0.0;
					flag_capturing[f] = 0;
				}
			}
		}
	}
}

void BattleEnv::step(const int *actions_att, const int *actions_def) {
	if (done) return;
	for (int k = 0; k < 3; k++) {
		intents[0][k] = actions_att[k];
		intents[1][k] = actions_def[k];
	}
	for (int t = 0; t < cfg.ticks_per_decision; t++) {
		tick();
		int aa = 0, da = 0;
		for (const Unit &u : units) {
			if (!u.alive) continue;
			if (u.side == 0) aa++;
			else da++;
		}
		if (aa == 0 || da == 0) {
			done = true;
			break;
		}
	}
	decisions_made++;
	if (decisions_made >= cfg.max_decisions) done = true;
}

void BattleEnv::observe(int side, std::vector<double> &out) const {
	out.assign(OBS_DIM, 0.0);
	const double forward = side == 0 ? 1.0 : -1.0;
	const int my = side == 0 ? 1 : 2;
	// 全局两维
	double hp_a = 0.0, hp_d = 0.0;
	int n_a = 0, n_d = 0;
	double cx_my = 0.0, cy_my = 0.0;
	int c_my = 0;
	for (const Unit &u : units) {
		if (!u.alive) continue;
		if (u.side == 0) {
			hp_a += u.hp;
			n_a++;
		} else {
			hp_d += u.hp;
			n_d++;
		}
		if (u.side == side) {
			cx_my += u.x;
			cy_my += u.y;
			c_my++;
		}
	}
	double hp_my = side == 0 ? hp_a : hp_d;
	double hp_fo = side == 0 ? hp_d : hp_a;
	out[0] = (hp_my + hp_fo) > 0.0 ? hp_my / (hp_my + hp_fo) : 0.5;
	out[1] = (n_a + n_d) > 0 ? (double)(side == 0 ? n_a : n_d) / (double)(n_a + n_d) : 0.5;
	// 旗 5 维 ×3
	double cxc = c_my > 0 ? cx_my / c_my : 0.0;
	double cyc = c_my > 0 ? cy_my / c_my : 0.0;
	for (int f = 0; f < 3; f++) {
		int base = 2 + f * 5;
		out[base + 0] = flag_owner[f] == (double)my ? 1.0 : (flag_owner[f] == 0.0 ? 0.0 : -1.0);
		if (flag_capturing[f] != 0) {
			double s = flag_capturing[f] == my ? 1.0 : -1.0;
			out[base + 1] = s * flag_prog[f] / 100.0;
		}
		double nd_my = -1.0, nd_fo = -1.0;
		for (const Unit &u : units) {
			if (!u.alive) continue;
			double dx = u.x - cfg.flag_x[f], dy = u.y - cfg.flag_y[f];
			double d = std::sqrt(dx * dx + dy * dy);
			bool is_my = u.side == side;
			if (is_my && (nd_my < 0.0 || d < nd_my)) nd_my = d;
			if (!is_my && (nd_fo < 0.0 || d < nd_fo)) nd_fo = d;
		}
		out[base + 2] = nd_my < 0.0 ? 2.0 : clampd(nd_my / 1000.0, 0.0, 2.0);
		out[base + 3] = nd_fo < 0.0 ? 2.0 : clampd(nd_fo / 1000.0, 0.0, 2.0);
		double cdx = c_my > 0 ? cxc - cfg.flag_x[f] : 0.0;
		double cdy = c_my > 0 ? cyc - cfg.flag_y[f] : 0.0;
		out[base + 4] = c_my > 0 ? clampd(std::sqrt(cdx * cdx + cdy * cdy) / 1000.0, 0.0, 2.0) : 2.0;
	}
	// 班 10 维 ×3
	for (int k = 0; k < 3; k++) {
		int base = 17 + k * 10;
		double sx = 0.0, sy = 0.0, shp = 0.0;
		int cnt = squad_alive[side][k];
		if (cnt > 0) {
			for (const Unit &u : units) {
				if (!u.alive || u.side != side || u.squad != k) continue;
				sx += u.x;
				sy += u.y;
				shp += u.hp;
			}
			sx /= cnt;
			sy /= cnt;
		}
		double nd = -1.0;
		if (cnt > 0) {
			for (const Unit &u : units) {
				if (!u.alive || u.side == side) continue;
				double dx = u.x - sx, dy = u.y - sy;
				double d = std::sqrt(dx * dx + dy * dy);
				if (nd < 0.0 || d < nd) nd = d;
			}
		}
		out[base + 0] = cnt > 0 ? sx / 1500.0 * forward : 0.0;
		out[base + 1] = cnt > 0 ? sy / 400.0 : 0.0;
		out[base + 2] = squad_init[side][k] > 0 ? (double)cnt / (double)squad_init[side][k] : 0.0;
		out[base + 3] = squad_init_hp[side][k] > 0.0 ? shp / squad_init_hp[side][k] : 0.0;
		out[base + 4] = cnt > 0 ? (nd < 0.0 ? 2.0 : clampd(nd / 1000.0, 0.0, 2.0)) : 0.0;
		for (int a = 0; a < 5; a++)
			out[base + 5 + a] = intents[side][k] == a ? 1.0 : 0.0;
	}
}

EnvResult BattleEnv::result() const {
	EnvResult r;
	r.decisions = decisions_made;
	int n_a = 0, n_d = 0;
	double hp_a = 0.0, hp_d = 0.0;
	for (const Unit &u : units) {
		if (!u.alive) continue;
		if (u.side == 0) {
			n_a++;
			hp_a += u.hp;
		} else {
			n_d++;
			hp_d += u.hp;
		}
	}
	r.attacker_alive = n_a;
	r.defender_alive = n_d;
	double init_a = squad_init_hp[0][0] + squad_init_hp[0][1] + squad_init_hp[0][2];
	double init_d = squad_init_hp[1][0] + squad_init_hp[1][1] + squad_init_hp[1][2];
	for (int f = 0; f < 3; f++) {
		if (flag_owner[f] == 1.0) r.flags_attacker++;
		else if (flag_owner[f] == 2.0) r.flags_defender++;
	}
	double win_pts = 0.0;
	r.timeout = decisions_made >= cfg.max_decisions;
	bool annih = n_a == 0 || n_d == 0;
	if (annih) {
		r.winner = n_a == 0 ? 2 : 1;
	} else if (r.timeout) {
		double ra = init_a > 0.0 ? hp_a / init_a : 0.0;
		double rd = init_d > 0.0 ? hp_d / init_d : 0.0;
		r.winner = ra > rd ? 1 : (ra < rd ? 2 : 0);
	}
	if (r.winner == 1) win_pts = 1.0;
	else if (r.winner == 2) win_pts = -1.0;
	double surv_a = (comp_att.total() > 0) ? (double)n_a / (double)comp_att.total() : 0.0;
	double surv_d = (comp_def.total() > 0) ? (double)n_d / (double)comp_def.total() : 0.0;
	r.reward_attacker = win_pts
			+ 0.5 * (surv_a - surv_d)
			+ 0.5 * (double)(r.flags_attacker - r.flags_defender) / 3.0;
	r.reward_defender = -r.reward_attacker;
	return r;
}

} // namespace rl
