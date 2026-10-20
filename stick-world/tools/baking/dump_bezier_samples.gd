extends SceneTree
## 临时校验件（S1 验收）：把动画 .tres 的 BEZIER 旋转轨在键时刻+段内采样点
## 的插值值打印为 TSV，供 python 与 Spine 原数据独立求值对比。
## 用后即删（temp/ 不入库）。运行：
##   godot --headless --path . --script res://temp/dump_bezier_samples.gd -- attack walk attack_bow run dead hit_front idle_spear

const ANIM_DIR := "res://modules/stick_rig/animations/"
const NAMES := ["attack", "walk", "attack_bow", "run", "dead", "hit_front", "idle_spear", "attack_spear", "block_attack_3"]


func _initialize() -> void:
	var names := NAMES
	var args := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		args.append(a)
	if args.size() > 0:
		names = []
		for a in args:
			names.append(a)
	for n in names:
		var anim: Animation = load(ANIM_DIR + n + ".tres") as Animation
		if anim == null:
			continue
		for i in anim.get_track_count():
			if anim.track_get_type(i) != Animation.TYPE_BEZIER:
				continue
			var p := String(anim.track_get_path(i))
			if not p.ends_with(":rotation"):
				continue
			var kc: int = anim.track_get_key_count(i)
			var ts: Array[float] = []
			for k in kc:
				var kt := float(anim.track_get_key_time(i, k))
				ts.append(kt)
				if k + 1 < kc:
					var nt := float(anim.track_get_key_time(i, k + 1))
					for j in 5:
						ts.append(kt + (nt - kt) * (float(j) + 1.0) / 6.0)
			for t in ts:
				print("%s\t%s\t%.6f\t%.8f" % [n, p, t, anim.bezier_track_interpolate(i, t)])
	quit(0)
