extends SceneTree
## bezier track 探针（批次 A 风险实验）：验证 Godot 4.7 Animation 的 bezier 轨道
## 能否精确等价表达 Spine 的归一化 bezier 曲线（curve/c2/c3/c4 字段语义）。
##
## 数学命题：Spine 键 {curve: x1, c2: y1, c3: x2, c4: y2} 的归一化空间 bezier
##   P(u) = bezier((0,0), (x1,y1), (x2,y2), (1,1))，时间=x(u)、值=y(u)
## 与 Godot bezier key 的几何控制点四边形
##   (t0,v0) → (t0+out_dx, v0+out_dy) → (t1+in_dx, v1+in_dy) → (t1,v1)
## 在 out=(x1*dt, y1*dv)、in=((x2-1)*dt, (y2-1)*dv) 时完全等价。
## 本脚本用 Animation.bezier_track_interpolate 采样并与二分法 Spine 语义求值对比。
##
## 另产出：bezier track 与 stepped(value track) 的 .tres 序列化文本（导入器照抄格式）。
## 用法：godot --headless --path stick-world --script res://tests/dev/bezier_track_probe.gd

const X1 := 0.339
const Y1 := 0.06
const X2 := 0.712
const Y2 := 0.48
const T0 := 0.0
const T1 := 1.0
const V0 := 0.0
const V1 := 90.0


func _cubic(a: float, b: float, c: float, d: float, u: float) -> float:
	var iu := 1.0 - u
	return iu * iu * iu * a + 3.0 * iu * iu * u * b + 3.0 * iu * u * u * c + u * u * u * d


## Spine 语义精确求值：解 x(u)=tn 得 u，返回 y(u)（归一化空间二分）
func _spine_bezier(tn: float) -> float:
	var lo := 0.0
	var hi := 1.0
	for _i in 40:
		var mid := (lo + hi) * 0.5
		if _cubic(0.0, X1, X2, 1.0, mid) < tn:
			lo = mid
		else:
			hi = mid
	var u := (lo + hi) * 0.5
	return _cubic(0.0, Y1, Y2, 1.0, u)


func _initialize() -> void:
	var anim := Animation.new()
	var track := anim.add_track(Animation.TYPE_BEZIER)
	anim.track_set_path(track, NodePath("hip:position:x"))
	var dt := T1 - T0
	var dv := V1 - V0
	# key 结构：[time, value, in_handle: Vector2, out_handle: Vector2]（handle=(dx,dy) 相对）
	anim.bezier_track_insert_key(track, T0, V0, Vector2(0.0, 0.0), Vector2(X1 * dt, Y1 * dv))
	anim.bezier_track_insert_key(track, T1, V1, Vector2((X2 - 1.0) * dt, (Y2 - 1.0) * dv), Vector2(0.0, 0.0))

	print("=== bezier track 采样对比（dt=%s dv=%s）===" % [dt, dv])
	var max_err := 0.0
	var t := 0.05
	while t <= 0.95:
		var godot_v: float = anim.bezier_track_interpolate(track, t)
		var spine_v: float = V0 + (V1 - V0) * _spine_bezier(t)
		var err: float = absf(godot_v - spine_v)
		max_err = maxf(max_err, err)
		print("t=%.2f  godot=%.6f  spine=%.6f  err=%.10f" % [t, godot_v, spine_v, err])
		t += 0.05
	print("max_err=%.10f %s" % [max_err, "PASS" if max_err < 1e-4 else "FAIL"])

	# round-trip：存 .tres 再读回再采样
	var path := "res://.tmp_bezier_probe.tres"
	var err2 := ResourceSaver.save(anim, path)
	if err2 != OK:
		print("ResourceSaver.save 失败: %d" % err2)
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		print("=== .tres 序列化文本 ===")
		print(f.get_as_text())
		f.close()
		var loaded := ResourceLoader.load(path) as Animation
		var err3 := 0.0
		t = 0.05
		while t <= 0.95:
			err3 = maxf(err3, absf(loaded.bezier_track_interpolate(0, t) - _spine_bezier(t) * dv))
			t += 0.1
		print("round-trip max_err=%.10f %s" % [err3, "PASS" if err3 < 1e-4 else "FAIL"])

	# stepped 语义的 value track 格式（对照样本）
	var anim2 := Animation.new()
	var tr2 := anim2.add_track(Animation.TYPE_VALUE)
	anim2.track_set_path(tr2, NodePath("hip:rotation"))
	anim2.track_set_interpolation_type(tr2, Animation.INTERPOLATION_NEAREST)
	anim2.track_insert_key(tr2, 0.0, 30.0)
	anim2.track_insert_key(tr2, 1.0, 60.0)
	var path2 := "res://.tmp_stepped_probe.tres"
	ResourceSaver.save(anim2, path2)
	var f2 := FileAccess.open(path2, FileAccess.READ)
	print("=== stepped value track .tres ===")
	print(f2.get_as_text())
	f2.close()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path2))
	quit(0)
