extends Node
## 描边闪烁探针（--flickerprobe）：连帧采样两个固定屏区的「描边白」像素量，
## 报逐帧序列的极差/跳变分布——描边粗细时间性抖动（量化档跳变/重烘风暴/
## mip 混合 shimmer）的量化工位。同时逐帧记录图集版本与 outline_eff，
## 机械层抖动（重烘/eff 变化）与采样层抖动（同版本内像素量波动）一目了然。
## 判读：版本恒定 + 像素量大幅波动 = 采样层抖动；版本连跳 = 机械层风暴。
## 屏区：A=左下指挥条带（指挥官/护卫，近静止——纯采样噪声的对照），
## B=战场中心（行进/接战单位，动画+采样混合）。相机静态（一屏战场）下
## 屏区在世界坐标里恒定。
## headless 不可跑（要 viewport 像素），带窗运行（arena_shot_boot 同口径）。

## 采样帧数（连帧；全屏同步回读每帧有成本，40 帧已够看节律）
const FRAMES := 40
## 白环判色阈（描边=白实例色近全透明度直出，身体色/血条/草地各通道均低）
const WHITE_T := 195
## 屏区 A（指挥条带左下角：指挥官 screen ≈(50,948)/护卫 ±90）
const CROP_A := Rect2i(10, 820, 320, 260)
## 屏区 B（战场中心：两军接战带）
const CROP_B := Rect2i(760, 300, 400, 300)
## 亚采样步（x/y 各隔 1 采 1——环宽 ~2px，隔行采样命中数减半但序列可比）
const STEP := 1


func run(_tag: String, _preset: int, _secs: int, _every: int) -> void:
	var arena: Node = null
	for i in 3600:
		await get_tree().process_frame
		arena = get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and (arena.get("_attacker") as Array).size() > 0:
			break
	if arena == null or not is_instance_valid(arena):
		print("[FlickerProbe] 观察场未就绪，退出")
		get_tree().quit()
		return
	# 等指挥官落位（出生完成口径，同 overlapprobe）
	for i in 3600:
		await get_tree().process_frame
		var cmd: Dictionary = arena.get("_arena_commanders")
		if cmd != null and not cmd.is_empty() \
				and cmd.values().all(func(c): return c != null and is_instance_valid(c)):
			break
	# 再等 2.5s：开拔+行进/接战已起（战斗中的描边采样才有代表性）
	await get_tree().create_timer(2.5).timeout
	print("[FlickerProbe] 采样开始 f=%d" % Engine.get_process_frames())
	var buckets: Node = _find_buckets()
	if buckets != null:
		var sm = buckets.get("_stroke_mat")
		if sm != null:
			print("[FlickerProbe] stroke 材质 atlas_lod=%s edge_cutoff=%s" % [
					str(sm.get_shader_parameter("atlas_lod")),
					str(sm.get_shader_parameter("edge_cutoff"))])
	var series_a: PackedInt32Array = []
	var series_b: PackedInt32Array = []
	var versions: PackedInt32Array = []
	var effs: PackedFloat32Array = []
	for i in FRAMES:
		# post_draw 同步采样（带 0.5s 兜底：窗口被遮挡时该信号饿死，退回
		# process_frame 读上一渲染帧——裸 process_frame 回读会撞上「清屏后
		# 未绘制」的中间帧，制造全暗伪影帧）
		var drawn := false
		var cb := func() -> void: drawn = true
		RenderingServer.frame_post_draw.connect(cb, CONNECT_ONE_SHOT)
		for k in 30:
			if drawn:
				break
			await get_tree().process_frame
		if not drawn:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		if img == null or img.is_empty():
			continue
		series_a.append(_count_white(img, CROP_A))
		series_b.append(_count_white(img, CROP_B))
		if buckets != null:
			var ja: Node = buckets.get("joint_atlas")
			versions.append(int(ja.version()) if ja != null and ja.has_method("version") else -1)
			effs.append(float(buckets.get("outline_eff")))
		else:
			versions.append(-1)
			effs.append(0.0)
		# 零值帧取证：区亮度（区分「白环消失但场景正常」=真闪 vs 「整帧暗」=回读伪影）
		# + 桶本帧写入行数（零写入=写行帧间隙；有写入而环不可见=采样层）
		if series_b.size() > 1 and series_b[-1] == 0:
			_crop_stats(img, CROP_B, "B零值帧")
			if buckets != null:
				var st: Node = buckets.get("stroke")
				var bd: Node = buckets.get("body")
				print("[FlickerProbe] 零值帧桶游标 stroke=%s body=%s 水位=%s" % [
						st.get("cursor") if st != null else "—",
						bd.get("cursor") if bd != null else "—",
						st.get("high_water") if st != null else "—"])
		if series_a.size() % 15 == 0:
			print("[FlickerProbe] …%d 帧 A=%d B=%d v=%d" % [
					series_a.size(), series_a[-1], series_b[-1], versions[-1]])
		if series_a.size() == 1:
			_crop_stats(img, CROP_A, "A")
			_crop_stats(img, CROP_B, "B")
	_report("A 指挥条带", series_a, versions, effs)
	_report("B 战场中心", series_b, versions, effs)
	var bumps := 0
	for i in range(1, versions.size()):
		if versions[i] != versions[i - 1]:
			bumps += 1
	print("[FlickerProbe] 图集版本跳变 %d 次 / eff 唯一值 %d 个（%s）" % [
			bumps, _uniq_count(effs), ", ".join(_uniq_list(effs).map(func(v): return "%.3f" % v))])
	await get_tree().create_timer(4.0).timeout
	_contact_census(arena)
	get_tree().quit()


