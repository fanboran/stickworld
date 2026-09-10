extends Node
## 标准站姿检查场景（dev）：**裸 rig**——不经过 StickmanEntity，直接实例化
## stickman_test.tscn 并剥离 legacy WASD 驱动脚本：无武器、无 AI、无输入。
##
## 批次 B（2026-09-10 渲染重标）后：骨架 = 真 Spine 数据（SpineSkeletonData.BONES
## 56 骨，rest=setup 姿态；髋骨由合成锚点骨 RigRoot 对到 rig 原点）。本场景是
## 批次 B 的验收工具——与真值骨骼线（tools/render_spine_bones.py）并排比对。
##
## 姿态档：
##   idle（默认）= 播真 Spine 站姿冻结 t=0（游戏内自然站姿）
##   hang = 双腿双臂按链方向直摆（对称垂放诊断档）
##   rest = 纯 setup 姿态（不播动画）
## 运行：
##   godot --path stick-world res://tests/dev/stickman_relaxed_pose.tscn --
##     --outdir=<目录> [--pose=idle|hang|rest] [--verbose]

const _RigScene: PackedScene = preload("res://modules/units/scenes/stickman_test.tscn")
const _OverlayScript := preload("res://modules/units/scripts/rig/procedural_overlay.gd")
const _SkeletonScript := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")
const _AnimsScript := preload("res://modules/units/scripts/rig/stickman_anims.gd")
## 与实体渲染同规格（stickman_entity.BASE_SCALE，批次 B 锚定值）
const RIG_SCALE := 0.3468

## hang 诊断档：骨名 → 目标链方向（全局屏幕角，度；90°=竖直向下）。
## 顺序 = 先父后子（父骨转动会改变子骨的全局角基准）。
const HANG_CHAIN: Array = [
	["minerarm1", 96.0], ["minerarm2", 92.0],
	["minerarm3", 84.0], ["minerarm4", 88.0],
	["minerleg2", 90.0], ["minerleg1", 90.0],
	["minerleg4", 90.0], ["minerleg3", 90.0],
]

## --verbose 逐骨 dump 的骨名（躯干轴 / 四肢链）
const DUMP_BONES: Array = [
	"bone", "minertorso1", "bone2", "bone3", "minerhead1",
	"minerarm1", "minerarm2", "minerarm3", "minerarm4",
	"minerleg2", "minerleg1", "minerfoot1",
	"minerleg4", "minerleg3", "minerfoot2",
]

var _outdir: String = "user://relax_pose"
var _pose: String = "idle"
var _verbose: bool = false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--outdir="):
			_outdir = arg.trim_prefix("--outdir=")
		elif arg.begins_with("--pose="):
			_pose = arg.trim_prefix("--pose=")
		elif arg.begins_with("--ik="):
			pass
		elif arg == "--verbose":
			_verbose = true
	DirAccess.make_dir_recursive_absolute(_outdir)
	# 关程序化叠加层（setup 在 rig._ready 里连接 process_frame，每帧叠加
	# hip/torso/head 旋转——静态基线不要任何摆动）
	_OverlayScript.ENABLED = false

	var rig_root: Node2D = _RigScene.instantiate()
	rig_root.set_script(null)  # 剥离 legacy WASD 测试驱动
	rig_root.scale = Vector2(RIG_SCALE, RIG_SCALE)
	rig_root.position = Vector2(960.0, 735.0)  # 髋部原点
	add_child(rig_root)

	var rig: Skeleton2D = rig_root.find_child("StickmanRig", true, false) as Skeleton2D
	var at: AnimationTree = rig.find_child("AnimationTree", true, false) as AnimationTree
	if at != null:
		at.active = false  # 不走状态机：直接驱动 AnimationPlayer，行为更确定

	for f in 2:
		await get_tree().process_frame
	var bones: Dictionary = rig.get("_bones") if "_bones" in rig else {}

	# 复位 setup（rest）姿态，再摆姿态
	for key in bones:
		var b: Bone2D = bones[key]
		if b is Bone2D:
			(b as Bone2D).transform = (b as Bone2D).rest
	match _pose:
		"rest":
			_freeze_anim(rig, "")
		"hang":
			_freeze_anim(rig, "")
			_pose_hang(bones)
		_:
			# idle = 游戏默认站姿（真 Spine 的 Swordwrath-Stand1，按游戏动作名入库）
			_freeze_anim(rig, "idle")

	for f in 6:
		await get_tree().process_frame
	if _verbose:
		print("[relax] pose=%s 骨数=%d" % [_pose, bones.size()])
		_dump_bones(bones)
	await _shoot(bones)
	get_tree().quit(0)


## 冻结动画：anim_name 为空 = 不播（纯 setup 姿态）；否则停在 t=0（速度归零）
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
		push_warning("[RelaxPose] 动画不存在: %s（回退纯 setup 姿态）" % anim_name)
		ap.stop()
		return
	ap.play(anim_name)
	ap.seek(0.0, true)


## 对称垂放直腿：把各骨的全局方向（= 骨骼 +x 轴）转到 HANG_CHAIN 目标角。
## 真 Spine 语义下骨骼 +x 轴即肢体方向，故直接改全局角即可；先父后子。
func _pose_hang(bones: Dictionary) -> void:
	for entry in HANG_CHAIN:
		var b := bones.get(entry[0]) as Bone2D
		if b == null:
			push_warning("[RelaxPose] 骨骼缺失: %s" % entry[0])
			continue
		b.rotation += deg_to_rad(float(entry[1])) - b.global_rotation


func _dump_bones(bones: Dictionary) -> void:
	for name in DUMP_BONES:
		var b: Bone2D = bones.get(name)
		if b == null:
			print("[relax] %-14s 缺失" % name)
			continue
		print("[relax] %-14s grot=%8.2f° gpos=(%.1f, %.1f)" % [
			name, rad_to_deg(b.global_rotation), b.global_position.x, b.global_position.y])


## 截图机位由**实际骨骼全局位置**推导（自适应几何变化，不再硬编码坐标）
func _shoot(bones: Dictionary) -> void:
	var hip := _bone_pos(bones, "bone", Vector2(960.0, 735.0))
	var head := _bone_pos(bones, "minerhead1", hip + Vector2(0, -60))
	var torso := _bone_pos(bones, "minertorso1", hip + Vector2(0, -20))
	var foot := _bone_pos(bones, "minerfoot1", hip + Vector2(0, 65))
	var shoulder := _bone_pos(bones, "minerarm1", hip + Vector2(0, -45))
	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	for shot in [
		{"name": "relax_full", "zoom": 1.2, "pos": (hip + head) * 0.5 + Vector2(0, 6)},
		{"name": "relax_head", "zoom": 5.0, "pos": head + Vector2(0, -6)},
		{"name": "relax_torso", "zoom": 3.0, "pos": torso},
		{"name": "relax_legs", "zoom": 3.0, "pos": (hip + foot) * 0.5},
		{"name": "relax_shoulder", "zoom": 6.0, "pos": shoulder},
	]:
		cam.zoom = Vector2(shot["zoom"], shot["zoom"])
		cam.position = shot["pos"]
		await _frames(3)
		var img: Image = get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [_outdir, shot["name"]]
		var err := img.save_png(path)
		print("[RelaxPose] %s (err=%d)" % [path, err])


func _bone_pos(bones: Dictionary, name: String, fallback: Vector2) -> Vector2:
	var b := bones.get(name) as Node2D
	return b.global_position if b != null else fallback


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
