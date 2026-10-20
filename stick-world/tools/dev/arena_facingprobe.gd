extends Node
## 朝向探针（--facingprobe，裁决#21c 遗留/2026-10-12 复现于验收图）：跑观察场，
## 每 0.25s 对每个存活单位采 faction/x/y/vx/facing，捕捉翻面事件并按通道分类：
##   move   翻面时刻 |vx|>1 且 vx 与新朝向同号（移动侧翻面，note_move_facing 链）
##   aim    翻面时刻近似静止（战斗面向 face_towards / face_battle_dir 链）
## 结尾按阵营汇总"背敌朝向"计数曲线（左军 facing=-1 / 右军 facing=+1）。
## stdout 报告一次性输出；无截图，headless 可跑。

const SAMPLE_DT := 0.25


func run(_tag: String, _preset: int, secs: int, _every: int) -> void:
	# 等观察场与首批单位（spawn 逐班 await，封面期无单位）
	var arena: Node = null
	for i in 3600:
		await get_tree().process_frame
		arena = get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and (arena.get("_attacker") as Array).size() > 0:
			break
	if arena == null or not is_instance_valid(arena):
		print("[FacingProbe] 观察场未就绪，退出")
		get_tree().quit()
		return
	var armies: Array = [arena.get("_attacker"), arena.get("_defender")]
	var last_facing: Dictionary = {}   # iid -> facing
	var t0: float = Time.get_ticks_msec() / 1000.0
	var acc := 0.0
	var wrong: Dictionary = {1: 0, 2: 0}   # 背敌计数（末次采样）
	var flips := []
	while _elapsed(t0) < float(secs):
		await get_tree().process_frame
		acc += get_process_delta_time()
		if acc < SAMPLE_DT:
			continue
		acc = 0.0
		wrong = {1: 0, 2: 0}
		for fi in 2:
			var faction: int = fi + 1
			for u in armies[fi]:
				if u == null or not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
					continue
				var iid: int = u.get_instance_id()
				var f: int = u.get_facing() if u.has_method("get_facing") else 0
				var vx: float = (u.velocity as Vector2).x
				if faction == 1 and f < 0:
					wrong[1] += 1
				if faction == 2 and f > 0:
					wrong[2] += 1
				var lf = last_facing.get(iid, null)
				if lf != null and int(lf) != f:
					var ch := "move" if absf(vx) > 1.0 and signf(vx) == signf(f) else "aim"
					flips.append("t=%.2f fac=%d x=%.0f y=%.0f %+d->%+d vx=%.1f [%s]"
							% [_elapsed(t0), faction, u.global_position.x, u.global_position.y,
									int(lf), f, vx, ch])
				last_facing[iid] = f
	print("[FacingProbe] ── 翻面事件（采样粒度 %.2fs）──" % SAMPLE_DT)
	for line in flips:
		print("[FacingProbe] " + line)
	print("[FacingProbe] 末态：左军背敌(facing=-1)=%d / 右军背敌(facing=+1)=%d；翻面事件 %d 起"
			% [wrong[1], wrong[2], flips.size()])
	get_tree().quit()


func _elapsed(t0: float) -> float:
	return Time.get_ticks_msec() / 1000.0 - t0
