extends RefCounted
## rl_core · 125 维观察编码 GDScript 镜像（v2 定稿维度）。
##
## 与 C++ BattleEnv::observe 互为独立实现：本脚本只消费对拍夹具（fixture v3）
## 的状态帧数据（units/flags/last_intent/squad_initial/platoons），按同一份
## 维度布局表独立重算观察——帧对帧对拍抓两侧笔误。布局思路参考
## tests/dev/rl/battle_env.gd 的 _encode_obs（阿尔法 57 维旧版，只读）。
##
## ── 维度布局表（125 维，己方视角镜像；faction 1/2）──
##   [0..5]    全局 6：己存活比/敌存活比/存活计数差(−1..1)/己均血/敌均血/剩余时间
##             （存活统计 = 士兵，不含指挥官；initial = 16/48/96）
##   [6..26]   旗×3（自视角左中右 = 镜像 x 升序）stride 7：归属 one-hot(己/敌/中立)
##             + 进度/100 + 己近旗人数比 + 敌近旗人数比 + 全军质心距/2500
##   [27..106] 班×8（编制槽序）stride 10：镜像位置(x/2000, y/400) + 存活比 + 均血
##             + 最近敌班质心距/1500 + 上拍意图 one-hot(5)
##             （空班/全灭班：位置/计数/均血置 0、意图 one-hot 全 0（li=-1），
##             近敌距照算且空班/空敌班质心回落 (mid_x, spawn_y)）
##   [107..122] 排×4 stride 4：排长存活(0/1) + 排长镜像位置(2) + 排存活比
##             （空排全 0；排长阵亡位置置 0 只留存活标志 0）
##   [123..124] 指挥官 2：己方血量比 + 敌方血量比（阵亡 → 0）

const OBS_DIM: int = 125
const N_SQUADS: int = 8
const N_PLATOONS: int = 4
const N_ACTIONS: int = 5
const FLAG_RADIUS: float = 180.0


static func _norm01(v: float) -> float:
	return clampf(v, 0.0, 1.0)


static func _mirror_sign(faction: int) -> float:
	return 1.0 if faction == 1 else -1.0


## 全 double 距离（Godot Vector2 是 float32——与 C++ double 对拍必须手写）
static func _dist(x1: float, y1: float, x2: float, y2: float) -> float:
	var dx := x1 - x2
	var dy := y1 - y2
	return sqrt(dx * dx + dy * dy)


