#include "rl_env.h"

#include <cmath>
#include <cstdlib>

namespace rl {

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
	return c;
}

void BattleEnv::load_config(const JsonPtr &j) {
	cfg = EnvConfig::from_json(j);
}

// ── 随机对阵（逐行镜像 gen_matchup / _gen_side_comp）──

static void gen_side_comp(RngPcg &rng, int n_total, SideComp &out) {
	static const int WEAPON_POOL[5] = { 1, 0, 2, 4, 5 };
	static const double SQUAD_SPLIT[3] = { 0.45, 0.35, 0.20 };
	// Dirichlet 风格：权重 randf()² 归一
	double weights[5], wsum = 0.0;
	for (int i = 0; i < 5; i++) {
		weights[i] = rng.randf() * rng.randf();
		wsum += weights[i];
	}
	if (wsum <= 0.0) {
		wsum = 1.0;
		weights[0] = 1.0;
	}
	// 最大余数法摊人数
	int counts[5], allocated = 0;
	double remainders[5];
	for (int i = 0; i < 5; i++) {
		double exact = (double)n_total * weights[i] / wsum;
		counts[i] = (int)std::floor(exact);
		remainders[i] = exact - (double)counts[i];
		allocated += counts[i];
	}
	int extra = n_total - allocated;
	while (extra > 0) {
		int best = 0;
		for (int i = 1; i < 5; i++)
			if (remainders[i] > remainders[best]) best = i;
		counts[best] += 1;
		remainders[best] = -1.0;
		extra -= 1;
	}
	// 按 SQUAD_SPLIT 拆班（余数从头补；班内武器交错）
	for (int si = 0; si < 3; si++) out.squad_weapons[si].clear();
	for (int wi = 0; wi < 5; wi++) {
		int sq_alloc[3], sum = 0;
		for (int si = 0; si < 3; si++) {
			sq_alloc[si] = (int)std::floor((double)counts[wi] * SQUAD_SPLIT[si]);
			sum += sq_alloc[si];
		}
		int left = counts[wi] - sum, si2 = 0;
		while (left > 0) {
			sq_alloc[si2 % 3] += 1;
			left -= 1;
			si2 += 1;
		}
		for (int si = 0; si < 3; si++)
			for (int k = 0; k < sq_alloc[si]; k++)
				out.squad_weapons[si].push_back(WEAPON_POOL[wi]);
	}
	out.n_total = n_total;
	out.band_x = rng.randf_range(900.0, 1500.0);
	out.side_y = rng.randf_range(-350.0, 350.0);
	for (int si = 0; si < 3; si++) {
		out.squad_x[si] = rng.randf_range(-250.0, 250.0);
		out.squad_y[si] = rng.randf_range(-250.0, 250.0);
	}
}

Matchup BattleEnv::gen_matchup(RngPcg &rng) const {
	static const int ARMY_TIERS[3] = { 16, 32, 48 };
	Matchup m;
	m.total = ARMY_TIERS[rng.randi_range(0, 2)];
	double split = rng.randf_range(0.35, 0.65);
	int n_a = (int)std::lround((double)m.total * split);
	if (n_a < 6) n_a = 6;
	if (n_a > m.total - 6) n_a = m.total - 6;
	int n_b = m.total - n_a;
	gen_side_comp(rng, n_a, m.side_a);
	gen_side_comp(rng, n_b, m.side_b);
	return m;
}

// ── 出生（紧凑版；位置公式镜像 _spawn_side）──

