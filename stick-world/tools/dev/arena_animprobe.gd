extends Node
## 观察场动画分布探针——由 arena_shot_boot 挂到 SceneTree.root（--animprobe 模式）。
## 用途：定位"异常姿势大户"（如振臂高呼疑云的 arrive 列阵动画）——按帧采样全部
## 存活单位的当前动画名，产出：①各动画帧占比分布（top N）②目标动画的进入沿
## 计数（prev≠X → cur=X 的次数 = 播放下限）与播过的单位数。stdout 报告，无落盘。
## 用法：tools/dev/arena_shot_boot.tscn -- --preset 1 --secs 30 --animprobe

const COVER_WAIT_FRAMES := 4200
const REPORT_EVERY := 5.0
## 重点盯的动画（进入沿计数+单位名单）；空 = 只出分布
const WATCH: Array = ["arrive", "block", "block_attack_1", "block_attack_2", "block_attack_3"]

var _t0 := 0.0
var _frames: int = 0
var _counts: Dictionary = {}          # anim -> 帧×单位样本数
var _enter_counts: Dictionary = {}    # anim(仅 WATCH) -> 进入沿次数
var _enter_units: Dictionary = {}     # anim(仅 WATCH) -> 播过的单位 instance_id 集合
var _prev: Dictionary = {}            # unit instance_id -> 上一拍动画名


func run(_tag: String, _preset: int, secs: int, _every: int) -> void:
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			break
	for i in 12:
		await get_tree().process_frame
	_t0 = Time.get_ticks_msec() / 1000.0
	var next_report := _t0 + REPORT_EVERY
	while _elapsed() < secs:
		await get_tree().process_frame
		_sample_frame()
		if Time.get_ticks_msec() / 1000.0 >= next_report:
			_report("…中途")
			next_report = Time.get_ticks_msec() / 1000.0 + REPORT_EVERY
	_finish()


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - _t0


func _sample_frame() -> void:
	var arena := get_tree().current_scene
	if arena == null or not is_instance_valid(arena):
		return
	_frames += 1
	for e in arena.find_children("", "StickmanEntity", true, false):
		if not is_instance_valid(e) or e.is_dead():
			continue
		var anim: String = e.get_current_anim()
		_counts[anim] = int(_counts.get(anim, 0)) + 1
		var id := e.get_instance_id()
		if WATCH.has(anim):
			if str(_prev.get(id, "")) != anim:
				_enter_counts[anim] = int(_enter_counts.get(anim, 0)) + 1
				if not _enter_units.has(anim):
					_enter_units[anim] = {}
				(_enter_units[anim] as Dictionary)[id] = true
		_prev[id] = anim


func _report(head: String) -> void:
	var total: int = 0
	for c in _counts.values():
		total += int(c)
	if total == 0:
		print("[AnimProbe] %s：尚无样本" % head)
		return
	var keys: Array = _counts.keys()
	keys.sort_custom(func(a, b): return int(_counts[a]) > int(_counts[b]))
	var lines: Array = []
	for i in mini(12, keys.size()):
		var k: String = keys[i]
		lines.append("%s %.1f%%(%d)" % [k, 100.0 * int(_counts[k]) / total, int(_counts[k])])
	print("[AnimProbe] %s %d帧 帧占比top：%s" % [head, _frames, "，".join(lines)])


func _finish() -> void:
	_report("最终")
	for anim in WATCH:
		var enters: int = int(_enter_counts.get(anim, 0))
		var units: int = (_enter_units.get(anim, {}) as Dictionary).size()
		print("[AnimProbe] 进入沿 %s：≈%d 次 / %d 个单位播过" % [anim, enters, units])
	print("[AnimProbe] done")
	get_tree().quit()
