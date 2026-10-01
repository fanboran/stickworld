extends SceneTree
## 弓手动画验收渲染（2026-09-30 两缺陷修复对比图：持瞄没拉弓动作 / 持弓行走没脚步）。
##
## 出两张图到 temp/观察场AI验收/动画/（worktree 根相对 res://../）：
##   bow_aim_draw.png —— attack_bow_hold 持瞄拉弓段三相位（拉弦中程 / 近满弓 / 定格拉满）
##   bow_walk.png     —— walk_bow 持弓行走三相位（迈步周期，上肢保持持弓）
##
## 运行：godot --path <工程> --script res://tools/baking/render_bow_anims.gd
## 覆盖输出目录：-- --out=<绝对路径>

const RIG_SCENE := "res://modules/stick_rig/scenes/stickman_test.tscn"
const BOW_SCENE := "res://modules/stick_rig/scenes/components/weapon_bow.tscn"
const HAND_BONE := "hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner/forearm_inner/hand_inner/weapon_hand"
## 摆位锚（脚底骨骼墨迹基准，取 char_sprite_3d 同款值）
const FOOT_ANCHOR := Vector2(3.0, 141.0)
const RIG_SCALE := 0.9

var _out_dir := ""

const HOLD_PHASES := [0.18, 0.42, 1.5]
const WALK_PHASES := [0.25, 0.7, 1.1]


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

	# 第一张：持瞄拉弓段三相位
	for i in HOLD_PHASES.size():
		await _spawn_bowman(world, Vector2(280.0 + 500.0 * i, 500.0), "attack_bow_hold", float(HOLD_PHASES[i]))
	for i in 10:
		await process_frame
	sub.get_texture().get_image().save_png(_out_dir + "/bow_aim_draw.png")
	print("[render_bow_anims] saved bow_aim_draw.png")
	for c in world.get_children():
		if c != bg and c != ground:
			c.queue_free()
	await process_frame

	# 第二张：持弓行走三相位（walk_bow 走与游戏相同的 walk state 资源换装通道）
	for i in WALK_PHASES.size():
		await _spawn_bowman(world, Vector2(280.0 + 500.0 * i, 500.0), "walk_bow", float(WALK_PHASES[i]))
	for i in 10:
		await process_frame
	sub.get_texture().get_image().save_png(_out_dir + "/bow_walk.png")
	print("[render_bow_anims] saved bow_walk.png")
	quit(0)


## 生成一个挂弓火柴人，播 anim 后定帧在 t 秒。骨架在入树一帧后才建好
## （_init_bones 走 _ready），挂弓须 await 之后；定帧手法 = 停自动推进
## （set_anim_update_hz(0)）+ AnimationTree.advance 手动推相位（LOD 驱动同通道）。
func _spawn_bowman(world: Node2D, foot_pos: Vector2, anim: String, t: float) -> void:
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
		push_warning("[render_bow_anims] 手骨未找到，弓未挂载")
	if anim == "walk_bow":
		# 持弓行走不是独立状态：走游戏同款换装（walk state 资源 → walk_bow）
		# ——实体侧 WeaponMount._reload_weapons / 镜像层 char_sprite_3d 同一机制
		if rig.has_method("set_state_anim"):
			rig.set_state_anim("walk", "walk_bow")
		anim = "walk"
	rig.play(anim)
	rig.set_anim_update_hz(0.0)
	var tree: AnimationTree = rig.get_node_or_null("AnimationTree")
	if tree != null:
		tree.advance(t)
	# 相位标注（ASCII，默认字体无中文字形）
	var label := Label.new()
	label.text = "%s  t=%.2fs" % [anim, t]
	label.position = foot_pos + Vector2(-100, 18)
	world.add_child(label)


static func _parse_out_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return ""
