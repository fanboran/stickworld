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
	# 硬看门狗：任何协程死亡/卡住（战斗结束场景自毁后协程静默断流）兜底退出，
	# 防 Godot 进程滞留挂死跑批通道
	get_tree().create_timer(45.0).timeout.connect(func() -> void:
		print("[FlickerProbe] 看门狗超时强制退出")
		get_tree().quit())
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
	# 再等 2.5s：开拔+行进/接战已起（战斗中的采样才有代表性）
	await get_tree().create_timer(2.5).timeout
	# 行为普查先行（战斗中段跑完 90 帧——放最后会被战斗结束的场景自动退出
	# 掐断：观察场打完就 quit，尾部挂长协程必死）
	_behavior_census(arena)
	_flicker_ab(arena)
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


## 行为普查（裁决#32 验收量化工位，多帧采样）：创始人三项主诉的量化——
##   接触未出手 stalled = 敌已在射程内、自身非攻击动画且 0.8s 内没出手过、
##   非硬直（=「都接敌了但是就不打」的直接计数，应趋零）
##   织行帧 weave = 推进在途（敌距 > 1.3×射程）却横着走——速度方向与
##   「指向最近敌」夹角 > 40°（=「绕来绕去的动作」，应趋零）
##   接触互顶 mosh = 近敌仍在移动互顶（接敌两病残余）
##   速度谱 = 移动单位速度分位数 + 站定/走/跑占比（「移动速度不自然」的
##   分布证据：非自然抖动会体现为中位数漂移/双峰/贴零堆积）
const CENSUS_FRAMES := 90
const STALL_AFTER_SECS := 0.8
const WEAVE_DEG := 40.0

func _behavior_census(arena: Node) -> void:
	print("[Census] 行为普查启动 f=%d" % Engine.get_process_frames())
	# iid → 最近一次攻击动画帧（动画名 begins_with "attack" 即视为出手中）
	var last_attack: Dictionary = {}
	var agg := {"stalled": 0, "weave": 0, "mosh": 0, "kite": 0, "closing": 0, "attack": 0,
			"still": 0, "samples": 0}
	var speeds: PackedFloat32Array = []
	var stalled_by_weapon: Dictionary = {}
	var per_frame_stalled: PackedInt32Array = []
	for f in CENSUS_FRAMES:
		if get_tree() == null or not is_instance_valid(arena):
			break  # 战斗结束场景自毁：协程断流前主动退出
		await get_tree().process_frame
		var stalled_n := 0
		for fi in 2:
			for u in arena.get("_attacker" if fi == 0 else "_defender"):
				if u == null or not is_instance_valid(u) or (u.has_method("is_dead") and u.is_dead()):
					continue
				var bi: Node = u.call("get_battle_instance") if u.has_method("get_battle_instance") else null
				if bi == null or not bi.has_method("get_enemies_of"):
					continue
				var faction: int = int(u.call("get_faction"))
				var near: float = INF
				var near_dir := Vector2.ZERO
				for e in bi.call("get_enemies_of", faction):
					if e == null or not is_instance_valid(e) or (e.has_method("is_dead") and e.is_dead()):
						continue
					var d: float = (u as Node2D).global_position.distance_to((e as Node2D).global_position)
					if d < near:
						near = d
						near_dir = ((e as Node2D).global_position - (u as Node2D).global_position).normalized()
				var wm: Node = u.get_node_or_null("WeaponMount")
				var rng: float = float(wm.attack_range) if wm != null and "attack_range" in wm else 100.0
				var vel: Vector2 = (u as CharacterBody2D).velocity
				var speed: float = vel.length()
				var iid: int = u.get_instance_id()
				var anim: String = str(u.get("_current_anim"))
				if anim.begins_with("attack"):
					last_attack[iid] = Engine.get_process_frames()
				agg["samples"] += 1
				if speed > 40.0:
					speeds.append(speed)
				# 分类（互斥优先级：出手 > 射程内 > 推进在途 > 站定）
				var attacked_recently: bool = Engine.get_process_frames() - int(last_attack.get(iid, -100000)) \
						< int(STALL_AFTER_SECS * 60.0)
				var stunned: bool = u.has_method("is_in_hit_stun") and u.call("is_in_hit_stun")
				if anim.begins_with("attack") or attacked_recently:
					agg["attack"] += 1
				elif near <= rng:
					# 射程内不出手的合法态：冷却未好（can_attack=false）/硬直/风筝后撤；
					# 站定 + 冷却已好 + 非硬直 + 0.8s 无出手 = 真停摆（接敌不打）
					if speed >= 40.0 and near < rng * 1.6:
						if near_dir != Vector2.ZERO and vel.normalized().dot(near_dir) < -0.3:
							agg["kite"] += 1  # 风筝后撤（背敌移动，远程合法态）
						else:
							agg["mosh"] += 1
					elif speed < 40.0 and not stunned and wm != null and wm.has_method("can_attack") \
							and wm.call("can_attack"):
						var wt: int = int(wm.weapon_type) if "weapon_type" in wm else -1
						stalled_by_weapon[wt] = int(stalled_by_weapon.get(wt, 0)) + 1
						agg["stalled"] += 1
						stalled_n += 1
				elif speed > 40.0:
					# 推进在途：速度方向应基本朝最近敌（直奔目标）——横着走 = 织行
					if near_dir != Vector2.ZERO and speed > 40.0:
						var cos_a: float = vel.normalized().dot(near_dir)
						if cos_a < cos(deg_to_rad(WEAVE_DEG)):
							agg["weave"] += 1
						else:
							agg["closing"] += 1
				else:
					agg["still"] += 1
		per_frame_stalled.append(stalled_n)
	var n: int = int(agg["samples"])
	if n == 0:
		print("[Census] 无样本")
		return
	speeds.sort()
	var pct := func(p: float) -> float:
		return speeds[maxi(0, mini(speeds.size() - 1, int(speeds.size() * p)))] \
				if speeds.size() > 0 else 0.0
	var weapon_names := {0: "剑", 1: "矛", 2: "弓", 3: "镐", 4: "杖", 5: "祭", -1: "?"}
	var w_parts := PackedStringArray()
	for wt in stalled_by_weapon.keys():
		w_parts.append("%s:%d" % [weapon_names.get(wt, str(wt)), int(stalled_by_weapon[wt])])
	print("[Census] 样本 %d 单位帧｜接触未出手 %d(%.1f%%，冷却已好仍站定，武器 %s)｜织行帧 %d(%.1f%%)｜接触互顶 %d｜风筝后撤 %d｜直奔 %d｜出手中 %d(%.1f%%)｜站定 %d" % [
			n, int(agg["stalled"]), float(agg["stalled"]) / n * 100.0,
			" ".join(w_parts) if w_parts.size() > 0 else "无",
			int(agg["weave"]), float(agg["weave"]) / n * 100.0,
			int(agg["mosh"]), int(agg["kite"]), int(agg["closing"]),
			int(agg["attack"]), float(agg["attack"]) / n * 100.0, int(agg["still"])])
	print("[Census] 移动速度谱 n=%d p10=%.0f p50=%.0f p90=%.0f（走带~160×移速档 / 跑带~320×移速档）" % [
			speeds.size(), pct.call(0.1), pct.call(0.5), pct.call(0.9)])
	var peak := 0
	for v in per_frame_stalled:
		peak = maxi(peak, v)
	print("[Census] 接触未出手峰值同帧 %d 人" % peak)


