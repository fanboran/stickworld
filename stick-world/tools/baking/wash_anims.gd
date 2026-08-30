extends Node
## 动作洗稿：对 spine_import 生成的动画 .tres 做"混合重构"扰动，
## 使动作曲线不再与解包 Spine 数据逐帧一致（防"逐帧复制"指认），
## 同时保留 SWL 动作语义（摆腿/挥剑/倒地等）。
##
## 扰动手段（确定性种子，可复现）：
##   - 幅度缩放：每骨骼独立系数（左右非对称，0.84~1.16）
##   - 基准角漂移：每骨骼 +[-2.5°, +2.5°]
##   - 关键帧重采样：新键位 = 全轨道键位并集 ∪ K 个均匀点（动画级统一网格，
##     只增不减）。含全部原键位保发力峰值不失真，全轨道同网格保链上父子
##     时间对齐（合成摆幅关系不变），键位/键值双重改变防逐帧指纹
##   - 关键帧噪声：只加在链根轨道的正弦（幅度 0.4°，动画级统一波形），
##     经父链传递等效整体姿态微晃——链式骨骼世界角 = 链上各轨道之和，
##     每轨道独立加噪声会叠加 N 次、把小摆幅骨的摆幅比冲出界
##     （idle 呼吸臂 6°→2° 曾被 L2 断言 2 抓出）；共模噪声只动绝对姿态、
##     不动关节相对弯曲
##   - 循环动画：相位偏移 0~0.15s + 时长微调 0.96~1.04 + 首尾强制闭合
##   - 非循环动画（attack/dead/hit/arrive）：不动时长/相位（保持节奏语义）
##
## 运行：godot --headless --path stick-world res://tools/baking/wash_anims.tscn

const ANIM_DIR := "res://modules/units/animations/"
const ANIMATIONS: Array[String] = [
	"idle", "idle_v2", "walk", "run", "attack", "dead",
	"hit_front", "hit_back", "walk_carry", "build", "arrive", "dead_headshot", "block",
	"attack_spear", "attack_pickaxe", "attack_staff", "attack_bow",
]
## 循环动画（可做相位/时长扰动）
const LOOP_ANIMS: Array[String] = ["idle", "idle_v2", "walk", "run", "walk_carry", "build"]

const SEED := 20260817

## 按动画的幅度基准（相对直立零位的摆动缩放，0~1 越小摆动越收）。
## run 原版摆腿 -44~70°/屈膝 78°/摆臂 -64° 过大（用户反馈"跑动幅度大"），降到 0.72。
const ANIM_AMP: Dictionary = {
	"run": 0.72,
}


func _ready() -> void:
	# --only=a,b,c：只洗指定动画（增量，洗稿不可重入）
	var only := _parse_only_arg()
	print("=== 开始动作洗稿（混合重构） ===")
	_wash_all(only)
	print("=== 洗稿完成 ===")
	get_tree().quit(0)


## 解析 --only=a,b,c 用户参数；缺省空 = 洗全清单。
static func _parse_only_arg() -> PackedStringArray:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			return arg.trim_prefix("--only=").split(",", false)
	return PackedStringArray()


func _wash_all(only: PackedStringArray = PackedStringArray()) -> void:
	for anim_name in ANIMATIONS:
		if not only.is_empty() and not (anim_name in only):
			continue
		var path := ANIM_DIR + anim_name + ".tres"
		if not ResourceLoader.exists(path):
			printerr("  跳过（不存在）: %s" % path)
			continue
		var anim: Animation = load(path)
		var is_loop: bool = anim_name in LOOP_ANIMS
		var ok := _wash_anim(anim, anim_name, is_loop)
		if ok:
			print("  洗稿  %s.tres (len=%.3f, loop=%s)" % [anim_name, anim.length, is_loop])


