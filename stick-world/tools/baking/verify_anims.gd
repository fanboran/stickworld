extends Node
## 验证：直接采样转换后动画 .tres 的骨骼旋转关键帧，应用到骨架，检查摆动角度是否合理。
## walk: 腿应在竖直附近摆动（thigh ±40°）、臂摆动、头微动；attack: 挥剑幅度大。

const StickmanSkeleton := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")

var _skel: Skeleton2D


func _ready() -> void:
	_skel = Skeleton2D.new()
	_skel.name = "Skeleton2D"
	StickmanSkeleton.build_from_scratch(_skel)
	add_child(_skel)

	for anim_name in ["walk", "attack", "idle", "run", "dead"]:
		var anim: Animation = load("res://modules/units/animations/%s.tres" % anim_name)
		print("=== %s (len=%.2f) ===" % [anim_name, anim.length])
		for t in [0.0, anim.length * 0.25, anim.length * 0.5, anim.length * 0.75, anim.length]:
			_apply(anim, t)
			var thigh := _rot("thigh_outer")
			var shin := _rot("thigh_outer/shin_outer")
			var arm := _rot("hip/lower_torso/upper_torso/upper_arm_outer")
			var head := _rot("hip/lower_torso/upper_torso/neck/head")
			print("  t=%.2f  thigh=%6.1f  shin=%6.1f  arm=%6.1f  head=%6.1f" % [t, thigh, shin, arm, head])
	print("验证完成")
	get_tree().quit(0)


## 应用动画到 t 时刻（线性插值关键帧）
func _apply(anim: Animation, t: float) -> void:
	for i in anim.get_track_count():
		if anim.track_get_type(i) != Animation.TYPE_VALUE:
			continue
		var key_count: int = anim.track_get_key_count(i)
		if key_count == 0:
			continue
		var path_str := String(anim.track_get_path(i))
		var is_pos: bool = path_str.ends_with(":position")
		var node_path: String = path_str.trim_suffix(":position").trim_suffix(":rotation")
		var node: Node2D = _skel.get_node_or_null(node_path)
		if node == null:
			continue
		var value: Variant = _sample(anim, i, t)
		if is_pos:
			node.position = value
		else:
			node.rotation = value


## 关键帧线性插值采样
func _sample(anim: Animation, track_idx: int, t: float) -> Variant:
	var kc: int = anim.track_get_key_count(track_idx)
	if kc == 1:
		return anim.track_get_key_value(track_idx, 0)
	if t <= anim.track_get_key_time(track_idx, 0):
		return anim.track_get_key_value(track_idx, 0)
	var last_k: int = kc - 1
	if t >= anim.track_get_key_time(track_idx, last_k):
		return anim.track_get_key_value(track_idx, last_k)
	for k in range(kc - 1):
		var t0: float = anim.track_get_key_time(track_idx, k)
		var t1: float = anim.track_get_key_time(track_idx, k + 1)
		if t >= t0 and t <= t1:
			var f: float = (t - t0) / maxf(t1 - t0, 0.0001)
			var v0: Variant = anim.track_get_key_value(track_idx, k)
			var v1: Variant = anim.track_get_key_value(track_idx, k + 1)
			return lerp(v0, v1, f)
	return anim.track_get_key_value(track_idx, last_k)


func _rot(path: String) -> float:
	var node: Node2D = _skel.get_node_or_null(path)
	if node == null:
		return 999.0
	return rad_to_deg(node.rotation)
