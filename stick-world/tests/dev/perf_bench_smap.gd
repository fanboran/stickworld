extends Node
## 战略图 L1/L2/L3 首开分相基准（dev 层）——headless 场景式复测工具。
##
## 测什么：三层地图场景「首次打开」的分相耗时（场景加载/实例化/进树/数据
## 初始化/装配接线），对应 system_setup_strategic_map 的生产装配路径
## （_setup_l1_strategic_map / _setup_l3_strategic_map / L2 下钻装配）。
## 旧版（--script SceneTree 式）在 class_name 全局注册缺失的 headless 环境下
## UI 组件链报错、L1 initialize/L3 分支静默失效，已重建为场景式。
##
## 运行（headless，无渲染噪声；场景式启动 autoload/类缓存全就绪）：
##   godot --headless --path . res://tests/dev/perf_bench_smap.tscn
##   godot --headless --path . res://tests/dev/perf_bench_smap.tscn -- --rounds=5
## 参数：
##   --rounds=N  进程内轮数（默认 1；轮 0=冷加载，后续轮=热资源缓存下的
##               重建成本——跨进程冷值由外层 smap_first_open.sh 多进程取中位）
##   --csv=P     CSV 追加落盘路径（默认 res://temp/perf/smap_first_open.csv；
##               列：stamp,round,cold,layer,phase,ms）
## 输出：每轮每相毫秒（print）+ 终局 JSON 汇总（各相冷值/热轮中位）。
## 规范：docs/技术/规范/性能量测规范.md（通道隔离/同条件 A/B）。

const L1_SCENE := "res://modules/world_map/scenes/strategic_map.tscn"
const L3_SCENE := "res://modules/world_map/scenes/strategic_map_l3.tscn"
const L2_SCENE := "res://modules/world_map/scenes/strategic_map_l2.tscn"
const DATA_DIR := "res://config/strategic_map"
const L1_JSON := "res://config/strategic_map/l1_world.json"
const L3_JSON := "res://config/strategic_map/l3_world.json"
const SETTLE_FRAMES := 5   # 相间结算帧：让 deferred/队列任务落进本相账内

var _rounds := 1
var _csv_path := "res://temp/perf/smap_first_open.csv"
var _rows: Array = []      # [round, cold, layer, phase, ms]
var _stamp := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--rounds="):
			_rounds = maxi(1, int(a.get_slice("=", 1)))
		elif str(a).begins_with("--csv="):
			_csv_path = str(a.get_slice("=", 1))
	_stamp = Time.get_datetime_string_from_system(false) \
			.replace(":", "").replace("-", "").replace(" ", "_")
	_run()


func _run() -> void:
	for r in _rounds:
		await _bench_round(r)
	_write_csv()
	_report()
	get_tree().quit(0)