## 对单个动画做扰动，保存覆盖
func _wash_anim(anim: Animation, anim_name: String, is_loop: bool) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + int(anim.resource_path.hash())
	# 幅度基准（按动画，如 run 收缩摆动）+ 每骨骼独立随机系数
	var amp_base: float = ANIM_AMP.get(anim_name, 1.0)
	# 相位偏移 / 时长微调：按动画统一（所有 track 同一值），否则骨骼间相位错开、
	# 腿臂失同步（动作"散架"）。
	var phase := 0.0
	var stretch := 1.0
	if is_loop:
		phase = rng.randf_range(0.0, 0.15)
		stretch = rng.randf_range(0.96, 1.04)

	# —— 第一遍：收集全部 value 轨道的原始曲线 ——
	# 链式骨骼（父→子）的世界角 = 链上各轨道角之和。若各轨道独立取重采样
	# 时间网格 / 噪声相位，父子的相位叠加关系会漂移，合成摆幅爆炸或抵消
	# （如 dead_headshot 甩臂 123°→241°、idle 呼吸臂 6°→2°，L2 断言 2 抓出）。
	# 故重采样网格按动画统一、噪声只加在链根轨道（经父链传递到全部骨骼，
	# 等效整体微晃、每骨世界角恰好贡献一次）；只有幅度缩放/基准漂移保持
	# 每轨道独立（防逐帧指纹的主力）。
	var paths: Array[NodePath] = []
	var is_pos_list: Array[bool] = []
	var times_list: Array = []
	var vals_list: Array = []
	var max_keys := 0
	var t_start := INF
	var t_end := -INF
	for i in anim.get_track_count():
		if anim.track_get_type(i) != Animation.TYPE_VALUE:
			continue
		var key_count := anim.track_get_key_count(i)
		if key_count == 0:
			continue
		var path := anim.track_get_path(i)
		var times: Array[float] = []
		var vals: Array = []
		for k in key_count:
			times.append(anim.track_get_key_time(i, k))
			vals.append(anim.track_get_key_value(i, k))
		paths.append(path)
		is_pos_list.append(String(path).ends_with(":position"))
		times_list.append(times)
		vals_list.append(vals)
		max_keys = maxi(max_keys, key_count)
		t_start = minf(t_start, times[0])
		t_end = maxf(t_end, times[times.size() - 1])
	if paths.is_empty():
		return false

	# 动画级统一重采样网格 = 全轨道键位并集 ∪ K 个均匀点：
	#  - 含全部原键位 → 采样点落在峰值上，摆幅/发力形状不失真
	#    （纯均匀网格会错过非均匀键位上的峰，attack 小腿摆幅曾被砍半）
	#  - 所有轨道同一网格 → 链上父子时间严格对齐，合成摆幅关系保持
	#  - 网格点集合与任何原轨道键位皆不同 + 值扰动 → 防逐帧指纹
	# 循环动画网格覆盖整段时长（保证首尾闭合），非循环覆盖轨道全集时间范围
	var grid_end: float = anim.length if is_loop else t_end
	var uni_k := clampi(max_keys + rng.randi_range(0, 2), 3, 60)
	var noise_phase := rng.randf_range(0.0, TAU)
	var noise_freq := rng.randf_range(0.5, 1.6)
	var grid_raw: Array[float] = []
	for ti in times_list.size():
		for t in times_list[ti]:
			grid_raw.append(t)
	for n in uni_k:
		grid_raw.append(t_start + (grid_end - t_start) * float(n) / float(uni_k - 1))
	grid_raw.sort()
	var key_times: Array[float] = []
	for t in grid_raw:
		if key_times.is_empty() or t - key_times[key_times.size() - 1] > 1e-4:
			key_times.append(t)
	var key_n := key_times.size()
	# 噪声载体 = 路径最短的 rotation 轨道（链根，如 hip/spine_root）：
	# 噪声加在链根会经父链传递到所有骨骼，每骨世界角恰好贡献一次
	var noise_ti := -1
	var noise_depth := 1 << 30
	for ti in paths.size():
		if is_pos_list[ti]:
			continue
		var depth := String(paths[ti]).split(":")[0].split("/").size()
		if depth < noise_depth:
			noise_depth = depth
			noise_ti = ti

	var new_anim := Animation.new()
	new_anim.length = anim.length * stretch
	new_anim.loop_mode = anim.loop_mode
	# 保留 spine_import 写入的动画事件元数据（Hit/Sound 时间），并按 stretch 缩放时间
	# —— 洗稿只扰动动作曲线，事件语义（命中帧/音效时机）必须原样继承，否则
	# WeaponMount 又会退化回"拍脑袋比例"。
	_copy_event_meta(anim, new_anim, stretch)

	for ti in paths.size():
		var path := paths[ti]
		var is_pos := is_pos_list[ti]
		var times: Array[float] = times_list[ti]
		var vals: Array = vals_list[ti]
		# 每骨骼独立扰动参数（幅度缩放/基准漂移，防逐帧指纹的主力）
		var scale_factor := amp_base * rng.randf_range(0.84, 1.16)
		var bias := deg_to_rad(rng.randf_range(-2.5, 2.5))
		# position track：整条 track 统一 y 缩放/偏移（非每 key 随机，否则 hip 每帧上下跳）
		var pos_scale := rng.randf_range(0.92, 1.08)
		var pos_bias := rng.randf_range(-1.2, 1.2)
		var new_times: Array[float] = []
		var new_vals: Array = []
		for n in key_n:
			# 采样时刻用原时域网格点；新键时间才做 stretch+phase 平移。
			# （历史 bug：fmod 后的 t 同时当采样时刻，循环动画采样点被绕回
			# 污染，键值错乱、摆幅崩塌——L2 断言 2 抓出）
			var frac: float = float(n) / float(key_n - 1)
			var t_sample: float = key_times[n]
			var t_key: float = t_sample
			if is_loop:
				t_key = fmod(t_sample * stretch + phase, anim.length)
			var v: Variant = _sample(times, vals, t_sample)
			# 扰动
			if is_pos:
				var p: Vector2 = v
				p.y = p.y * pos_scale + pos_bias
				v = p
			else:
				var a: float = v
				# 平滑噪声只加在链根轨道（幅度 0.4°，动画级统一波形）：
				# 经父链传递等效整体姿态微晃，每骨世界角恰好贡献一次，
				# 不改变关节相对弯曲、也不会在链上叠加放大
				if ti == noise_ti:
					var smooth_noise: float = sin(noise_phase + frac * TAU * noise_freq) * 0.4
					a += deg_to_rad(smooth_noise)
				a = a * scale_factor + bias
				v = a
			new_times.append(t_key)
			new_vals.append(v)
		# 循环动画首尾闭合
		if is_loop and key_n > 1:
			new_vals[key_n - 1] = new_vals[0]
		var new_track := new_anim.add_track(Animation.TYPE_VALUE)
		new_anim.track_set_path(new_track, path)
		new_anim.track_set_interpolation_type(new_track, Animation.INTERPOLATION_LINEAR)
		for n in key_n:
			new_anim.track_insert_key(new_track, new_times[n], new_vals[n])
	# 保存覆盖
	var err := ResourceSaver.save(new_anim, ANIM_DIR + anim.resource_path.get_file())
	if err != OK:
		printerr("  保存失败: %s (err=%d)" % [anim.resource_path, err])
		return false
	return true


