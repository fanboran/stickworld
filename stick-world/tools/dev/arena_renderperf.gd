extends Node
## 观察场渲染性能 driver（S2 渲染直渲改造 A/B 工位）——由 arena_shot_boot 挂到
## SceneTree.root（--renderperf 模式），揭幕后采样 N 秒，产出与角色渲染路线
## 相关的性能口径（烘焙基线 vs 直渲 A/B 同口径对比）：
##   - 帧时分位：逐渲染帧 ticks_usec 差（mean/p50/p95/max，ms）
##   - draw calls / 显存 / 纹理显存：RenderingServer 帧级读数（报告时刻快照）
##   - 实体数/宿主数/渲染路线（joint3d，唯一路线）
## JSON 落 user://renderperf/，由 arena_renderperf.sh 归集。带窗口跑（真实渲染帧）。

const RENDERPERF_OUT := "user://renderperf"

var _t0: float = 0.0
var _prev_usec: int = 0
var _win_ms: PackedFloat32Array = PackedFloat32Array()
var _hosts: Array = []
const COVER_WAIT_FRAMES := 4200


func run(_tag: String, _preset: int, secs: int, every: int) -> void:
	var waited := false
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			waited = true
			break
	print("[RenderPerf] cover gone=%s，采样 %ds（route=%s）" % [
		waited, secs, "joint3d"])
	for i in 12:
		await get_tree().process_frame
	# 首帧差分基准
	_prev_usec = Time.get_ticks_usec()
	_t0 = Time.get_ticks_msec() / 1000.0
	var next_report := _t0 + maxf(every, 2)
	while _elapsed() < secs:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		_win_ms.append((now - _prev_usec) / 1000.0)
		_prev_usec = now
		if Time.get_ticks_msec() / 1000.0 >= next_report:
			_report("…中途", false)
			next_report = Time.get_ticks_msec() / 1000.0 + maxf(every, 2)
	_finish(secs, _tag, _preset)


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - _t0


## 角色宿主扫描（char_rig_3d 关节烘焙宿主）
func _scan_hosts() -> void:
	_hosts.clear()
	var arena := get_tree().current_scene
	if arena == null or not is_instance_valid(arena):
		return
	for h in arena.find_children("Char*", "Node3D", true, false):
		if h != null and is_instance_valid(h) and h.has_method("set_world_pos"):
			_hosts.append(h)


func _percentile(sorted: PackedFloat32Array, q: float) -> float:
	if sorted.is_empty():
		return -1.0
	var idx: int = clampi(int(sorted.size() * q), 0, sorted.size() - 1)
	return sorted[idx]


func _report(prefix: String, _final: bool) -> void:
	_scan_hosts()
	var win := _win_ms.duplicate()
	win.sort()
	var mean := 0.0
	for v in win:
		mean += v
	if not win.is_empty():
		mean /= float(win.size())
	var entities := 0
	var arena := get_tree().current_scene
	if arena != null and is_instance_valid(arena):
		entities = arena.find_children("", "StickmanEntity", true, false).size()
	print("[RenderPerf] %s fps=%.0f 帧ms mean=%.2f p50=%.2f p95=%.2f max=%.2f | draws=%d vidMem=%.0fMB texMem=%.0fMB | 实体=%d 宿主=%d" % [
		prefix, Engine.get_frames_per_second(), mean, _percentile(win, 0.5),
		_percentile(win, 0.95), _percentile(win, 0.99),  # max 列打 p99 防单帧野值淹没中位信息
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0,
		entities, _hosts.size()])
	_win_ms.clear()


func _finish(secs: int, tag: String, preset: int) -> void:
	_report("最终", true)
	var out := {
		"tag": tag,
		"preset": preset,
		"secs": secs,
		"route": "joint3d",
	}
	DirAccess.make_dir_recursive_absolute(RENDERPERF_OUT)
	var path := "%s/renderperf_%s_p%d_%d.json" % [RENDERPERF_OUT, tag, preset, Time.get_ticks_msec()]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "  "))
		f.close()
	print("[RenderPerf] json=%s" % path)
	get_tree().quit(0)
