extends Node
## 武器持握画面验收截图工具（裸骨架直出，对照 tools/render_swl_ref.py 忠实参考帧）。
##
## 为什么用裸骨架：StickmanSkeleton.build_from_scratch 与 dump_rig_pose.gd 同款
## （rest=全骨世界角 0，正是 weapon_mount 挂载公式假设的"挂载帧"），且不依赖
## autoload/物理帧/AnimationTree，截图可复现性最好。
##
## [已结案] 曾登记的"实体在独立场景下全身渲染横躺 ~90°"（骨骼 global_transform
## 打印直立、渲染却横躺，伴随 "Using transform rotation for bone angle" 刷屏）
## 根因链（2026-09-03 排查结论，最小复现见 tools/baking/diag_entity_pose_root.tscn）：
##   1. 骨链重排（fd95bf6，新增 spine_root/chest_mid/weapon_hand/shield_hand，共 23 骨）
##      后，stickman_test.tscn 的**腿 IK NodePath 仍指向旧链**（"spine_root/thigh_outer"，
##      缺 hip/ 前缀）→ 运行时解析失败；
##   2. StickmanRig._init_ik 对解析失败的修改器只告警、不处理 → tscn 里写死的
##      残留 joint_bone_idx (0,1)/(3,4) 继续生效——在新骨链里 0=hip、1=spine_root，
##      即**腿 IK 把根骨 hip 拽向脚部 IK 目标** → 全身绕 hip 旋转 ~90° 横躺；
##   3. "打印直立、渲染横躺"的表象是引擎机制：Skeleton2D 修改器在骨架内部
##      process 阶段以 local_pose_override 写入 Bone2D 渲染变换，常规 process
##      阶段又从 cache_transform 还原（Godot skeleton_2d.cpp
##      execute_modifications，非持久 override）——常规阶段采样的
##      global_transform 永远是"未解算"的直立值，渲染看到的才是 override 后姿态；
##   4. "Using transform rotation for bone angle" 刷屏是另一独立小问题（骨
##      auto_calculate=true 时无 Bone2D 子骨的骨在构建期告警，见 Bone2D
##      calculate_length_and_rotation），与横躺无因果，已由 build_from_scratch
##      显式 auto_calculate=false 消除；
##   5. 当时"播 idle/不播动画/关 IK 三配置均横躺"的原因：动画 .tres 轨道路径
##      同批失效（idle 实际没播）；外部关 IK 会被 rig._init_ik 的 call_deferred
##      重新启用（配置没真正关上）。
## 修复：d63fc57（腿 IK 路径补 hip/ 前缀 + auto_calculate=false）已在主路径消除
## 症状；_init_ik 加固为"NodePath 解析失败的修改器整条移除"（防同类静默劫持复发）。
## 实体管线独立场景渲染已验证直立（diag_entity_pose_root 三探针对照）。
## 本工具保留裸骨架直出（可复现性最好），不再是对 bug 的绕开。
##
## 输出 stick-world/tools/baking/_faithful/shot_*.png：
##   ① C 实验：剑 4 候选 Sprite.rotation = C + 46.85；
##   ② 六件武器正式截图（数据取各 weapon_*.tscn 现值）。
## 运行：GODOT --path stick-world res://tools/baking/render_weapon_check.tscn

const Skeleton := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")
const WEAPON_DIR := "res://modules/units/scenes/components/"

const OUT_DIR := "res://tools/baking/_faithful"
const RIG_POS := Vector2(560, 420)
const RIG_SCALE := 1.6

func _ready() -> void:
	await _run()
	get_tree().quit(0)


func _run() -> void:
	for c: int in [0, 90, -90, 180]:
		await _shoot("weapon_sword.tscn", "cand_sword_c%d" % c, float(c))
	await _shoot("weapon_sword.tscn", "sword")
	await _shoot("weapon_spear.tscn", "spear")
	await _shoot("weapon_bow.tscn", "bow")
	await _shoot("weapon_pickaxe.tscn", "pickaxe")
	await _shoot("weapon_magicstaff.tscn", "magicstaff")
	await _shoot("weapon_shield.tscn", "shield")
	print("=== 全部截图完成 ===")


## 裸骨架 + 手骨原点标记 + 武器场景挂 weapon_hand/shield_hand，截图。
## c_override 非空时覆盖剑 Sprite.rotation = c_override + 46.85（C 候选形式），
## 并按 weapon_mount._mount_one 同款公式重摆 instance.position。
func _shoot(scene_name: String, tag: String, c_override: float = NAN) -> void:
	var world := Node2D.new()
	add_child(world)
	var bg := ColorRect.new()
	bg.color = Color(0.27, 0.27, 0.27)
	bg.size = Vector2(4000, 4000)
	bg.position = Vector2(-1000, -1000)
	# 武器 z_index=-2（z_as_relative=false，绝对层级），背景必须更低否则盖住武器
	bg.z_index = -100
	world.add_child(bg)

	var root := Node2D.new()
	world.add_child(root)
	root.position = RIG_POS
	root.scale = Vector2(RIG_SCALE, RIG_SCALE)
	var skel := Skeleton2D.new()
	root.add_child(skel)
	Skeleton.build_from_scratch(skel)

	var weapon_path := WEAPON_DIR + scene_name
	var scene: PackedScene = load(weapon_path)
	if scene == null:
		printerr("场景加载失败: " + weapon_path)
		get_tree().quit(1)
		return
	var inst: Node2D = scene.instantiate()
	var spr := inst.get_node("Sprite") as Sprite2D
	var grip := inst.get_node("GripPoint") as Marker2D
	if not is_nan(c_override):
		spr.rotation = deg_to_rad(c_override + 46.85)
	inst.position = -(grip.position * spr.scale).rotated(spr.rotation)
	inst.z_index = -2
	inst.z_as_relative = false
	var bone_path := "hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner/forearm_inner/hand_inner/weapon_hand"
	if scene_name == "weapon_shield.tscn":
		bone_path = "hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_outer/forearm_outer/hand_outer/shield_hand"
	var bone: Node2D = skel.get_node_or_null(bone_path)
	if bone == null:
		printerr("挂载骨不存在: " + bone_path)
		get_tree().quit(1)
		return
	bone.add_child(inst)
	print("%s 挂载骨世界角=%.2f° Sprite.rotation=%.2f°" % [
		tag, rad_to_deg(bone.global_rotation), rad_to_deg(spr.rotation)])
	# 手骨原点标记（对照参考帧的橙色手位点）
	var marker := ColorRect.new()
	marker.color = Color(1.0, 0.63, 0.16)
	marker.size = Vector2(7, 7)
	marker.position = bone.global_position - Vector2(3.5, 3.5)
	marker.z_index = 50
	world.add_child(marker)

	for i in 4:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var out := OUT_DIR + "/shot_%s.png" % tag
	img.save_png(out)
	print("saved ", out)
	world.queue_free()
	await get_tree().process_frame
