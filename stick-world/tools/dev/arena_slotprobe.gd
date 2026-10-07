extends Node
## 批5 远程槽位锚定探针（--slotprobe）：跑的观察场里逐时点吐远程班方阵几何，
## 并同步截图（数字与像素同场绑定）。每 every 秒对每个仍存活的远程班
## （成员武器全为 BOW/STAFF）报告：
##   - 存活人数 / 战斗锚状态 / 可开火数（射程内有敌——后列哑火诊断）
##   - x 列数（按 ROW_GAP 聚类成员 x）与纵深（x 极差）——方阵应有 2+ 列
##     （单排=1 列 = 回归信号）
##   - y 横宽（极差）与距各自槽位的均值/最大值（收拢度）
##   - 成员坐标 dump（x,y 一行——几何 ground truth）
## 结尾给全时段汇总（最深时刻列数/槽位误差均值）。stdout 报告，一次性。

const COVER_WAIT_FRAMES := 4200
## x 列聚类容差（px）：同列成员 x 差在此内算同列（< ROW_GAP 一半）
const COL_CLUSTER_TOL: float = 40.0
const SHOT_DIR := "user://shots"


func run(_tag: String, _preset: int, secs: int, every: int) -> void:
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena0 := get_tree().current_scene
		if arena0 != null and is_instance_valid(arena0) \
				and arena0.get_node_or_null("ArenaCover") == null:
			break
	for i in 12:
		await get_tree().process_frame
	# 编队系统走观察场自持 GameRoot（arena._game_root；_arena_formation 只在
	# 已废弃夺点模式注入）；等首批班建好（spawn 流程逐班 await，封面消散后
	# 仍需轮询）
	var fs: Node = null
	var game_root: Node = null
	for i in 1800:
		var arena_now: Node = get_tree().current_scene
		if arena_now != null and is_instance_valid(arena_now):
			game_root = arena_now.get("_game_root")
		if game_root != null and game_root.has_method("get_formation_system"):
			fs = game_root.get_formation_system()
			if fs != null and fs.get_squad_count() > 0:
				break
		await get_tree().process_frame
	if fs == null or fs.get_squad_count() <= 0:
		print("[SlotProbe] 编队系统无班，退出")
		get_tree().quit()
		return
	var t0: float = Time.get_ticks_msec() / 1000.0
	var acc: float = 0.0
	var worst_cols: int = -1
	var slot_err_sum: float = 0.0
	var slot_err_n: int = 0
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	while _elapsed(t0) < secs:
		await get_tree().process_frame
		acc += get_process_delta_time()
		if acc < float(every):
			continue
		acc = 0.0
		var t_now: int = int(round(_elapsed(t0)))
		print("[SlotProbe] ── t=%.0fs ──" % _elapsed(t0))
		for sid in fs.get_all_squads():
			var units: Array = fs.get_squad_units(sid)
			var alive: Array = []
			var ranged_all: bool = not units.is_empty()
			for u in units:
				if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
					alive.append(u)
					var w: Node = u.get_weapon() if u.has_method("get_weapon") else null
					var wt: int = int(w.weapon_type) if w != null and "weapon_type" in w else -1
					if wt != 2 and wt != 4:  # BOW / STAFF
						ranged_all = false
			if not ranged_all or alive.is_empty():
				continue
			var anchored_n: int = 0
			var slot_dists: Array = []
			var can_fire: int = 0
			var dump: Array = []
			for u in alive:
				var slot: Vector2 = fs.get_unit_combat_slot(u)
				if is_inf(slot.x):
					dump.append("(%.0f,%.0f)" % [u.global_position.x, u.global_position.y])
				else:
					anchored_n += 1
					slot_dists.append(u.global_position.distance_to(slot))
					dump.append("(%.0f,%.0f)*" % [u.global_position.x, u.global_position.y])
				if fs._member_enemy_in_range(u):
					can_fire += 1
			var cols: int = _count_columns(alive)
			var depth: float = _x_spread(alive)
			var y_span: float = _y_span(alive)
			var mean_err: float = 0.0
			var max_err: float = 0.0
			if not slot_dists.is_empty():
				for d in slot_dists:
					mean_err += d
					max_err = maxf(max_err, d)
				mean_err /= float(slot_dists.size())
				slot_err_sum += mean_err
				slot_err_n += 1
			worst_cols = maxi(worst_cols, cols)
			print("[SlotProbe] %s: %d 人 | 锚 %d/%d | 可开火 %d | x列 %d | 纵深 %.0f | 横宽 %.0f | 槽距 均%.0f 最大%.0f" % [
				fs.get_squad_name(sid), alive.size(), anchored_n, alive.size(), can_fire,
				cols, depth, y_span, mean_err, max_err])
			print("[SlotProbe]   坐标(*=锚定): %s" % " ".join(dump))
		# 同场截图（数字与像素绑定）：与 shot driver 同链路
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/slotprobe_第%d秒.png" % [SHOT_DIR, t_now])
	var overall: float = slot_err_sum / float(maxi(slot_err_n, 1))
	print("[SlotProbe] 汇总: 全程最大 x 列数 %d | 锚定期槽距均值 %.0fpx" % [worst_cols, overall])
	print("[SlotProbe] done")
	get_tree().quit()


func _elapsed(t0: float) -> float:
	return Time.get_ticks_msec() / 1000.0 - t0


## x 列数：按 x 排序后以 COL_CLUSTER_TOL 断列
func _count_columns(alive: Array) -> int:
	var xs: Array = []
	for u in alive:
		xs.append(u.global_position.x)
	xs.sort()
	var cols: int = 1 if not xs.is_empty() else 0
	for i in range(1, xs.size()):
		if float(xs[i]) - float(xs[i - 1]) > COL_CLUSTER_TOL:
			cols += 1
	return cols


func _x_spread(alive: Array) -> float:
	var lo: float = 1.0e9
	var hi: float = -1.0e9
	for u in alive:
		lo = minf(lo, u.global_position.x)
		hi = maxf(hi, u.global_position.x)
	return hi - lo if lo <= hi else 0.0


func _y_span(alive: Array) -> float:
	var lo: float = 1.0e9
	var hi: float = -1.0e9
	for u in alive:
		lo = minf(lo, u.global_position.y)
		hi = maxf(hi, u.global_position.y)
	return hi - lo if lo <= hi else 0.0
