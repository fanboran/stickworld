extends SceneTree
## rl_core · GDScript 镜像环境（对拍锚点，非游戏代码）
##
## 本文件是 addons/rl_core/src/rl_env.h + rl_net.h 规格的 GDScript 逐字镜像——
## 两处规格注释必须同步改（改一处必改另一处）。用途：
##   1. 对拍门：godot --headless -s 本脚本 → 产出 mirror_dump.json →
##      test_core.exe verify <dump.json> 同种子逐步对齐（观察/奖励容差 1e-6，
##      exp/sqrt 跨运行时可能差 1 ULP，不做逐位相等）。
##   2. 吞吐基线：--bench 模式跑 20 局计 episodes/sec，与 C++ 侧同口径对比。
##
## 运行（项目根 = stick-world/）：
##   Godot --headless --path . -s res://addons/rl_core/tests/gdscript_mirror/mirror_dump.gd
##   Godot --headless --path . -s res://addons/rl_core/tests/gdscript_mirror/mirror_dump.gd -- --bench
##
## 【诚实预期】紧凑环境与真实 Godot 战斗存在保真度差（迁移差距）——本镜像与 C++ 版
## 互为规格参照，真实进步的唯一裁判仍是 nn_brain 在真实 Godot Benchmark 里打手调
## 规划器（tests/dev/diag_arena_benchmark_driver.gd）。

const OUT_PATH := "res://temp/rl_core_mirror/mirror_dump.json"
const DUMP_SEED := 20260930
const NET_SEED := 20260930