## 闪烁三相对照（创始人 2026-10-13「血条和单位不断闪烁」定位工位）：
## 固定屏区逐帧计数 白环（描边）/阵营色（血条）像素 → 三相各采 40 帧：
##   基线（现状）→ 隐FX（箭矢+粒子全隐）→ 强60Hz（LOD 停摆+全员近景全速）
## 归因：隐FX 相波动消失 = FX 半透明盖单位；强60Hz 相消失 = LOD 密度降频
## （102 单位 T0=15Hz 逐单位错相位 = 全场微闪烁感）；都不消 = 桶级下一步。
const AB_FRAMES := 40
const CROP_FIGHT := Rect2i(560, 380, 800, 300)
## 阵营血条色（FACTION_COLORS 直录），逐通道容差
const BAR_BLUE := Color(0.38, 0.58, 0.98)
const BAR_RED := Color(0.98, 0.44, 0.35)
const BAR_TOL := 30


func _flicker_ab(arena: Node) -> void:
	print("[FlickAB] 三相对照开始（基线 → 隐FX → 强60Hz）")
	_ab_phase("基线", arena, false, false)
	_ab_phase("隐FX", arena, true, false)
	_ab_phase("强60Hz", arena, false, true)
	print("[FlickAB] 对照结束")


## 单相采样：逐帧（可选）隐藏 FX / 下发 60Hz 档，回读 CROP_FIGHT 计数
## 白环/阵营色像素 + fps。FX 逐帧重扫（箭矢持续新生成）；60Hz 相在相首
## 一次性停摆 LOD 导演器 + 全员近景全速（新生 minidon 例外，可忽略）。
func _ab_phase(label: String, arena: Node, hide_fx: bool, force_60: bool) -> void:
	var lod: Node = get_tree().root.find_child("UnitLodDirector", true, false)
	if force_60 and lod != null:
		lod.set_physics_process(false)
		for fi in 2:
			for u in arena.get("_attacker" if fi == 0 else "_defender"):
				if u != null and is_instance_valid(u) and u.has_method("set_perf_tier"):
					u.call("set_perf_tier", 0, 60.0)
	var hidden_fx: Array = []
	var whites: PackedInt32Array = []
	var bars: PackedInt32Array = []
	var fps_sum: float = 0.0
	for i in AB_FRAMES:
		if get_tree() == null or not is_instance_valid(arena):
			break  # 战斗结束场景自毁：协程断流前主动退出
		await get_tree().process_frame
		if hide_fx:
			_hide_fx_once(hidden_fx)  # 采样前扫：新箭矢/新粒子即时隐（记录以便相末还原）
		var img := get_viewport().get_texture().get_image()
		if img == null or img.is_empty():
			continue
		var counts := _count_fight(img)
		whites.append(counts[0])
		bars.append(counts[1])
		fps_sum += Engine.get_frames_per_second()
	for node in hidden_fx:
		if node != null and is_instance_valid(node):
			node.visible = true
	if force_60 and lod != null:
		lod.set_physics_process(true)
	if whites.is_empty():
		print("[FlickAB] %s 无样本" % label)
		return
	var wz := 0
	var wmx := -1
	var wsum := 0
	for v in whites:
		wz += 1 if v == 0 else 0
		wmx = maxi(wmx, v)
		wsum += v
	var bz := 0
	var bmx := -1
	var bsum := 0
	var bmn := 1 << 30
	for v in bars:
		bz += 1 if v == 0 else 0
		bmx = maxi(bmx, v)
		bmn = mini(bmn, v)
		bsum += v
	# 波动强度 = 逐帧差分绝对值均值（对 0 敏感：闪烁=大幅差分高频出现）
	var wdiff := 0.0
	for i in range(1, whites.size()):
		wdiff += absi(whites[i] - whites[i - 1])
	wdiff /= maxf(whites.size() - 1.0, 1.0)
	var bdiff := 0.0
	for i in range(1, bars.size()):
		bdiff += absi(bars[i] - bars[i - 1])
	bdiff /= maxf(bars.size() - 1.0, 1.0)
	print("[FlickAB] %s n=%d fps≈%.0f｜白环 mean=%.0f max=%d 零帧%d 差分%.0f｜血条色 mean=%.0f min=%d max=%d 零帧%d 差分%.0f" % [
			label, whites.size(), fps_sum / whites.size(),
			float(wsum) / whites.size(), wmx, wz, wdiff,
			float(bsum) / bars.size(), bmn, bmx, bz, bdiff])