func _bench_round(r: int) -> void:
	var cold := r == 0

	# ── L1（Tab 大图：load / instantiate / add_child / initialize）──
	var t0 := Time.get_ticks_usec()
	var l1_scene: PackedScene = load(L1_SCENE)
	var t1 := Time.get_ticks_usec()
	var l1: Node = l1_scene.instantiate()
	var t2 := Time.get_ticks_usec()
	l1.name = "BenchStrategicMap"
	add_child(l1)
	var t3 := Time.get_ticks_usec()
	var content: Node = l1.get_node_or_null("Content")
	var api: Node = content.get_node_or_null("Api") if content else null
	if api != null and api.has_method("initialize"):
		api.initialize(L1_JSON, DATA_DIR)
	var t4 := Time.get_ticks_usec()
	await _settle()
	var t5 := Time.get_ticks_usec()
	_rec(r, cold, "L1", "load_scene", t1 - t0)
	_rec(r, cold, "L1", "instantiate", t2 - t1)
	_rec(r, cold, "L1", "add_child", t3 - t2)
	_rec(r, cold, "L1", "initialize", t4 - t3)
	_rec(r, cold, "L1", "settle_frames", t5 - t4)

	# ── L3（M 大世界：load / instantiate / add_child / 数据加载 / set_data）──
	var s0 := Time.get_ticks_usec()
	var l3_scene: PackedScene = load(L3_SCENE)
	var s1 := Time.get_ticks_usec()
	var l3: Node = l3_scene.instantiate()
	var s2 := Time.get_ticks_usec()
	l3.name = "BenchStrategicMapL3"
	add_child(l3)
	var s3 := Time.get_ticks_usec()
	var l3_content: Node = l3.get_node_or_null("Content")
	var renderer: Node = l3_content.get_node_or_null("L3MapRenderer") if l3_content else null
	var l3_data: Object = null
	if renderer != null and renderer.has_method("set_data"):
		var l3_script: GDScript = load("res://modules/world_map/data/l3_world_data.gd")
		l3_data = l3_script.load_from(L3_JSON, DATA_DIR)
	var s4 := Time.get_ticks_usec()
	if renderer != null and renderer.has_method("set_data") and l3_data != null:
		renderer.set_data(l3_data)
	var s5 := Time.get_ticks_usec()
	_rec(r, cold, "L3", "load_scene", s1 - s0)
	_rec(r, cold, "L3", "instantiate", s2 - s1)
	_rec(r, cold, "L3", "add_child", s3 - s2)
	_rec(r, cold, "L3", "load_data", s4 - s3)
	_rec(r, cold, "L3", "set_data_mesh", s5 - s4)

	# ── L2（下钻视图：instantiate / add_child / 生产接线）──
	var u0 := Time.get_ticks_usec()
	var l2_scene: PackedScene = load(L2_SCENE)
	var l2: Node = l2_scene.instantiate()
	var u1 := Time.get_ticks_usec()
	l2.name = "BenchStrategicMapL2"
	add_child(l2)
	var u2 := Time.get_ticks_usec()
	# 生产接线（_setup_l3_strategic_map 同式）：L3 content 持 L2 视图 + L2 持 L1 视图
	var l2_content: Node = l2.get_node_or_null("Content")
	if l2_content != null and l3_content != null and l3_content.has_method("set_l2_view") \
			and l2_content.has_method("open"):
		l3_content.call("set_l2_view", l2_content)
	if l2_content != null and content != null and l2_content.has_method("set_l1_view"):
		l2_content.call("set_l1_view", content)
	var u3 := Time.get_ticks_usec()
	await _settle()
	var u4 := Time.get_ticks_usec()
	_rec(r, cold, "L2", "instantiate", u1 - u0)
	_rec(r, cold, "L2", "add_child", u2 - u1)
	_rec(r, cold, "L2", "wire_views", u3 - u2)
	_rec(r, cold, "L2", "settle_frames", u4 - u3)

	# 清场（queue_free + 两帧，避免下一轮树残留干扰）
	for n in [l1, l3, l2]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await get_tree().process_frame


func _rec(round: int, cold: bool, layer: String, phase: String, usec: int) -> void:
	var ms := snappedf(float(usec) / 1000.0, 0.01)
	_rows.append([round, cold, layer, phase, ms])
	print("R%d%s %s.%s = %.2fms" % [round, "(冷)" if cold else "", layer, phase, ms])


func _write_csv() -> void:
	var dir_path := _csv_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var f := FileAccess.open(_csv_path, FileAccess.READ_WRITE \
			if FileAccess.file_exists(_csv_path) else FileAccess.WRITE)
	if f == null:
		push_warning("[smap-bench] CSV 打不开: %s" % _csv_path)
		return
	f.seek_end()
	if f.get_length() == 0:
		f.store_line("stamp,round,cold,layer,phase,ms")
	for row in _rows:
		f.store_line("%s,%d,%s,%s,%s,%.2f" % [
				_stamp, row[0], "1" if row[1] else "0", row[2], row[3], row[4]])
	f.close()
	print("[smap-bench] csv appended: %s" % ProjectSettings.globalize_path(_csv_path))


func _report() -> void:
	# 跨轮汇总（冷轮单独一档，热轮取中位）
	var summary := {}
	for row in _rows:
		var key := "%s.%s" % [row[2], row[3]]
		if not summary.has(key):
			summary[key] = {"cold": null, "warm": []}
		if row[1]:
			summary[key]["cold"] = row[4]
		else:
			summary[key]["warm"].append(row[4])
	var out := {}
	for key in summary:
		var s = summary[key]
		var warm: Array = s["warm"]
		warm.sort()
		out[key] = {
			"cold_ms": s["cold"],
			"warm_med_ms": warm[warm.size() / 2] if not warm.is_empty() else null,
		}
	print("[PERF] %s" % str({"bench": "smap_first_open", "rounds": _rounds, "phases": out}))
