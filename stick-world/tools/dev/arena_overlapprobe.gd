extends Node
## 出生碰撞重叠探针（--overlapprobe，裁决#26 追修）：出生刚完成时对全部单位
## 的 Collider 世界矩形做两两相交检测（O(n²)，百级单位无压力），报告：
##   - 重叠对数量 / 最深重叠量 / 类别分布（melee/ranged/commander/guard）
##   - 前 12 对明细（双方类别 + 坐标 + 重叠量）
##   - 单位 x 占用范围 vs 地图两缘（两侧空间利用率）
## 采样三点：出生完成即刻（分离推挤未起）/ +1s / +2s（分离是否自解）。
## headless 可跑。判定标准（创始人 2026-10-12）：初始状态碰撞箱零重合。

const BOX := Vector2(40.0, 48.0)   # stickman_entity.tscn Collider 尺寸（固体箱 SWL 真值 0.75u×52）
const BOX_OFF := Vector2(8.5, 130.0)


func run(_tag: String, _preset: int, _secs: int, _every: int) -> void:
	var arena: Node = null
	for i in 3600:
		await get_tree().process_frame
		arena = get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and (arena.get("_attacker") as Array).size() > 0:
			break
	if arena == null or not is_instance_valid(arena):
		print("[OverlapProbe] 观察场未就绪，退出")
		get_tree().quit()
		return
	# 等出生收敛：两军单位全部落地且战斗刚登记（开战前一刻）即首采。
	#（旧等 "_arena_commanders" 指挥官链——该链已随裁决#36 根除，改等
	#   _defender 非空 = 双军到齐）
	for i in 3600:
		await get_tree().process_frame
		var atk: Array = arena.get("_attacker") if arena.get("_attacker") is Array else []
		var def_: Array = arena.get("_defender") if arena.get("_defender") is Array else []
		if not atk.is_empty() and not def_.is_empty():
			break
	_sample(arena, "出生完成（开战前一刻） f=%d" % Engine.get_process_frames())
	# 逐帧盯梢：瞬移帧定位（速度大=积分爆炸 / 速度零=直改坐标）
	var watchers: Array = []
	for u in arena.get("_attacker"):
		if u != null and is_instance_valid(u):
			var wm: Node = u.get_node_or_null("WeaponMount")
			if wm != null and int(wm.weapon_type) == 4 and watchers.size() < 3:
				watchers.append(u)
	var prev := {}
	for w in watchers:
		prev[w.get_instance_id()] = (w as Node2D).global_position.x
	for i in 10:
		await get_tree().process_frame
		var line := "f%d" % Engine.get_process_frames()
		for w in watchers:
			var x: float = (w as Node2D).global_position.x
			var d := x - float(prev[w.get_instance_id()])
			prev[w.get_instance_id()] = x
			line += " x=%.0f(Δ%+.0f v=%.0f)" % [x, d, (w as Node2D).velocity.x]
		var w0: Node = watchers[0]
		var ai: Node = w0.call("get_ai_controller") if w0.has_method("get_ai_controller") else null
		if ai != null and ai.has_method("get_ordered_behavior"):
			var prm: Dictionary = ai.call("get_ordered_params") if ai.has_method("get_ordered_params") else {}
			line += " | 号令=%s 目标=%s" % [ai.call("get_ordered_behavior"), str(prm.get("target", "—"))]
		print("[OverlapProbe] 盯梢 " + line)
	await get_tree().create_timer(0.5).timeout
	_sample(arena, "+0.5s f=%d" % Engine.get_process_frames())
	await get_tree().create_timer(0.5).timeout
	_sample(arena, "+1s")
	await get_tree().create_timer(1.0).timeout
	_sample(arena, "+2s")
	get_tree().quit()


func _sample(arena: Node, label: String) -> void:
	var units: Array = []
	for fi in 2:
		for u in arena.get("_attacker" if fi == 0 else "_defender"):
			if u != null and is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
				units.append(u)
	var rects := []
	for u in units:
		var c: Vector2 = u.global_position + BOX_OFF
		rects.append([Rect2(c - BOX * 0.5, BOX), u])
	var pairs := []
	var worst := 0.0
	var cat_count := {}
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			var a: Rect2 = rects[i][0]
			var b: Rect2 = rects[j][0]
			if not a.intersects(b, true):
				continue
			var ov: Vector2 = a.intersection(b).size
			var depth: float = minf(ov.x, ov.y)
			worst = maxf(worst, depth)
			var ca := _cat(rects[i][1])
			var cb := _cat(rects[j][1])
			var key := "%s×%s" % [ca, cb]
			cat_count[key] = int(cat_count.get(key, 0)) + 1
			if pairs.size() < 12:
				pairs.append("%s(%s)×%s(%s) @(%.0f,%.0f)/(%.0f,%.0f) 叠%.0fpx"
						% [ca, rects[i][1].get_instance_id() % 10000, cb,
							rects[j][1].get_instance_id() % 10000,
							a.position.x, a.position.y, b.position.x, b.position.y, depth])
	var xs := []
	for u in units:
		xs.append(u.global_position.x)
	var map: Node = arena.get("_game_root").call("get_current_map") \
			if arena.get("_game_root") != null else null
	var map_l: float = float(map.map_left) if map != null and "map_left" in map else 0.0
	var map_r: float = float(map.map_right) if map != null and "map_right" in map else 0.0
	print("[OverlapProbe] ── %s ── 单位 %d，重叠 %d 对，最深 %.0fpx" % [label, units.size(), pairs.size(), worst])
	for k in cat_count:
		print("[OverlapProbe]   类别 %s: %d 对" % [k, cat_count[k]])
	for p in pairs:
		print("[OverlapProbe]   " + p)
	# 按类别的 x 中位数（左军一侧）——追号令把哪组挪到哪
	var by_cat := {}
	for r in rects:
		if (r[1] as Node).get_faction() == 1:
			var c := _cat(r[1])
			if not by_cat.has(c):
				by_cat[c] = []
			(by_cat[c] as Array).append(r[0].position.x)
	var med := ""
	for c in by_cat:
		var a: Array = (by_cat[c] as Array).duplicate()
		a.sort()
		med += "%s:x=%.0f(n=%d) " % [c, a[a.size() / 2], a.size()]
	print("[OverlapProbe]   左军类别x中位: " + med)
	print("[OverlapProbe]   x 占用 [%.0f, %.0f] 地图 [%s, %s]" \
			% [xs.min(), xs.max(), map_l, map_r])


func _cat(u: Node) -> String:
	if bool(u.get("guard_post")):
		return "guard"
	if u.has_method("get_rank") and u.get_rank() >= 3:
		return "commander"
	var wm: Node = u.get_node_or_null("WeaponMount")
	var t: int = int(wm.weapon_type) if wm != null and "weapon_type" in wm else -1
	return "ranged" if t in [2, 4, 5] else "melee"
