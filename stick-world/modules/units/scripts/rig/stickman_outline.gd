class_name StickmanOutline
extends RefCounted
## 火柴人邻接融合描边系统
##
## ID Buffer + 非传递邻接表：
## - 每个零件 part_id 编码到 alpha 通道（ID Pass）
## - Outline Pass 解码 ID，查邻接表判定融合/分隔
## - "相邻"不传递：A↔B、B↔C 相邻不代表 A↔C 相邻

const ID_SHADER := preload("res://modules/units/shaders/stickman_outline_id.gdshader")
const OUTLINE_SHADER := preload("res://modules/units/shaders/stickman_outline.gdshader")
const TextureGen := preload("res://modules/units/scripts/rig/stickman_texture_gen.gd")

## 零件 ID -> 贴图键映射；14=未分类前景（武器等，与一切不相邻），15=肩甲补丁
const PART_MISC := 14
const PART_SHOULDER := 15
## 肩甲补丁直径（逻辑像素，盖住肩关节融合区）
const SHOULDER_PATCH_DIAMETER := 30.0

const SPRITE_TO_PART_ID := {
	6: 0, 7: 1, 8: 2, 10: 3,
	1: 4, 2: 5, 14: 6, 15: 7,
	3: 8, 4: 9, 5: 10, 11: 11, 12: 12, 13: 13,
}

## 仅肢体链内部融合：躯干+头一条链、每条手臂/腿各自成链。
## 跨肢体重叠一律画分隔线（SWL 观感）；肩关节由肩甲补丁（PART_SHOULDER）
## 局部桥接融合，避免"整条手臂和腹部融成一团"。
const ADJACENCY := [
	[0, 1], [1, 2], [2, 3],        # 躯干链（髋-下躯干-上躯干-头）
	[4, 5], [6, 7],                # 手臂链（外/内大臂↔前臂）
	[8, 9], [9, 10],               # 外腿链
	[11, 12], [12, 13],            # 内腿链
	[15, 2],                       # 肩甲↔上躯干
	[15, 4], [15, 6],              # 肩甲↔外/内大臂
]


static func setup(group: CanvasGroup, sprites: Dictionary) -> void:
	if not is_instance_valid(group):
		return
	# 调整渲染顺序（必须在 _init_ik 之前执行，让 bone_idx 被正确修正）
	var rig := group.get_node_or_null("StickmanRig")
	if rig != null:
		# 腿移到躯干之前：外腿 -> 内腿 -> 躯干（腿不覆盖手臂）
		var hip := rig.get_node_or_null("hip")
		var thigh_outer := rig.get_node_or_null("thigh_outer")
		var thigh_inner := rig.get_node_or_null("thigh_inner")
		if hip != null and thigh_outer != null and thigh_inner != null:
			rig.move_child(thigh_outer, 0)
			rig.move_child(thigh_inner, 1)
		# 头移到手臂之后：颈部段 -> 内臂 -> 外臂 -> 头
		var upper_torso := rig.get_node_or_null("hip/lower_torso/upper_torso")
		if upper_torso != null:
			# 交换手臂顺序：inner 先渲染，outer 后渲染（outer 覆盖 inner）
			var arm_outer := upper_torso.get_node_or_null("upper_arm_outer")
			var arm_inner := upper_torso.get_node_or_null("upper_arm_inner")
			if arm_outer != null and arm_inner != null:
				upper_torso.move_child(arm_inner, arm_outer.get_index())
			var neck := upper_torso.get_node_or_null("neck")
			if neck != null:
				upper_torso.move_child(neck, -1)
	for sprite_id in sprites.keys():
		var part_id: int = SPRITE_TO_PART_ID.get(sprite_id, PART_MISC)
		var sprite: Sprite2D = sprites[sprite_id]
		if not is_instance_valid(sprite):
			continue
		var mat := ShaderMaterial.new()
		mat.shader = ID_SHADER
		mat.set_shader_parameter("part_id", part_id)
		sprite.material = mat
	# 肩甲补丁要在 _scan_and_assign_id 之前创建（自带 part_id 材质，不被扫成 14）
	if rig != null:
		_create_shoulder_patches(rig)
	_scan_and_assign_id(group)
	var outline_mat := ShaderMaterial.new()
	outline_mat.shader = OUTLINE_SHADER
	outline_mat.set_shader_parameter("outline_color", Color.WHITE)
	outline_mat.set_shader_parameter("outline_width", 1.5)
	outline_mat.set_shader_parameter("adj_tex", _build_adjacency_texture())
	group.material = outline_mat


static func _scan_and_assign_id(node: Node) -> void:
	if node is Sprite2D:
		var sprite := node as Sprite2D
		if sprite.material == null:
			var mat := ShaderMaterial.new()
			mat.shader = ID_SHADER
			mat.set_shader_parameter("part_id", PART_MISC)
			sprite.material = mat
	for child in node.get_children():
		_scan_and_assign_id(child)


## 肩甲补丁：小圆盘挂上臂骨骼原点（肩关节），part_id=PART_SHOULDER。
## 与躯干、大臂都相邻 → 关节处融合无分隔线；手臂与腹部交叉处仍画线。
## 注意：body_color 运行时改动不会刷新补丁颜色（补丁纹理一次性生成）。
static func _create_shoulder_patches(rig: Node) -> void:
	var color: Color = rig.get("body_color") if rig.get("body_color") != null \
			else Color(0.82, 0.82, 0.85)
	var d := int(SHOULDER_PATCH_DIAMETER)
	var tex := TextureGen.generate(TextureGen.Type.CIRCLE, d, d / 2, color)
	for arm_path in ["hip/lower_torso/upper_torso/upper_arm_outer",
			"hip/lower_torso/upper_torso/upper_arm_inner"]:
		var arm := rig.get_node_or_null(arm_path) as Bone2D
		if arm == null:
			continue
		var patch := Sprite2D.new()
		patch.name = "ShoulderPatch"
		patch.texture = tex
		patch.scale = Vector2(1.0 / TextureGen.OUTPUT_SCALE, 1.0 / TextureGen.OUTPUT_SCALE)
		var mat := ShaderMaterial.new()
		mat.shader = ID_SHADER
		mat.set_shader_parameter("part_id", PART_SHOULDER)
		patch.material = mat
		arm.add_child(patch)


static func _build_adjacency_texture() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_R8)
	img.fill(Color(0.0, 0.0, 0.0, 1.0))
	for pair in ADJACENCY:
		var a: int = pair[0]
		var b: int = pair[1]
		img.set_pixel(a, b, Color(1.0, 0.0, 0.0, 1.0))
		img.set_pixel(b, a, Color(1.0, 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(img)
