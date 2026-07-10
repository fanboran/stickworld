class_name StickmanSkeleton
extends RefCounted
## 火柴人骨骼数据 + 骨骼构建 + Sprite 创建

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

## SWL Swordwrath 骨骼数据（已移除武器骨骼，武器改用 scene 挂载）
## root=髋部, 身体↑(6->7->8), 头↑(9->10), 手臂↓(1->2,14->15), 腿↓(3->4->5,11->12->13)
const SKELETON_DATA: Dictionary = {
	0:  {"parent": -1, "x": 0.0,    "y": 0.0,    "length": 0,   "thickness": 0,  "type": -1},
	3:  {"parent": 0,  "x": 25.4,   "y": 60.9,   "length": 66,  "thickness": 23, "type": TYPE_ROUND_SEG},
	4:  {"parent": 3,  "x": 2.9,    "y": 68.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	5:  {"parent": 4,  "x": 11.0,   "y": 0.0,    "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	11: {"parent": 0,  "x": -4.8,   "y": 65.8,   "length": 66,  "thickness": 23, "type": TYPE_ROUND_SEG},
	12: {"parent": 11, "x": -16.9,  "y": 66.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	13: {"parent": 12, "x": 11.0,   "y": -0.2,   "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	6:  {"parent": 0,  "x": 1.8,    "y": -30.9,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	7:  {"parent": 6,  "x": 5.7,    "y": -30.5,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	8:  {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	1:  {"parent": 8,  "x": -34.7,  "y": 53.9,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	2:  {"parent": 1,  "x": -3.1,   "y": 48.7,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	14: {"parent": 8,  "x": 1.1,    "y": 64.1,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	15: {"parent": 14, "x": 33.8,   "y": 35.2,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	9:  {"parent": 8,  "x": 19.9,   "y": -45.9,  "length": 50,  "thickness": 23, "type": -1},
	10: {"parent": 9,  "x": -15.1,  "y": 34.8,   "length": 38,  "thickness": 23, "type": TYPE_CIRCLE},
}

# ===== 默认颜色 =====
const DEFAULT_BODY := Color(0.82, 0.82, 0.85, 1.0)
const DEFAULT_WEAPON := Color(0.72, 0.74, 0.78, 1.0)
const DEFAULT_GUARD := Color(0.65, 0.45, 0.18, 1.0)


# ============================================================
#  骨骼构建
# ============================================================

## 从零构建骨骼层级（运行时，场景中没有预置节点时）
static func build_from_scratch(root: Node2D) -> Dictionary:
	var bones: Dictionary = {}
	var ordered := _topo_sort(SKELETON_DATA)
	for id in ordered:
		var data: Dictionary = SKELETON_DATA[id]
		var node := Node2D.new()
		node.name = "bone_%d" % id
		node.position = Vector2(data["x"], data["y"])
		var pid: int = data["parent"]
		if pid >= 0 and bones.has(pid):
			(bones[pid] as Node2D).add_child(node)
		else:
			root.add_child(node)
		bones[id] = node
	return bones


## 扫描场景中已有的骨骼和 sprite 节点
static func collect_nodes(parent: Node) -> Dictionary:
	var bones: Dictionary = {}
	var sprites: Dictionary = {}
	_scan(parent, bones, sprites)
	return {"bones": bones, "sprites": sprites}


# ============================================================
#  Sprite 创建
# ============================================================

## 为骨骼创建 Sprite2D
static func create_sprite(bone: Node2D, id: int, length: int, thickness: int, node_type: int, px: float, py: float, thickness_scale: float, colors: Dictionary) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.name = "sprite_%d" % id
	bone.add_child(sprite)

	var tex := _load_baked_texture(id, node_type, colors)
	if tex == null:
		var color: Color = _color_for_type(node_type, colors)
		var adj_t: int = max(int(thickness * thickness_scale), 1)
		tex = TextureGen.generate(node_type, length, adj_t, color)
	sprite.texture = tex
	sprite.scale = Vector2(1.0 / OUTPUT_SCALE, 1.0 / OUTPUT_SCALE)

	if node_type == TYPE_CIRCLE:
		sprite.rotation = 0.0
		sprite.position = Vector2.ZERO
	else:
		sprite.rotation = Vector2(px, py).angle()
		sprite.position = Vector2(-px / 2.0, -py / 2.0)
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
		if child.name.begins_with("bone_"):
			var id_str := child.name.trim_prefix("bone_")
			if id_str.is_valid_int():
				bones[id_str.to_int()] = child
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