extends Node
## 标准站姿检查场景（dev）：**裸 rig**——不经过 StickmanEntity，直接实例化
## stickman_test.tscn 并剥离 legacy WASD 驱动脚本：无武器、无 AI、无输入。
##
## 批次 4h 实测定稿（勿回退，证据见交接档批次 4h 节）：
## - 本骨架 rest 旋转全 0、肢体方向烤在子骨偏移里（Spine 导入遗留），rest 是
##   未立直的 bind 姿态。早期按"骨轴=局部+x"语义把骨骼 _aim 到 ±90° 等于整体
##   放倒（裸 rig 塌块根因）。
## - **IK 修改器栈实测不参与解算**（裸 rig 结算后骨骼值=动画值逐度相等；两种
##   Marker 目标输出一致）——limb 姿态=rest+动画微调，IK 目标 Marker 全是
##   死重（游戏内同代码路径，同样不生效）。
## - 游戏内自然站姿 = idle 第 0 帧（对骨骼只有 <3° 微调，≈rest）；本场景默认
##   播 idle 冻结 t=0 作为"游戏基线站姿"，另有 hang（对称垂放直腿）/rest（纯
##   bind）两档对照。
## - 每帧覆写源：ProceduralOverlay 每帧绝对复位 hip/torso/head 旋转（呼吸/微抖），
##   静态基线必须关（本场景恒关）。
## 运行：
##   godot --path stick-world res://tests/dev/stickman_relaxed_pose.tscn --
##     --outdir=<目录> [--pose=idle|hang|rest] [--ik=on] [--verbose]

const _RigScene: PackedScene = preload("res://modules/units/scenes/stickman_test.tscn")
const _OverlayScript := preload("res://modules/units/scripts/rig/procedural_overlay.gd")
const _SkeletonScript := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")
## 与实体渲染同规格（game_root BASE_SCALE）
const RIG_SCALE := 0.5

## hang 姿态的链方向目标（全局屏幕角，度；90°=竖直向下，<90 偏前，>90 偏后）。
## 键=骨骼 id，值=[主子骨偏移(SKELETON_DATA), 目标链方向角]；先父后子逐条摆。
const HANG_CHAIN: Dictionary = {
	18: [Vector2(-34.7, 53.9), 98.0],   # 上臂外→前臂外：垂放微后
	1:  [Vector2(-3.1, 48.7), 94.0],    # 前臂外→手外：与上臂对齐
	19: [Vector2(1.1, 64.1), 82.0],     # 上臂内→前臂内：垂放微前
	14: [Vector2(33.8, 35.2), 86.0],    # 前臂内→手内：与上臂对齐
	16: [Vector2(25.4, 60.9), 90.0],    # 大腿外→小腿外：竖直
	3:  [Vector2(2.9, 68.9), 90.0],     # 小腿外→脚外：竖直
	17: [Vector2(-4.8, 65.8), 90.0],    # 大腿内→小腿内：竖直
	11: [Vector2(-16.9, 66.9), 90.0],   # 小腿内→脚内：竖直
}

var _outdir: String = "user://relax_pose"
var _pose: String = "idle"
var _ik: String = "off"
var _verbose: bool = false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--outdir="):
			_outdir = arg.trim_prefix("--outdir=")
		elif arg.begins_with("--pose="):
			_pose = arg.trim_prefix("--pose=")
		elif arg.begins_with("--ik="):
			_ik = arg.trim_prefix("--ik=")
		elif arg == "--verbose":
			_verbose = true
	DirAccess.make_dir_recursive_absolute(_outdir)
	# 关程序化叠加层（setup 在 rig._ready 里连接 process_frame，每帧绝对复位
	# hip/torso/head 旋转——静态基线不要任何摆动）
	_OverlayScript.ENABLED = false

	var rig_root: Node2D = _RigScene.instantiate()
	rig_root.set_script(null)  # 剥离 legacy WASD 测试驱动（位置/Marker 同步不再跑）
	rig_root.scale = Vector2(RIG_SCALE, RIG_SCALE)
	rig_root.position = Vector2(960.0, 735.0)  # 髋部原点
	add_child(rig_root)

	var rig: Skeleton2D = rig_root.find_child("StickmanRig", true, false) as Skeleton2D
	var at: AnimationTree = rig.find_child("AnimationTree", true, false) as AnimationTree
	if at != null:
		at.active = false  # 不走状态机：直接驱动 AnimationPlayer，行为更确定

	# 等 _ready 与 call_deferred 的 IK 延迟启用走完再关（实测不参与解算，
	# 关掉只为消除变量；--ik=on 可对照）
	await _frames(2)
	var bones: Dictionary = rig.get("_bones") if "_bones" in rig else {}
	if _ik != "on":
		var stack: SkeletonModificationStack2D = rig.get_modification_stack()
		if stack != null:
			stack.enabled = false

	# 复位 rest（IK 短暂启用的两帧内可能已拽动腿臂），再摆姿态
	for id in bones:
		var b: Bone2D = bones[id]
		if b is Bone2D:
			(b as Bone2D).transform = (b as Bone2D).rest
	match _pose:
		"rest":
			_freeze_anim(rig, "")
		"hang":
			_freeze_anim(rig, "")
			_pose_hang(bones)
		_:
			_freeze_anim(rig, "idle")

	for f in 6:
		await get_tree().process_frame
	# 结算完成后再 dump（动画 seek 与摆姿都已落定，才是渲染所见）
	if _verbose:
		var stack_chk: SkeletonModificationStack2D = rig.get_modification_stack()
		print("[relax] ik_stack enabled=%s mods=%s" % [
			str(stack_chk != null and stack_chk.enabled),
			str(stack_chk.modification_count) if stack_chk != null else "null"])
		_dump_bones(bones)
	await _shoot()
	get_tree().quit(0)


