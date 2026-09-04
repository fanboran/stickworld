extends Node
## 诊断（根视口版）：独立场景=本场景作为主场景直接运行（root viewport + stretch），
## 复现 render_weapon_check 08-30 观察环境。同窗并排：
##   左：独立实例化 stickman_entity.tscn（实体管线，登记问题现场）
##   右：裸 Skeleton2D + build_from_scratch（已知直立对照）
## 截图根视口 + 分区域像素包围盒 + 骨骼变换全量打印。
## 运行：GODOT --path stick-world res://tools/baking/diag_entity_pose_root.tscn（非 headless）

const Skeleton := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")
const ENTITY_SCENE := preload("res://modules/units/scenes/stickman_entity.tscn")

const OUT_DIR := "res://tools/baking/_faithful"
const BG_COLOR := Color(0.12, 0.12, 0.14)

var _entity: Node2D
var _entity_rig: Node2D
var _bare_root: Node2D
var _bare_skel: Node2D
var _no_ik_entity: Node2D


func _ready() -> void:
	await _run()
	get_tree().quit(0)


func _run() -> void:
	# 左：实体管线
	_entity = ENTITY_SCENE.instantiate()
	add_child(_entity)
	_entity.position = Vector2(400, 500)
	_entity_rig = _entity.get_node("RigHost/OutlineGroup/StickmanRig")
	# 右：裸骨架（缩放对齐实体 BASE_SCALE=0.5）
	_bare_root = Node2D.new()
	_bare_root.name = "BareRoot"
	add_child(_bare_root)
	_bare_root.position = Vector2(1000, 500)
	_bare_root.scale = Vector2(0.5, 0.5)
	_bare_skel = Skeleton2D.new()
	_bare_root.add_child(_bare_skel)
	Skeleton.build_from_scratch(_bare_skel)
	# 中右：实体但移除 IK 栈（因果链验证：若横躺由 IK 驱动，去掉栈应直立）
	var no_ik := ENTITY_SCENE.instantiate()
	add_child(no_ik)
	no_ik.position = Vector2(1400, 500)
	(no_ik.get_node("RigHost/OutlineGroup/StickmanRig") as Skeleton2D).set_modification_stack(null)
	_no_ik_entity = no_ik

	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.size = Vector2(4000, 4000)
	bg.position = Vector2(-1000, -1000)
	bg.z_index = -100
	bg.z_as_relative = false
	add_child(bg)
	move_child(bg, 0)

	for i in 30:
		await get_tree().process_frame
		if i < 12:
			var head := _entity_rig.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso/neck/head") as Node2D
			var hip := _entity_rig.get_node_or_null("hip") as Node2D
			if head != null and hip != null:
				print("f%02d hip g_rot=%8.3f head g_rot=%8.3f rig g_rot=%8.3f" % [
					i, rad_to_deg(hip.global_rotation), rad_to_deg(head.global_rotation),
					rad_to_deg(_entity_rig.global_rotation)])

	_dump_skeleton("ROOT_entity", _entity_rig)
	_dump_skeleton("ROOT_bare", _bare_skel)
	_dump_skeleton("ROOT_entity_no_ik", (_no_ik_entity.get_node("RigHost/OutlineGroup/StickmanRig") as Node2D))

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path := OUT_DIR + "/diag_pose_ROOT.png"
	var err := img.save_png(path)
	print("save_png(%s) err=%d" % [path, err])
	# 分区域像素包围盒（实体 x<700，裸骨架 700..1200，无IK实体 x>=1200）
	_pixel_bbox(img, "ROOT_entity", 0, 700)
	_pixel_bbox(img, "ROOT_bare", 700, 1200)
	_pixel_bbox(img, "ROOT_entity_no_ik", 1200, 2000)
	print("=== 根视口诊断完成 ===")


## 像素包围盒（x 区域内非背景像素）
func _pixel_bbox(img: Image, tag: String, x_from: int, x_to: int) -> void:
	var min_x := img.get_width()
	var max_x := -1
	var min_y := img.get_height()
	var max_y := -1
	for y in range(0, img.get_height(), 2):
		for x in range(x_from, mini(x_to, img.get_width()), 2):
			var c := img.get_pixel(x, y)
			if absf(c.r - BG_COLOR.r) > 0.05 or absf(c.g - BG_COLOR.g) > 0.05 \
					or absf(c.b - BG_COLOR.b) > 0.05:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	if max_x < 0:
		print("  [%s] 像素包围盒: 空" % tag)
		return
	var w := float(max_x - min_x)
	var h := float(max_y - min_y)
	print("  [%s] 像素包围盒: x[%d..%d] w=%.0f, y[%d..%d] h=%.0f  → %s" % [
		tag, min_x, max_x, w, min_y, max_y, h, "横躺(w>h)" if w > h else "直立(h>=w)"])


## 全量骨骼 dump：祖先链 + 逐骨变换 + 骨关节包围盒
func _dump_skeleton(tag: String, rig: Node2D) -> void:
	print("---- [%s] 骨架祖先链 ----" % tag)
	var chain: Array[Node] = []
	var n: Node = rig
	while n != null and n is Node2D:
		chain.push_front(n)
		n = n.get_parent()
	for node in chain:
		var n2d := node as Node2D
		print("  %s: g_rot=%9.3f rot=%9.3f scale=%s pos=%s" % [
			node.name, rad_to_deg(n2d.global_rotation), rad_to_deg(n2d.rotation),
			n2d.scale, n2d.position])
	print("---- [%s] Bone2D 逐骨 ----" % tag)
	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF
	var stack: Array[Node] = [rig]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for child in cur.get_children():
			stack.push_back(child)
		if cur is Bone2D:
			var b := cur as Bone2D
			var xf := b.global_transform
			min_x = minf(min_x, xf.origin.x)
			max_x = maxf(max_x, xf.origin.x)
			min_y = minf(min_y, xf.origin.y)
			max_y = maxf(max_y, xf.origin.y)
			print("  %-16s g_rot=%9.3f l_rot=%9.3f rest_rot=%9.3f g_pos=(%8.1f, %8.1f)" % [
				b.name, rad_to_deg(xf.get_rotation()), rad_to_deg(b.rotation),
				rad_to_deg(b.rest.get_rotation()), xf.origin.x, xf.origin.y])
	var w := max_x - min_x
	var h := max_y - min_y
	print("  [%s] 骨关节包围盒: x[%.1f..%.1f] w=%.1f, y[%.1f..%.1f] h=%.1f  → %s" % [
		tag, min_x, max_x, w, min_y, max_y, h, "横躺(w>h)" if w > h else "直立(h>=w)"])
