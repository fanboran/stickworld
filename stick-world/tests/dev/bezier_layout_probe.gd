extends SceneTree
## 决定性实验2：handle x 语义（比例 vs 绝对秒），非对称曲线。
## 三轨道同 Δv=100，bezier(0.25, 0.3, 0.75, 0.7) 的 tn=0.4 期望：比例/绝对秒不同形状。
func _cubic(a: float, b: float, c: float, d: float, u: float) -> float:
	var iu: float = 1.0 - u
	return iu*iu*iu*a + 3.0*iu*iu*u*b + 3.0*iu*u*u*c + u*u*u*d
func _spine_y(tn: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for _i in 50:
		var mid := (lo + hi) * 0.5
		if _cubic(0.0, 0.25, 0.75, 1.0, mid) < tn:
			lo = mid
		else:
			hi = mid
	return _cubic(0.0, 0.3, 0.7, 1.0, (lo + hi) * 0.5)
func _initialize() -> void:
	# A: dt=1 out=(0.25, 30)  B: dt=2 out=(0.25, 30)  C: dt=2 out=(0.5, 30)（绝对秒口径）
	var want_04 := _spine_y(0.4) * 100.0
	print("spine_want(tn=0.4)=", want_04)
	for cfg in [[1.0, 0.25, "A_dt1_h0.25"], [2.0, 0.25, "B_dt2_h0.25"], [2.0, 0.5, "C_dt2_h0.5"]]:
		var anim := Animation.new()
		anim.length = cfg[0]
		var track := anim.add_track(Animation.TYPE_BEZIER)
		anim.track_set_path(track, NodePath("hip:rotation"))
		anim.bezier_track_insert_key(track, 0.0, 0.0, Vector2(0.0, 0.0), Vector2(cfg[1], 30.0))
		anim.bezier_track_insert_key(track, cfg[0], 100.0, Vector2(-cfg[1], -30.0), Vector2(0.0, 0.0))
		var v04: float = anim.bezier_track_interpolate(track, 0.4 * cfg[0])
		# tn=0.75 也采一个（更敏感）
		var v75: float = anim.bezier_track_interpolate(track, 0.75 * cfg[0])
		print("%s  tn0.4=%.6f  tn0.75=%.6f  want0.4=%.6f" % [cfg[2], v04, v75, want_04])
	quit(0)
