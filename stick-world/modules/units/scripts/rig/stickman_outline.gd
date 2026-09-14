class_name StickmanOutline
extends RefCounted
## 火柴人邻接融合描边系统（2026-09-14 从 Git 历史复活）
##
## 旧版（77bbfd35，位图时代）随矢量化整体删除；本版按创始人指令恢复观感、
## 适配现行矢量骨架：ID Buffer + 非传递邻接表机制原样保留——
## - 每个零件 part_id 编码到 alpha 通道（ID Pass，CanvasGroup 自身缓冲）
## - Outline Pass 解码 ID，查邻接表判定融合/分隔
## - "相邻"不传递：A↔B、B↔C 相邻不代表 A↔C 相邻
##
## 与旧版的映射差异：旧版按 14 个位图精灵逐件给 ID；现行矢量骨架按
## **骨骼名**归 6 组（躯干链/双臂/双腿 + 肩甲补丁），组内全融合、跨组
## 重叠画分隔线——观感等价（旧表内同链相邻对也全融合）。
##
## 生效范围：HD-2D 角色通道（char_sprite_3d 的 SubViewport，每角色独立
## 渲染，数量少，屏幕空间描边付得起）。2D 战场的批渲染路径不受影响。

const ID_SHADER := preload("res://modules/units/shaders/stickman_outline_id.gdshader")
const OUTLINE_SHADER := preload("res://modules/units/shaders/stickman_outline.gdshader")

## 零件组 ID（0-5 现行骨架组；14=未分类前景；15=肩甲补丁）
const P_TORSO := 0
const P_ARM_OUTER := 1
const P_ARM_INNER := 2
const P_LEG_OUTER := 3
const P_LEG_INNER := 4
const P_MISC := 14
const P_SHOULDER := 15

## 骨骼名 → 零件组
const BONE_GROUP: Dictionary = {
	"hip": P_TORSO, "spine_root": P_TORSO, "lower_torso": P_TORSO,
	"chest_mid": P_TORSO, "upper_torso": P_TORSO, "neck": P_TORSO, "head": P_TORSO,
	"upper_arm_outer": P_ARM_OUTER, "forearm_outer": P_ARM_OUTER, "hand_outer": P_ARM_OUTER,
	"upper_arm_inner": P_ARM_INNER, "forearm_inner": P_ARM_INNER, "hand_inner": P_ARM_INNER,
	"thigh_outer": P_LEG_OUTER, "shin_outer": P_LEG_OUTER,
	"foot_outer": P_LEG_OUTER, "toe_outer": P_LEG_OUTER,
	"thigh_inner": P_LEG_INNER, "shin_inner": P_LEG_INNER,
	"foot_inner": P_LEG_INNER, "toe_inner": P_LEG_INNER,
}

## 全融合口径下邻接表不再承载语义（全部零件同 ID）——保留空表。

## 肩甲补丁半径（rig 本地单位；旧版直径 30 逻辑像素同量级）
const SHOULDER_PATCH_RADIUS := 15.0


## 对一个 CanvasGroup 内的现行矢量骨架启用融合描边。
## group 内须有名为 StickmanRig 的 Skeleton2D（char_host 的结构）。
static func setup(group: CanvasGroup) -> void:
	if not is_instance_valid(group):
		return
	var rig := group.get_node_or_null("OutlineGroup/StickmanRig") as Skeleton2D
	if rig == null:
		rig = group.get_node_or_null("StickmanRig") as Skeleton2D
	if rig == null:
		return
	_assign_ids(rig)
	_hide_stroke_layers(rig)
	var outline_mat := ShaderMaterial.new()
	outline_mat.shader = OUTLINE_SHADER
	outline_mat.set_shader_parameter("outline_color", Color.WHITE)
	outline_mat.set_shader_parameter("outline_width", 1.5)
	outline_mat.set_shader_parameter("adj_tex", _build_adjacency_texture())
	group.material = outline_mat


## 零件容器（sprite_*）按骨骼祖先归组，给容器挂 ID 材质——子级
## Line2D/Polygon2D 无自备材质时继承，整组统一进同一 ID。
static func _assign_ids(rig: Node) -> void:
	# 全部零件同一 ID：is_adjacent(a==a)=true → 内部任何重叠永不出线，
	# 白描边只画整体剪影外轮廓（创始人定稿口径：内部无任何描边）
	for container in _iter_limb_containers(rig):
		var mat := ShaderMaterial.new()
		mat.shader = ID_SHADER
		mat.set_shader_parameter("part_id", P_TORSO)
		(container as CanvasItem).material = mat


## 收集骨架下全部"sprite_*"零件容器（现行骨架的肢体都包在这种容器里）
static func _iter_limb_containers(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Node2D and String(child.name).begins_with("sprite_"):
			out.append(child)
			continue   # 容器内不再下钻（子级继承材质）
		out.append_array(_iter_limb_containers(child))
	return out


## 向上找最近的 Bone2D 祖先
static func _find_bone_ancestor(node: Node) -> Bone2D:
	var p: Node = node.get_parent()
	while p != null:
		if p is Bone2D:
			return p
		p = p.get_parent()
	return null


## 隐藏每段肢体的自备描边层（stroke 盒含 tip_arc）：内部不允许任何描边，
## 轮廓由 Outline Pass 的外轮廓白描边独自承担。
static func _hide_stroke_layers(rig: Node) -> void:
	for container in _iter_limb_containers(rig):
		var stroke := (container as Node).get_node_or_null("stroke")
		if stroke is CanvasItem:
			(stroke as CanvasItem).visible = false


static func _build_adjacency_texture() -> ImageTexture:
	# 全融合口径：全零表（全部零件同 ID，is_adjacent 走 a==b 短路）
	var img := Image.create(16, 16, false, Image.FORMAT_R8)
	img.fill(Color(0.0, 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(img)
