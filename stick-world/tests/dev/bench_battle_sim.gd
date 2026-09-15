extends Node
## 战斗模拟热路径基准（headless 专用，无渲染噪声，非 CI 测试）。
##
## 场景：96v96 混编（矛 36 / 剑 36 / 弓 24 每方），seed(4242) 固定 →
## battle 开战 + 双侧 TeamAi 注册（不建小队：formation._process 空转，
## 保证模拟完全由物理 tick 驱动、黄金哈希跨运行稳定）。
##
## 时间线（物理 tick，Engine.get_physics_frames 相对计数）：
##   [0, 120)    热身（刷兵级联 / 武器延迟挂载 / 接敌展开）
##   [120, 420)  采样窗口：逐 tick 记录物理回调间隔（CPU 饱和时 = 真实每 tick 成本）
##   tick 420    拍"黄金哈希"（全单位 global_position/hp/faction 确定性摘要；
##               修复前后同种子必须一致——行为零回归的黄金对照）
##   随后        暂停世界 + 微基准：分项计时（空间网格 / 寻敌 / 状态机 /
##               ai 决策 / formation._process / team_ai 快照 / weapon 攻击 /
##               alive 缓存 / 攻击者计数）
##
## 用法：
##   timeout 180 godot --headless --path . res://tests/dev/bench_battle_sim.tscn
## 输出：[BENCH] 前缀 JSON 行（macro / hash / sub_*）。

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _TargetFinder := preload("res://modules/combat/scripts/target_finder.gd")
const _BehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")

# ── 基准配置 ──
const RNG_SEED: int = 4242
const WARMUP_TICKS: int = 120
const MEASURE_TICKS: int = 300  ## 采样窗口 [120, 420)
const HASH_TICK: int = WARMUP_TICKS + MEASURE_TICKS
## 编制：每方 12 列 × 8 行 = 96；行序前→后（矛先锋卡线 / 剑中坚 / 弓后排压制）
const COLS: int = 12
const ROWS: int = 8
const X_GAP: float = 64.0
const Y_GAP: float = 60.0
## 左右两团出生中心相对中线的偏移（弓射程 1400 > 2×560：开战即互射，接敌约 3s）
const TEAM_OFFSET_X: float = 560.0
const ROW_WEAPON: Array = [1, 1, 1, 0, 0, 0, 2, 2]  ## 1=矛 0=剑 2=弓（对齐 WeaponMount.WeaponType）

enum Phase { SETUP, MEASURE, DONE }

var _phase: int = Phase.SETUP
var _game_root: Node = null
var _map: Node2D = null
var _battle: Node = null
var _left: Array = []
var _right: Array = []
var _units: Array = []  ## 出生序全量（含已亡；哈希按此序，位置无关 instance_id）
var _start_frame: int = 0
var _last_tick_usec: int = 0
var _tick_samples: Array[float] = []
var _obj_count_0: int = 0
var _checkpoint_hashes: Array = []  ## [[tick, hash], ...] 发散定位用


## 轻量检查点哈希（只折位置与 hp，免 has_method 开销；与终态哈希同折叠常数）
func _capture_hash_lite() -> int:
	var h: int = 1469598103934665603
	for u in _units:
		if not is_instance_valid(u):
			h = (h * 1000003) ^ 0x7FFFFFFF
			continue
		var p: Vector2 = u.global_position
		var hc = u.get("health_component")
		h = (h * 1000003) ^ int(p.x * 100.0)
		h = (h * 1000003) ^ int(p.y * 100.0)
		h = (h * 1000003) ^ int((float(hc.get("hp")) if hc != null else 0.0) * 100.0)
	return h


func _ready() -> void:
	Engine.max_fps = 60  ## headless 无 vsync：钉住 process 频率，防 UI 空转抢 CPU 干扰采样
	seed(RNG_SEED)
	# 确定性笼子 ④：每物理 tick 起点重播种全局 RNG。模拟期间天空/环境/特效系统在
	# process 帧按真实时间消耗 randf，会挪动随机流（已实测：同代码两次运行哈希必异）；
	# physics_frame 信号先于本帧全部节点物理回调触发，这里重播种即可把帧间污染隔离——
	# 模拟内 RNG 只依赖（tick 序号，tick 内确定性的调用序）。
	get_tree().physics_frame.connect(_on_physics_frame)
	_neutralize_wall_clock_windows()
	_run.call_deferred()