## 深度限访客隐 FX（零数组分配——全树 append_array 版实测把跑批挂死）；
## 从当前场景起 depth 8 覆盖地图/实体/FX 池；隐掉的记进 ledger 相末还原。
func _hide_fx_once(ledger: Array) -> void:
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	_hide_fx_in(scene, 8, ledger)


func _hide_fx_in(node: Node, depth: int, ledger: Array) -> void:
	if node == null or depth <= 0:
		return
	var n: int = node.get_child_count()
	for i in n:
		var c: Node = node.get_child(i)
		if c is GPUParticles2D or c is CPUParticles2D or c is ArrowProjectile:
			if c.visible:
				c.visible = false
				ledger.append(c)
		_hide_fx_in(c, depth - 1, ledger)


## 战区计数：白环（min 通道 ≥ WHITE_T）+ 阵营血条色像素（蓝/红容差匹配）
func _count_fight(img: Image) -> Array:
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var c: Image = img.get_region(CROP_FIGHT)
	var d: PackedByteArray = c.get_data()
	var white := 0
	var bar := 0
	var w: int = c.get_width()
	for y in range(0, c.get_height(), 2):
		var row: int = y * w * 4
		for x in range(0, w, 2):
			var o: int = row + x * 4
			var r: int = d[o]
			var g: int = d[o + 1]
			var b: int = d[o + 2]
			if mini(mini(r, g), b) >= WHITE_T:
				white += 1
				continue
			if absi(r - int(BAR_RED.r8)) <= BAR_TOL and absi(g - int(BAR_RED.g8)) <= BAR_TOL \
					and absi(b - int(BAR_RED.b8)) <= BAR_TOL:
				bar += 1
			elif absi(r - int(BAR_BLUE.r8)) <= BAR_TOL and absi(g - int(BAR_BLUE.g8)) <= BAR_TOL \
					and absi(b - int(BAR_BLUE.b8)) <= BAR_TOL:
				bar += 1
	return [white, bar]


func _find_buckets() -> Node:
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
