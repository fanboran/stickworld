extends Node
## PerfProbe —— 运行时性能审计临时探针（temp/ 下，gitignored，审计后移除注册）。
##
## 能力：
##   - 每秒采样一行指标写入 user://perf/audit_<stamp>.csv（帧时长 avg/p95/max、
##     process/physics 耗时、draw calls、对象/节点/资源数、显存）
##   - 文件命令通道（bash 直接读写，零防火墙依赖）：轮询 user://perf/cmd.txt，
##     回应追加到 user://perf/resp.txt，处理完删除 cmd.txt。
##     命令：
##     ping / stat / mark <文本> / shot [名字] / scene <res路径> /
##     tree [深度] / info <路径> / sysoff <路径> / syson <路径> /
##     key <键名> <down|up> / action <动作> <down|up> /
##     mouse <dx> <dy> / mousebtn <l|m|r> <down|up> / click <x> <y> /
##     call <节点路径> <方法> [参数...] / quit

const PORT := 9850
const CMD_PATH := "user://perf/cmd.txt"
const RESP_PATH := "user://perf/resp.txt"

var _csv: FileAccess
var _csv_path := ""
var _mark := "boot"
var _secs := 0.0
var _acc := 0.0
var _samples: PackedFloat32Array = []
var _last_row_us := 0


func _ready() -> void:
	# 仅调试构建激活（编辑器/F5 运行有效，导出 release 零开销零暴露）
	if not OS.is_debug_build():
		set_process(false)
		return
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("perf"):
		dir.make_dir("perf")
	var stamp := Time.get_datetime_string_from_system(false)
	stamp = stamp.replace(":", "").replace("-", "_").replace(" ", "_")
	_csv_path = "user://perf/audit_%s.csv" % stamp
	_csv = FileAccess.open(_csv_path, FileAccess.WRITE)
	if _csv:
		_csv.store_line("sec,mark,fps,frame_ms_avg,frame_ms_p95,frame_ms_max,proc_ms,phys_ms,draw_calls,objects,nodes,resources,video_mem_mb,win_size")
	print("[PerfProbe] cmd=", ProjectSettings.globalize_path(CMD_PATH),
		" csv=", ProjectSettings.globalize_path(_csv_path))


func _process(delta: float) -> void:
	_samples.append(delta * 1000.0)
	_acc += delta
	_secs += delta
	if _acc >= 1.0:
		_flush_row()
	_poll_cmd_file()