## 每物理 tick 起点：重播种 + 攻击者新鲜度刷新 + 死者收口（见 _neutralize_wall_clock_windows）
func _on_physics_frame() -> void:
	if _phase == Phase.SETUP:
		return
	seed(RNG_SEED + Engine.get_physics_frames())
	# 兜底：开战自动暂停若在任何一帧再次生效（配置异步竞态），强制恢复 X1
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)
	if _battle != null and is_instance_valid(_battle):
		var now_ms: int = Time.get_ticks_msec()
		var ta: Dictionary = _battle._target_attackers
		for tid in ta:
			var atts: Dictionary = ta[tid]["attackers"]
			for k in atts:
				atts[k] = now_ms
	# 确定性笼子 ⑦：死者收口同步化——实体的碰撞体禁用走 set_deferred、尸体回收走
	# queue_free，两者都在主迭代末尾批量 flush；CPU 饱和时一次迭代跑多个物理 tick，
	# 生效 tick 对齐随"触发 tick 落在迭代内位置"漂移 → 尸体当墙的时长逐运行不同 →
	# 活单位移动发散。这里在每个 tick 起点同步禁用死者碰撞体并冻结淡出计时，
	# 尸体当墙从死亡 tick 起恒定、且永不回收（不进消息队列，无批处理抖动）。
	for u in _units:
		if not is_instance_valid(u) or not (u.has_method("is_dead") and u.is_dead()):
			continue
		var col: Node = u.get_node_or_null("Collider")
		if col != null and col.get("disabled") == false:
			col.set("disabled", true)
		u.set("_dead_disable_timer", -1.0)
		u.set("_corpse_fade_timer", -1.0)


## 确定性笼子：本环境模拟 CPU 饱和（约 8tps，远低于 60 目标），代码里按真实时钟
## （Time.get_ticks_msec）工作的窗口会随墙钟抖动翻转 → RNG 消费序列漂移 →
## 黄金哈希跨运行不可复现（已实测：同代码两次运行哈希必异）。这里统一冻结：
##   ① 行为档案关掉"箭矢威胁举盾 / 攻击后举盾"两窗口（get_profile 静态缓存，原地生效）；
##   ② TeamAi 投射物来袭窗口拉满（overrides 通道，等价"开战射过箭 = 恒受袭"）；
##   ③ 战斗实例攻击者新鲜度：每物理帧把全部登记时间戳刷成当前（见 _physics_process）。
## 基线与优化两侧共用同一笼子 → 哈希差异只反映被测代码的逻辑变化；
## 被冻结的三机制逻辑本次不动（不在优化范围），故对照依然有效。
func _neutralize_wall_clock_windows() -> void:
	for wt in [0, 1, 2]:
		var prof: Dictionary = _BehaviorProfiles.get_profile(wt)
		prof["arrow_threat_block"] = false
		prof["block_after_attack"] = 0.0


func _run() -> void:
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)
	_game_root.set("suppress_battlefield_enemies", true)
	for i in 10:
		await get_tree().process_frame
	var loader: Node = _game_root.get("scene_loader")
	if loader != null and loader.has_method("load_map"):
		loader.load_map("battlefield")
	for i in 20:
		await get_tree().process_frame
		var m: Node2D = _game_root.get_current_map()
		if m != null and "battlefield" in str(m.scene_file_path):
			break
	_map = _game_root.get_current_map()
	if _map == null:
		print("[BENCH][FATAL] 地图未加载")
		get_tree().quit(1)
		return
	# 清空地图自带单位（演练只保留基准自己刷的 192 个）
	for e in _map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame
	var mid_x: float = (_map.map_left + _map.map_right) * 0.5
	var spawn_y: float = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	for side in 2:
		var sign_x: float = -1.0 if side == 0 else 1.0
		var arr: Array = _left if side == 0 else _right
		for r in ROWS:
			for c in COLS:
				var x: float = mid_x + sign_x * (TEAM_OFFSET_X + float(c) * X_GAP)
				var y: float = spawn_y + (float(r) - float(ROWS - 1) * 0.5) * Y_GAP
				var u: Node2D = _spawn_unit(Vector2(x, y), int(ROW_WEAPON[r]))
				if u != null:
					arr.append(u)
					_units.append(u)
	# 两帧让 WeaponMount 延迟重挂（call_deferred）落地，再开战
	await get_tree().process_frame
	await get_tree().process_frame
	_freeze_anim_to_physics()
	_battle = _game_root.start_test_battle(_left, _right)
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)  # 开战自动暂停豁免（对齐 battle_arena）
	# 双侧阵营 AI（物理 tick 驱动、确定性；不建小队 → formation 空转，见文件头）
	if _battle != null and _battle.has_method("enable_team_ai"):
		_battle.enable_team_ai(1, {"projectile_window": 1.0e9})
		_battle.enable_team_ai(2, {"projectile_window": 1.0e9})
	_obj_count_0 = Performance.get_monitor(Performance.OBJECT_COUNT)
	_start_frame = Engine.get_physics_frames()
	_phase = Phase.MEASURE
	print("[BENCH] setup 完成: units=%d battle_ok=%s seed=%d map=%s" % [
		_units.size(), str(_battle != null), RNG_SEED,
		_map.scene_file_path.get_file()])


