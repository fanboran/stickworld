extends Node
## 一屏战场几何验收（headless 驱动，非 CI 测试）。
##
## 验收口径（一屏战场改造，创始人：战场范围限定在屏幕一样大）：
##   ① 一屏几何：三档预设（16/48/96）开战时刻的全部单位 + 旗点，落在观战缩放
##     （battle_arena 设 0.75，缩放条 100% 档）以战场中线为中心的可见窗口内
##     （边缘留 FIT_MARGIN 余量）；
##   ② 能打完：每局在 BATTLE_TIMEOUT_GAME_SEC 游戏秒内战至结算（战斗实例结束
##     = 全灭或斩首；指挥官斩首也会收束战斗实例）；
##   ③ 无报错：脚本错误落 user://logs/，由 tools/check_godot_errors.sh 门禁扫描，
##     本驱动不重复断言。
##
## 运行：godot --headless --path . res://tests/dev/arena_one_screen_check.tscn
## 退出码：0 三档全过 / 1 有失败（逐条 [ArenaCheck][FAIL] 打印）。

const _ArenaScene: PackedScene = preload("res://tests/dev/battle_arena.tscn")
const _ArenaScript: GDScript = preload("res://tests/dev/battle_arena.gd")

## 跑哪几档（下标对齐 battle_arena.PRESETS）
const PRESET_INDICES: Array = [0, 1, 2]
## 一屏判定边缘余量（px，视野边内收——HUD/边缘装饰不吃满）
const FIT_MARGIN: float = 40.0
## 等开战预算（游戏秒；含 arena 自举 boot/切图/出生——帧等待不吃 time_scale，
## 预算按墙钟上限折算留足）
const STARTUP_BUDGET_GAME_SEC: float = 240.0
## 每局战斗最长游戏秒（超时 = 未打完，判失败）
const BATTLE_TIMEOUT_GAME_SEC: float = 420.0
## headless 加速倍率（battle_sim 同口径；≤4 不触 physics 每帧步数上限 8）
const SIM_TIME_SCALE: float = 4.0

var _arena: Node = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	Engine.time_scale = SIM_TIME_SCALE
	var failures: Array = []
	for idx_v in PRESET_INDICES:
		var idx: int = int(idx_v)
		var r: Dictionary = await _run_preset(idx)
		var line := "[ArenaCheck] 预设[%s] 一屏=%s 跨度=%.0fpx（半宽预算 %.0f）打完=%s 时长≈%.0fs 终局存活 蓝%d / 红%d"
		print(line % [
			r["name"], "是" if bool(r["fit"]) else "否", float(r["span"]), float(r["budget"]),
			"是" if bool(r["ended"]) else "否", float(r["duration"]),
			int(r["left_alive"]), int(r["right_alive"]),
		])
		if not bool(r["fit"]):
			failures.append("预设%d（%s）一屏越界：%s" % [idx + 1, r["name"], r["fit_detail"]])
		if not bool(r["ended"]):
			failures.append("预设%d（%s）战斗未在 %.0f 游戏秒内打完" % [idx + 1, r["name"], BATTLE_TIMEOUT_GAME_SEC])
	Engine.time_scale = 1.0
	if failures.is_empty():
		print("[ArenaCheck] ================ 三档全过（一屏几何 + 能打完）================")
		get_tree().quit(0)
	else:
		for f in failures:
			print("[ArenaCheck][FAIL] %s" % f)
		print("[ArenaCheck] ================ %d 项失败 ================" % failures.size())
		get_tree().quit(1)


