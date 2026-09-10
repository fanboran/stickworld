extends Node
## 标准放松站姿检查场景（dev）：**裸 rig**——不经过 StickmanEntity（实体侧有
## 每帧重置骨骼的覆写源，已用探针实锤 bone21 摆姿后被强制回 rest），直接实例化
## stickman_test.tscn 并剥离 legacy 驱动脚本：无武器、无 AI、无动画，骨骼摆好
## 什么姿势就渲染什么姿势。
## 运行：
##   godot --path stick-world res://tests/dev/stickman_relaxed_pose.tscn -- --outdir=<目录>

const _RigScene: PackedScene = preload("res://modules/units/scenes/stickman_test.tscn")
## 与实体渲染同规格（game_root BASE_SCALE）
const RIG_SCALE := 0.5

var _outdir: String = "user://relax_pose"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--outdir="):
			_outdir = arg.trim_prefix("--outdir=")
	DirAccess.make_dir_recursive_absolute(_outdir)

	var rig_root: Node2D = _RigScene.instantiate()
	rig_root.set_script(null)  # 剥离 legacy WASD 测试驱动
	rig_root.scale = Vector2(RIG_SCALE, RIG_SCALE)
	rig_root.position = Vector2(960.0, 735.0)  # 髋部原点，脚 ≈800
	add_child(rig_root)

	var rig: Node = rig_root.find_child("StickmanRig", true, false)
	var at: AnimationTree = rig.find_child("AnimationTree", true, false) if rig != null else null
	if at != null:
		at.active = false
	if rig.has_method("set_anim_paused"):
		rig.set_anim_paused(true)
	var bones: Dictionary = rig.get("_bones") if "_bones" in rig else {}
	for id in bones:
		var b: Bone2D = bones[id]
		if b is Bone2D:
			(b as Bone2D).transform = (b as Bone2D).rest
	_pose_relaxed(bones)

	for f in 12:
		await get_tree().process_frame
	await _shoot()
	get_tree().quit(0)


## 放松站姿：脊柱链立直（bind pose 本身前倾，idle 动画才立起来）、双臂垂放
## 体侧微弯、双腿微分直立。先父后子逐链摆；_aim 用世界角差量。
func _pose_relaxed(bones: Dictionary) -> void:
	_aim(bones, 21, -PI / 2.0)         # spine_root：脊柱立直
	_aim(bones, 22, -PI / 2.0)         # chest_mid
	_aim(bones, 7, -PI / 2.0)          # upper_torso
	_aim(bones, 9, -PI / 2.0)          # neck
	_aim(bones, 18, PI / 2.0 + 0.18)   # 上臂外：垂下微外张
	_aim(bones, 19, PI / 2.0 - 0.04)   # 上臂内：垂下贴体
	_aim(bones, 1, PI / 2.0 + 0.10)    # 前臂外：微弯
	_aim(bones, 14, PI / 2.0 - 0.06)   # 前臂内：微弯
	_aim(bones, 16, PI / 2.0 + 0.05)   # 大腿外
	_aim(bones, 17, PI / 2.0 - 0.05)   # 大腿内
	_aim(bones, 3, PI / 2.0)           # 小腿外：直
	_aim(bones, 11, PI / 2.0)          # 小腿内：直


## 把骨骼的世界朝向转到 target_angle（骨骼基准轴 = 局部 +x）
func _aim(bones: Dictionary, id: int, target_angle: float) -> void:
	var b: Bone2D = bones.get(id)
	if b == null or not (b is Bone2D):
		push_warning("[RelaxPose] 骨骼 %d 缺失" % id)
		return
	var delta := wrapf(target_angle - b.global_rotation, -PI, PI)
	b.rotation += delta


func _shoot() -> void:
	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	for shot in [
		{"name": "relax_full", "zoom": 1.4, "pos": Vector2(960, 660)},
		{"name": "relax_head", "zoom": 5.0, "pos": Vector2(960, 630)},
		{"name": "relax_torso", "zoom": 3.0, "pos": Vector2(960, 700)},
		{"name": "relax_legs", "zoom": 3.0, "pos": Vector2(960, 760)},
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