## 冻结动画：anim_name 为空 = 不播（纯 rest）；否则停在 idle 第 0 帧（速度归零）。
func _freeze_anim(rig: Skeleton2D, anim_name: String) -> void:
	var ap := rig.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		push_warning("[RelaxPose] AnimationPlayer 缺失")
		return
	ap.speed_scale = 0.0
	if anim_name.is_empty():
		ap.stop()
		return
	if not ap.has_animation(anim_name):
		push_warning("[RelaxPose] 动画不存在: %s（回退纯 rest）" % anim_name)
		ap.stop()
		return
	ap.play(anim_name)
	ap.seek(0.0, true)


## 对称垂放直腿站姿：把"该骨到主子骨的链方向"转到 HANG_CHAIN 目标角。
## 链方向 = 子骨偏移角 + 骨骼全局旋转（rest 旋转全 0、方向烤在偏移里的正确
## 语义）；先父后子（父骨转动会改变子骨链方向基准，须按序重算）。
func _pose_hang(bones: Dictionary) -> void:
	for id in HANG_CHAIN:
		var cfg: Array = HANG_CHAIN[id]
		var b := bones.get(id) as Bone2D
		if b == null:
			push_warning("[RelaxPose] 骨骼 %d 缺失" % id)
			continue
		var cur: float = b.global_rotation + (cfg[0] as Vector2).angle()
		b.rotation += deg_to_rad(cfg[1]) - cur


func _dump_bones(bones: Dictionary) -> void:
	var names: Dictionary = _SkeletonScript.BONE_NAMES
	for id in [0, 21, 6, 22, 7, 9, 10, 16, 3, 4, 17, 11, 18, 1, 19, 14]:
		var b: Bone2D = bones.get(id)
		if b == null or not (b is Bone2D):
			continue
		var bb := b as Bone2D
		print("[relax] %3d %-16s grot=%7.2f° gpos=%v" % [
			id, str(names.get(id, "?")), rad_to_deg(bb.global_rotation), bb.global_position])


func _shoot() -> void:
	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	# 机位按站姿几何（世界坐标 = (960,735) + 0.5×骨局部坐标）：
	# 头圆心≈(971,684) 肩点≈(969,690) 髋(960,735) 脚≈(974,800)
	for shot in [
		{"name": "relax_full", "zoom": 1.2, "pos": Vector2(965, 685)},
		{"name": "relax_head", "zoom": 5.0, "pos": Vector2(971, 684)},
		{"name": "relax_torso", "zoom": 3.0, "pos": Vector2(966, 700)},
		{"name": "relax_legs", "zoom": 3.0, "pos": Vector2(967, 772)},
		{"name": "relax_shoulder", "zoom": 6.0, "pos": Vector2(969, 691)},
	]:
		cam.zoom = Vector2(shot["zoom"], shot["zoom"])
		cam.position = shot["pos"]
		await _frames(3)
		var img: Image = get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [_outdir, shot["name"]]
		var err := img.save_png(path)
		print("[RelaxPose] %s (err=%d)" % [path, err])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
