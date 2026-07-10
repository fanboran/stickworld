@tool
class_name StickmanRig
extends Node2D
## 商业级火柴人渲染骨架
##
## 从 SWL .nodes 数据构建 Node2D 层级，程序化生成纹理，
## 通过 AnimationPlayer + AnimationTree StateMachine 驱动动画。
## Inspector 面板可实时调整厚度、颜色、缩放。

# ===== 节点类型常量 =====
const TYPE_ROUND_SEG: int = 0
const TYPE_CIRCLE: int = 2
const TYPE_TRIANGLE: int = 3
const TYPE_ELLIPSE: int = 5

# ===== 超采样倍率 =====
const SSAA: int = 2

# ===== 动画状态名 =====
const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_ATTACK := "attack"
const ANIM_DEAD := "dead"

# ===== Inspector 可调参数 =====
@export var stick_scale: float = 1.0:
	set(v):
		stick_scale = v
		_rebuild_all_sprites()
@export var thickness_scale: float = 1.0:
	set(v):
		thickness_scale = v
		_rebuild_all_sprites()
@export var body_color: Color = Color(0.82, 0.82, 0.85, 1.0):
	set(v):
		body_color = v
		_rebuild_all_sprites()
@export var weapon_color: Color = Color(0.72, 0.74, 0.78, 1.0):
	set(v):
		weapon_color = v
		_rebuild_all_sprites()
@export var guard_color: Color = Color(0.65, 0.45, 0.18, 1.0):
	set(v):
		guard_color = v
		_rebuild_all_sprites()

## SWL Swordwrath 完整骨骼数据（24 节点，Y 已取反适配 Godot Y-down）
## root=髋部, 身体↑(6→7→8), 头↑(9→10), 手臂↓(1→2,14→15), 腿↓(3→4→5,11→12→13)
const SWL_SWORDWRATH: Dictionary = {
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
	16: {"parent": 15, "x": 144.2,  "y": -91.9,  "length": 171, "thickness": 0,  "type": TYPE_ROUND_SEG},
	17: {"parent": 16, "x": -100.3, "y": 64.0,   "length": 119, "thickness": 18, "type": TYPE_TRIANGLE},
	18: {"parent": 17, "x": -28.7,  "y": 18.3,   "length": 34,  "thickness": 18, "type": TYPE_TRIANGLE},
	23: {"parent": 18, "x": 15.4,   "y": 24.2,   "length": 29,  "thickness": 18, "type": TYPE_TRIANGLE},
	22: {"parent": 18, "x": -15.4,  "y": -24.2,  "length": 29,  "thickness": 18, "type": TYPE_TRIANGLE},
	19: {"parent": 18, "x": -13.9,  "y": 8.9,    "length": 17,  "thickness": 7,  "type": TYPE_TRIANGLE},
	20: {"parent": 19, "x": -11.8,  "y": 7.5,    "length": 14,  "thickness": 7,  "type": TYPE_TRIANGLE},
	21: {"parent": 20, "x": -26.1,  "y": 16.7,   "length": 31,  "thickness": 14, "type": TYPE_ELLIPSE},
	9:  {"parent": 8,  "x": 19.9,   "y": -45.9,  "length": 50,  "thickness": 23, "type": -1},  ## 脖：仅用于定位头，不渲染
	10: {"parent": 9,  "x": -15.1,  "y": 34.8,   "length": 38,  "thickness": 23, "type": TYPE_CIRCLE},
}

# ===== 默认颜色（用于判断是否加载烘焙 PNG） =====
const DEFAULT_BODY := Color(0.82, 0.82, 0.85, 1.0)
const DEFAULT_WEAPON := Color(0.72, 0.74, 0.78, 1.0)
const DEFAULT_GUARD := Color(0.65, 0.45, 0.18, 1.0)

