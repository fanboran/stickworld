extends Node
## 观察场抽搐诊断探针——arena_shot_boot `--twitch` 挂 root 驱动。
## 两路证据（只读，不改游戏代码）：
##   B. 出生窗连拍：首单位出现后 200 帧内每 2 帧截中幅 crop，供肉眼复核。
##   C. 抽搐采样：揭幕后逐物理帧记录全员 位置/速度/动画/seq/盾态/移动意图，
##      统计 同名重播churn / vx翻转率 / 待机漂移 / 盾态抖动 / 姿态换装抖动。
##（烘焙内容审计段随整卡烘焙退役删除——关节烘焙无逐帧回读，无坏帧可言。）


const BURST_FRAMES := 200
const SETTLE := 12


func run(_tag: String, _preset: int, secs: int, _every: int) -> void:
	DirAccess.make_dir_recursive_absolute("user://twitch_burst")
	await _phase_spawn_audit_and_burst()
	await _phase_twitch_sample(secs)
	get_tree().quit(0)


# ───────── B：出生窗连拍 ─────────

var _first_spawn_frame := -1
var _shot_idx := 0


func _find_map() -> Node:
	var arena := get_tree().current_scene
	if arena == null or not is_instance_valid(arena):
		return null
	for m in arena.find_children("", "Hd2dMapBase", true, false):
		return m
	return null


## 相机取景直测：地面 z 反投影到屏幕百分比——半屏契约（地平线 z=0 应 50%H）
## 与出界兜底（带前缘 z=93 应 ≤100%H）的数学验收，不靠像素启发式（绿树线
## 会污染草线检测）
func _camera_math_audit() -> void:
	var map := _find_map()
	var hd: Node = map.get("_hd") if map != null else null
	if hd == null:
		return
	var cam: Camera3D = hd.get("_cam") if hd.get("_cam") is Camera3D else null
	if cam == null:
		return
	var out := "[TwitchProbe] 取景直测（%s）: " % ("战场" if bool(hd.get("battlefield")) else "街景")
	if map != null:
		out += "walk_front=%.0f ground_bottom=%.0f(带前缘z=%.1f) hd_uz=%.3f | " % [
				float(map.get("walk_front_y")), float(map.get("ground_bottom")),
				(float(map.get("ground_bottom")) - float(map.get("depth_y_min"))) / float(map.get("CELL_PX")),
				float(hd.get("_last_user_zoom"))]
	for z in [0.0, 28.0, 85.0, 93.1]:
		# 地面点 (0, 0, z)：反投影求屏幕 y 百分比
		var gp := Vector3(0.0, 0.0, z)
		if cam.is_position_behind(gp):
			out += "z%d=behind " % z
			continue
		var sp: Vector2 = cam.unproject_position(gp)
		var frac: float = sp.y / cam.get_viewport().get_visible_rect().size.y
		out += "z%d=%.0f%%H " % [z, frac * 100.0]
	print(out)


func _phase_spawn_audit_and_burst() -> void:
	var wait := 0
	while wait < 3600:   # ~60s 上限：等图装配
		await get_tree().process_frame
		wait += 1
		var map := _find_map()
		if map != null and map.get("_char_map") != null \
				and (map.get("_char_map") as Dictionary).size() > 0:
			break
	print("[TwitchProbe] 图就绪，开始出生窗连拍 frame=%d" % Engine.get_process_frames())
	while _shot_idx * 2 < BURST_FRAMES:
		await get_tree().process_frame
		var map := _find_map()
		if map == null:
			continue
		if (map.get("_char_map") as Dictionary).is_empty():
			continue
		if _first_spawn_frame < 0:
			_first_spawn_frame = Engine.get_process_frames()
		# 连拍（每 2 帧一张，全幅缩到 960x540——出生军在屏幕两翼，窄裁会漏）
		if Engine.get_process_frames() % 2 == 0:
			var img := get_viewport().get_texture().get_image()
			if img != null and not img.is_empty():
				var full := Image.create(960, 540, false, Image.FORMAT_RGB8)
				img.resize(960, 540, Image.INTERPOLATE_BILINEAR)
				full = img
				full.save_png("user://twitch_burst/b%04d.png" % _shot_idx)
				_shot_idx += 1






# ───────── C：抽搐采样 ─────────