## 确定性笼子 ⑤+⑥：动画与 rig 逐帧检测从 process（墙钟帧）切到物理帧确定性路径——
## 命中帧结算（WeaponMount._has_reached_hit_frame / animation_event 双路径）依赖
## rig 动画播放位置与事件检测时机：
##   ⑤ AnimationMixer 切 PHYSICS（枚举值 0）：动画按物理 delta 推进，位置按 tick 确定；
##   ⑥ rig.set_process(false)：stickman_rig._process 里的受击回切计时器（真实 delta）与
##      动画事件检测（隔 process 帧采样）在 CPU 饱和（迭代=1 process 帧）时奇偶抖动，
##      事件会落进不同的 tick 间隙 → RNG 级联。关掉后命中结算只走物理帧轮询路径，
##      `_pending_strike_elapsed` 宽限也是物理 delta——全链路按 tick 确定。
func _freeze_anim_to_physics() -> void:
	for u in _units:
		if not is_instance_valid(u):
			continue
		var rig: Node = u.get("rig") if "rig" in u else null
		if rig != null:
			rig.set_process(false)
		_set_mixers_physics(u)


func _set_mixers_physics(node: Node) -> void:
	if node is AnimationMixer:
		node.callback_mode_process = 0
	for c in node.get_children():
		_set_mixers_physics(c)


## 出生一个单位（照抄 battle_sim：脚底对齐 + 不附身 + 设武器 + hp 兜底）
func _spawn_unit(pos: Vector2, wtype: int) -> Node2D:
	var e: Node2D = _map.spawn_entity(_StickmanScene, pos)
	if e == null:
		return null
	if e.get("foot_offset") != null:
		e.global_position.y = pos.y - e.foot_offset
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	var wm: Node = e.get_node_or_null("WeaponMount")
	if wm != null:
		wm.weapon_type = wtype
	var hc = e.get("health_component")
	if hc != null and float(hc.get("hp")) <= 0.0:
		hc.set("hp", hc.get("max_hp"))
	return e


func _physics_process(_delta: float) -> void:
	if _phase != Phase.MEASURE:
		return
	var f := Engine.get_physics_frames() - _start_frame
	var now := Time.get_ticks_usec()
	# 间隔样本 = 上一物理帧回调 → 本帧回调的墙钟差；CPU 饱和时即真实每 tick 成本
	if _last_tick_usec > 0 and f > WARMUP_TICKS:
		_tick_samples.append(float(now - _last_tick_usec) / 1000.0)
	_last_tick_usec = now
	# 中途检查点哈希（每 20 tick）：黄金对照取 tick 240（实测多运行逐字节稳定）；
	# 300+ 后偶发引擎级事件时序抖动（物理 flush/延迟释放的迭代批处理），终态哈希仅作哨兵
	if f > WARMUP_TICKS and (f - WARMUP_TICKS) % 20 == 0:
		var pos_h := 0
		var hp_h := 0
		var alive := 0
		for u in _units:
			if not is_instance_valid(u):
				pos_h = (pos_h * 1000003) ^ 0x7FFFFFFF
				hp_h = (hp_h * 1000003) ^ 0x7FFFFFFF
				continue
			var p: Vector2 = u.global_position
			pos_h = (pos_h * 1000003) ^ int(p.x * 100.0)
			pos_h = (pos_h * 1000003) ^ int(p.y * 100.0)
			var hc2 = u.get("health_component")
			var hpv: float = float(hc2.get("hp")) if hc2 != null else 0.0
			hp_h = (hp_h * 1000003) ^ int(hpv * 100.0)
			if not (u.has_method("is_dead") and u.is_dead()):
				alive += 1
		_checkpoint_hashes.append([f, alive, pos_h, hp_h])
	if f >= HASH_TICK:
		_phase = Phase.DONE
		_finish()


# ─────────────────────────────── 收尾：哈希 + 报告 + 微基准 ────────────────────────────────

