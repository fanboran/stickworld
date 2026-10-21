extends Node
## 无头验收 driver —— 寻路避障 9h 复验：观察场（战斗）与主街（村民劳作通勤）
## 两场各跑一轮，采样"有移动意图但窗口内净位移≈0"的卡死窗口，输出指标并判定
## 是否存在永久卡死。
##
## 判定口径（与 AIController 看门狗同族阈值取严一档）：
##   - 意图 = entity.velocity 长度 > 10（看门狗 stuck_watchdog_intent_speed 同值）
##   - 卡死窗口 = 连续 3s 意图在跑但净位移 < 12px（看门狗窗口 2s/12px 的加严版）
##   - 永久卡死 = 连续卡死 ≥ 8s（看门狗 2s + 避障放弃 5s 的恢复链全部失效才算）
## 输出：逐场 [NavStuck] 行（t/活体/卡死窗口数/最长连续卡死）+ 终局摘要；
## 退出码 0 = 无永久卡死，1 = 有永久卡死或装配失败。
## 用法：godot --headless --path stick-world res://tests/dev/nav_stuck_check.tscn

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const SAMPLE_EVERY := 60          ## 采样间隔（帧，~1s）
const WINDOW_FRAMES := 180        ## 净位移窗（~3s）
const DRIFT_MIN := 12.0           ## 窗口净位移下限（看门狗同值）
const INTENT_MIN := 10.0          ## 意图速度下限（看门狗同值）
const STUCK_HARD_SEC := 8.0       ## 永久卡死判定（连续秒）
const ARENA_PRESET := 1           ## 密度压力·48（设计验收主档之上的人群档）
const ARENA_SETTLE_FRAMES := 60 * 8      ## 出生列阵等待
const ARENA_BUDGET_FRAMES := 60 * 240    ## 观察场采样预算（4 分钟墙钟兜底）
const STREET_SETTLE_FRAMES := 60 * 50    ## 主街就绪等待（村民出生+出城通勤+上工）
const STREET_BUDGET_FRAMES := 60 * 240   ## 主街采样预算（4 分钟）


## 单位采样记录（按实例 id 字典持有，离开战场自动收缩）
class Track:
	var pos: Vector2 = Vector2.ZERO
	var window_start: Vector2 = Vector2.ZERO
	var window_frames: int = 0
	var stuck_sec: float = 0.0     ## 连续卡死秒数（窗口判定累加）
	var max_stuck: float = 0.0


var _tracks: Dictionary = {}  ## instance_id -> Track
var _worst_stuck: float = 0.0
var _stuck_events: int = 0
var _engaged_press: int = 0
var _sample_count: int = 0
var _world: Node = null       ## 场景级缓存：get_current_map 持有者（game_root）


func run() -> void:
	# ── 第一场：观察场（密度压力·48，打完或预算耗尽）──
	get_tree().change_scene_to_file(ARENA_SCENE)
	if not await _wait_world_ready(false):
		push_error("[NavStuck] 观察场装配失败")
		get_tree().quit(1)
		return
	await _frames(ARENA_SETTLE_FRAMES)
	var arena: Node = get_tree().current_scene
	if arena.has_method("_switch_preset"):
		arena.call("_switch_preset", ARENA_PRESET)  # static 档位跨 reload 保持
		await _frames(ARENA_SETTLE_FRAMES)
	print("[NavStuck] === 观察场（预设 %d）开始采样 ===" % ARENA_PRESET)
	var arena_hard: bool = await _probe(ARENA_BUDGET_FRAMES, true)
	# ── 第二场：主街（新游戏直连，村民劳作/通勤穿越城门与建筑带）──
	_world = null
	get_tree().change_scene_to_file(GAME_ROOT_SCENE)
	if not await _wait_world_ready(true):
		push_error("[NavStuck] 主街装配失败")
		get_tree().quit(1)
		return
	await _frames(STREET_SETTLE_FRAMES)
	print("[NavStuck] === 主街开始采样 ===")
	var street_hard: bool = await _probe(STREET_BUDGET_FRAMES, false)
	# ── 终局摘要 ──
	print("[NavStuck] === 复验摘要 ===")
	print("[NavStuck] 观察场永久卡死: %s | 主街永久卡死: %s" % [arena_hard, street_hard])
	get_tree().quit(0 if not arena_hard and not street_hard else 1)


