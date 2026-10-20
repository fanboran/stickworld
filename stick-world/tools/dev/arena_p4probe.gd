extends Node
## 批4 门禁探针（--p4probe）：号令粘性 + 游走度两指标跑批。
##   - 号令翻转率（门禁 <20 次/分钟）：双方规划器 get_order_stats() 的 flips
##     换算每分钟；elapsed 取结算权那台的拍时钟。
##   - 游走度（拉扯感代理）：单位级 vx 翻转率（x 速度符号变化沿/秒，0.1s 采样）
##     ——均值与 worst。治理参照：旧值均值 0.79/s（按 1/6 折算口径）。
## stdout 报告，一次性。

const COVER_WAIT_FRAMES := 4200
const VXSAMPLE_DT: float = 0.1

var _t0 := 0.0
var _prev_x: Dictionary = {}     # unit id -> 上一拍 x
var _prev_dir: Dictionary = {}   # unit id -> 上一拍 x 符号
var _flip_counts: Dictionary = {}   # unit id -> vx 翻转次数
var _samples: int = 0


func run(_tag: String, _preset: int, secs: int, _every: int) -> void:
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			break
	for i in 12:
		await get_tree().process_frame
	var arena: Node = get_tree().current_scene
	_t0 = Time.get_ticks_msec() / 1000.0
	var acc: float = 0.0
	while _elapsed() < secs:
		await get_tree().process_frame
		acc += get_process_delta_time()
		if acc >= VXSAMPLE_DT:
			acc = 0.0
			_sample_vx(arena)
	_report_planners(arena)
	_report_wander()
	print("[P4Probe] done")
	get_tree().quit()


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - _t0


## 游走度采样：单位 x 符号变化沿计数（0.1s 一拍）
func _sample_vx(arena: Node) -> void:
	if arena == null or not is_instance_valid(arena):
		return
	_samples += 1
	for e in arena.find_children("", "StickmanEntity", true, false):
		if not is_instance_valid(e) or e.is_dead():
			continue
		var id := e.get_instance_id()
		var x: float = e.global_position.x
		if _prev_x.has(id):
			var dx: float = x - float(_prev_x[id])
			if absf(dx) > 0.5:
				var dir: int = 1 if dx > 0.0 else -1
				if _prev_dir.has(id) and int(_prev_dir[id]) != dir:
					_flip_counts[id] = int(_flip_counts.get(id, 0)) + 1
				_prev_dir[id] = dir
		_prev_x[id] = x


## 号令翻转率：双方规划器 flips / elapsed × 60（次/分钟）
func _report_planners(arena: Node) -> void:
	var planners: Dictionary = arena.get("_planners")
	var total_flips: int = 0
	var total_issues: int = 0
	var elapsed: float = 0.0
	for f in planners:
		var p: RefCounted = planners[f]
		var st: Dictionary = p.get_order_stats()
		total_flips += int(st["flips"])
		total_issues += int(st["issues"])
		elapsed = maxf(elapsed, float(st["elapsed"]))
	if elapsed <= 0.0:
		print("[P4Probe] 规划器无数据（夺点模式未开？）")
		return
	var per_min: float = float(total_flips) / elapsed * 60.0
	var gate: String = "PASS" if per_min < 20.0 else "FAIL"
	var reasons: Dictionary = { "first": 0, "expire": 0, "event_owner": 0, "event_threat": 0 }
	for f in planners:
		var r: Dictionary = (planners[f] as RefCounted).get_order_stats()["reasons"]
		for k in r:
			reasons[k] = int(reasons.get(k, 0)) + int(r[k])
	print("[P4Probe] 号令翻转率 %.1f 次/分钟（双方合计 %d 翻转 / %d 下发 / %.0fs）门禁<20：%s"
			% [per_min, total_flips, total_issues, elapsed, gate])
	print("[P4Probe] 翻转归因：首次 %d / 到期 %d / 事件-易主 %d / 事件-威胁 %d" % [int(reasons["first"]), int(reasons["expire"]), int(reasons["event_owner"]), int(reasons["event_threat"])])


## 游走度：vx 翻转率均值 / worst（次/秒）
func _report_wander() -> void:
	if _flip_counts.is_empty():
		print("[P4Probe] 游走度无样本")
		return
	var span: float = maxf(_elapsed(), 1.0)
	var rates: Array = []
	for id in _flip_counts:
		rates.append(float(_flip_counts[id]) / span)
	rates.sort()
	var mean: float = 0.0
	for r in rates:
		mean += r
	mean /= float(rates.size())
	print("[P4Probe] 游走度 vx 翻转率：均值 %.2f/s / worst %.2f/s（采样 %d 拍 × %d 单位）"
			% [mean, rates[rates.size() - 1], _samples, rates.size()])