## 伤害飘字对位端到端验证：2D 重映射脚点（remap_fx_pos，飘字锚同链）与 3D
## 接地影脚点（真实渲出来的地面点）反投影到屏幕像素——对差即飘字落点误差。
## 旧锚死 walk_front 的实现下此差达半屏（2026-10-05 创始人点名），活锚对应≈0
func _fx_align_audit() -> void:
	var map := _find_map()
	if map == null or not map.has_method("remap_fx_pos"):
		return
	var canvas_xform: Transform2D = map.get_viewport().get_canvas_transform()
	var worst := 0.0
	var n := 0
	for e in get_tree().current_scene.find_children("", "StickmanEntity", true, false):
		if not is_instance_valid(e) or e.is_dead() or n >= 12:
			continue
		var char_map: Dictionary = map.get("_char_map")
		var card: Node3D = char_map.get(e.get_instance_id())
		if card == null or not is_instance_valid(card):
			continue
		var shadow: MeshInstance3D = card.get("_my_shadow")
		if shadow == null or not is_instance_valid(shadow) or not shadow.visible:
			continue
		var cam3d: Camera3D = (map.get("_hd") as Node).get("_cam")
		if cam3d == null or cam3d.is_position_behind(shadow.global_position):
			continue
		var foot_3d: Vector2 = cam3d.unproject_position(shadow.global_position)
		var foot_2d: Vector2 = canvas_xform * map.remap_fx_pos((e as Node2D).global_position)
		worst = maxf(worst, absf(foot_2d.y - foot_3d.y))
		n += 1
	print("[TwitchProbe] 伤害字锚对位（%d 实体）: 2D重映射脚 vs 3D影脚 worst Δy=%.1f px%s" % [
			n, worst, "  ✓<8px" if worst < 8.0 else "  ✗ 超容差"])