## 跑一档预设：换档 → 等 arena 开战 → 一屏几何检查 → 等战斗收束
func _run_preset(idx: int) -> Dictionary:
	var result: Dictionary = {
		"name": "未知", "fit": false, "ended": false, "span": -1.0,
		"budget": -1.0, "duration": 0.0, "left_alive": -1, "right_alive": -1,
		"fit_detail": "",
	}
	# 清上一局（arena 与其 GameRoot/单位/规划器同树同灭；boot 协程随实例失效静默弃——
	# 同 battle_arena 自己 reload_current_scene 的既有机制）
	if _arena != null and is_instance_valid(_arena):
		_arena.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	# 换档（static _preset_idx 跨实例保持——同控制面板 1/2/3 切档口径；
	# 经 set() 走 duck 通道——const 脚本引用上的属性赋值是解析错误）
	_ArenaScript.set("_preset_idx", idx)
	result["name"] = str(_ArenaScript.PRESETS[idx]["name"])
	_arena = _ArenaScene.instantiate()
	add_child(_arena)
	# ── 等开战（battle_arena 自举：boot → 切战场图 → 出生 → start_test_battle）──
	# 结算监听（收束原因归因：decapitation/annihilation/rout/timeout/mutual）
	var settle_info: Array = []   # [reason, alive_a, alive_b]
	var eb: Node = get_node_or_null("/root/EventBus")
	var on_settled: Callable = func(_bid: String, payload: Dictionary) -> void:
		settle_info.append(payload)
	if eb != null and eb.has_signal("battle_settled"):
		eb.battle_settled.connect(on_settled)
	var attackers: Array = []
	var defenders: Array = []
	var waited: float = 0.0
	while waited < STARTUP_BUDGET_GAME_SEC:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if _arena == null or not is_instance_valid(_arena):
			result["fit_detail"] = "arena 实例失效"
			if eb != null and eb.has_signal("battle_settled") and eb.battle_settled.is_connected(on_settled):
				eb.battle_settled.disconnect(on_settled)
			return result
		attackers = _arena.get("_attacker") if _arena.get("_attacker") != null else []
		defenders = _arena.get("_defender") if _arena.get("_defender") != null else []
		if attackers.size() > 0 and defenders.size() > 0 and bool(_arena.get("_camera_following")):
			break
	if attackers.is_empty() or defenders.is_empty():
		result["fit_detail"] = "开战超时（%.0f 游戏秒未进入战斗）" % waited
		if eb != null and eb.has_signal("battle_settled") and eb.battle_settled.is_connected(on_settled):
			eb.battle_settled.disconnect(on_settled)
		return result
	# ── 一屏几何检查：开战时刻全员 + 旗点 vs 以中线为中心的可见窗口 ──
	var game_root: Node = _arena.get("_game_root")
	var map: Node2D = game_root.get_current_map()
	var rig: Node = game_root.get("camera_rig")
	if map == null or rig == null:
		result["fit_detail"] = "地图/相机未就绪"
		if eb != null and eb.has_signal("battle_settled") and eb.battle_settled.is_connected(on_settled):
			eb.battle_settled.disconnect(on_settled)
		return result
	# 遥测（缩放链各层实测——窗口 = 1080p 设计视口宽 / 2 / 用户缩放；
	# headless 的 visible_rect 受 stretch expand 影响可能是 1920×1920 方形，
	# 窗口口径锚定观察场契约基准 1920×1080，不读 live visible_rect）
	var user_zoom: float = float(rig.get_user_zoom())
	print("[ArenaCheck] 遥测 vp=%s base=%.4f user=%.4f effective=%.4f" % [
		get_viewport().get_visible_rect().size, float(rig.get_base_zoom()),
		user_zoom, float(rig.get_effective_zoom())])
	var half_w: float = 960.0 / maxf(user_zoom, 0.01)
	var mid_x: float = (float(map.map_left) + float(map.map_right)) * 0.5
	var min_x := INF
	var max_x := -INF
	for u in attackers + defenders:
		if is_instance_valid(u):
			min_x = minf(min_x, u.global_position.x)
			max_x = maxf(max_x, u.global_position.x)
	for p in _arena.get("_capture_points"):
		min_x = minf(min_x, (p.get_position() as Vector2).x)
		max_x = maxf(max_x, (p.get_position() as Vector2).x)
	result["span"] = max_x - min_x
	result["budget"] = (half_w - FIT_MARGIN) * 2.0
	result["fit"] = max_x <= mid_x + half_w - FIT_MARGIN and min_x >= mid_x - half_w + FIT_MARGIN
	if not bool(result["fit"]):
		result["fit_detail"] = "范围 [%.0f, %.0f] 超出窗口 [%.0f, %.0f]" % [
			min_x, max_x, mid_x - half_w + FIT_MARGIN, mid_x + half_w - FIT_MARGIN]
	# ── 等战斗收束（战斗实例结束 = 全灭或斩首结算）──
	var battle: Node = null
	for u in attackers:
		if is_instance_valid(u) and u.has_method("get_battle_instance"):
			battle = u.get_battle_instance()
			if battle != null:
				break
	var sim_time: float = 0.0
	while sim_time < BATTLE_TIMEOUT_GAME_SEC:
		await get_tree().create_timer(0.5).timeout
		sim_time += 0.5
		if battle == null or not is_instance_valid(battle) or not battle.is_active():
			result["ended"] = true
			break
	result["duration"] = sim_time
	result["left_alive"] = _count_alive(attackers)
	result["right_alive"] = _count_alive(defenders)
	if not settle_info.is_empty():
		var p: Dictionary = settle_info[0]
		result["settle_reason"] = str(p.get("reason", "?"))
		print("[ArenaCheck] 结算 reason=%s payload=%s" % [result["settle_reason"], JSON.stringify(p)])
	if eb != null and eb.has_signal("battle_settled") and eb.battle_settled.is_connected(on_settled):
		eb.battle_settled.disconnect(on_settled)
	return result


func _count_alive(units: Array) -> int:
	var n: int = 0
	for u in units:
		if is_instance_valid(u) and u.get("health_component") != null \
				and not u.health_component.is_dead():
			n += 1
	return n
