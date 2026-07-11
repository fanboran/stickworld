class_name StickmanSkeleton
extends RefCounted
## 火柴人骨骼数据 + 骨骼构建 + Sprite 创建
##
## 使用 Skeleton2D + Bone2D 实现真正的骨骼约束。
## 骨骼命名采用"肢体段"命名法：骨骼名 = 该骨骼到子骨骼之间的肢体段。
## 大腿骨骼（thigh_outer/thigh_inner）位于髋部位置(0,0)，作为大腿精灵的容器。
## 旋转大腿骨骼 = 整条腿围绕髋部转；旋转小腿骨骼 = 小腿以下围绕膝盖转。

const TextureGen := preload("res://modules/units/scripts/stickman_texture_gen.gd")

# ===== 节点类型 =====
const TYPE_ROUND_SEG: int = 0
const TYPE_CIRCLE: int = 2
const TYPE_TRIANGLE: int = 3
const TYPE_ELLIPSE: int = 5

# ===== 输出倍率 =====
const OUTPUT_SCALE: float = 4.0

# ===== 武器挂载骨骼 =====
const WEAPON_ATTACH_R := 15
const WEAPON_ATTACH_L := 2

# ===== 骨骼名称映射（肢体段命名法）=====
## 骨骼名代表"从此骨骼到子骨骼"的肢体段
## 例如 thigh_outer = 大腿（从髋部到膝盖的段），位于髋部位置(0,0)
const BONE_NAMES: Dictionary = {
	0:  "hip",             # 髋部（根节点）
	1:  "forearm_outer",   # 小臂外（从外肘到外手）
	2:  "hand_outer",      # 手外（叶子节点）
	3:  "shin_outer",      # 小腿外（从外膝到外脚踝）
	4:  "foot_outer",      # 脚掌外（从外脚踝到外脚尖）
	5:  "toe_outer",       # 脚趾外（叶子节点）
	6:  "lower_torso",     # 下躯干（从髋到下腹）
	7:  "upper_torso",     # 上躯干（从下腹到胸）
	9:  "neck",            # 颈部（从胸到头根）
	10: "head",            # 头部（从颈根到头顶）
	11: "shin_inner",      # 小腿内
	12: "foot_inner",      # 脚掌内
	13: "toe_inner",       # 脚趾内
	14: "forearm_inner",   # 小臂内
	15: "hand_inner",      # 手内（叶子节点）
	16: "thigh_outer",     # 大腿外（从髋到外膝，位于髋部位置）
	17: "thigh_inner",     # 大腿内（从髋到内膝，位于髋部位置）
	18: "upper_arm_outer", # 大臂外（从胸到外肘，位于胸部位置）
	19: "upper_arm_inner", # 大臂内（从胸到内肘，位于胸部位置）
}

## 反向映射：骨骼名 -> ID
const BONE_NAME_TO_ID: Dictionary = {
	"hip": 0,
	"forearm_outer": 1,
	"hand_outer": 2,
	"shin_outer": 3,
	"foot_outer": 4,
	"toe_outer": 5,
	"lower_torso": 6,
	"upper_torso": 7,
	"neck": 9,
	"head": 10,
	"shin_inner": 11,
	"foot_inner": 12,
	"toe_inner": 13,
	"forearm_inner": 14,
	"hand_inner": 15,
	"thigh_outer": 16,
	"thigh_inner": 17,
	"upper_arm_outer": 18,
	"upper_arm_inner": 19,
}