func _phase_twitch_sample(secs: int) -> void:
	# 等揭幕（ArenaCover 消失）+ 稳定
	for i in 4200:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			break
	for i in SETTLE:
		await get_tree().process_frame
	print("[TwitchProbe] 揭幕完成，开始抽搐采样")
	_camera_math_audit()
	_fx_align_audit()
	var t0 := Time.get_ticks_msec() / 1000.0
	# series[eid] = {fields..., frames: [...]} 逐物理帧采样
	var series := {}
	var frames := 0
	while Time.get_ticks_msec() / 1000.0 - t0 < secs:
		await get_tree().physics_frame
		frames += 1
		var arena := get_tree().current_scene
		if arena == null or not is_instance_valid(arena):
			continue
		for e in arena.find_children("", "StickmanEntity", true, false):
			if not is_instance_valid(e) or e.is_dead():
				continue
			var id: int = e.get_instance_id()
			var rec: Dictionary = series.get(id, {})
			if rec.is_empty():
				var visual: Variant = e.get("_visual")
				var mount: Variant = e.get("weapon_mount")
				rec = {"first_frame": frames, "visual": visual, "mount": mount,
						"data": []}
				series[id] = rec
			var body := e as Node2D
			var vel: Vector2 = (body as CharacterBody2D).velocity \
					if body is CharacterBody2D else Vector2.ZERO
			var anim: String = str(e.get("_current_anim"))
			var seq: int = -1
			var stance := "  "
			if rec["visual"] != null and is_instance_valid(rec["visual"]):
				seq = int(rec["visual"].get("_mirror_seq"))
				var st: Dictionary = rec["visual"].get_stance_anims()
				stance = ("%d%d" % [1 if not str(st.get("walk", "")).is_empty() else 0,
						1 if not str(st.get("idle", "")).is_empty() else 0])
			var shield := -1
			if rec["mount"] != null and is_instance_valid(rec["mount"]) \
					and rec["mount"].has_method("shield_visual_enabled"):
				shield = 1 if rec["mount"].shield_visual_enabled() else 0
			var dir: Vector2 = e.get("_ai_move_dir")
			var face: int = e.get_facing() if e.has_method("get_facing") else 1
			var ts: float = float(e.get("_last_direction_change_frame")) if "_last_direction_change_frame" in e else -99.0
			var poss: bool = bool(e.get("possessed")) if "possessed" in e else false
			(rec["data"] as Array).append([body.position.x, body.position.y,
					vel.x, vel.y, anim, seq, stance, shield,
					0.0 if dir == null else dir.x, face, ts, poss])
	# ── 统计 ──
	var wall_elapsed := Time.get_ticks_msec() / 1000.0 - t0
	print("[TwitchProbe] 采样 %d 物理 = %.1fs（物理 %.1fHz）实体 %d" % [frames,
			wall_elapsed, float(frames) / maxf(wall_elapsed, 0.001), series.size()])
	var churn_tot := 0
	var churn_worst: Array = []
	var flips_tot := 0.0
	var flips_worst: Array = []
	var face_flips_tot := 0.0
	var face_flips_worst: Array = []
	var idle_wander_tot := 0.0
	var stance_flap_tot := 0
	var shield_flap_tot := 0
	for id in series:
		var rec: Dictionary = series[id]
		var d: Array = rec["data"]
		if d.size() < 30:
			continue
		# 1) 同名重播 churn：anim 名没变但 seq 递增（镜像被强制重播）
		var churn := 0
		for i in range(1, d.size()):
			if d[i][4] == d[i - 1][4] and int(d[i][5]) > int(d[i - 1][5]):
				churn += 1
		churn_tot += churn
		churn_worst.append([churn, id])
		# 2) vx 翻转率（|vx|>10 才计），次/秒
		var flips := 0
		var last_s := 0
		for i in range(d.size()):
			var vx: float = d[i][2]
			var s := 0
			if vx > 10.0:
				s = 1
			elif vx < -10.0:
				s = -1
			if s != 0 and last_s != 0 and s != last_s:
				flips += 1
			if s != 0:
				last_s = s
		var dur := wall_elapsed   # 速率分母 = 实测墙钟（物理帧非 60Hz，旧 frames/60 虚高 6 倍）
		flips_tot += flips / dur
		flips_worst.append([flips / dur, id])
		# 2b) 朝向翻面率（次/秒）：创始人看到的"左右甩头"直接指标——
		# DIRECTION_CHANGE_FREQUENCY=0.5s 节流后理论上限 2 次/s
		var face_flips := 0
		for i in range(1, d.size()):
			if int(d[i][9]) != int(d[i - 1][9]):
				face_flips += 1
		face_flips_tot += face_flips / dur
		face_flips_worst.append([face_flips / dur, id])
		# 3) 待机漂移：anim==idle 期间的位移总和（px）
		var wander := 0.0
		for i in range(1, d.size()):
			if d[i][4] == "idle" and d[i - 1][4] == "idle":
				wander += Vector2(d[i][0] - d[i - 1][0], d[i][1] - d[i - 1][1]).length()
		idle_wander_tot += wander
		# 4) 姿态/盾抖动
		for i in range(1, d.size()):
			if d[i][6] != d[i - 1][6]:
				stance_flap_tot += 1
			if d[i][7] != -1 and d[i][7] != d[i - 1][7]:
				shield_flap_tot += 1
	churn_worst.sort_custom(func(a, b) -> bool: return a[0] > b[0])
	flips_worst.sort_custom(func(a, b) -> bool: return a[0] > b[0])
	face_flips_worst.sort_custom(func(a, b) -> bool: return a[0] > b[0])
	print("[TwitchProbe] 同名重播churn 总数=%d（worst5: %s）" % [churn_tot,
			str(churn_worst.slice(0, 5)).replace("[", "").replace("]", "")])
	print("[TwitchProbe] vx翻转率 均值=%.2f/s（worst5: %s）" % [flips_tot / maxi(series.size(), 1),
			str(flips_worst.slice(0, 5)).replace("[", "").replace("]", "")])
	print("[TwitchProbe] 朝向翻面率 均值=%.2f/s（worst5: %s）| 节流上限 2.0/s" % [
			face_flips_tot / maxi(series.size(), 1),
			str(face_flips_worst.slice(0, 5)).replace("[", "").replace("]", "")])
	# worst 翻面者的翻面帧距（节流生效则任意相邻翻面 ≥30 帧）
	if not face_flips_worst.is_empty():
		var wrec: Dictionary = series.get(face_flips_worst[0][1], {})
		if not wrec.is_empty():
			var wd: Array = wrec["data"]
			var gaps: Array = []
			var last_flip := -1
			for i in range(wd.size()):
				if i > 0 and int(wd[i][9]) != int(wd[i - 1][9]):
					if last_flip >= 0:
						gaps.append(i - last_flip)
					last_flip = i
			print("[TwitchProbe]   worst翻面者帧距: %s（节流生效=全部≥30）" % str(gaps.slice(0, 12)))
			# 翻面点前后 3 帧的节流时戳与附身标志（判节流为何未拦）
			var flip_frames: Array = []
			last_flip = -1
			for i in range(wd.size()):
				if i > 0 and int(wd[i][9]) != int(wd[i - 1][9]):
					flip_frames.append(i)
					if flip_frames.size() >= 4:
						break
			for ff_v in flip_frames:
				var ff: int = int(ff_v)
				var ctx: Array = []
				for k in range(maxi(ff - 1, 0), mini(ff + 2, wd.size())):
					ctx.append("f%d:face=%d ts=%.2f poss=%s" % [k, int(wd[k][9]),
							float(wd[k][10]), str(bool(wd[k][11]))])
				print("[TwitchProbe]   翻面@%d → %s" % [ff, " | ".join(ctx)])
	print("[TwitchProbe] 待机漂移总和=%.0fpx | 姿态换装翻转=%d | 盾态翻转=%d" % [
			idle_wander_tot, stance_flap_tot, shield_flap_tot])
	# 抽 1 个 churn 最高的实体打 12 帧原始序列（肉眼对时序）
	if not churn_worst.is_empty():
		var rec: Dictionary = series.get(churn_worst[0][1], {})
		if not rec.is_empty():
			var d: Array = rec["data"]
			print("[TwitchProbe] churn冠军原始序列（每8物理帧）: x,y,vx,anim,seq,stance,sh,dx")
			for i in range(0, d.size(), 8):
				var r = d[i]
				print("[TwitchProbe]   %7.1f %7.1f %6.1f %-10s seq=%d st=%s sh=%d dx=%.2f" % [
						r[0], r[1], r[2], r[4], r[5], r[6], r[7], r[8]])