## 采样主循环：每 SAMPLE_EVERY 帧采一次，净位移窗 WINDOW_FRAMES 判卡死。
## battle_mode=true 时战斗收敛（无活跃战斗）提前收场。
func _probe(budget_frames: int, battle_mode: bool) -> bool:
	_tracks.clear()
	_worst_stuck = 0.0
	_stuck_events = 0
	_engaged_press = 0
	_sample_count = 0
	var frames := 0
	while frames < budget_frames:
		await _frames(SAMPLE_EVERY)
		frames += SAMPLE_EVERY
		_sample_count += 1
		if battle_mode and not _battle_active():
			print("[NavStuck] t=%4.0fs 战斗收敛收场" % [frames / 60.0])
			break
		_sample()
		if _sample_count % 20 == 0:
			print("[NavStuck] t=%4.0fs 活体=%d 追踪=%d 卡死事件=%d 接战压制=%d 最长连续=%.1fs"
					% [frames / 60.0, _alive_count(), _tracks.size(), _stuck_events,
							_engaged_press, _worst_stuck])
		if _worst_stuck >= STUCK_HARD_SEC:
			break  # 永久卡死实锤：提前收场报红
	print("[NavStuck] 场终: 采样=%d 卡死事件=%d 接战压制=%d 最长连续=%.1fs 判永久卡死=%s"
			% [_sample_count, _stuck_events, _engaged_press, _worst_stuck,
					_worst_stuck >= STUCK_HARD_SEC])
	return _worst_stuck >= STUCK_HARD_SEC


## 单次采样：收集场上存活单位，滚动净位移窗 + 卡死窗口判定。
## 接战豁免：attack 行为（接战推进压制/y 走位振荡——战斗语义域，归分离/看门狗）
## 与 150px 内有存活敌人的顶线不算寻路卡死，单独计数 engaged_press 供观测。
func _sample() -> void:
	var units := _collect_units()
	var seen: Dictionary = {}
	for e in units:
		if e == null or not is_instance_valid(e):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		var iid: int = e.get_instance_id()
		seen[iid] = true
		var tr: Track = _tracks.get(iid)
		if tr == null:
			tr = Track.new()
			tr.pos = e.global_position
			tr.window_start = e.global_position
			_tracks[iid] = tr
			continue
		var pos: Vector2 = e.global_position
		tr.pos = pos
		tr.window_frames += SAMPLE_EVERY
		if tr.window_frames >= WINDOW_FRAMES:
			var drift: float = pos.distance_to(tr.window_start)
			tr.window_start = pos
			tr.window_frames = 0
			var intent: float = e.velocity.length() if e is CharacterBody2D else 0.0
			if intent > INTENT_MIN and drift < DRIFT_MIN:
				if _behavior_of(e) == "attack" or _enemy_near(e, 150.0):
					_engaged_press += 1
					tr.stuck_sec = 0.0  # 战斗压制不累计寻路卡死
					continue
				tr.stuck_sec += float(WINDOW_FRAMES) / 60.0
				_stuck_events += 1
				tr.max_stuck = maxf(tr.max_stuck, tr.stuck_sec)
				_dump_unit(e, drift, intent, tr)
				_worst_stuck = maxf(_worst_stuck, tr.stuck_sec)
			else:
				tr.stuck_sec = 0.0
	# 离场单位记录收缩
	for iid in _tracks.keys():
		if not seen.has(iid):
			_tracks.erase(iid)


## 单位当前行为名（无 AI 面 = 空串）。
func _behavior_of(e: Node) -> String:
	if not e.has_method("get_ai_controller"):
		return ""
	var ai: Node = e.get_ai_controller()
	if ai == null or not is_instance_valid(ai) or not ai.has_method("get_current_behavior"):
		return ""
	return ai.get_current_behavior()