## fixture：dump_obs_fixture v3 的 JSON 字典；frame：frames 数组元素。
## 返回 125 维观察（PackedFloat32Array）。
static func encode(fixture: Dictionary, frame: Dictionary, faction: int) -> PackedFloat32Array:
	var obs := PackedFloat32Array()
	obs.resize(OBS_DIM)
	var mid_x: float = float(fixture.get("mid_x", 0.0))
	var spawn_y: float = float(fixture.get("spawn_y", 0.0))
	var time_limit: float = float(fixture.get("time_limit", 125.0))
	var squad_initial: Array = fixture["squad_initial"] # [side][squad]
	var platoons: Array = fixture["platoons"] # [[0,1],[2,3]...]
	var foe: int = 3 - faction
	var mir: float = _mirror_sign(faction)

	# 单位分桶：己方兵 / 敌方兵 / 双方指挥官（按 (side, squad) 桶保持帧序）。
	# 只收存活兵——C++ 侧全部统计（存活比/质心/旗近邻/班块/排存活）不含死者，
	# 分母一律用 squad_initial；死兵除了 is_commander 判定外不进任何特征。
	var my_units: Array = []
	var foe_units: Array = []
	var commanders := {}
	for u_v in frame["units"]:
		var u: Dictionary = u_v
		if bool(u["is_commander"]):
			commanders[int(u["side"])] = u
			continue
		if not bool(u["alive"]):
			continue
		if int(u["side"]) + 1 == faction:
			my_units.append(u)
		else:
			foe_units.append(u)

	# ── 全局块 [0..5] ──
	var my_alive: int = my_units.size()
	var foe_alive: int = foe_units.size()
	var my_hp: float = 0.0
	var foe_hp: float = 0.0
	for u in my_units:
		my_hp += float(u["ratio"])
	for u in foe_units:
		foe_hp += float(u["ratio"])
	var my_init: int = squad_initial[faction - 1].reduce(func(a: float, b: float) -> float: return a + b, 0.0) if squad_initial[faction - 1].size() > 0 else 0
	var foe_init: int = squad_initial[foe - 1].reduce(func(a: float, b: float) -> float: return a + b, 0.0) if squad_initial[foe - 1].size() > 0 else 0
	obs[0] = _norm01(float(my_alive) / float(maxi(my_init, 1)))
	obs[1] = _norm01(float(foe_alive) / float(maxi(foe_init, 1)))
	obs[2] = clampf(float(my_alive) / float(maxi(my_alive + foe_alive, 1)) * 2.0 - 1.0, -1.0, 1.0)
	obs[3] = _norm01(my_hp / float(maxi(my_alive, 1)))
	obs[4] = _norm01(foe_hp / float(maxi(foe_alive, 1)))
	obs[5] = clampf(1.0 - float(frame["t"]) / time_limit, 0.0, 1.0)

	# 己方全军质心（兵；空回落 (mid_x, spawn_y)）
	var ccx: float = mid_x
	var ccy: float = spawn_y
	if my_alive > 0:
		ccx = 0.0
		ccy = 0.0
		for u in my_units:
			ccx += float(u["x"])
			ccy += float(u["y"])
		ccx /= my_alive
		ccy /= my_alive

	# ── 旗块 [6..26]：自视角左中右（f1 = 世界 f0/f1/f2；f2 = f2/f1/f0）──
	var flags_geo: Array = fixture["flags"] # 世界序 {x,y,radius}
	var frame_flags: Array = frame["flags"]
	for fi in 3:
		var world_f: int = fi if faction == 1 else 2 - fi
		var geo: Dictionary = flags_geo[world_f]
		var st: Dictionary = frame_flags[world_f]
		var owner_f: int = int(float(st["owner"]))
		var base: int = 6 + fi * 7
		obs[base] = 1.0 if owner_f == faction else 0.0
		obs[base + 1] = 1.0 if owner_f == foe else 0.0
		obs[base + 2] = 1.0 if owner_f == 0 else 0.0
		obs[base + 3] = _norm01(float(st["progress"]) / 100.0)
		var fx: float = float(geo["x"])
		var fy: float = float(geo["y"])
		var radius: float = float(geo.get("radius", FLAG_RADIUS))
		var my_near: int = 0
		var foe_near: int = 0
		for u in my_units:
			if _dist(float(u["x"]), float(u["y"]), fx, fy) <= radius:
				my_near += 1
		for u in foe_units:
			if _dist(float(u["x"]), float(u["y"]), fx, fy) <= radius:
				foe_near += 1
		obs[base + 4] = _norm01(float(my_near) / float(maxi(my_alive, 1)))
		obs[base + 5] = _norm01(float(foe_near) / float(maxi(foe_alive, 1)))
		obs[base + 6] = _norm01(_dist(ccx, ccy, fx, fy) / 2500.0)

	# ── 班块 [27..106]：8 槽 stride 10 ──
	var last_intent: Dictionary = frame["last_intent"]
	var li_arr: Array = last_intent[str(faction)]
	# 己方班质心缓存（槽序）；空班回落 (mid_x, spawn_y)
	var sq_cx: Array = []
	var sq_cy: Array = []
	var sq_alive: Array = []
	var sq_hp: Array = []
	for si in N_SQUADS:
		var cnt: int = 0
		var sx: float = 0.0
		var sy: float = 0.0
		var shp: float = 0.0
		for u in my_units:
			if int(u["squad"]) != si:
				continue
			sx += float(u["x"])
			sy += float(u["y"])
			shp += float(u["ratio"])
			cnt += 1
		if cnt > 0:
			sq_cx.append(sx / cnt)
			sq_cy.append(sy / cnt)
		else:
			sq_cx.append(mid_x)
			sq_cy.append(spawn_y)
		sq_alive.append(cnt)
		sq_hp.append(shp / float(maxi(cnt, 1)))
	# 敌方班质心缓存（空班同样回落）
	var foe_cx: Array = []
	var foe_cy: Array = []
	for si in N_SQUADS:
		var cnt2: int = 0
		var sx2: float = 0.0
		var sy2: float = 0.0
		for u in foe_units:
			if int(u["squad"]) != si:
				continue
			sx2 += float(u["x"])
			sy2 += float(u["y"])
			cnt2 += 1
		if cnt2 > 0:
			foe_cx.append(sx2 / cnt2)
			foe_cy.append(sy2 / cnt2)
		else:
			foe_cx.append(mid_x)
			foe_cy.append(spawn_y)
	for si in N_SQUADS:
		var base: int = 27 + si * 10
		var alive_n: int = sq_alive[si]
		var init_n: int = int(squad_initial[faction - 1][si])
		if alive_n > 0:
			obs[base] = clampf(mir * (sq_cx[si] - mid_x) / 2000.0, -1.0, 1.0)
			obs[base + 1] = clampf((sq_cy[si] - spawn_y) / 400.0, -1.0, 1.0)
		obs[base + 2] = _norm01(float(alive_n) / float(maxi(init_n, 1)))
		obs[base + 3] = _norm01(sq_hp[si])
		# 最近敌班质心距（无条件计算；空班质心已回落；初值 3000 与 C++ 同款——
		# 全部敌班距离超 3000 时夹在 3000，norm01 后同为 1）
		var best: float = 3000.0
		for fs in N_SQUADS:
			var d: float = _dist(sq_cx[si], sq_cy[si], foe_cx[fs], foe_cy[fs])
			if d < best:
				best = d
		obs[base + 4] = _norm01(best / 1500.0)
		var li: int = int(li_arr[si])
		if li >= 0 and li < N_ACTIONS:
			obs[base + 5 + li] = 1.0

	# ── 排层 [107..122]：4 槽 stride 4 ──
	for p in platoons.size():
		var squads_p: Array = platoons[p] # [2p, 2p+1]
		var base: int = 107 + p * 4
		# 排长 = 该排首班的 rank2 兵（帧内唯一）
		var officer: Dictionary = {}
		for u in my_units:
			if int(u["rank"]) == 2 and int(u["squad"]) == int(squads_p[0]):
				officer = u
				break
		if not officer.is_empty() and bool(officer["alive"]):
			obs[base] = 1.0
			obs[base + 1] = clampf(mir * float(officer["x"]) / 2000.0, -1.0, 1.0)
			obs[base + 2] = clampf(float(officer["y"]) / 400.0, -1.0, 1.0)
		# 排存活比 = 排内班存活和 / 初始和
		var ini: int = 0
		var alv: int = 0
		for sq_v in squads_p:
			var sq: int = int(sq_v)
			ini += int(squad_initial[faction - 1][sq])
			for u in my_units:
				if int(u["squad"]) == sq:
					alv += 1
		obs[base + 3] = _norm01(float(alv) / float(maxi(ini, 1)))

	# ── 指挥官 [123..124]：双方血量比 ──
	for side in 2:
		if commanders.has(side):
			var c: Dictionary = commanders[side]
			var ratio: float = float(c["ratio"]) if bool(c["alive"]) else 0.0
			obs[123 + side] = _norm01(ratio)
	return obs