func _finish() -> void:
	# 暂停世界：微基准不再与后台模拟互相抢 CPU（数字更稳；均为直接函数调用，暂停不影响）
	if TimeManager != null:
		TimeManager.set_speed(TimeManager.Speed.PAUSED)
	_report_macro()
	_report_hash(_capture_hash())
	_run_micro()
	print("[BENCH] 完成")
	get_tree().quit(0)


## 黄金哈希：出生序遍历全单位，pos(0.01px 量化)/hp(0.01 量化)/faction 折叠进 64 位摘录。
## 已 queue_free 的尸体（淡出回收）贡献固定哨兵——是否已回收由物理 tick 决定，仍确定。
func _capture_hash() -> int:
	var h: int = 1469598103934665603
	var alive: int = 0
	for u in _units:
		if not is_instance_valid(u):
			h = (h * 1000003) ^ 0x7FFFFFFF
			continue
		var hp: float = 0.0
		var hc = u.get("health_component")
		if hc != null:
			hp = float(hc.get("hp"))
		if not (u.has_method("is_dead") and u.is_dead()):
			alive += 1
		var p: Vector2 = u.global_position
		var f: int = u.get_faction() if u.has_method("get_faction") else 0
		h = (h * 1000003) ^ int(p.x * 100.0)
		h = (h * 1000003) ^ int(p.y * 100.0)
		h = (h * 1000003) ^ int(hp * 100.0)
		h = (h * 1000003) ^ f
	_alive_at_hash = alive
	return h

var _alive_at_hash: int = 0


func _report_hash(h: int) -> void:
	var ended: bool = _battle == null or not is_instance_valid(_battle) \
			or not _battle.is_active()
	var winner: int = 0
	var dur: float = -1.0
	if _battle != null and is_instance_valid(_battle):
		if _battle.has_method("get_winner"):
			winner = _battle.get_winner()
		if _battle.has_method("get_duration"):
			dur = snappedf(_battle.get_duration(), 0.01)
	print("[BENCH] hash {%s}" % JSON.stringify({
		"seed": RNG_SEED,
		"tick": HASH_TICK,
		"hash": h,
		"alive": _alive_at_hash,
		"battle_ended": ended,
		"winner": winner,
		"battle_dur": dur,
		"paused": TimeManager != null and TimeManager.is_paused(),
	}))
	var cps: Array = []
	for cp in _checkpoint_hashes:
		cps.append("%d:a%d/p%d/h%d" % [cp[0], cp[1], cp[2], cp[3]])
	print("[BENCH] checkpoints [%s]" % " ".join(cps))


func _report_macro() -> void:
	var n := _tick_samples.size()
	if n == 0:
		print("[BENCH][FATAL] 无采样")
		return
	var sorted := _tick_samples.duplicate()
	sorted.sort()
	var sum: float = 0.0
	for s in _tick_samples:
		sum += s
	var avg: float = sum / float(n)
	var obj_delta: int = Performance.get_monitor(Performance.OBJECT_COUNT) - _obj_count_0
	print("[BENCH] macro {%s}" % JSON.stringify({
		"units": _units.size(),
		"samples": n,
		"tick_avg_ms": snappedf(avg, 0.001),
		"tick_p50_ms": snappedf(sorted[n / 2], 0.001),
		"tick_p95_ms": snappedf(sorted[mini(n - 1, int(n * 0.95))], 0.001),
		"tick_max_ms": snappedf(sorted[n - 1], 0.001),
		"per_unit_per_tick_us": snappedf(avg * 1000.0 / float(_units.size()), 0.01),
		"tps_effective": snappedf(1000.0 / avg, 0.1),
		"obj_count_delta": obj_delta,
	}))


# ─────────────────────────────── 微基准（分项计时）────────────────────────────────

## 取一个存活采样单位（优先指定兵种；找不到回退任意存活者）
func _pick_unit(arr: Array, wtype: int) -> Node:
	var fallback = null
	for u in arr:
		if not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
			continue
		var wm: Node = u.get_node_or_null("WeaponMount")
		if wm != null and int(wm.weapon_type) == wtype:
			return u
		if fallback == null:
			fallback = u
	return fallback