# ===== 运行时引用 =====
var _bones: Dictionary = {}
var _sprites: Dictionary = {}
var _anim_player: AnimationPlayer
var _anim_tree: AnimationTree
var _state_machine: AnimationNodeStateMachinePlayback
var _current_anim: String = ANIM_IDLE
var _rebuild_pending: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		# 编辑器：扫描已有节点，但不生成纹理（用 .tscn 的 ExtResource）
		_collect_existing_nodes(self)
		return
	if _bones.size() > 0:
		return
	_build_skeleton()
	_setup_animations()
	_setup_animation_tree()


func _process(_delta: float) -> void:
	if _state_machine == null:
		_acquire_playback()
	if _rebuild_pending:
		_rebuild_pending = false
		_do_rebuild_all_sprites()


# ============================================================
#  Inspector 触发的重建
# ============================================================

func _rebuild_all_sprites() -> void:
	# 延迟到 _process 执行，避免在 setter 中操作节点
	_rebuild_pending = true


func _do_rebuild_all_sprites() -> void:
	# 清除旧 sprites
	for id in _sprites.keys():
		var sprite: Node = _sprites[id]
		if is_instance_valid(sprite):
			sprite.queue_free()
	_sprites.clear()
	# 重新创建
	for id in _bones.keys():
		if id == 0:
			continue
		var data: Dictionary = SWL_SWORDWRATH.get(id, {})
		var node_type: int = data.get("type", -1)
		if node_type < 0:
			continue
		var bone: Node2D = _bones[id]
		var length: int = data["length"]
		var thickness: int = data["thickness"]
		_create_part_sprite(bone, id, length, thickness, node_type, data["x"], data["y"])


# ============================================================
#  骨骼构建
# ============================================================

func _build_skeleton() -> void:
	if get_node_or_null("bone_0") != null:
		_build_from_existing_nodes()
	else:
		_build_from_scratch()


func _build_from_existing_nodes() -> void:
	_collect_existing_nodes(self)
	for id in _bones.keys():
		if id == 0:
			continue
		var data: Dictionary = SWL_SWORDWRATH.get(id, {})
		var node_type: int = data.get("type", -1)
		if node_type < 0:
			continue
		var bone: Node2D = _bones[id]
		# 已有 Sprite → 更新纹理；没有 → 创建新的
		if _sprites.has(id):
			_update_sprite_texture(_sprites[id], data["length"], data["thickness"], node_type)
		else:
			_create_part_sprite(bone, id, data["length"], data["thickness"], node_type, data["x"], data["y"])


func _collect_existing_nodes(parent: Node) -> void:
	for child in parent.get_children():
		if child.name.begins_with("bone_"):
			var id_str := child.name.trim_prefix("bone_")
			if id_str.is_valid_int():
				_bones[id_str.to_int()] = child
		elif child.name.begins_with("sprite_"):
			var id_str := child.name.trim_prefix("sprite_")
			if id_str.is_valid_int():
				_sprites[id_str.to_int()] = child
		_collect_existing_nodes(child)


func _update_sprite_texture(sprite: Sprite2D, length: int, thickness: int, node_type: int) -> void:
	# 从 sprite 名称提取 bone id，优先加载烘焙 PNG
	var id_str := sprite.name.trim_prefix("sprite_")
	var tex: Texture2D = null
	if id_str.is_valid_int():
		tex = _try_load_baked_texture(id_str.to_int(), node_type)
	if tex == null:
		var color: Color = _get_color_for_type(node_type)
		var adj_thickness: int = max(int(thickness * thickness_scale), 1)
		tex = _generate_texture(node_type, length, adj_thickness, color)
	sprite.texture = tex


func _build_from_scratch() -> void:
	var ordered: Array[int] = _topological_sort(SWL_SWORDWRATH)
	for id in ordered:
		var data: Dictionary = SWL_SWORDWRATH[id]
		var node := Node2D.new()
		node.name = "bone_%d" % id
		node.position = Vector2(data["x"], data["y"])
		var parent_id: int = data["parent"]
		if parent_id >= 0 and _bones.has(parent_id):
			_bones[parent_id].add_child(node)
		else:
			add_child(node)
		_bones[id] = node
		var length: int = data["length"]
		var thickness: int = data["thickness"]
		var node_type: int = data["type"]
		if id == 0 or node_type < 0:
			continue
		_create_part_sprite(node, id, length, thickness, node_type, data["x"], data["y"])