void BattleEnv::spawn_side(const SideComp &comp, int faction) {
	int side = faction - 1;
	double side_sign = (faction == 1) ? -1.0 : 1.0; // 攻西(−) 守东(+)
	for (int si = 0; si < 3; si++) {
		double depth = (double)si * 260.0 * side_sign;
		double sx = 0.0 + side_sign * (comp.band_x + comp.squad_x[si]) + depth;
		double sy = clampd(0.0 + comp.side_y + comp.squad_y[si], -cfg.band_half_y + 80.0, cfg.band_half_y - 80.0);
		const std::vector<int> &weapons = comp.squad_weapons[si];
		int n = (int)weapons.size();
		for (int k = 0; k < n; k++) {
			int row = k / 8, col = k % 8;
			double uy = clampd(sy + ((double)col - 3.5) * 90.0, -cfg.band_half_y + 80.0, cfg.band_half_y - 80.0);
			double ux = sx + (double)row * 110.0 * side_sign;
			Unit u;
			u.x = ux;
			u.y = uy;
			u.weapon = weapons[k];
			u.max_hp = cfg.w_hp[u.weapon];
			u.hp = u.max_hp;
			u.cd = 0.0;
			u.alive = true;
			u.side = side;
			u.squad = si;
			units.push_back(u);
			squad_init[side][si] += 1;
			side_init[side] += 1;
		}
	}
	for (int si = 0; si < 3; si++) squad_alive[side][si] = squad_init[side][si];
}

void BattleEnv::reset(const Matchup &m, bool swap) {
	cur_matchup = m;
	cur_swap = swap;
	units.clear();
	for (int s = 0; s < 2; s++)
		for (int k = 0; k < 3; k++) {
			squad_alive[s][k] = 0;
			squad_init[s][k] = 0;
		}
	side_init[0] = side_init[1] = 0;
	for (int f = 0; f < 3; f++) {
		flag_owner[f] = 0.0;
		flag_prog[f] = 0.0;
		flag_capturing[f] = 0;
		flag_contested[f] = false;
	}
	for (int s = 0; s < 2; s++)
		for (int k = 0; k < 3; k++) last_intent[s][k] = -1;
	decisions_made = 0;
	done = false;
	t = 0.0;
	// 正局：a 攻西(f1) / b 守东(f2)；反局整体交换（_spawn_side 口径）
	const SideComp &comp_f1 = swap ? m.side_b : m.side_a;
	const SideComp &comp_f2 = swap ? m.side_a : m.side_b;
	spawn_side(comp_f1, 1);
	spawn_side(comp_f2, 2);
}

// ── 旗点结算（每拍一次；CapturePoint 语义：单方独占积分 / 双方冻结 / 无人不动）──