func _time_us(n: int, f: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	for i in n:
		f.call()
	return float(Time.get_ticks_usec() - t0) / float(n)


func _run_micro() -> void:
	var mid_x: float = (_map.map_left + _map.map_right) * 0.5
	var spawn_y: float = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	var crowd := Vector2(mid_x, spawn_y)
	var battle_ok: bool = _battle != null and is_instance_valid(_battle)

	# ① 空间网格邻域查询（分离/威胁/寻敌预筛共用入口）
	print("[BENCH] sub_query_neighbors {%s}" % JSON.stringify({
		"r56_us": snappedf(_time_us(2000, func() -> void: _map.query_neighbors(crowd, 56.0)), 0.2),
		"r148_us": snappedf(_time_us(1000, func() -> void: _map.query_neighbors(crowd, 148.0)), 0.2),
		"r300_us": snappedf(_time_us(500, func() -> void: _map.query_neighbors(crowd, 300.0)), 0.2),
	}))

	# ② battle 寻敌（get_nearest_enemy / TargetFinder.find_target）
	var u_sword := _pick_unit(_left, 0)
	if battle_ok and u_sword != null:
		var opts: Dictionary = {"battle": _battle, "ignore_current_attackers": true, "prefer_large": 0.0}
		print("[BENCH] sub_find_enemy {%s}" % JSON.stringify({
			"nearest_enemy_us": snappedf(_time_us(500, func() -> void: _battle.get_nearest_enemy(u_sword)), 0.2),
			"find_target_us": snappedf(_time_us(500, func() -> void: _TargetFinder.find_target(u_sword, opts)), 0.2),
		}))

	# ③ AI：决策 + 行为状态机推进（30Hz 语义 delta）
	var u_ai := _pick_unit(_left, 1)
	if u_ai != null and u_ai.has_method("get_ai_controller"):
		var ai: Node = u_ai.get_ai_controller()
		var sm: Node = ai.get_state_machine()
		print("[BENCH] sub_ai {%s}" % JSON.stringify({
			"make_decision_us": snappedf(_time_us(500, func() -> void: ai._make_decision()), 0.2),
			"sm_physics_update_us": snappedf(_time_us(1000, func() -> void: sm.physics_update(0.0333)), 0.2),
		}))
	else:
		print("[BENCH] sub_ai {\"skipped\": true}")

	# ④ formation_system._process（含建小队：清理扫描/集火决策/指挥官光环）
	var fs: Node = _game_root.get_formation_system()
	if fs != null and fs.has_method("create_squad"):
		fs.set_process(false)  # 隔离引擎侧 _process，只测手动调用
		for si in 3:
			for side_i in 2:
				var side_arr: Array = _left if side_i == 0 else _right
				var slice: Array = []
				for k in 32:
					var idx: int = si * 32 + k
					if idx < side_arr.size():
						slice.append(side_arr[idx])
				if not slice.is_empty():
					fs.create_squad(slice, "bench_s%d_%d" % [si, side_i], "fp_combat_squad")
		print("[BENCH] sub_formation {%s}" % JSON.stringify({
			"process_us": snappedf(_time_us(600, func() -> void: fs._process(0.01666)), 0.2),
		}))

	# ⑤ team_ai 快照（姿态机决策主体，O(n) 双方扫描）
	var tai1: Variant = _battle.get_team_ai(1) if battle_ok and _battle.has_method("get_team_ai") else null
	var tai2: Variant = _battle.get_team_ai(2) if battle_ok and _battle.has_method("get_team_ai") else null
	if tai1 != null and tai2 != null:
		print("[BENCH] sub_team_ai {%s}" % JSON.stringify({
			"refresh_snapshot_us": snappedf(
					_time_us(200, func() -> void:
						tai1._refresh_snapshot()
						tai2._refresh_snapshot()), 0.2),
		}))

	# ⑥ weapon_mount：冷却查询 + 近战出手（含命中帧登记）
	var u_att := _pick_unit(_left, 0)
	if u_att != null:
		var wm: Node = u_att.get_node_or_null("WeaponMount")
		var tgt: Node = _battle.get_nearest_enemy(u_att) if battle_ok and _battle.has_method("get_nearest_enemy") else null
		if wm != null:
			var item := {
				"can_attack_us": snappedf(_time_us(3000, func() -> void: wm.can_attack()), 0.2),
			}
			if tgt != null and is_instance_valid(tgt):
				item["perform_attack_us"] = snappedf(_time_us(200, func() -> void: wm.perform_attack(tgt)), 0.2)
			if battle_ok:
				item["get_attacker_count_us"] = snappedf(_time_us(3000, func() -> void: _battle.get_attacker_count(tgt if tgt != null else u_att)), 0.2)
			print("[BENCH] sub_weapon {%s}" % JSON.stringify(item))

	# ⑦ battle 存活缓存重建（每物理帧一次的真实成本）
	if battle_ok and _battle.has_method("get_alive_enemies_of"):
		print("[BENCH] sub_alive_cache {%s}" % JSON.stringify({
			"rebuild_us": snappedf(_time_us(300, func() -> void:
				_battle._alive_cache_frame = -1
				_battle.get_alive_enemies_of(1)), 0.2),
		}))
