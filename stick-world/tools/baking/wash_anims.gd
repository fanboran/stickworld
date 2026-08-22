extends Node
## 动作洗稿：对 spine_import 生成的动画 .tres 做"混合重构"扰动，
## 使动作曲线不再与解包 Spine 数据逐帧一致（防"逐帧复制"指认），
## 同时保留 SWL 动作语义（摆腿/挥剑/倒地等）。
##
## 扰动手段（确定性种子，可复现）：
##   - 幅度缩放：每骨骼独立系数（左右非对称，0.84~1.16）
##   - 基准角漂移：每骨骼 +[-2.5°, +2.5°]
##   - 关键帧重采样：新帧数 = 原帧数 ±2（≥3），均匀时间点重建
##   - 关键帧噪声：每采样点 +[-1.2°, +1.2°]
##   - 循环动画：相位偏移 0~0.15s + 时长微调 0.96~1.04 + 首尾强制闭合
##   - 非循环动画（attack/dead/hit/arrive）：不动时长/相位（保持节奏语义）
##
## 运行：godot --headless --path stick-world res://tools/baking/wash_anims.tscn

const ANIM_DIR := "res://modules/units/animations/"
const ANIMATIONS: Array[String] = [
	"idle", "idle_v2", "walk", "run", "attack", "dead",
	"hit_front", "hit_back", "walk_carry", "build", "arrive",
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
	print("=== 开始动作洗稿（混合重构） ===")
	_wash_all()
	print("=== 洗稿完成 ===")
	get_tree().quit(0)


func _wash_all() -> void:
	for anim_name in ANIMATIONS:
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
	# 腿臂失同步（动作"散架"）。幅度/基准/噪声才每 track 独立。
	var phase := 0.0
	var stretch := 1.0
	if is_loop:
		phase = rng.randf_range(0.0, 0.15)
		stretch = rng.randf_range(0.96, 1.04)
	var new_anim := Animation.new()
	new_anim.length = anim.length * stretch
	new_anim.loop_mode = anim.loop_mode

	var track_count := anim.get_track_count()
	for i in track_count:
		if anim.track_get_type(i) != Animation.TYPE_VALUE:
			continue
		var key_count := anim.track_get_key_count(i)
		if key_count == 0:
			continue
		var path := anim.track_get_path(i)
		var is_pos: bool = String(path).ends_with(":position")
		# 每骨骼独立扰动参数（幅度/基准漂移）
		var scale_factor := amp_base * rng.randf_range(0.84, 1.16)
		var bias_deg := rng.randf_range(-2.5, 2.5)
		var bias := deg_to_rad(bias_deg)
		# 平滑噪声：沿 key 时间正弦变化（每 track 一个相位/频率），
		# 避免"每 key 独立随机"导致骨骼逐帧跳变（= 视觉抖动/重影）。
		var noise_phase := rng.randf_range(0.0, TAU)
		var noise_freq := rng.randf_range(0.5, 1.6)
		# position track：整条 track 统一 y 缩放/偏移（非每 key 随机，否则 hip 每帧上下跳）
		var pos_scale := rng.randf_range(0.92, 1.08)
		var pos_bias := rng.randf_range(-1.2, 1.2)
		# 原曲线采样点
		var times: Array[float] = []
		var vals: Array = []
		for k in key_count:
			times.append(anim.track_get_key_time(i, k))
			vals.append(anim.track_get_key_value(i, k))
		if times.is_empty():
			continue
		# 重采样到新帧数（原 ±2，≥3）
		var new_key_count := clampi(key_count + rng.randi_range(-2, 2), 3, 60)
		var length: float = anim.length
		var t0: float = times[0]
		var t1: float = times[times.size() - 1]
		var end_t: float = length if is_loop else t1
		var new_times: Array[float] = []
		var new_vals: Array = []
		for n in new_key_count:
			# 时间点：循环动画含首尾闭合；非循环 0..end 均匀
			var frac: float = float(n) / float(new_key_count - 1)
			var t: float = t0 + (end_t - t0) * frac
			if is_loop:
				t = fmod(t * stretch + phase, length)
			var v: Variant = _sample(times, vals, t)
			# 扰动
			if is_pos:
				var p: Vector2 = v
				p.y = p.y * pos_scale + pos_bias
				v = p
			else:
				var a: float = v
				var smooth_noise: float = sin(noise_phase + frac * TAU * noise_freq) * 1.2
				a = a * scale_factor + bias + deg_to_rad(smooth_noise)
				v = a
			new_times.append(t)
			new_vals.append(v)
		# 循环动画首尾闭合
		if is_loop and new_key_count > 1:
			new_vals[new_key_count - 1] = new_vals[0]
		var new_track := new_anim.add_track(Animation.TYPE_VALUE)
		new_anim.track_set_path(new_track, path)
		new_anim.track_set_interpolation_type(new_track, Animation.INTERPOLATION_LINEAR)
		for n in new_key_count:
			new_anim.track_insert_key(new_track, new_times[n], new_vals[n])
	# 保存覆盖
	var err := ResourceSaver.save(new_anim, ANIM_DIR + anim.resource_path.get_file())
	if err != OK:
		printerr("  保存失败: %s (err=%d)" % [anim.resource_path, err])
		return false
	return true


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