void BattleEnv::capture_beat() {
	const int n = (int)units.size();
	for (int f = 0; f < 3; f++) {
		double fx = (double)(f - 1) * 500.0;                       // 左中右
		double fy = clampd((double)(f - 1) * 200.0, -370.0, 370.0); // y 错开 ±200（带内夹紧取整十）
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

void BattleEnv::internal_tick() {
	const double dt = cfg.internal_dt;
	const int n = (int)units.size();
	for (int i = 0; i < n; i++) {
		Unit &u = units[i];
		if (!u.alive) continue;
		int w = u.weapon;
		bool healer = (w == 5);
		bool melee = (!healer) && cfg.w_range[w] <= 250.0;
		double d0 = -1.0;
		int e0 = nearest_enemy_unit(i, &d0);
		// 班目标（意图语义翻译）
		int intent = last_intent[u.side][u.squad];
		if (intent < 0) intent = 4; // 开局未下令：默认接敌
		double tx = 0, ty = 0, speed = 0;
		bool move = false;
		if (healer) {
			// 祭司：跟班质心（落在班群内），不开火
			double cx, cy; int an; double hs;
			squad_centroid(u.side, u.squad, &cx, &cy, &an, &hs);
			if (an > 0) {
				tx = cx;
				ty = cy;
				speed = cfg.walk_speed;
				move = std::sqrt((tx - u.x) * (tx - u.x) + (ty - u.y) * (ty - u.y)) > 20.0;
			}
		} else if (intent == 4 && e0 >= 0) {
			tx = units[e0].x;
			ty = units[e0].y;
			speed = cfg.run_speed;
			move = true;
		} else if (e0 >= 0 && d0 <= cfg.w_range[w]) {
			move = false;
		} else if (melee && e0 >= 0 && d0 <= cfg.engage_trigger) {
			tx = units[e0].x;
			ty = units[e0].y;
			speed = cfg.run_speed;
			move = true;
		} else if (intent <= 2) {
			// 自视角旗 idx → 世界坐标：faction1 左中右 = x −500/0/+500；faction2 镜像
			double fx = (u.side == 0 ? 1.0 : -1.0) * (double)(intent - 1) * 500.0;
			double fy = clampd((double)(intent - 1) * 200.0, -370.0, 370.0);
			if (std::sqrt((fx - u.x) * (fx - u.x) + (fy - u.y) * (fy - u.y)) > cfg.attack_flag_hold) {
				tx = fx;
				ty = fy;
				speed = cfg.walk_speed;
				move = true;
			}
		} else { // intent == 3 驻防最近己旗 → 无己旗退化攻自视角中旗
			int my = u.side == 0 ? 1 : 2;
			double fwd = u.side == 0 ? 1.0 : -1.0;
			int pick = -1;
			double pd = 0.0;
			for (int f = 0; f < 3; f++) {
				if (flag_owner[f] != (double)my) continue;
				double fx = (double)(f - 1) * 500.0;
				double fy = clampd((double)(f - 1) * 200.0, -370.0, 370.0);
				double d = std::sqrt((fx - u.x) * (fx - u.x) + (fy - u.y) * (fy - u.y));
				if (pick < 0 || d < pd) {
					pick = f;
					pd = d;
				}
			}
			int selfview_idx = pick >= 0 ? (u.side == 0 ? pick : 2 - pick) : 1;
			double fx = fwd * (double)(selfview_idx - 1) * 500.0;
			double fy = clampd((double)(selfview_idx - 1) * 200.0, -370.0, 370.0);
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
		// 攻击 / 治疗
		u.cd = u.cd > 0.0 ? u.cd - dt : 0.0;
		if (healer) {
			if (u.cd <= 0.0) {
				int best = -1;
				double best_ratio = 1.0;
				for (int j = 0; j < n; j++) {
					if (j == i || !units[j].alive || units[j].side != u.side) continue;
					double dx = units[j].x - u.x, dy = units[j].y - u.y;
					if (dx * dx + dy * dy > cfg.heal_range * cfg.heal_range) continue;
					double ratio = units[j].hp / units[j].max_hp;
					if (ratio < 1.0 && ratio < best_ratio) {
						best_ratio = ratio;
						best = j;
					}
				}
				if (best >= 0) {
					units[best].hp += cfg.heal_amount;
					if (units[best].hp > units[best].max_hp) units[best].hp = units[best].max_hp;
					u.cd = cfg.heal_cooldown;
				}
			}
		} else {
			double d1 = -1.0;
			int e1 = nearest_enemy_unit(i, &d1);
			if (u.cd <= 0.0 && e1 >= 0 && d1 <= cfg.w_range[w]) {
				units[e1].hp -= cfg.w_dmg[w];
				if (units[e1].hp <= 0.0) {
					units[e1].alive = false;
					squad_alive[units[e1].side][units[e1].squad] -= 1;
				}
				u.cd = cfg.w_cd[w];
			}
		}
	}
}

void BattleEnv::step(const int *actions_f1, const int *actions_f2) {
	if (done) return;
	for (int k = 0; k < 3; k++) {
		last_intent[0][k] = actions_f1[k];
		last_intent[1][k] = actions_f2[k];
	}
	capture_beat();
	for (int t_i = 0; t_i < cfg.internal_ticks_per_beat; t_i++) internal_tick();
	t += cfg.beat;
	decisions_made++;
	int a0 = 0, a1 = 0;
	for (const Unit &u : units) {
		if (!u.alive) continue;
		if (u.side == 0) a0++;
		else a1++;
	}
	if (a0 == 0 || a1 == 0) done = true;
	if (decisions_made >= BEATS_MAX) done = true;
}

// ── 57 维观察（逐行镜像 battle_env._encode_obs；faction 1/2，全特征己方视角镜像）──

void BattleEnv::observe(int faction, std::vector<double> &out) const {
	out.assign(OBS_DIM, 0.0);
	int side = faction - 1;
	int foe_side = 1 - side;
	int foe = 3 - faction;
	double mir = (faction == 1) ? 1.0 : -1.0;
	// 全局块 [0..5]
	int my_alive = 0, foe_alive = 0;
	double my_hp = 0.0, foe_hp = 0.0;
	for (const Unit &u : units) {
		if (!u.alive) continue;
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
	// 己方全军质心
	double ccx = 0, ccy = 0;
	if (my_alive > 0) {
		for (const Unit &u : units) {
			if (!u.alive || u.side != side) continue;
			ccx += u.x;
			ccy += u.y;
		}
		ccx /= my_alive;
		ccy /= my_alive;
	} else {
		ccx = 0.0;
		ccy = 0.0;
	}
	// 旗块 [6..26]：自视角左中右 = 镜像 x 升序 → f=0(midx−500) 恒为双方的自视角左
	// （对称布旗下 faction1 自视角左 = 西旗 f0；faction2 自视角左 = 东旗 f2）
	for (int fi = 0; fi < 3; fi++) {
		int f = (side == 0) ? fi : 2 - fi; // 世界旗下标
		double fx = (double)(f - 1) * 500.0;
		double fy = clampd((double)(f - 1) * 200.0, -370.0, 370.0);
		int base = 6 + fi * 7;
		out[base + 0] = (flag_owner[f] == (double)faction) ? 1.0 : 0.0;
		out[base + 1] = (flag_owner[f] == (double)foe) ? 1.0 : 0.0;
		out[base + 2] = (flag_owner[f] == 0.0) ? 1.0 : 0.0;
		out[base + 3] = norm01(flag_prog[f] / 100.0);
		int my_near = 0, foe_near = 0;
		double my_total = (double)(my_alive > 0 ? my_alive : 1);
		double foe_total = (double)(foe_alive > 0 ? foe_alive : 1);
		for (const Unit &u : units) {
			if (!u.alive) continue;
			double dx = u.x - fx, dy = u.y - fy;
			if (dx * dx + dy * dy > cfg.flag_radius * cfg.flag_radius) continue;
			if (u.side == side) my_near += 1;
			else foe_near += 1;
		}
		out[base + 4] = norm01((double)my_near / my_total);
		out[base + 5] = norm01((double)foe_near / foe_total);
		out[base + 6] = norm01(std::sqrt((ccx - fx) * (ccx - fx) + (ccy - fy) * (ccy - fy)) / 2500.0);
	}
	// 班块 [27..56]：编制序；镜像位置；上拍意图 one-hot
	for (int si = 0; si < 3; si++) {
		int base = 27 + si * 8;
		double cx = 0, cy = 0, hp_avg = 0;
		int alive_n = 0;
		squad_centroid(side, si, &cx, &cy, &alive_n, &hp_avg);
		if (alive_n > 0) {
			out[base + 0] = clampd(mir * (cx - 0.0) / 2000.0, -1.0, 1.0);
			out[base + 1] = clampd((cy - 0.0) / 400.0, -1.0, 1.0);
		} else {
			out[base + 0] = 0.0;
			out[base + 1] = 0.0;
		}
		out[base + 2] = norm01((double)alive_n / (double)(squad_init[side][si] > 0 ? squad_init[side][si] : 1));
		out[base + 3] = norm01(hp_avg > 0.0 ? hp_avg : 0.0);
		// 最近敌班质心距（阿尔法口径：无条件计算——空班质心回落 (mid_x, spawn_y)、
		// 空敌班质心同样回落参与比较；无敌 → 3000 → norm01=1）
		double best = 3000.0;
		{
			for (int fs = 0; fs < 3; fs++) {
				double ecx = 0, ecy = 0;
				int en = 0;
				double ehp = 0;
				squad_centroid(foe_side, fs, &ecx, &ecy, &en, &ehp);
				if (en <= 0) {
					ecx = 0.0;
					ecy = 0.0; // _squad_centroid 空班回落
				}
				double d = std::sqrt((ecx - cx) * (ecx - cx) + (ecy - cy) * (ecy - cy));
				if (d < best) best = d;
			}
		}
		out[base + 4] = norm01(best / 1500.0);
		int li = last_intent[side][si];
		for (int a = 0; a < 5; a++)
			out[base + 5 + a] = (li == a) ? 1.0 : 0.0;
	}
}

void BattleEnv::active_mask(int faction, int *mask3) const {
	int side = faction - 1;
	for (int k = 0; k < 3; k++) mask3[k] = squad_alive[side][k] > 0 ? 1 : 0;
}

EnvResult BattleEnv::result() const {
	EnvResult r;
	r.decisions = decisions_made;
	r.duration = t;
	r.initial[0] = side_init[0];
	r.initial[1] = side_init[1];
	for (const Unit &u : units) {
		if (!u.alive) continue;
		r.alive[u.side] += 1;
	}
	for (int f = 0; f < 3; f++) {
		if (flag_owner[f] == 1.0) r.flags_owned[0]++;
		else if (flag_owner[f] == 2.0) r.flags_owned[1]++;
	}
	r.timeout = decisions_made >= BEATS_MAX;
	bool annih = r.alive[0] == 0 || r.alive[1] == 0;
	if (annih) {
		r.winner = r.alive[0] == 0 ? 2 : 1;
	} else if (r.timeout || t >= cfg.time_limit) {
		// 超时按剩余存活判胜（_collect_result 兜底口径）；等则平
		r.winner = r.alive[0] > r.alive[1] ? 1 : (r.alive[1] > r.alive[0] ? 2 : 0);
	}
	r.reward_f1 = faction_reward(r, 1);
	r.reward_f2 = faction_reward(r, 2);
	return r;
}

double BattleEnv::faction_reward(const EnvResult &r, int faction) {
	int foe = 3 - faction;
	int fi = faction - 1, fe = foe - 1;
	double rw = 0.0;
	if (r.winner == faction) rw += 1.0;
	else if (r.winner == foe) rw -= 1.0;
	rw += 0.5 * ((double)r.alive[fi] / (double)(r.initial[fi] > 0 ? r.initial[fi] : 1)
			- (double)r.alive[fe] / (double)(r.initial[fe] > 0 ? r.initial[fe] : 1));
	rw += 0.5 * (double)(r.flags_owned[fi] - r.flags_owned[fe]) / 3.0;
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
void BattleEnv::planner_intents(int faction, int *intents3) {
	const double SCORE_CAPTURE = 85.0, SCORE_INTERCEPT = 90.0, SCORE_GARRISON = 50.0;
	const double INERTIA = 30.0, DUP = 40.0, DECAY = 3000.0, TRIGGER = 600.0;
	const double RATIO_FLOOR = 0.1, RATIO_CEIL = 2.0, DF_FLOOR = 0.05, STACK = 0.3;
	int side = faction - 1;
	int foe = 3 - faction;
	int own_total = 0, foe_total = 0;
	for (const Unit &x : units) {
		if (!x.alive) continue;
		if (x.side == side) own_total++;
		else foe_total++;
	}
	for (int k = 0; k < 3; k++) intents3[k] = -1; // -1 = 不动（保持上拍）
	if (own_total <= 0) return;
	double ratio = clampd((double)own_total / (double)(foe_total > 0 ? foe_total : 1), RATIO_FLOOR, RATIO_CEIL);
	// 己方旗质心（INTERCEPT 威胁距离用）
	bool has_home = false;
	double home_fx[3], home_fy[3];
	int home_n = 0;
	for (int f = 0; f < 3; f++) {
		if (flag_owner[f] == (double)faction) {
			has_home = true;
			home_fx[home_n] = (double)(f - 1) * 500.0;
			home_fy[home_n] = clampd((double)(f - 1) * 200.0, -370.0, 370.0);
			home_n++;
		}
	}
	// 敌班聚合（质心 + 存活数）
	double e_cx[3], e_cy[3];
	int e_n[3];
	for (int fs = 0; fs < 3; fs++) {
		double hp;
		squad_centroid(1 - side, fs, &e_cx[fs], &e_cy[fs], &e_n[fs], &hp);
	}
	int assigned_flag[3] = { 0, 0, 0 };
	int assigned_enemy[3] = { 0, 0, 0 };
	double fwd = (side == 0) ? 1.0 : -1.0;
	for (int si = 0; si < 3; si++) {
		double cx, cy, hp;
		int an;
		squad_centroid(side, si, &cx, &cy, &an, &hp);
		if (an <= 0) continue; // 全灭班不动
		struct Cand {
			double score;
			int intent; // 0/1/2 攻旗(自视角) 3 驻防 4 接敌
			int target; // 旗世界下标 或 敌班序
		};
		Cand cands[8];
		int nc = 0;
		double df_arr[3];
		for (int f = 0; f < 3; f++) {
			double fx = (double)(f - 1) * 500.0;
			double fy = clampd((double)(f - 1) * 200.0, -370.0, 370.0);
			double df = clampd(1.0 - std::sqrt((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)) / DECAY, DF_FLOOR, 1.0);
			df_arr[f] = df;
			if (flag_owner[f] != (double)faction) {
				double sc = SCORE_CAPTURE * df * ratio;
				if (assigned_flag[f] > 0) sc -= DUP;
				// 惯性：上拍同意图同目标
				if (last_intent[side][si] == (side == 0 ? f : 2 - f)) sc += INERTIA;
				cands[nc].score = sc;
				cands[nc].intent = side == 0 ? f : 2 - f;
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
			for (int es = 0; es < 3; es++) {
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
		intents3[si] = best.intent;
		if (best.intent <= 2) assigned_flag[best.target]++;
		else if (best.intent == 3) assigned_flag[best.target]++;
		else assigned_enemy[best.target]++;
	}
	// 未决策班保持上拍意图（无 → 接敌）
	for (int k = 0; k < 3; k++)
		if (intents3[k] < 0) intents3[k] = last_intent[side][k] >= 0 ? last_intent[side][k] : 4;
	(void)fwd;
}

// ── 对拍夹具：状态帧 dump（GDScript obs_gate 注入阿尔法原版 _encode_obs 用）──
JsonPtr BattleEnv::dump_obs_fixture(uint32_t seed, int sample_every, int max_frames) const {
	// 复制一份跑（const 方法内不改 this）
	BattleEnv tmp = *this;
	RngPcg rng;
	rng.seed(seed);
	Matchup m = tmp.gen_matchup(rng);
	tmp.reset(m, false);
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
				for (int k = 0; k < 3; k++) arr->arr.push_back(Json::num_of(tmp.last_intent[f - 1][k]));
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
		int af1[3], af2[3];
		for (int g = 0; g < 3; g++) {
			af1[g] = (beat + g) % 5;
			af2[g] = (beat * 2 + g * 3 + 1) % 5;
		}
		tmp.step(af1, af2);
		beat++;
	}
	auto root = Json::make(Json::OBJ);
	root->set("format", Json::str_of("rl_core.obs_fixture.v2"));
	root->set("seed", Json::num_of((double)seed));
	root->set("mid_x", Json::num_of(0.0));
	root->set("spawn_y", Json::num_of(0.0));
	root->set("time_limit", Json::num_of(cfg.time_limit));
	root->set("flags", []() {
		auto arr = Json::make(Json::ARR);
		for (int f = 0; f < 3; f++) {
			auto fo = Json::make(Json::OBJ);
			fo->set("x", Json::num_of((double)(f - 1) * 500.0));
			fo->set("y", Json::num_of(clampd((double)(f - 1) * 200.0, -370.0, 370.0)));
			fo->set("radius", Json::num_of(180.0));
			arr->arr.push_back(fo);
		}
		return arr;
	}());
	root->set("frames", frames);
	return root;
}

} // namespace rl