# ── RNG 规格（xorshift32，与 rl_math.h 逐字一致；掩码保 32 位非负，位移序不可动）──
class Rng:
	var s: int = 0x9E3779B9
	func seed(v: int) -> void:
		s = (0x9E3779B9) if v == 0 else (v & 0xFFFFFFFF)
	func next() -> int:
		s = (s ^ ((s << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF
		s = (s ^ (s >> 17)) & 0xFFFFFFFF
		s = (s ^ ((s << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF
		return s
	func unit() -> float:
		return float(next()) / 4294967296.0
	func below(n: int) -> int:
		return next() % n

# ── 配置（默认值 = rl_env.h EnvConfig 默认）──
var cfg := {
	"arena_half_x": 2000.0, "band_half_y": 400.0, "team_offset_x": 1400.0,
	"flag_x": [-500.0, 0.0, 500.0], "flag_y": [-200.0, 0.0, 200.0],
	"flag_radius": 180.0, "capture_rate": 20.0,
	"dt": 0.1, "ticks_per_decision": 5, "max_decisions": 120,
	"separation_radius": 42.0, "separation_force": 1.6,
	"walk_speed": 160.0, "run_speed": 320.0,
	"engage_trigger": 600.0, "attack_flag_hold": 60.0, "garrison_hold": 90.0,
	"w_hp": [80.0, 440.0, 70.0, 150.0],   # 0剑 1矛 2弓 3杖
	"w_dmg": [12.0, 15.0, 10.0, 50.0],
	"w_cd": [1.0, 2.0, 2.0, 7.0],
	"w_range": [80.0, 200.0, 1400.0, 600.0],
	"spear_opts": [8, 16], "sword_opts": [4, 10, 20], "staff_opts": [1, 2, 4], "bow_opts": [0, 3, 8],
}

# 单位字典：x,y,hp,max_hp,weapon,cd,alive,side,squad
var units: Array = []
var squad_alive := [[0, 0, 0], [0, 0, 0]]
var squad_init := [[0, 0, 0], [0, 0, 0]]
var squad_init_hp := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
var flag_owner := [0.0, 0.0, 0.0]
var flag_prog := [0.0, 0.0, 0.0]
var flag_capturing := [0, 0, 0]
var flag_contested := [false, false, false]
var intents := [[4, 4, 4], [4, 4, 4]]
var decisions_made := 0
var is_done := true
var rng := Rng.new()
var comp_att := { "spear": 8, "sword": 4, "staff": 1, "bow": 3 }
var comp_def := { "spear": 8, "sword": 4, "staff": 1, "bow": 3 }
const OBS_DIM := 47


static func squad_size(squad: int, c: Dictionary) -> int:
	if squad == 0: return int(c["spear"])
	if squad == 1: return int(c["sword"])
	return int(c["staff"]) + int(c["bow"])


static func squad_weapon(squad: int, idx: int, c: Dictionary) -> int:
	if squad == 0: return 1
	if squad == 1: return 0
	return 3 if idx < int(c["staff"]) else 2


func reset_fixed(p_seed: int, att: Dictionary, def: Dictionary) -> void:
	rng.seed(p_seed)
	comp_att = att
	comp_def = def
	units = []
	intents = [[4, 4, 4], [4, 4, 4]]
	decisions_made = 0
	is_done = false
	for f in 3:
		flag_owner[f] = 0.0
		flag_prog[f] = 0.0
		flag_capturing[f] = 0
		flag_contested[f] = false
	var comps := [att, def]
	for side in 2:
		var forward := 1.0 if side == 0 else -1.0
		for k in 3:
			var n: int = squad_size(k, comps[side])
			squad_alive[side][k] = n
			squad_init[side][k] = n
			var cx: float = -forward * (cfg["team_offset_x"] - float(k) * 150.0)
			var cy: float = float(k) * 150.0 - 150.0
			var cols: int = clampi(n, 1, 8)
			var rows: int = ceili(float(n) / float(cols))
			var hp_sum := 0.0
			for i in n:
				var r := i / cols
				var c := i % cols
				var w: int = squad_weapon(k, i, comps[side])
				var u := {
					"x": cx + (float(c) - float(cols - 1) * 0.5) * 70.0,
					"y": cy + (float(r) - float(rows - 1) * 0.5) * 70.0,
					"weapon": w, "cd": 0.0, "alive": true,
					"max_hp": float(cfg["w_hp"][w]), "hp": float(cfg["w_hp"][w]),
					"side": side, "squad": k,
				}
				hp_sum += float(cfg["w_hp"][w])
				units.append(u)
			squad_init_hp[side][k] = hp_sum


func reset(p_seed: int) -> void:
	rng.seed(p_seed)
	# 抽样顺序即规格：矛(2选) 剑(3选) 杖(3选) 弓(3选)，攻方先守方后
	var ca := {
		"spear": cfg["spear_opts"][rng.below(2)], "sword": cfg["sword_opts"][rng.below(3)],
		"staff": cfg["staff_opts"][rng.below(3)], "bow": cfg["bow_opts"][rng.below(3)],
	}
	var cd := {
		"spear": cfg["spear_opts"][rng.below(2)], "sword": cfg["sword_opts"][rng.below(3)],
		"staff": cfg["staff_opts"][rng.below(3)], "bow": cfg["bow_opts"][rng.below(3)],
	}
	reset_fixed(p_seed, ca, cd)


func nearest_enemy(idx: int) -> Array:
	# 返回 [best_idx, best_dist]（无 → [-1, -1.0]）
	var u: Dictionary = units[idx]
	var best := -1
	var bd := 0.0
	for j in units.size():
		if j == idx or not units[j]["alive"] or units[j]["side"] == u["side"]:
			continue
		var dx: float = units[j]["x"] - u["x"]
		var dy: float = units[j]["y"] - u["y"]
		var d := sqrt(dx * dx + dy * dy)
		if best < 0 or d < bd:
			best = j
			bd = d
	return [best, bd]


func tick() -> void:
	var dt: float = cfg["dt"]
	var n := units.size()
	for i in n:
		var u: Dictionary = units[i]
		if not u["alive"]:
			continue
		var w: int = u["weapon"]
		var melee: bool = float(cfg["w_range"][w]) <= 250.0
		var e0 := nearest_enemy(i)
		var d0: float = e0[1]
		# ── 移动决策（顺序即规格）──
		var tx := 0.0
		var ty := 0.0
		var speed := 0.0
		var move := false
		var intent: int = intents[u["side"]][u["squad"]]
		if intent == 4 and e0[0] >= 0:
			tx = units[e0[0]]["x"]
			ty = units[e0[0]]["y"]
			speed = cfg["run_speed"]
			move = true
		elif e0[0] >= 0 and d0 <= float(cfg["w_range"][w]):
			move = false
		elif melee and e0[0] >= 0 and d0 <= float(cfg["engage_trigger"]):
			tx = units[e0[0]]["x"]
			ty = units[e0[0]]["y"]
			speed = cfg["run_speed"]
			move = true
		elif intent <= 2:
			var fx: float = cfg["flag_x"][intent]
			var fy: float = cfg["flag_y"][intent]
			if sqrt((fx - u["x"]) * (fx - u["x"]) + (fy - u["y"]) * (fy - u["y"])) > float(cfg["attack_flag_hold"]):
				tx = fx
				ty = fy
				speed = cfg["walk_speed"]
				move = true
		elif intent == 3:
			var my := 1 if u["side"] == 0 else 2
			var pick := -1
			var pd := 0.0
			for pass_i in 2:
				if pick >= 0:
					break
				for f in 3:
					var ok: bool = (flag_owner[f] == float(my)) if pass_i == 0 else (flag_owner[f] == 0.0)
					if not ok:
						continue
					var dx: float = cfg["flag_x"][f] - u["x"]
					var dy: float = cfg["flag_y"][f] - u["y"]
					var d := sqrt(dx * dx + dy * dy)
					if pick < 0 or d < pd:
						pick = f
						pd = d
			if pick < 0:
				pick = 1
			var gx: float = cfg["flag_x"][pick] - u["x"]
			var gy: float = cfg["flag_y"][pick] - u["y"]
			if sqrt(gx * gx + gy * gy) > float(cfg["garrison_hold"]):
				tx = cfg["flag_x"][pick]
				ty = cfg["flag_y"][pick]
				speed = cfg["walk_speed"]
				move = true
		# ── 位移 ──
		var dirx := 0.0
		var diry := 0.0
		if move:
			var dx2: float = tx - u["x"]
			var dy2: float = ty - u["y"]
			var len2 := sqrt(dx2 * dx2 + dy2 * dy2)
			if len2 > 1e-9:
				dirx = dx2 / len2
				diry = dy2 / len2
		var pushx := 0.0
		var pushy := 0.0
		for j in n:
			if j == i or not units[j]["alive"]:
				continue
			var dx3: float = u["x"] - units[j]["x"]
			var dy3: float = u["y"] - units[j]["y"]
			var d3 := sqrt(dx3 * dx3 + dy3 * dy3)
			if d3 >= float(cfg["separation_radius"]) or d3 <= 1e-9:
				continue
			var wgt := 1.0 - d3 / float(cfg["separation_radius"])
			pushx += dx3 / d3 * wgt
			pushy += dy3 / d3 * wgt
		var stepx := dirx + float(cfg["separation_force"]) * pushx
		var stepy := diry + float(cfg["separation_force"]) * pushy
		var slen := sqrt(stepx * stepx + stepy * stepy)
		if slen > 1e-9:
			u["x"] += stepx / slen * speed * dt
			u["y"] += stepy / slen * speed * dt
		u["x"] = clampf(u["x"], -float(cfg["arena_half_x"]), float(cfg["arena_half_x"]))
		u["y"] = clampf(u["y"], -float(cfg["band_half_y"]), float(cfg["band_half_y"]))
		# ── 攻击（新位形重找最近敌）──
		u["cd"] = (u["cd"] - dt) if float(u["cd"]) > 0.0 else 0.0
		var e1 := nearest_enemy(i)
		if float(u["cd"]) <= 0.0 and e1[0] >= 0 and e1[1] <= float(cfg["w_range"][w]):
			var tgt: Dictionary = units[e1[0]]
			tgt["hp"] = float(tgt["hp"]) - float(cfg["w_dmg"][w])
			if float(tgt["hp"]) <= 0.0:
				tgt["alive"] = false
				squad_alive[tgt["side"]][tgt["squad"]] -= 1
			u["cd"] = float(cfg["w_cd"][w])
	capture_tick()


func capture_tick() -> void:
	for f in 3:
		var fx: float = cfg["flag_x"][f]
		var fy: float = cfg["flag_y"][f]
		var a := 0
		var b := 0
		for u in units:
			if not u["alive"]:
				continue
			var dx: float = u["x"] - fx
			var dy: float = u["y"] - fy
			if dx * dx + dy * dy > float(cfg["flag_radius"]) * float(cfg["flag_radius"]):
				continue
			if u["side"] == 0: a += 1
			else: b += 1
		flag_contested[f] = a > 0 and b > 0
		flag_capturing[f] = 0
		if flag_contested[f]:
			continue
		if a > 0:
			if flag_owner[f] != 1.0:
				flag_capturing[f] = 1
				flag_prog[f] += float(cfg["capture_rate"]) * float(cfg["dt"])
				if flag_prog[f] >= 100.0:
					flag_owner[f] = 1.0
					flag_prog[f] = 0.0
					flag_capturing[f] = 0
		elif b > 0:
			if flag_owner[f] != 2.0:
				flag_capturing[f] = 2
				flag_prog[f] += float(cfg["capture_rate"]) * float(cfg["dt"])
				if flag_prog[f] >= 100.0:
					flag_owner[f] = 2.0
					flag_prog[f] = 0.0
					flag_capturing[f] = 0


func step(act_att: Array, act_def: Array) -> void:
	if is_done:
		return
	for k in 3:
		intents[0][k] = act_att[k]
		intents[1][k] = act_def[k]
	for t in int(cfg["ticks_per_decision"]):
		tick()
		var aa := 0
		var da := 0
		for u in units:
			if not u["alive"]:
				continue
			if u["side"] == 0: aa += 1
			else: da += 1
		if aa == 0 or da == 0:
			is_done = true
			break
	decisions_made += 1
	if decisions_made >= int(cfg["max_decisions"]):
		is_done = true


func observe(side: int) -> Array:
	var out := []
	out.resize(OBS_DIM)
	out.fill(0.0)
	var forward := 1.0 if side == 0 else -1.0
	var my := 1 if side == 0 else 2
	var hp_a := 0.0
	var hp_d := 0.0
	var n_a := 0
	var n_d := 0
	var cx_my := 0.0
	var cy_my := 0.0
	var c_my := 0
	for u in units:
		if not u["alive"]:
			continue
		if u["side"] == 0:
			hp_a += float(u["hp"])
			n_a += 1
		else:
			hp_d += float(u["hp"])
			n_d += 1
		if u["side"] == side:
			cx_my += float(u["x"])
			cy_my += float(u["y"])
			c_my += 1
	var hp_my := hp_a if side == 0 else hp_d
	var hp_fo := hp_d if side == 0 else hp_a
	out[0] = hp_my / (hp_my + hp_fo) if (hp_my + hp_fo) > 0.0 else 0.5
	out[1] = (float(n_a if side == 0 else n_d) / float(n_a + n_d)) if (n_a + n_d) > 0 else 0.5
	var cxc := cx_my / c_my if c_my > 0 else 0.0
	var cyc := cy_my / c_my if c_my > 0 else 0.0
	for f in 3:
		var base := 2 + f * 5
		out[base + 0] = 1.0 if flag_owner[f] == float(my) else (0.0 if flag_owner[f] == 0.0 else -1.0)
		if flag_capturing[f] != 0:
			var sg := 1.0 if flag_capturing[f] == my else -1.0
			out[base + 1] = sg * flag_prog[f] / 100.0
		var nd_my := -1.0
		var nd_fo := -1.0
		for u in units:
			if not u["alive"]:
				continue
			var dx: float = u["x"] - cfg["flag_x"][f]
			var dy: float = u["y"] - cfg["flag_y"][f]
			var d := sqrt(dx * dx + dy * dy)
			var is_my: bool = u["side"] == side
			if is_my and (nd_my < 0.0 or d < nd_my): nd_my = d
			if not is_my and (nd_fo < 0.0 or d < nd_fo): nd_fo = d
		out[base + 2] = 2.0 if nd_my < 0.0 else clampf(nd_my / 1000.0, 0.0, 2.0)
		out[base + 3] = 2.0 if nd_fo < 0.0 else clampf(nd_fo / 1000.0, 0.0, 2.0)
		if c_my > 0:
			var cdx: float = cxc - cfg["flag_x"][f]
			var cdy: float = cyc - cfg["flag_y"][f]
			out[base + 4] = clampf(sqrt(cdx * cdx + cdy * cdy) / 1000.0, 0.0, 2.0)
		else:
			out[base + 4] = 2.0
	for k in 3:
		var base2 := 17 + k * 10
		var sx := 0.0
		var sy := 0.0
		var shp := 0.0
		var cnt: int = squad_alive[side][k]
		if cnt > 0:
			for u in units:
				if not u["alive"] or u["side"] != side or u["squad"] != k:
					continue
				sx += float(u["x"])
				sy += float(u["y"])
				shp += float(u["hp"])
			sx /= cnt
			sy /= cnt
		var nd := -1.0
		if cnt > 0:
			for u in units:
				if not u["alive"] or u["side"] == side:
					continue
				var dx2: float = u["x"] - sx
				var dy2: float = u["y"] - sy
				var d2 := sqrt(dx2 * dx2 + dy2 * dy2)
				if nd < 0.0 or d2 < nd: nd = d2
		out[base2 + 0] = (sx / 1500.0 * forward) if cnt > 0 else 0.0
		out[base2 + 1] = (sy / 400.0) if cnt > 0 else 0.0
		out[base2 + 2] = (float(cnt) / float(squad_init[side][k])) if squad_init[side][k] > 0 else 0.0
		out[base2 + 3] = (shp / squad_init_hp[side][k]) if squad_init_hp[side][k] > 0.0 else 0.0
		if cnt > 0:
			out[base2 + 4] = 2.0 if nd < 0.0 else clampf(nd / 1000.0, 0.0, 2.0)
		else:
			out[base2 + 4] = 0.0
		for a in 5:
			out[base2 + 5 + a] = 1.0 if intents[side][k] == a else 0.0
	return out


func result() -> Dictionary:
	var n_a := 0
	var n_d := 0
	var hp_a := 0.0
	var hp_d := 0.0
	for u in units:
		if not u["alive"]:
			continue
		if u["side"] == 0:
			n_a += 1
			hp_a += float(u["hp"])
		else:
			n_d += 1
			hp_d += float(u["hp"])
	var init_a: float = squad_init_hp[0][0] + squad_init_hp[0][1] + squad_init_hp[0][2]
	var init_d: float = squad_init_hp[1][0] + squad_init_hp[1][1] + squad_init_hp[1][2]
	var flags_a := 0
	var flags_d := 0
	for f in 3:
		if flag_owner[f] == 1.0: flags_a += 1
		elif flag_owner[f] == 2.0: flags_d += 1
	var winner := 0
	var timeout: bool = decisions_made >= int(cfg["max_decisions"])
	var annih: bool = n_a == 0 or n_d == 0
	if annih:
		winner = 2 if n_a == 0 else 1
	elif timeout:
		var ra := hp_a / init_a if init_a > 0.0 else 0.0
		var rd := hp_d / init_d if init_d > 0.0 else 0.0
		winner = (1 if ra > rd else (2 if ra < rd else 0))
	var win_pts := 0.0
	if winner == 1: win_pts = 1.0
	elif winner == 2: win_pts = -1.0
	var surv_a := float(n_a) / float(comp_att["spear"] + comp_att["sword"] + comp_att["staff"] + comp_att["bow"]) \
			if (comp_att["spear"] + comp_att["sword"] + comp_att["staff"] + comp_att["bow"]) > 0 else 0.0
	var surv_d := float(n_d) / float(comp_def["spear"] + comp_def["sword"] + comp_def["staff"] + comp_def["bow"]) \
			if (comp_def["spear"] + comp_def["sword"] + comp_def["staff"] + comp_def["bow"]) > 0 else 0.0
	var r_att := win_pts + 0.5 * (surv_a - surv_d) + 0.5 * float(flags_a - flags_d) / 3.0
	return {
		"winner": winner, "reward_attacker": r_att, "reward_defender": -r_att,
		"decisions": decisions_made, "attacker_alive": n_a, "defender_alive": n_d,
		"flags_attacker": flags_a, "flags_defender": flags_d, "timeout": timeout,
	}


# ── 网络（规格见 rl_net.h：47→24 relu→15，3×5 组内 softmax；Glorot 初始化序 w1→w2）──
class MirrorNet:
	var inn := 47
	var hid := 24
	var out_n := 15
	var w1: Array = []
	var b1: Array = []
	var w2: Array = []
	var b2: Array = []

	func alloc(p_in: int, p_hid: int, p_out: int) -> void:
		inn = p_in
		hid = p_hid
		out_n = p_out
		w1 = []
		w1.resize(hid * inn)
		w1.fill(0.0)
		b1 = []
		b1.resize(hid)
		b1.fill(0.0)
		w2 = []
		w2.resize(out_n * hid)
		w2.fill(0.0)
		b2 = []
		b2.resize(out_n)
		b2.fill(0.0)

	func init_weights(p_seed: int) -> void:
		var rng := Rng.new()
		rng.seed((p_seed ^ 0x5BD1E995) & 0xFFFFFFFF)
		var lim1 := sqrt(6.0 / float(inn + hid))
		for i in w1.size():
			w1[i] = (rng.unit() * 2.0 - 1.0) * lim1
		var lim2 := sqrt(6.0 / float(hid + out_n))
		for i in w2.size():
			w2[i] = (rng.unit() * 2.0 - 1.0) * lim2

	func forward(obs: Array) -> Array:
		var h := []
		h.resize(hid)
		for j in hid:
			var s: float = b1[j]
			for i in inn:
				s += w1[j * inn + i] * obs[i]
			h[j] = s if s > 0.0 else 0.0
		var logits := []
		logits.resize(out_n)
		for o in out_n:
			var s2: float = b2[o]
			for j in hid:
				s2 += w2[o * hid + j] * h[j]
			logits[o] = s2
		return logits


# ── 主流程 ──

func _dump_mode() -> void:
	var env := self
	env.reset(DUMP_SEED)
	var dump := {
		"spec": "rl_core.mirror_dump.v1",
		"seed": DUMP_SEED,
		"net_seed": NET_SEED,
		"comp_attacker": comp_att,
		"comp_defender": comp_def,
	}
	var obs0a := env.observe(0)
	var obs0d := env.observe(1)
	dump["initial_obs_attacker"] = obs0a
	dump["initial_obs_defender"] = obs0d
	# 固定意图循环表（无 RNG，隔离环境对拍与网络采样）
	var decisions := []
	var d := 0
	var guard := 0
	while not env.is_done and guard < 200:
		guard += 1
		var act_att := [(d + 0) % 5, (d + 1) % 5, (d + 2) % 5]
		var act_def := [(d * 2 + 1) % 5, (d * 2 + 3 + 1) % 5, (d + 4) % 5]
		env.step(act_att, act_def)
		var rec := {
			"actions_attacker": act_att,
			"actions_defender": act_def,
		}
		if not env.is_done:
			rec["obs_attacker"] = env.observe(0)
			rec["obs_defender"] = env.observe(1)
		decisions.append(rec)
		d += 1
	dump["decisions"] = decisions
	dump["result"] = env.result()
	# 网络前向探针：确定性生成的观察喂镜像网络，C++ 侧读同值比 logits
	var net := MirrorNet.new()
	net.alloc(OBS_DIM, 24, 15)
	net.init_weights(NET_SEED)
	var probes := []
	for pi in 8:
		var x := []
		for j in OBS_DIM:
			x.push_back(sin(float(pi * 13 + j * 7) * 0.37) * 0.9)
		probes.append({ "obs": x, "logits": net.forward(x) })
	dump["net_probes"] = probes

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_PATH), FileAccess.WRITE)
	if f == null:
		push_error("[mirror] 无法写 dump: " + OUT_PATH)
		quit(1)
		return
	f.store_string(JSON.stringify(dump))
	f.close()
	print("[mirror] dump 写出: %s（decisions=%d winner=%s）" % [OUT_PATH, decisions.size(), str(env.result()["winner"])])
	quit(0)


func _bench_mode(episodes: int) -> void:
	var tr_rng := Rng.new()
	tr_rng.seed(1)
	var net := MirrorNet.new()
	net.alloc(OBS_DIM, 24, 15)
	net.init_weights(1)
	var env := self
	# 预热 2 局（种子与 C++ bench 同口径：1、2，不换边）
	for warm in 2:
		env.reset(1 + warm)
		while not env.is_done:
			var oa := env.observe(0)
			var ob := env.observe(1)
			var la := net.forward(oa)
			var lb := net.forward(ob)
			var aa := []
			var ab := []
			for g in 3:
				aa.append(_sample(la, g, tr_rng))
				ab.append(_sample(lb, g, tr_rng))
			env.step(aa, ab)
	var t0 := Time.get_ticks_usec()
	var ret_acc := 0.0
	for i in episodes:
		var ep_seed: int = 100 + i
		if i % 2 == 1:
			ep_seed = (ep_seed ^ 0x9E3779B9) & 0xFFFFFFFF  # 与 C++ run_episode 换边口径一致
		env.reset(ep_seed)
		while not env.is_done:
			var oa := env.observe(0)
			var ob := env.observe(1)
			var la := net.forward(oa)
			var lb := net.forward(ob)
			var aa := []
			var ab := []
			for g in 3:
				aa.append(_sample(la, g, tr_rng))
				ab.append(_sample(lb, g, tr_rng))
			env.step(aa, ab)
		ret_acc += float(env.result()["reward_attacker"])
	var secs := float(Time.get_ticks_usec() - t0) / 1e6
	print("[GDScript镜像] episodes=%d 耗时=%.3fs episodes/sec=%.2f 平均奖励=%.4f" % [
		episodes, secs, float(episodes) / secs, ret_acc / float(episodes)])
	quit(0)


func _sample(logits: Array, group: int, p_rng: Rng) -> int:
	var off := group * 5
	var m: float = logits[off]
	for k in range(1, 5):
		if logits[off + k] > m: m = logits[off + k]
	var sum := 0.0
	var probs := [0.0, 0.0, 0.0, 0.0, 0.0]
	for k in 5:
		probs[k] = exp(logits[off + k] - m)
		sum += probs[k]
	for k in 5:
		probs[k] /= sum
	var u := p_rng.unit()
	var cum := 0.0
	for k in 5:
		cum += probs[k]
		if u < cum: return k
	return 4


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a == "--bench":
			_bench_mode(20)
			return
	_dump_mode()
