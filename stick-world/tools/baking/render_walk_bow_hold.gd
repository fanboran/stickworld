extends SceneTree
## walk_bow_hold 拉弓保持姿态行走验收渲染：三相位一行（不同迈步相位、上身恒拉满）。
##
## 渲染通道与游戏一致：walk_bow_hold 经 set_state_anim("walk", …) 换入 walk state
## 资源（持弓行走无独立状态节点，与 walk_bow 同机制），AnimationTree.advance 手动
## 推相位定帧（LOD 驱动同通道）；挂弓口径同 WeaponMount/char_sprite_3d。
##
## 出图：temp/观察场AI验收/动画/walk_bow_hold.png（worktree 根相对 res://../）
## 运行：godot --path <工程> --script res://tools/baking/render_walk_bow_hold.gd
## 覆盖输出目录：-- --out=<绝对路径>

const RIG_SCENE := "res://modules/stick_rig/scenes/stickman_test.tscn"
const BOW_SCENE := "res://modules/stick_rig/scenes/components/weapon_bow.tscn"
const HAND_BONE := "hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner/forearm_inner/hand_inner/weapon_hand"
## 摆位锚（脚底骨骼墨迹基准，取 char_sprite_3d 同款值）
const FOOT_ANCHOR := Vector2(3.0, 141.0)
const RIG_SCALE := 0.9

## 迈步三相位（walk_bow_hold 时长 1.6667s 循环：跨步中段/换步/后段）
const PHASES := [0.25, 0.7, 1.1]

var _out_dir := ""


func _initialize() -> void:
	_out_dir = _parse_out_arg()
	if _out_dir.is_empty():
		_out_dir = ProjectSettings.globalize_path("res://../temp/观察场AI验收/动画")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_run()


func _run() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1560, 640)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)
	var world := Node2D.new()
	sub.add_child(world)
	var bg := ColorRect.new()
	bg.color = Color(0.32, 0.34, 0.38)
	bg.size = Vector2(1560, 640)
	world.add_child(bg)
	var ground := ColorRect.new()
	ground.color = Color(0.45, 0.52, 0.34)
	ground.position = Vector2(0, 520)
	ground.size = Vector2(1560, 120)
	world.add_child(ground)

	for i in PHASES.size():
		await _spawn_bowman(world, Vector2(280.0 + 500.0 * i, 500.0), float(PHASES[i]))
	for i in 10:
		await process_frame
	sub.get_texture().get_image().save_png(_out_dir + "/walk_bow_hold.png")
	print("[render_walk_bow_hold] saved walk_bow_hold.png")
	quit(0)


## 生成一个挂弓火柴人，walk state 换装 walk_bow_hold 后定帧在 t 秒。
## 骨架在入树一帧后才建好（_init_bones 走 _ready），挂弓须 await 之后；
## 定帧手法 = 停自动推进（set_anim_update_hz(0)）+ AnimationTree.advance 手动推相位。
func _spawn_bowman(world: Node2D, foot_pos: Vector2, t: float) -> void:
	var inst: Node = (load(RIG_SCENE) as PackedScene).instantiate()
	inst.set_script(null)
	world.add_child(inst)
	(inst as Node2D).position = foot_pos - FOOT_ANCHOR * RIG_SCALE
	await process_frame
	var rig: Node2D = inst.get_node("OutlineGroup/StickmanRig")
	rig.scale = Vector2(RIG_SCALE, RIG_SCALE)
	# 挂弓（GripPoint 对齐握把，口径同 WeaponMount._mount_one / char_sprite_3d）
	var bow: Node2D = (load(BOW_SCENE) as PackedScene).instantiate()
	var grip := bow.get_node_or_null("GripPoint") as Marker2D
	var spr := bow.get_node_or_null("Sprite") as Sprite2D
	if grip != null and spr != null:
		bow.position = -(grip.position * spr.scale).rotated(spr.rotation)
	var bone: Node2D = rig.get_node_or_null(HAND_BONE)
	if bone != null:
		bone.add_child(bow)
	else:
		bow.queue_free()
		push_warning("[render_walk_bow_hold] 手骨未找到，弓未挂载")
	# 走游戏同款换装通道：walk state 资源 → walk_bow_hold（实体侧/镜像层同机制）
	if rig.has_method("set_state_anim"):
		var swapped: bool = rig.set_state_anim("walk", "walk_bow_hold")
		if not swapped:
			push_warning("[render_walk_bow_hold] walk state 换装 walk_bow_hold 失败（未入库？）")
	rig.play("walk")
	rig.set_anim_update_hz(0.0)
	var tree: AnimationTree = rig.get_node_or_null("AnimationTree")
	if tree != null:
		# Godot 4.7 状态机坑（实测，多实例渲染必现）：经 play() 的 travel 首次
		# advance 会被"Start 重置"吞掉（骨骼全 0），补推一次相位又归零，跨实例
		# 表现还不确定。绕开 travel：playback.start("walk") 直启 + advance(t)×2
		# ——首推落起步帧、次推精确落到 t 相位（探针实测 thigh 误差 <0.002rad）。
		var pb: AnimationNodeStateMachinePlayback = tree.get("parameters/playback")
		if pb != null:
			pb.start("walk")
		tree.advance(t)
		tree.advance(t)
	# 相位标注（ASCII，默认字体无中文字形）
	var label := Label.new()
	label.text = "walk_bow_hold  t=%.2fs" % t
	label.position = foot_pos + Vector2(-100, 18)
	world.add_child(label)


static func _parse_out_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return ""