func _poll_cmd_file() -> void:
	var dir := DirAccess.open("user://perf")
	if dir == null or not dir.file_exists("cmd.txt"):
		return
	var f := FileAccess.open(CMD_PATH, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()
	DirAccess.open("user://perf").remove("cmd.txt")
	for line in content.split("\n", false):
		var resp := _handle(line.strip_edges())
		var rf := FileAccess.open(RESP_PATH, FileAccess.READ_WRITE if FileAccess.file_exists(RESP_PATH) else FileAccess.WRITE)
		if rf:
			rf.seek_end()
			rf.store_line("[%s] %s" % [_mark, resp])
			rf.close()


func _flush_row() -> void:
	_acc = 0.0
	if not _csv:
		return
	var n := _samples.size()
	if n == 0:
		return
	var total := 0.0
	var mx := 0.0
	for v in _samples:
		total += v
		if v > mx:
			mx = v
	var sorted: PackedFloat32Array = _samples.duplicate()
	sorted.sort()
	var p95 := sorted[mini(int(n * 0.95), n - 1)]
	var row := ",".join([
		"%.1f" % _secs, _mark,
		"%.0f" % Engine.get_frames_per_second(),
		"%.2f" % (total / n), "%.2f" % p95, "%.2f" % mx,
		"%.2f" % (Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0),
		"%.2f" % (Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0),
		"%d" % Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"%d" % Performance.get_monitor(Performance.OBJECT_COUNT),
		"%d" % Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"%d" % Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"%.1f" % (Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0),
		"%dx%d" % [get_window().size.x, get_window().size.y],
	])
	_csv.store_line(row)
	_csv.flush()
	_samples.clear()


# ─────────────────────────── 回应写文件 ───────────────────────────

func _send(text: String) -> void:
	var rf := FileAccess.open(RESP_PATH, FileAccess.READ_WRITE if FileAccess.file_exists(RESP_PATH) else FileAccess.WRITE)
	if rf:
		rf.seek_end()
		rf.store_line(text)
		rf.close()


func _handle(line: String) -> String:
	if line.is_empty():
		return "ok"
	var parts := line.split(" ", false)
	var cmd := parts[0].to_lower()
	match cmd:
		"ping":
			return "pong scene=%s" % get_tree().current_scene.scene_file_path
		"stat":
			return "fps=%.0f proc=%.2fms phys=%.2fms draws=%d nodes=%d objects=%d" % [
				Engine.get_frames_per_second(),
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				Performance.get_monitor(Performance.OBJECT_COUNT),
			]
		"sd":
			var st := load("res://modules/ui_global/scripts/theme/sketch_textures.gd")
			var t0 := Time.get_ticks_usec()
			var r = st._advance()
			var dt := Time.get_ticks_usec() - t0
			return "boxes=%d cursor=%d step=%d 手动_advance耗时=%dus 返回=%s" % [
				st._boxes.size(), st._cursor, st._step, dt, str(r)]
		"sdtime":
			var st2 := load("res://modules/ui_global/scripts/theme/sketch_textures.gd")
			var acc_us := 0
			var rounds := 0
			for k in 5:
				var ta := Time.get_ticks_usec()
				st2._advance()
				acc_us += Time.get_ticks_usec() - ta
				rounds += 1
				if st2._cursor == 0:
					break
			return "连续%d次_advance累计=%dus boxes=%d cursor=%d" % [
				rounds, acc_us, st2._boxes.size(), st2._cursor]
		"mark":
			_mark = " ".join(parts.slice(1)) if parts.size() > 1 else "unmarked"
			return "ok mark=%s" % _mark
		"shot":
			_take_shot(" ".join(parts.slice(1)) if parts.size() > 1 else "shot_%d" % Time.get_ticks_msec())
			return "ok"
		"scene":
			if parts.size() < 2:
				return "err scene <res路径>"
			get_tree().change_scene_to_file(parts[1])
			return "ok"
		"tree":
			var depth := 3 if parts.size() < 2 else int(parts[1])
			return "\n" + "\n".join(_dump_tree(get_tree().root, 0, depth, []))
		"info":
			var node := _find(parts[1] if parts.size() > 1 else ".")
			if node == null:
				return "err 节点不存在"
			return "%s class=%s script=%s proc=%s phys=%s children=%d" % [
				node.get_path(), node.get_class(),
				(node.get_script() as Script).resource_path if node.get_script() else "-",
				str(node.is_processing()), str(node.is_physics_processing()), node.get_child_count(),
			]
		"kids":
			var node := _find(parts[1] if parts.size() > 1 else ".")
			if node == null:
				return "err 节点不存在"
			var names := []
			for c in node.get_children():
				names.append("%s [%s]" % [c.name, c.get_class()])
			return "children(%d): %s" % [names.size(), ", ".join(names)]
		"sysoff":
			return _set_subtree(parts[1] if parts.size() > 1 else ".", false)
		"syson":
			return _set_subtree(parts[1] if parts.size() > 1 else ".", true)
		"key":
			if parts.size() < 3:
				return "err key <键名> <down|up>"
			var ev := InputEventKey.new()
			ev.physical_keycode = OS.find_keycode_from_string(parts[1])
			ev.pressed = parts[2].to_lower() != "up"
			Input.parse_input_event(ev)
			return "ok"
		"action":
			if parts.size() < 3:
				return "err action <动作> <down|up>"
			if parts[2].to_lower() == "down":
				Input.action_press(parts[1])
			else:
				Input.action_release(parts[1])
			return "ok"
		"mouse":
			if parts.size() < 3:
				return "err mouse <dx> <dy>"
			var mm := InputEventMouseMotion.new()
			mm.relative = Vector2(float(parts[1]), float(parts[2]))
			Input.parse_input_event(mm)
			return "ok"
		"mousebtn":
			if parts.size() < 3:
				return "err mousebtn <l|m|r> <down|up>"
			var btn := InputEventMouseButton.new()
			match parts[1].to_lower():
				"l": btn.button_index = MOUSE_BUTTON_LEFT
				"m": btn.button_index = MOUSE_BUTTON_MIDDLE
				"r": btn.button_index = MOUSE_BUTTON_RIGHT
			btn.pressed = parts[2].to_lower() != "up"
			Input.parse_input_event(btn)
			return "ok"
		"click":
			if parts.size() < 3:
				return "err click <x> <y>"
			var pos := Vector2(float(parts[1]), float(parts[2]))
			Input.warp_mouse(pos)
			var mv := InputEventMouseMotion.new()
			mv.position = pos
			Input.parse_input_event(mv)
			for pressed in [true, false]:
				var cb := InputEventMouseButton.new()
				cb.button_index = MOUSE_BUTTON_LEFT
				cb.pressed = pressed
				cb.position = pos
				Input.parse_input_event(cb)
			return "ok"
		"call":
			if parts.size() < 3:
				return "err call <节点路径> <方法> [参数...]"
			var target := _find(parts[1])
			if target == null:
				return "err 节点不存在: %s" % parts[1]
			var args: Array = []
			for a in parts.slice(3):
				var parsed = str_to_var(a)
				args.append(parsed if parsed != null else a)
			var result = target.callv(parts[2], args)
			return "ok 返回=%s" % str(result)
		"quit":
			_flush_row()
			get_tree().quit(0)
			return "ok"
		_:
			return "err 未知命令: %s" % cmd
	return "ok"


func _find(path: String) -> Node:
	if path == "." or path.is_empty():
		return get_tree().current_scene
	var node: Node = get_tree().root.get_node_or_null(path)
	if node:
		return node
	return get_tree().current_scene.get_node_or_null(path)


func _set_subtree(path: String, on: bool) -> String:
	var node := _find(path)
	if node == null:
		return "err 节点不存在: %s" % path
	var count := 0
	for n in _iter_subtree(node):
		n.set_process(on)
		n.set_physics_process(on)
		n.set_process_internal(on)
		count += 1
	return "ok %s 子树 %d 节点 -> %s" % [path, count, "开" if on else "关"]


func _iter_subtree(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _dump_tree(node: Node, depth: int, max_depth: int, lines: Array) -> Array:
	if lines.size() > 500:
		return lines
	var flags := ""
	if node.is_processing() or node.is_physics_processing():
		flags = " *proc*"
	var sname: String = "-"
	if node.get_script():
		sname = (node.get_script().resource_path.get_file())
	lines.append("%s%s [%s] %s%s (%d)" % [
		"  ".repeat(depth), node.name, node.get_class(), sname, flags, node.get_child_count(),
	])
	if depth < max_depth:
		for c in node.get_children():
			_dump_tree(c, depth + 1, max_depth, lines)
	else:
		if node.get_child_count() > 0:
			lines.append("%s... (%d 子节点省略)" % ["  ".repeat(depth + 1), node.get_child_count()])
	return lines


func _take_shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://perf/%s.png" % name)
	_send("shot_saved: %s" % ProjectSettings.globalize_path("user://perf/%s.png" % name))