static func _topological_sort(data: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var visited: Dictionary = {}
	for id in data.keys():
		_visit_node(id, data, visited, result)
	return result


static func _visit_node(id: int, data: Dictionary, visited: Dictionary, result: Array[int]) -> void:
	if visited.has(id):
		return
	visited[id] = true
	var parent_id: int = data[id]["parent"]
	if parent_id >= 0 and data.has(parent_id):
		_visit_node(parent_id, data, visited, result)
	result.append(id)


# ============================================================
#  Sprite2D 创建
# ============================================================

func _create_part_sprite(node: Node2D, id: int, length: int, thickness: int, node_type: int, px: float, py: float) -> void:
	var sprite := Sprite2D.new()
	sprite.name = "sprite_%d" % id
	node.add_child(sprite)

	# 优先加载烘焙好的 PNG，失败则程序化生成
	var tex := _try_load_baked_texture(id, node_type)
	if tex == null:
		var color: Color = _get_color_for_type(node_type)
		var adj_thickness: int = max(int(thickness * thickness_scale), 1)
		tex = _generate_texture(node_type, length, adj_thickness, color)
	sprite.texture = tex

	var offset := Vector2(px, py)
	if node_type == TYPE_CIRCLE:
		sprite.rotation = 0.0
		sprite.position = Vector2.ZERO
	else:
		sprite.rotation = offset.angle()
		sprite.position = Vector2(-px / 2.0, -py / 2.0)

	_sprites[id] = sprite


func _try_load_baked_texture(id: int, node_type: int) -> Texture2D:
	# 颜色非默认时跳过烘焙 PNG，使用程序化生成以实时反映颜色变更
	if not _colors_are_default():
		return null
	var type_str := _type_str(node_type)
	var path := "res://assets/textures/stickman/bone_%d_%s.png" % [id, type_str]
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


func _colors_are_default() -> bool:
	return body_color == DEFAULT_BODY and weapon_color == DEFAULT_WEAPON and guard_color == DEFAULT_GUARD


static func _type_str(node_type: int) -> String:
	match node_type:
		TYPE_ROUND_SEG: return "pill"
		TYPE_CIRCLE: return "circle"
		TYPE_TRIANGLE: return "tri"
		TYPE_ELLIPSE: return "ellipse"
		_: return "pill"


func _get_color_for_type(node_type: int) -> Color:
	match node_type:
		TYPE_TRIANGLE:
			return weapon_color
		TYPE_ELLIPSE:
			return guard_color
		_:
			return body_color


func _generate_texture(node_type: int, length: int, thickness: int, color: Color) -> ImageTexture:
	match node_type:
		TYPE_ROUND_SEG:
			return _generate_pill_texture(float(length), thickness, color)
		TYPE_CIRCLE:
			# 圆直径为 length 和 thickness*2 的较大值，确保比例协调
			return _generate_circle_texture(max(length, thickness * 2), color)
		TYPE_TRIANGLE:
			return _generate_triangle_texture(float(length), max(thickness, 2), color)
		TYPE_ELLIPSE:
			return _generate_ellipse_texture(float(length), max(thickness, 4), color)
		_:
			return _generate_pill_texture(float(length), thickness, color)


# ============================================================
#  纹理生成（2x 超采样 + Lanczos 降采样抗锯齿）
# ============================================================

func _generate_pill_texture(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = max(int(length) + thickness, 4)
	var h: int = max(thickness, 4)
	var img := _draw_pill_ssaa(w, h, thickness, color)
	return ImageTexture.create_from_image(img)


func _generate_circle_texture(diameter: int, color: Color) -> ImageTexture:
	var d: int = max(diameter, 4)
	var img := _draw_circle_ssaa(d, color)
	return ImageTexture.create_from_image(img)


func _generate_triangle_texture(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = max(int(length), 4)
	var h: int = max(thickness * 2, 8)
	var img := _draw_triangle_ssaa(w, h, color)
	return ImageTexture.create_from_image(img)


func _generate_ellipse_texture(length: float, thickness: int, color: Color) -> ImageTexture:
	var w: int = max(int(length), 4)
	var h: int = max(thickness, 4)
	var img := _draw_ellipse_ssaa(w, h, color)
	return ImageTexture.create_from_image(img)


func _draw_pill_ssaa(w: int, h: int, thickness: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var st: int = thickness * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var radius: float = st / 2.0
	var rect_left: float = radius
	var rect_right: float = sw - radius
	for py in range(sh):
		for px in range(sw):
			var alpha: float = _pill_coverage(float(px), float(py), radius, rect_left, rect_right, sh)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale_lanczos(img, w, h)


func _draw_circle_ssaa(d: int, color: Color) -> Image:
	var sd: int = d * SSAA
	var img := Image.create(sd, sd, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx: float = sd / 2.0
	var cy: float = sd / 2.0
	var radius: float = sd / 2.0
	for py in range(sd):
		for px in range(sd):
			var dist := Vector2(px + 0.5 - cx, py + 0.5 - cy).length()
			var alpha: float = clampf(radius - dist + 0.5, 0.0, 1.0)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale_lanczos(img, d, d)


func _draw_triangle_ssaa(w: int, h: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var p1 := Vector2(0.0, sh / 2.0)
	var p2 := Vector2(float(sw), 0.0)
	var p3 := Vector2(float(sw), float(sh))
	for py in range(sh):
		for px in range(sw):
			var pt := Vector2(float(px) + 0.5, float(py) + 0.5)
			if _point_in_triangle(pt, p1, p2, p3):
				img.set_pixel(px, py, color)
	return _downscale_lanczos(img, w, h)


func _draw_ellipse_ssaa(w: int, h: int, color: Color) -> Image:
	var sw: int = w * SSAA
	var sh: int = h * SSAA
	var img := Image.create(sw, sh, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rx: float = sw / 2.0
	var ry: float = sh / 2.0
	var cx: float = rx
	var cy: float = ry
	for py in range(sh):
		for px in range(sw):
			var dx: float = (px + 0.5 - cx) / rx
			var dy: float = (py + 0.5 - cy) / ry
			var d: float = dx * dx + dy * dy
			var edge: float = 1.0 - d
			var alpha: float = clampf(edge * 2.0, 0.0, 1.0)
			if alpha > 0.0:
				img.set_pixel(px, py, Color(color.r, color.g, color.b, alpha * color.a))
	return _downscale_lanczos(img, w, h)


static func _pill_coverage(px: float, py: float, radius: float, rect_left: float, rect_right: float, sh: int) -> float:
	var cy: float = sh / 2.0
	if px >= rect_left and px <= rect_right:
		var dy: float = abs(py + 0.5 - cy)
		return clampf(radius - dy + 0.5, 0.0, 1.0)
	if px < rect_left:
		var dist := Vector2(px + 0.5 - rect_left, py + 0.5 - cy).length()
		return clampf(radius - dist + 0.5, 0.0, 1.0)
	var dist2 := Vector2(px + 0.5 - rect_right, py + 0.5 - cy).length()
	return clampf(radius - dist2 + 0.5, 0.0, 1.0)


static func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1: float = _sign2d(p, a, b)
	var d2: float = _sign2d(p, b, c)
	var d3: float = _sign2d(p, c, a)
	var has_neg: bool = (d1 < 0) or (d2 < 0) or (d3 < 0)
	var has_pos: bool = (d1 > 0) or (d2 > 0) or (d3 > 0)
	return not (has_neg and has_pos)


static func _sign2d(p1: Vector2, p2: Vector2, p3: Vector2) -> float:
	return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)


static func _downscale_lanczos(img: Image, target_w: int, target_h: int) -> Image:
	img.resize(target_w, target_h, Image.INTERPOLATE_LANCZOS)
	return img


# ============================================================
#  动画系统
# ============================================================

func _setup_animations() -> void:
	_anim_player = AnimationPlayer.new()
	_anim_player.name = "AnimationPlayer"
	add_child(_anim_player)
	_create_idle_anim()
	_create_walk_anim()
	_create_attack_anim()
	_create_dead_anim()


func _setup_animation_tree() -> void:
	_anim_tree = AnimationTree.new()
	_anim_tree.name = "AnimationTree"
	add_child(_anim_tree)
	var sm := AnimationNodeStateMachine.new()
	var idle_node := AnimationNodeAnimation.new()
	idle_node.animation = ANIM_IDLE
	sm.add_node(ANIM_IDLE, idle_node)
	var walk_node := AnimationNodeAnimation.new()
	walk_node.animation = ANIM_WALK
	sm.add_node(ANIM_WALK, walk_node)
	var attack_node := AnimationNodeAnimation.new()
	attack_node.animation = ANIM_ATTACK
	sm.add_node(ANIM_ATTACK, attack_node)
	var dead_node := AnimationNodeAnimation.new()
	dead_node.animation = ANIM_DEAD
	sm.add_node(ANIM_DEAD, dead_node)
	sm.add_transition(ANIM_IDLE, ANIM_WALK, _make_smt(0.2))
	sm.add_transition(ANIM_WALK, ANIM_IDLE, _make_smt(0.2))
	sm.add_transition(ANIM_IDLE, ANIM_ATTACK, _make_smt(0.1))
	sm.add_transition(ANIM_WALK, ANIM_ATTACK, _make_smt(0.1))
	sm.add_transition(ANIM_ATTACK, ANIM_IDLE, _make_smt(0.3))
	sm.add_transition(ANIM_IDLE, ANIM_DEAD, _make_smt(0.3))
	sm.add_transition(ANIM_WALK, ANIM_DEAD, _make_smt(0.3))
	sm.add_transition(ANIM_ATTACK, ANIM_DEAD, _make_smt(0.3))
	sm.add_transition("Start", ANIM_IDLE, _make_smt(0.0))
	_anim_tree.tree_root = sm
	_anim_tree.anim_player = _anim_player.get_path()
	_anim_tree.active = true
	_acquire_playback()


func _acquire_playback() -> void:
	if _state_machine == null and _anim_tree != null:
		_state_machine = _anim_tree.get("parameters/playback")


static func _make_smt(xfade: float) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.advance_mode = 1
	t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC
	t.xfade_time = xfade
	return t


func _create_idle_anim() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.length = 2.0
	var lib := AnimationLibrary.new()
	_add_rot_keys(anim, 8, [0.0, deg_to_rad(4.0), 1.0, deg_to_rad(-3.0), 2.0, 0.0])
	_add_rot_keys(anim, 1, [0.0, deg_to_rad(2.0), 1.0, deg_to_rad(-1.5), 2.0, 0.0])
	_add_rot_keys(anim, 3, [0.0, deg_to_rad(5.0), 1.0, deg_to_rad(-4.0), 2.0, 0.0])
	_add_rot_keys(anim, 11, [0.0, deg_to_rad(-4.0), 1.0, deg_to_rad(5.0), 2.0, 0.0])
	_add_rot_keys(anim, 9, [0.0, deg_to_rad(2.0), 1.0, deg_to_rad(-1.5), 2.0, 0.0])
	lib.add_animation(ANIM_IDLE, anim)
	_anim_player.add_animation_library("", lib)


func _create_walk_anim() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_LINEAR
	anim.length = 0.8
	_add_rot_keys(anim, 9, [0.0, deg_to_rad(35.0), 0.4, deg_to_rad(-30.0), 0.8, 0.0])
	_add_rot_keys(anim, 3, [0.0, deg_to_rad(-25.0), 0.4, deg_to_rad(25.0), 0.8, 0.0])
	_add_rot_keys(anim, 11, [0.0, deg_to_rad(25.0), 0.4, deg_to_rad(-25.0), 0.8, 0.0])
	_add_rot_keys(anim, 4, [0.0, deg_to_rad(-10.0), 0.4, deg_to_rad(10.0), 0.8, 0.0])
	_add_rot_keys(anim, 12, [0.0, deg_to_rad(10.0), 0.4, deg_to_rad(-10.0), 0.8, 0.0])
	_add_rot_keys(anim, 8, [0.0, deg_to_rad(5.0), 0.4, deg_to_rad(-5.0), 0.8, 0.0])
	_add_rot_keys(anim, 1, [0.0, deg_to_rad(-3.0), 0.4, deg_to_rad(3.0), 0.8, 0.0])
	_add_rot_keys(anim, 14, [0.0, deg_to_rad(8.0), 0.4, deg_to_rad(-8.0), 0.8, 0.0])
	_anim_player.get_animation_library("").add_animation(ANIM_WALK, anim)


func _create_attack_anim() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_NONE
	anim.length = 0.6
	_add_rot_keys(anim, 14, [0.0, deg_to_rad(-80.0), 0.15, deg_to_rad(100.0), 0.4, deg_to_rad(15.0), 0.6, 0.0])
	_add_rot_keys(anim, 15, [0.0, deg_to_rad(-40.0), 0.15, deg_to_rad(50.0), 0.4, 0.0, 0.6, 0.0])
	_add_rot_keys(anim, 8, [0.0, deg_to_rad(-12.0), 0.15, deg_to_rad(15.0), 0.4, 0.0, 0.6, 0.0])
	_add_rot_keys(anim, 16, [0.0, deg_to_rad(30.0), 0.15, deg_to_rad(-40.0), 0.4, 0.0, 0.6, 0.0])
	_add_rot_keys(anim, 3, [0.0, deg_to_rad(-10.0), 0.15, deg_to_rad(15.0), 0.4, 0.0, 0.6, 0.0])
	_anim_player.get_animation_library("").add_animation(ANIM_ATTACK, anim)


func _create_dead_anim() -> void:
	var anim := Animation.new()
	anim.loop_mode = Animation.LOOP_NONE
	anim.length = 1.0
	_add_rot_keys(anim, 8, [0.0, deg_to_rad(100.0), 0.5, deg_to_rad(95.0), 1.0, 0.0])
	_add_rot_keys(anim, 3, [0.0, deg_to_rad(50.0), 0.5, deg_to_rad(55.0), 1.0, 0.0])
	_add_rot_keys(anim, 11, [0.0, deg_to_rad(-50.0), 0.5, deg_to_rad(-55.0), 1.0, 0.0])
	_add_rot_keys(anim, 9, [0.0, deg_to_rad(-15.0), 0.5, deg_to_rad(-10.0), 1.0, 0.0])
	_add_rot_keys(anim, 14, [0.0, deg_to_rad(30.0), 0.5, deg_to_rad(40.0), 1.0, 0.0])
	_add_rot_keys(anim, 1, [0.0, deg_to_rad(40.0), 0.5, deg_to_rad(45.0), 1.0, 0.0])
	_anim_player.get_animation_library("").add_animation(ANIM_DEAD, anim)


func _add_rot_keys(anim: Animation, bone_id: int, keys: Array) -> void:
	if keys.size() < 2:
		return
	var bone: Node2D = _bones.get(bone_id, null)
	if bone == null:
		return
	var path := "%s:rotation" % str(get_path_to(bone))
	var track_idx: int = anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track_idx, path)
	anim.track_set_interpolation_type(track_idx, 3)
	var i: int = 0
	while i + 1 < keys.size():
		anim.track_insert_key(track_idx, float(keys[i]), float(keys[i + 1]))
		i += 2


# ============================================================
#  公共 API
# ============================================================

func play(anim_name: String) -> void:
	if _state_machine == null:
		_acquire_playback()
	if _state_machine == null:
		return
	match anim_name:
		ANIM_IDLE:
			_state_machine.travel(ANIM_IDLE)
		ANIM_WALK:
			_state_machine.travel(ANIM_WALK)
		ANIM_ATTACK:
			_state_machine.travel(ANIM_ATTACK)
		ANIM_DEAD:
			_state_machine.travel(ANIM_DEAD)
	_current_anim = anim_name


func get_current_anim() -> String:
	return _current_anim


func get_bone_by_id(id: int) -> Node2D:
	return _bones.get(id, null)


func get_bone_ids() -> Array:
	return _bones.keys()