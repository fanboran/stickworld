extends Node
## 批2 结构探针（--p2probe）：断言旗视觉/护卫小群/稳定锚在跑的观察场里真实存在。
## stdout 报告，一次性：旗节点数与位置、指挥官+护卫小群与主力末排的间距、
## 相机 5s 内的移动量（稳定锚应纹丝不动或极缓）。

const COVER_WAIT_FRAMES := 4200


func run(_tag: String, _preset: int, secs: int, _every: int) -> void:
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			break
	for i in 12:
		await get_tree().process_frame
	var arena2: Node = get_tree().current_scene
	# ①旗节点：全树找 CaptureFlagView
	var flags: Array = []
	_collect_flags(get_tree().root, flags)
	var pos_line: Array = []
	for f in flags:
		pos_line.append("(%.0f,%.0f)" % [f.global_position.x, f.global_position.y])
	print("[P2Probe] 旗节点 %d 面：%s" % [flags.size(), "，".join(pos_line)])
	# ②指挥官+护卫小群 vs 主力末排间距（按阵营取最后方 3 名的 x 与其余最后 10% 均值）
	var atk: Array = arena2.get("_attacker")
	var dfd: Array = arena2.get("_defender")
	for pair in [["蓝(攻)", atk], ["红(守)", dfd]]:
		var xs: Array = []
		for u in pair[1]:
			if is_instance_valid(u) and not u.is_dead():
				xs.append(u.global_position.x)
		if xs.size() >= 8:
			xs.sort()
			var rear3: float = (xs[0] + xs[1] + xs[2]) / 3.0
			var main_rear: float = 0.0
			var n: int = maxi(1, int(xs.size() * 0.2))
			var s: float = 0.0
			for i in n:
				s += xs[i]
			main_rear = s / float(n)
			print("[P2Probe] %s 后方小群均值 x=%.0f vs 主力后沿均值 x=%.0f 间距=%.0fpx" % [pair[0], rear3, main_rear, absf(rear3 - main_rear)])
	# ③相机稳定：5s 内移动量
	var cam0: Vector2 = (arena2.get("_cam_proxy") as Node2D).global_position
	var t0 := Time.get_ticks_msec() / 1000.0
	while Time.get_ticks_msec() / 1000.0 - t0 < minf(secs, 10.0):
		await get_tree().process_frame
	var cam1: Vector2 = (arena2.get("_cam_proxy") as Node2D).global_position
	print("[P2Probe] 相机 %ds 移动 Δ=(%.1f,%.1f)px" % [minf(secs, 10.0), cam1.x - cam0.x, cam1.y - cam0.y])
	print("[P2Probe] done")
	get_tree().quit()


func _collect_flags(node: Node, out: Array) -> void:
	if node.get_script() != null and str(node.get_script().resource_path).contains("capture_flag_view"):
		out.append(node)
	for c in node.get_children():
		_collect_flags(c, out)
