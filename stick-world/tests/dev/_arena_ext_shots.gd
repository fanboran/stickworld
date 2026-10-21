extends Node
## 演练场扩展出图/冒烟 driver（窗口模式，非 CI；挂 SceneTree.root 跨场景存活）。
##
## 用法（必须带显示；boot 启动器 = _arena_ext_shots_boot.tscn）：
##   godot --path . res://tests/dev/_arena_ext_shots_boot.tscn --resolution 1920x1080 \
##       -- --duel --out <绝对目录>     # 单挑观察场：开战对峙截图
##       -- --comp --out <绝对目录>     # 观察场：编队配置窗打开截图 + 面板交互冒烟
## 产物： duel_arena.png / arena_comp_panel.png（另打印面板冒烟结果行）


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: String = "comp" if args.has("--comp") else "duel"
	var out_dir: String = "."
	var out_idx := args.find("--out")
	if out_idx >= 0 and out_idx + 1 < args.size():
		out_dir = args[out_idx + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	if mode == "duel":
		await _duel_shot(out_dir)
	else:
		await _comp_shot(out_dir)
	get_tree().quit(0)


## 等当前场景就绪（battle started 标志：双方单位就位 + 相机跟随开启）
func _await_battle_started(timeout_sec: float) -> Node:
	var waited := 0.0
	while waited < timeout_sec:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		var cs: Node = get_tree().current_scene
		if cs == null:
			continue
		if cs.get("_blue") != null:
			var b: Node = cs.get("_blue")
			var r: Node = cs.get("_red")
			if b != null and r != null and is_instance_valid(b) and is_instance_valid(r):
				return cs
		var atk: Array = cs.get("_attacker") if cs.get("_attacker") != null else []
		var dfd: Array = cs.get("_defender") if cs.get("_defender") != null else []
		if atk.size() > 0 and dfd.size() > 0 and bool(cs.get("_camera_following")):
			return cs
	print("[ArenaExtShots][FAIL] 等待开战超时")
	return null


func _shot(out_dir: String, name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [out_dir, name]
	img.save_png(path)
	print("[ArenaExtShots] 保存 %s" % path)


## 单挑观察场：等开局对峙（出生面对面、开战即战）截图
func _duel_shot(out_dir: String) -> void:
	get_tree().change_scene_to_file("res://tests/dev/duel_arena.tscn")
	var cs: Node = await _await_battle_started(120.0)
	if cs == null:
		return
	await get_tree().create_timer(1.0).timeout   # 对峙走位起步后的画面
	await _shot(out_dir, "duel_arena")


## 观察场 + 编队配置窗：开配置窗截图；再跑面板交互冒烟（增删改行/班名推导）
func _comp_shot(out_dir: String) -> void:
	get_tree().change_scene_to_file("res://tests/dev/battle_arena.tscn")
	var cs: Node = await _await_battle_started(180.0)
	if cs == null:
		return
	cs.call("_toggle_comp_panel")
	for i in 10:
		await get_tree().process_frame
	var panel: Control = cs.get("_comp_panel")
	if panel == null or not panel.visible:
		print("[ArenaExtShots][FAIL] 编队配置窗未打开")
		return
	await _shot(out_dir, "arena_comp_panel")
	_panel_smoke(cs, panel)


## 面板交互冒烟：编辑操作链（载入→加班→加行→改兵种→加人数→终版班名推导）
func _panel_smoke(cs: Node, panel: Control) -> void:
	var fails: Array = []
	panel.call("open_with", {
		"mirror": true,
		"left": [
			{"name": "矛士班", "rows": [{"weapon": 1, "count": 8}]},
			{"name": "火力班", "rows": [{"weapon": 4, "count": 2}, {"weapon": 2, "count": 4}]},
		],
		"right": [],
	})
	var left: Array = panel.get("_left")
	if left.size() != 2:
		fails.append("载入班数 %d（应 2）" % left.size())
	panel.call("_add_squad", 1)
	left = panel.get("_left")
	if left.size() != 3:
		fails.append("加班后 %d（应 3）" % left.size())
	panel.call("_add_row", 1, 0)
	var rows: Array = left[0]["rows"]
	if rows.size() != 2:
		fails.append("加行后 %d（应 2）" % rows.size())
	var w_before: int = int(rows[0]["weapon"])
	panel.call("_cycle_row_weapon", 1, 0, 0)
	if int(rows[0]["weapon"]) == w_before:
		fails.append("换兵种未生效")
	var c_before: int = int(rows[0]["count"])
	panel.call("_bump_count", 1, 0, 0, 1)
	if int(rows[0]["count"]) != c_before + 1:
		fails.append("人数步进未生效")
	# 终版班名推导：单一兵种 = 兵种名+班；混编 = 混编N班。
	# 此刻编辑态：班0 = 弓8+矛4（上面把矛换成了弓 → 混编1班）；
	# 班1 = 杖2+弓4（载入即混编 → 混编2班）；班2 = 新加班剑士×4（→ 剑士班）
	var fin_left: Array = panel.call("_finalize_side", left)
	var names: Array = []
	for s in fin_left:
		names.append(String(s["name"]))
	if String(names[0]) != "混编1班":
		fails.append("班名推导[0]=%s（应 混编1班）" % names[0])
	if String(names[1]) != "混编2班":
		fails.append("班名推导[1]=%s（应 混编2班）" % names[1])
	if String(names[2]) != "剑士班":
		fails.append("班名推导[2]=%s（应 剑士班）" % names[2])
	if fails.is_empty():
		print("[ArenaExtShots] 面板冒烟通过：载入/加班/加行/换兵种/步进/班名推导 全链 OK")
	else:
		for f in fails:
			print("[ArenaExtShots][FAIL] %s" % f)
		get_tree().quit(1)
