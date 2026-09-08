extends Node
## 基础设施基准④：建造管理（dev 层，headless）。
##
## ① 100 个并发 UNDER_CONSTRUCTION 项目 × 1800 tick（30Hz 等效 60 秒）
## ② 300 栋建筑下 get_nearest_warehouse × 1 万（仓库子集缓存已修，验证缓存后成本）
## ③ 100 个项目下 get_nearest_project × 1 万
##
## 运行：godot --headless --path . res://tests/dev/bench_infra_construction.tscn

const ScriptConstructionManager := preload("res://modules/construction/scripts/construction_manager.gd")
const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")

const N_PROJECTS := 100
const N_TICKS := 1800
const N_BUILDINGS := 300
const N_QUERIES := 10000


## 仓库假建筑（带 def_id 属性的 Node2D；get_nearest_warehouse 只读
## def_id / global_position / is-Building 检查，不依赖真场景）
class FakeWarehouse extends Node2D:
	var def_id: String = "warehouse"


func _ready() -> void:
	var cm: ScriptConstructionManager = ScriptConstructionManager.new()
	cm.name = "BenchConstructionManager"
	add_child(cm)
	# 100 个 UNDER_CONSTRUCTION 项目（map=null：占位视觉/障碍自动跳过，tick 纯推进）
	var projects: Array = []
	for i in N_PROJECTS:
		var p := ScriptConstructionProject.new("proj_%04d" % i, "placeholder", i * 3, 2, null, null, 8.0, "")
		p.state = ScriptConstructionProject.State.UNDER_CONSTRUCTION
		projects.append(p)
	# 直接注入 manager 活跃表（绕过 start_construction 的地图/资源依赖，聚焦 tick 与查询；
	# 注入后依赖缓存默认脏标记，首查自动重建快照）
	for i in N_PROJECTS:
		cm._projects["proj_%04d" % i] = projects[i]

	# ① 派工 tick：manager._physics_process 等效循环（走同一快照缓存路径，纯计时）
	var t0 := Time.get_ticks_usec()
	var delta := 1.0 / 30.0
	if cm._project_cache_dirty:
		cm._rebuild_project_cache()
	for i in N_TICKS:
		for entry: Array in cm._project_cache:
			(entry[1] as ScriptConstructionProject).tick(delta)
	var t_tick := Time.get_ticks_usec() - t0
	print("BENCH construction 100项目x1800tick: %d us（单 tick 全表 %.2f us）" % [t_tick, float(t_tick) / N_TICKS])

	# ② 300 栋建筑（含 60 栋仓库）下 get_nearest_warehouse × 1 万
	for i in N_BUILDINGS:
		var b := FakeWarehouse.new()
		b.def_id = "warehouse" if i % 5 == 0 else "house"
		b.position = Vector2(float(i * 37 % 6000), 900.0)
		cm._buildings["%04d" % i] = b
	cm._warehouse_cache_dirty = true
	var pos := Vector2(3000.0, 900.0)
	cm.get_nearest_warehouse(pos)  # 热身：建缓存
	t0 = Time.get_ticks_usec()
	for i in N_QUERIES:
		cm.get_nearest_warehouse(pos)
	var t_wh := Time.get_ticks_usec() - t0
	print("BENCH construction get_nearest_warehouse x%d（%d 建筑/60 仓库）: %d us（单次 %.2f us）"
		% [N_QUERIES, N_BUILDINGS, t_wh, float(t_wh) / N_QUERIES])

	# ③ get_nearest_project × 1 万（100 项目全扫）
	# 同进程 A/B：交替跑新（快照缓存）旧（直扫 values()）各 5 轮取中位，
	# 消除跨轮机器抖动（本机跨进程噪声 ±20-40%）
	var t_new_runs: Array = []
	var t_old_runs: Array = []
	for round_i in 5:
		t0 = Time.get_ticks_usec()
		for i in N_QUERIES:
			cm.get_nearest_project(pos)
		t_new_runs.append(Time.get_ticks_usec() - t0)
		t0 = Time.get_ticks_usec()
		for i in N_QUERIES:
			_bench_nearest_project_legacy(cm, pos)
		t_old_runs.append(Time.get_ticks_usec() - t0)
	t_new_runs.sort()
	t_old_runs.sort()
	var t_new: int = t_new_runs[t_new_runs.size() / 2]
	var t_old: int = t_old_runs[t_old_runs.size() / 2]
	print("BENCH construction get_nearest_project x%d（%d 项目）新:快照缓存 %d us（单次 %.2f us）"
		% [N_QUERIES, N_PROJECTS, t_new, float(t_new) / N_QUERIES])
	print("BENCH construction get_nearest_project x%d（%d 项目）旧:直扫对照 %d us（单次 %.2f us）"
		% [N_QUERIES, N_PROJECTS, t_old, float(t_old) / N_QUERIES])
	print("BENCH construction DONE")
	get_tree().quit(0)


## 旧版 get_nearest_project 直扫实现（修复前原逻辑逐行复刻，仅作 A/B 对照）
func _bench_nearest_project_legacy(cm: ScriptConstructionManager, pos: Vector2) -> RefCounted:
	var best: RefCounted = null
	var best_dist: float = INF
	for p in cm._projects.values():
		if p is ScriptConstructionProject:
			var proj: ScriptConstructionProject = p as ScriptConstructionProject
			if proj.state != proj.State.UNDER_CONSTRUCTION:
				continue
			var center_x: float = float(proj.cell_x) * 32.0 + float(proj.width) * 16.0
			var d: float = absf(center_x - pos.x)
			if d < best_dist:
				best_dist = d
				best = proj
	return best
