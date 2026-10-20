extends Node
## 观察场镜像通道指标 driver——由 arena_shot_boot 挂到 SceneTree.root（--metrics 模式），
## 等揭幕后采样 N 秒，产出三项批1门禁指标（战场观感重构批1验收口径）：
##   - 挥砍可见率：出击窗口内（登记目标未结算）镜像动画显示攻击族的帧占比 → 目标 ≈1
##   - 滑步比：动画速率推算速度 vs 实际速度的相对偏差（walk/run 帧）→ 目标 ≈0
##   - 命中-Hit 帧偏差：攻击动画起点→sim 实际结算的时长 vs 动画 Hit 帧表时长（近战）
## 采样走渲染帧（与镜像 feed 同拍）；JSON 落 user://metrics/，由 arena_metrics.sh 归集。


const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT
## 滑步基准单一真相源＝entity_motion 常量（2026-10-06 校准为满走/满跑速后，
## 本文件旧副本 75/156/1.4 与真值漂移＝度量衡假红，滑步比虚报 0.64）
const Motion := preload("res://modules/units/scripts/entity/entity_motion.gd")
const WALK_ANIM_BASE: float = Motion.WALK_ANIM_BASE
const RUN_ANIM_BASE: float = Motion.RUN_ANIM_BASE
const ANIM_SPEED_MULT: float = Motion.ANIM_SPEED_MULT
const COVER_WAIT_FRAMES := 4200
## 命中偏差只统计近战（弓两段动画 hold/release 的动画起点对不上 Hit 表）
const MELEE_WEAPONS := [0, 1, 3]   # SWORD / SPEAR / PICKAXE

var _t0 := 0.0
var _strike_total := 0
var _strike_visible := 0
var _slip_n := 0
var _slip_sum := 0.0
var _dev_abs_sum := 0.0
var _dev_n := 0
var _dev_list: Array = []
var _e_state: Dictionary = {}


func run(_tag: String, _preset: int, secs: int, every: int) -> void:
	var waited := false
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			waited = true
			break
	print("[ArenaMetrics] cover gone=%s，采样 %ds" % [waited, secs])
	# 等旧图退场（arena"旧图延迟销毁"：遮罩撤除后旧村图还挂几帧，
	# 截图/采样落在窗内会把村舍残影当战场）——揭幕后稳定一小段再动作
	for i in 12:
		await get_tree().process_frame
	_t0 = Time.get_ticks_msec() / 1000.0
	var next_report := _t0 + maxf(every, 5)
	while _elapsed() < secs:
		await get_tree().process_frame
		_sample_frame()
		if Time.get_ticks_msec() / 1000.0 >= next_report:
			_report("…中途")
			next_report = Time.get_ticks_msec() / 1000.0 + maxf(every, 5)
	_finish(secs)


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - _t0