## 接敌普查（战团中段）：创始人 2026-10-12 口径「明明已接敌还在互相不攻击跑步
## 顶」的量化——按单位当前行为 × 最近敌距分类：
##   attack=攻击中 / mosh=射程近邻仍在移动（互顶残余，应趋零）/ march=推进在途
##（远敌正常行军）/ hold=近敌站定待援 / other
func _contact_census(arena: Node) -> void:
	var counts := {"attack": 0, "mosh": 0, "march": 0, "hold": 0, "other": 0}
	var total := 0
	for fi in 2:
		for u in arena.get("_attacker" if fi == 0 else "_defender"):
			if u == null or not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
				continue
			total += 1
			var bi: Node = u.call("get_battle_instance") if u.has_method("get_battle_instance") else null
			if bi == null or not bi.has_method("get_enemies_of"):
				continue
			var near: float = INF
			for e in bi.call("get_enemies_of", int(u.call("get_faction"))):
				if e == null or not is_instance_valid(e) or (e.has_method("is_dead") and e.is_dead()):
					continue
				near = minf(near, (u as Node2D).global_position.distance_to(
						(e as Node2D).global_position))
			var wm: Node = u.get_node_or_null("WeaponMount")
			var rng: float = float(wm.attack_range) if wm != null and "attack_range" in wm else 100.0
			var moving: bool = (u as CharacterBody2D).velocity.length() > 40.0
			var ai: Node = u.call("get_ai_controller") if u.has_method("get_ai_controller") else null
			var beh: String = str(ai.call("get_current_behavior")) if ai != null and ai.has_method("get_current_behavior") else ""
			if beh == "attack":
				counts["attack"] += 1
			elif near < rng * 1.6 and moving:
				counts["mosh"] += 1
			elif moving:
				counts["march"] += 1
			elif near < rng * 1.6:
				counts["hold"] += 1
			else:
				counts["other"] += 1
	var parts := PackedStringArray()
	for k in counts.keys():
		parts.append("%s:%d" % [k, int(counts[k])])
	print("[FlickerProbe] 接敌普查 n=%d %s" % [total, " ".join(parts)])


func _find_buckets() -> Node:
	var map: Node = get_tree().current_scene
	# 经 GameRoot→当前地图→_hd→_joint_buckets 链取（结构稳定，duck 防御）
	for node in _iter_descendants(get_tree().root, 6):
		if node != null and "joint_atlas" in node and "outline_eff" in node:
			return node
	return null


func _iter_descendants(node: Node, depth: int) -> Array:
	var out: Array = []
	if depth <= 0:
		return out
	for c in node.get_children():
		out.append(c)
		out.append_array(_iter_descendants(c, depth - 1))
	return out


func _count_white(img: Image, crop: Rect2i) -> int:
	# 强制 RGBA8：回读格式不保证（RGB8 时 4 字节步长会错位读垃圾）
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var c: Image = img.get_region(crop)
	var d: PackedByteArray = c.get_data()
	var n := 0
	var w: int = c.get_width()
	var h: int = c.get_height()
	for y in range(0, h, STEP):
		var row: int = y * w * 4
		for x in range(0, w, STEP):
			var o: int = row + x * 4
			var mn: int = mini(mini(d[o], d[o + 1]), d[o + 2])
			if mn >= WHITE_T:
				n += 1
	return n


func _crop_stats(img: Image, crop: Rect2i, label: String) -> void:
	# 健全性统计：回读是否拿到真实画面（全黑=回读空/被遮挡；直方图看场景构成）
	var c: Image = img.get_region(crop)
	var hist := {}
	var mx := 0
	for y in range(0, c.get_height(), 4):
		for x in range(0, c.get_width(), 4):
			var p := c.get_pixel(x, y)
			var lum := int((p.r8 + p.g8 + p.b8) / 3.0)
			mx = maxi(mx, lum)
			hist[lum / 32] = hist.get(lum / 32, 0) + 1
	var parts := PackedStringArray()
	for k in 8:
		parts.append("%d:%d" % [k * 32, int(hist.get(k, 0))])
	print("[FlickerProbe] 区%s 亮度直方(32级:采样数) %s 最亮=%d" % [label, " ".join(parts), mx])


func _report(label: String, s: PackedInt32Array, versions: PackedInt32Array, _effs: PackedFloat32Array) -> void:
	if s.is_empty():
		print("[FlickerProbe] %s 无样本" % label)
		return
	var mn := s[0]
	var mx := s[0]
	var sum := 0
	var jumps := 0
	for i in s.size():
		mn = mini(mn, s[i])
		mx = maxi(mx, s[i])
		sum += s[i]
		if i > 0 && absi(s[i] - s[i - 1]) > 12:
			jumps += 1
	var mean := float(sum) / float(s.size())
	# 前 24 帧序列直出（看节律：等幅振荡/突发/缓变）
	var head := PackedStringArray()
	for i in mini(24, s.size()):
		head.append("%d" % s[i])
	print("[FlickerProbe] %s n=%d mean=%.0f min=%d max=%d 极差=%d(%.1f%%) 跳变>12px %d 帧" % [
			label, s.size(), mean, mn, mx, mx - mn, float(mx - mn) / maxf(mean, 1.0) * 100.0, jumps])
	print("[FlickerProbe]   序列[%s]" % " ".join(head))


func _uniq_count(arr: PackedFloat32Array) -> int:
	return _uniq_list(arr).size()


func _uniq_list(arr: PackedFloat32Array) -> Array:
	var seen := {}
	for v in arr:
		seen[float(snappedf(v, 0.0001))] = true
	return seen.keys()
