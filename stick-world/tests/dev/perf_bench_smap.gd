extends SceneTree
## 性能基准：战略图首次打开总成本（场景实例化 + 数据加载 + 网格构建）
## 运行：godot --headless --script res://tests/dev/perf_bench_smap.gd

func _init() -> void:
	# ── L1 (Tab) ──
	var t0 := Time.get_ticks_msec()
	var l1_scene: PackedScene = load("res://modules/world_map/scenes/strategic_map.tscn")
	var t1 := Time.get_ticks_msec()
	var l1_inst: Node = l1_scene.instantiate()
	var t2 := Time.get_ticks_msec()
	root.add_child(l1_inst)
	var t3 := Time.get_ticks_msec()
	var content: Node = l1_inst.get_node_or_null("Content")
	var api: Node = content.get_node_or_null("Api") if content else null
	if api and api.has_method("initialize"):
		api.initialize("res://config/strategic_map/l1_world.json", "res://config/strategic_map")
	var t4 := Time.get_ticks_msec()
	print("L1: load_scene=%dms instantiate=%dms add_child=%dms initialize(L1WorldData)=%dms" % [t1-t0, t2-t1, t3-t2, t4-t3])

	# ── L3 (M) ──
	var s0 := Time.get_ticks_msec()
	var l3_scene: PackedScene = load("res://modules/world_map/scenes/strategic_map_l3.tscn")
	var s1 := Time.get_ticks_msec()
	var l3_inst: Node = l3_scene.instantiate()
	var s2 := Time.get_ticks_msec()
	root.add_child(l3_inst)
	var s3 := Time.get_ticks_msec()
	var l3_content: Node = l3_inst.get_node_or_null("Content")
	var renderer: Node = l3_content.get_node_or_null("L3MapRenderer") if l3_content else null
	if renderer and renderer.has_method("set_data"):
		var data = load("res://modules/world_map/data/l3_world_data.gd").new()
		var tw0 := Time.get_ticks_msec()
		data = data.load_from("res://config/strategic_map/l3_world.json", "res://config/strategic_map")
		var tw1 := Time.get_ticks_msec()
		renderer.set_data(data)
		var tw2 := Time.get_ticks_msec()
		print("L3: load_scene=%dms instantiate=%dms add_child=%dms load_from=%dms set_data(mesh)=%dms" % [s1-s0, s2-s1, s3-s2, tw1-tw0, tw2-tw1])
	# L2 场景实例化
	var l2_scene: PackedScene = load("res://modules/world_map/scenes/strategic_map_l2.tscn")
	var l2_inst: Node = l2_scene.instantiate()
	root.add_child(l2_inst)
	var s4 := Time.get_ticks_msec()
	print("L2: instantiate+add=%dms" % [s4 - s3])
	print("TOTAL first-open ≈ %dms" % [s4 - t0])
	quit()