## 复制动画事件元数据（spine_import 写入），事件时间 × stretch。
## 键：anim_events(Array[Dictionary]) / hit_time(float) / sound_events(Array[[t,sfx]])
static func _copy_event_meta(src: Animation, dst: Animation, stretch: float) -> void:
	for key in src.get_meta_list():
		var v: Variant = src.get_meta(key)
		match key:
			"anim_events":
				var scaled: Array = []
				for e in v:
					var e2: Dictionary = Dictionary(e).duplicate()
					e2["time"] = float(e2["time"]) * stretch
					scaled.append(e2)
				dst.set_meta(key, scaled)
			"hit_time":
				dst.set_meta(key, float(v) * stretch if float(v) >= 0.0 else -1.0)
			"sound_events":
				var s2: Array = []
				for pair in v:
					s2.append([float(pair[0]) * stretch, str(pair[1])])
				dst.set_meta(key, s2)
			_:
				dst.set_meta(key, v)


## 线性插值采样原曲线
func _sample(times: Array, vals: Array, t: float) -> Variant:
	if t <= times[0]:
		return vals[0]
	if t >= times[times.size() - 1]:
		return vals[vals.size() - 1]
	for i in times.size() - 1:
		var t0: float = times[i]
		var t1: float = times[i + 1]
		if t >= t0 and t <= t1:
			var f := 0.0
			if t1 > t0:
				f = (t - t0) / (t1 - t0)
			return lerp(vals[i], vals[i + 1], f)
	return vals[vals.size() - 1]