## SWL Swordwrath 骨骼数据
## root=hip, 躯干↑(6->7), 头↑(9->10)
## 手臂外↓(18->1->2), 手臂内↓(19->14->15)
## 腿外↓(16->3->4->5), 腿内↓(17->11->12->13)
## x,y = 相对父骨骼的偏移量
## type = 精灵类型，-1 = 无精灵。精灵挂在父骨骼上。
const SKELETON_DATA: Dictionary = {
	0:  {"parent": -1, "x": 0.0,    "y": 0.0,    "length": 0,   "thickness": 0,  "type": -1},
	16: {"parent": -1, "x": 0.0,    "y": 0.0,    "length": 66,  "thickness": 23, "type": -1},
	3:  {"parent": 16, "x": 25.4,   "y": 60.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	4:  {"parent": 3,  "x": 2.9,    "y": 68.9,   "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	5:  {"parent": 4,  "x": 11.0,   "y": 0.0,    "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	17: {"parent": -1, "x": 0.0,    "y": 0.0,    "length": 66,  "thickness": 23, "type": -1},
	11: {"parent": 17, "x": -4.8,   "y": 65.8,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	12: {"parent": 11, "x": -16.9,  "y": 66.9,   "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	13: {"parent": 12, "x": 11.0,   "y": -0.2,   "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	6:  {"parent": 0,  "x": 1.8,    "y": -30.9,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	7:  {"parent": 6,  "x": 5.7,    "y": -30.5,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	18: {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 64,  "thickness": 23, "type": -1},
	1:  {"parent": 18, "x": -34.7,  "y": 53.9,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	2:  {"parent": 1,  "x": -3.1,   "y": 48.7,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	19: {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 64,  "thickness": 23, "type": -1},
	14: {"parent": 19, "x": 1.1,    "y": 64.1,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	15: {"parent": 14, "x": 33.8,   "y": 35.2,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	9:  {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 50,  "thickness": 23, "type": -1},
	10: {"parent": 9,  "x": -15.1,  "y": 34.8,   "length": 38,  "thickness": 23, "type": TYPE_CIRCLE},
}

# ===== 默认颜色 =====
const DEFAULT_BODY := Color(0.82, 0.82, 0.85, 1.0)
const DEFAULT_WEAPON := Color(0.72, 0.74, 0.78, 1.0)
const DEFAULT_GUARD := Color(0.65, 0.45, 0.18, 1.0)


# ============================================================
#  骨骼构建
# ============================================================

## 从零构建骨骼 + 精灵层级
## 精灵挂在父骨骼上：大腿精灵挂在髋部，小腿精灵挂在膝盖，以此类推。
static func build_from_scratch(skeleton: Skeleton2D, thickness_scale: float = 1.0, colors: Dictionary = {}) -> Dictionary:
	var bones: Dictionary = {}
	var sprites: Dictionary = {}
	var ordered := _topo_sort(SKELETON_DATA)

	# 第一遍：创建所有骨骼
	for id in ordered:
		var data: Dictionary = SKELETON_DATA[id]
		var node := Bone2D.new()
		node.name = BONE_NAMES.get(id, "bone_%d" % id)
		node.position = Vector2(data["x"], data["y"])
		var pid: int = data["parent"]
		if pid >= 0 and bones.has(pid):
			(bones[pid] as Bone2D).add_child(node)
		else:
			skeleton.add_child(node)
		bones[id] = node

	# 第二遍：为有精灵的骨骼，把精灵挂到父骨骼上
	for id in ordered:
		var data: Dictionary = SKELETON_DATA[id]
		var node_type: int = data.get("type", -1)
		if node_type < 0:
			continue
		var pid: int = data["parent"]
		var parent_node: Node2D = bones[pid] if (pid >= 0 and bones.has(pid)) else skeleton
		var sprite := create_sprite(parent_node, id, data["length"], data["thickness"],
			node_type, data["x"], data["y"], thickness_scale, colors)
		sprites[id] = sprite

	return {"bones": bones, "sprites": sprites}


## 扫描 Skeleton2D 中已有的骨骼和精灵节点
static func collect_nodes(skeleton: Skeleton2D) -> Dictionary:
	var bones: Dictionary = {}
	var sprites: Dictionary = {}
	_scan(skeleton, bones, sprites)
	return {"bones": bones, "sprites": sprites}


# ============================================================
#  Sprite 创建
# ============================================================

## 在 parent_bone 上创建精灵，表示从 parent 到子骨骼的肢体段
## px, py = 子骨骼相对 parent 的偏移
## 精灵放在段的中点，旋转对齐段方向
static func create_sprite(parent_bone: Node2D, id: int, length: int, thickness: int, node_type: int, px: float, py: float, thickness_scale: float, colors: Dictionary) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.name = "sprite_%d" % id
	parent_bone.add_child(sprite)

	var tex := _load_baked_texture(id, node_type, colors)
	if tex == null:
		var color: Color = _color_for_type(node_type, colors)
		var adj_t: int = max(int(thickness * thickness_scale), 1)
		tex = TextureGen.generate(node_type, length, adj_t, color)
	sprite.texture = tex
	sprite.scale = Vector2(1.0 / OUTPUT_SCALE, 1.0 / OUTPUT_SCALE)

	if node_type == TYPE_CIRCLE:
		sprite.rotation = 0.0
		sprite.position = Vector2(px, py)
	else:
		sprite.rotation = Vector2(px, py).angle()
		sprite.position = Vector2(px / 2.0, py / 2.0)
	return sprite


## 更新已有 sprite 的纹理
static func update_sprite_texture(sprite: Sprite2D, node_type: int, colors: Dictionary) -> void:
	var id_str := sprite.name.trim_prefix("sprite_")
	var tex: Texture2D = null
	if id_str.is_valid_int():
		tex = _load_baked_texture(id_str.to_int(), node_type, colors)
	if tex != null:
		sprite.texture = tex
		sprite.scale = Vector2(1.0 / OUTPUT_SCALE, 1.0 / OUTPUT_SCALE)
		sprite.modulate = Color.WHITE


## 颜色更新（只改 modulate，不重建纹理）
static func apply_colors(sprites: Dictionary, colors: Dictionary) -> void:
	var is_default: bool = _colors_default(colors)
	for id in sprites.keys():
		var sprite: Sprite2D = sprites[id]
		if not is_instance_valid(sprite):
			continue
		var data: Dictionary = SKELETON_DATA.get(id, {})
		var node_type: int = data.get("type", -1)
		if node_type < 0:
			continue
		sprite.modulate = _color_for_type(node_type, colors)
		if is_default:
			sprite.modulate = Color.WHITE


# ============================================================
#  内部辅助
# ============================================================

static func _scan(parent: Node, bones: Dictionary, sprites: Dictionary) -> void:
	for child in parent.get_children():
		if child is Bone2D:
			var id: int = BONE_NAME_TO_ID.get(child.name, -1)
			if id >= 0:
				bones[id] = child
		elif child.name.begins_with("sprite_"):
			var id_str := child.name.trim_prefix("sprite_")
			if id_str.is_valid_int():
				sprites[id_str.to_int()] = child
		_scan(child, bones, sprites)


static func _topo_sort(data: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var visited: Dictionary = {}
	for id in data.keys():
		_visit(id, data, visited, result)
	return result


static func _visit(id: int, data: Dictionary, visited: Dictionary, result: Array[int]) -> void:
	if visited.has(id):
		return
	visited[id] = true
	var pid: int = data[id]["parent"]
	if pid >= 0 and data.has(pid):
		_visit(pid, data, visited, result)
	result.append(id)


static func _load_baked_texture(id: int, node_type: int, colors: Dictionary) -> Texture2D:
	if not _colors_default(colors):
		return null
	var path := "res://modules/units/assets/textures/stickman/bone_%d_%s.png" % [id, TextureGen.type_str(node_type)]
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


static func _color_for_type(node_type: int, colors: Dictionary) -> Color:
	match node_type:
		TYPE_TRIANGLE:
			return colors.get("weapon", DEFAULT_WEAPON)
		TYPE_ELLIPSE:
			return colors.get("guard", DEFAULT_GUARD)
		_:
			return colors.get("body", DEFAULT_BODY)


static func _colors_default(colors: Dictionary) -> bool:
	return colors.get("body", DEFAULT_BODY) == DEFAULT_BODY \
		and colors.get("weapon", DEFAULT_WEAPON) == DEFAULT_WEAPON \
		and colors.get("guard", DEFAULT_GUARD) == DEFAULT_GUARD