## 卡死窗口触发时的单位画像（行为/武器/位置——归因用）。
func _dump_unit(e: Node, drift: float, intent: float, tr: Track) -> void:
	if tr.stuck_sec > float(WINDOW_FRAMES) / 60.0 + 0.01:
		return  # 只在首个窗口 dump，后续窗口静默累计
	var behav := "?"
	if e.has_method("get_ai_controller"):
		var ai: Node = e.get_ai_controller()
		if ai != null and is_instance_valid(ai) and ai.has_method("get_current_behavior"):
			behav = ai.get_current_behavior()
	var wt := -1
	if e.has_method("get_weapon"):
		var w: Node = e.get_weapon()
		if w != null and is_instance_valid(w) and "weapon_type" in w:
			wt = int(w.weapon_type)
	print("[NavStuck]   卡死窗口: %s 行为=%s 武器=%d pos=%v 意图速=%.0f 窗净位移=%.1f 累计=%.1fs"
			% [e.name, behav, wt, e.global_position, intent, drift, tr.stuck_sec])


## 半径内是否有存活敌人（接战豁免判定；无战斗面/无阵营面 = false）。
func _enemy_near(e: Node, radius: float) -> bool:
	if not (e is CharacterBody2D):
		return false
	if not e.has_method("get_faction"):
		return false
	var faction: int = e.get_faction()
	if faction == 0:
		return false
	if not e.has_method("get_battle_instance"):
		return false
	var bi: Node = e.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("is_active") \
			or not bi.is_active() or not bi.has_method("get_enemies_of"):
		return false
	for foe in bi.get_enemies_of(faction):
		if foe == null or not is_instance_valid(foe):
			continue
		if foe.has_method("is_dead") and foe.is_dead():
			continue
		if e.global_position.distance_to(foe.global_position) <= radius:
			return true
	return false


## 收集当前场景存活单位（地图实体表——观察场与主街同一条路：game_root 地图）。
func _collect_units() -> Array:
	var map: Node2D = _current_map()
	if map != null and map.has_method("get_entities"):
		return map.get_entities()
	return []


func _alive_count() -> int:
	var n := 0
	for e in _collect_units():
		if e != null and is_instance_valid(e) and not (e.has_method("is_dead") and e.is_dead()):
			n += 1
	return n


## 是否有活跃战斗（观察场收敛判定）：game_root → battle_director → has_active_battle。
func _battle_active() -> bool:
	var gr := _resolve_world()
	if gr == null or not gr.has_method("get_battle_director_node"):
		return false
	var bd: Node = gr.get_battle_director_node()
	return bd != null and bd.has_method("has_active_battle") and bd.has_active_battle()


func _current_map() -> Node2D:
	var gr := _resolve_world()
	if gr == null or not gr.has_method("get_current_map"):
		return null
	return gr.get_current_map()


## 场景级缓存 get_current_map 持有者：主街 = 当前场景本体（game_root）；
## 观察场 = 当前场景（battle_arena）内嵌的 game_root 子孙。
func _resolve_world() -> Node:
	if _world != null and is_instance_valid(_world):
		return _world
	var cs := get_tree().current_scene
	if cs == null:
		return null
	if cs.has_method("get_current_map"):
		_world = cs
		return _world
	_world = _find_descendant_world(cs, 0)
	return _world


func _find_descendant_world(node: Node, depth: int) -> Node:
	if depth > 4:
		return null
	for c in node.get_children():
		if c.has_method("get_current_map"):
			return c
		var found: Node = _find_descendant_world(c, depth + 1)
		if found != null:
			return found
	return null


## 等世界加载完成（地图就绪；require_player=true 再等玩家实体——主街口径，
## 观察场无玩家不要求）。
func _wait_world_ready(require_player: bool, timeout: float = 90.0) -> bool:
	var t := 0.0
	while t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
		var map: Node2D = _current_map()
		if map != null:
			if not require_player:
				await _frames(10)
				return true
			var gr := _resolve_world()
			if gr != null and gr.has_method("get_player_entity") and gr.get_player_entity() != null:
				await _frames(10)
				return true
	return false


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