func _sample_frame() -> void:
	var arena := get_tree().current_scene
	if arena == null or not is_instance_valid(arena):
		return
	for e in arena.find_children("", "StickmanEntity", true, false):
		if not is_instance_valid(e) or e.is_dead():
			continue
		var visual: Variant = e.get("_visual")
		if visual == null or not is_instance_valid(visual) or not visual.has_method("get_mirror_anim_state"):
			continue
		var ms: Dictionary = visual.get_mirror_anim_state()
		var anim := str(ms.get("anim", ""))
		var speed := float(ms.get("speed", 1.0))
		var weapon: Node = e.get_node_or_null("WeaponMount")
		if weapon == null:
			continue
		var id := e.get_instance_id()
		var st: Dictionary = _e_state.get_or_add(id, {
			"was_in_attack": false, "attack_start": 0.0, "armed": false, "prev_fired": false,
		})
		var fired: bool = bool(weapon.get("_strike_fired"))
		var pending = weapon.get("_pending_strike_target")
		# 挥砍可见率：出击窗口（登记目标未结算）
		if pending != null and not fired:
			_strike_total += 1
			# 可见口径 = 攻击族或受击族：近战互殴中 flinch 插播打断挥砍是本批
			# 落的受击反馈（SWL 同款），不是丢挥砍；只有中性 walk/idle/定格才算丢
			if _is_attack_family(anim) or anim.begins_with("hit") or anim.begins_with("block"):
				_strike_visible += 1
		# 滑步比：动画速率推算速度 vs 实际速度
		if (anim == "walk" or anim == "run") and speed > 0.01:
			var base := WALK_ANIM_BASE if anim == "walk" else RUN_ANIM_BASE
			var implied := speed * base / ANIM_SPEED_MULT
			var actual := (e as CharacterBody2D).velocity.length()
			if actual > 20.0:
				_slip_n += 1
				_slip_sum += absf(implied - actual) / actual
		# 命中-Hit 帧偏差（近战，动画沿触发窗口）
		var in_attack := _is_attack_family(anim)
		var wt := int(weapon.get("weapon_type"))
		if in_attack and not st["was_in_attack"] and wt in MELEE_WEAPONS:
			st["attack_start"] = _elapsed()
			# 期望 Hit 帧按实际起播的变体动画取（attack_spear_2/block_attack_1 等
			# 变体各有自己的 Hit 点，取基础武器动画会引入系统性偏差）
			var expected_now: float = Anims.rigless_anim_event_time(anim, "Hit")
			if expected_now < 0.0:
				expected_now = Anims.rigless_anim_event_time(Anims.anim_for_weapon(wt), "Hit")
			st["expected"] = expected_now
			st["armed"] = expected_now >= 0.0
		if st["armed"]:
			if fired and not st["prev_fired"]:
				var dev := _elapsed() - float(st["attack_start"]) - float(st.get("expected", -1.0))
				_dev_n += 1
				_dev_abs_sum += absf(dev)
				_dev_list.append(dev)
				st["armed"] = false
			elif _elapsed() - float(st["attack_start"]) > 3.0:
				st["armed"] = false
		st["was_in_attack"] = in_attack
		st["prev_fired"] = fired


## 攻击族动画判定：attack* 与持盾攻击池 block_attack*（后者是举盾矛兵的
## 三连刺变体，不算"attack 开头"会被误计为挥砍不可见）
func _is_attack_family(anim: String) -> bool:
	return anim.begins_with("attack") or anim.begins_with("block_attack")


func _report(prefix: String) -> void:
	var vis: float = float(_strike_visible) / float(_strike_total) if _strike_total > 0 else -1.0
	var slip: float = _slip_sum / _slip_n if _slip_n > 0 else -1.0
	var dev_ms: float = _dev_abs_sum / _dev_n * 1000.0 if _dev_n > 0 else -1.0
	print("[ArenaMetrics] %s 挥砍可见率=%.3f（%d 采样） 滑步比=%.3f（%d） 命中偏差|均值|=%.0fms（%d）" % [
		prefix, vis, _strike_total, slip, _slip_n, dev_ms, _dev_n])


func _finish(secs: int) -> void:
	_report("最终")
	var out := {
		"secs": secs,
		"swing_visible_rate": float(_strike_visible) / _strike_total if _strike_total > 0 else -1.0,
		"swing_samples": _strike_total,
		"slip_ratio": _slip_sum / _slip_n if _slip_n > 0 else -1.0,
		"slip_samples": _slip_n,
		"hit_dev_abs_mean_ms": _dev_abs_sum / _dev_n * 1000.0 if _dev_n > 0 else -1.0,
		"hit_dev_samples": _dev_n,
		"hit_dev_raw_s": _dev_list,
	}
	DirAccess.make_dir_recursive_absolute("user://metrics")
	var path := "user://metrics/metrics_%d.json" % Time.get_ticks_msec()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[ArenaMetrics] json=%s" % path)
	get_tree().quit(0)
