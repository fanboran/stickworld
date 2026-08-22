class_name StickmanSkeleton
extends RefCounted
## 火柴人骨骼数据 + 骨骼构建 + 矢量肢体渲染
##
## 使用 Skeleton2D + Bone2D 实现真正的骨骼约束。
## 骨骼命名采用"肢体段"命名法：骨骼名 = 该骨骼到子骨骼之间的肢体段。
## 大腿骨骼（thigh_outer/thigh_inner）位于髋部位置(0,0)，作为大腿肢体的容器。
## 旋转大腿骨骼 = 整条腿围绕髋部转；旋转小腿骨骼 = 小腿以下围绕膝盖转。
##
## 渲染架构（方案 B · 矢量化描边，两遍渲染）：
## - 每段肢体 = 容器 Node2D（命名 sprite_<id> 保持扫描兼容），内含两层：
##   描边层（加宽深色圆头 Line2D / 外圈 Polygon2D，z_index=-1）+ 填充层（z=0）。
## - 两遍渲染：全部描边压底、全部填充置顶 → 肢体重叠处填充无缝融合
##   （关节自动连接），描边只在整体剪影外缘露出一圈。
## - 不再使用位图贴图 / CanvasGroup / ID 缓冲着色器 / 邻接表。

# ===== 节点类型 =====
const TYPE_ROUND_SEG: int = 0
const TYPE_CIRCLE: int = 2
const TYPE_TRIANGLE: int = 3
const TYPE_ELLIPSE: int = 5

# ===== 描边参数 =====
## 描边宽度（逻辑像素，单侧）
const OUTLINE_WIDTH: float = 2.0

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
	4:  {"parent": 3,  "x": 2.9,    "y": 68.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	5:  {"parent": 4,  "x": 11.0,   "y": 0.0,    "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	17: {"parent": -1, "x": 0.0,    "y": 0.0,    "length": 66,  "thickness": 23, "type": -1},
	11: {"parent": 17, "x": -4.8,   "y": 65.8,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	12: {"parent": 11, "x": -16.9,  "y": 66.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	13: {"parent": 12, "x": 11.0,   "y": -0.2,   "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	6:  {"parent": 0,  "x": 1.8,    "y": -30.9,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	7:  {"parent": 6,  "x": 5.7,    "y": -30.5,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	18: {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 64,  "thickness": 23, "type": -1},
	1:  {"parent": 18, "x": -34.7,  "y": 53.9,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	2:  {"parent": 1,  "x": -3.1,   "y": 48.7,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	19: {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 64,  "thickness": 23, "type": -1},
	14: {"parent": 19, "x": 1.1,    "y": 64.1,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	15: {"parent": 14, "x": 33.8,   "y": 35.2,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	9:  {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 50,  "thickness": 23, "type": -1},
	10: {"parent": 9,  "x": 4.8,    "y": -11.1,   "length": 38,  "thickness": 23, "type": TYPE_CIRCLE},
}

## 纯视觉附加肢体（无对应骨骼，仅渲染；旧 stickman_test.tscn 的 sprite_8 胸段收编于此）
const EXTRA_LIMBS: Dictionary = {
	20: {"parent": 7, "x": 10.4, "y": -29.2, "length": 31, "thickness": 23, "type": TYPE_ROUND_SEG},
}

# ===== 默认颜色 =====
const DEFAULT_BODY := Color(0.82, 0.82, 0.85, 1.0)
const DEFAULT_WEAPON := Color(0.72, 0.74, 0.78, 1.0)
const DEFAULT_GUARD := Color(0.65, 0.45, 0.18, 1.0)
const DEFAULT_OUTLINE := Color.WHITE


# ============================================================
#  骨骼构建
# ============================================================

## 从零构建骨骼 + 矢量肢体层级
static func build_from_scratch(skeleton: Skeleton2D, thickness_scale: float = 1.0, colors: Dictionary = {}) -> Dictionary:
	var bones: Dictionary = {}
	var ordered := _topo_sort(SKELETON_DATA)

	# 第一遍：创建所有骨骼
	for id in ordered:
		var data: Dictionary = SKELETON_DATA[id]
		var node := Bone2D.new()
		node.name = BONE_NAMES.get(id, "bone_%d" % id)
		node.position = Vector2(data["x"], data["y"])
		# rest 必须显式设置：Bone2D 默认 rest 是零矩阵（引擎"未设 rest"标记），
		# Skeleton2D._update_bone_setup 对 rest 求 affine_inverse 会报 det==0
		node.rest = Transform2D(0.0, node.position)
		var pid: int = data["parent"]
		if pid >= 0 and bones.has(pid):
			(bones[pid] as Bone2D).add_child(node)
		else:
			skeleton.add_child(node)
		bones[id] = node

	reorder_render_order(skeleton)
	var sprites := build_limbs(skeleton, bones, thickness_scale, colors)
	return {"bones": bones, "sprites": sprites}


## 渲染顺序整理（原 Outline.setup 内逻辑，描边系统删除后收编于此）：
## 腿移到躯干之前（腿在身体后面）；内臂先于外臂（外臂覆盖内臂）；头最后。
static func reorder_render_order(skeleton: Skeleton2D) -> void:
	var thigh_outer := skeleton.get_node_or_null("thigh_outer") as Node
	var thigh_inner := skeleton.get_node_or_null("thigh_inner") as Node
	if thigh_outer != null and thigh_inner != null:
		skeleton.move_child(thigh_outer, 0)
		skeleton.move_child(thigh_inner, 1)
	var upper_torso := skeleton.get_node_or_null("hip/lower_torso/upper_torso") as Node
	if upper_torso != null:
		var arm_outer := upper_torso.get_node_or_null("upper_arm_outer") as Node
		var arm_inner := upper_torso.get_node_or_null("upper_arm_inner") as Node
		if arm_outer != null and arm_inner != null and arm_inner.get_index() > arm_outer.get_index():
			upper_torso.move_child(arm_inner, arm_outer.get_index())


## 为已有骨骼（.tscn 路径）构建矢量肢体层
static func build_limbs(skeleton: Skeleton2D, bones: Dictionary, thickness_scale: float, colors: Dictionary) -> Dictionary:
	var sprites: Dictionary = {}
	var all_data := SKELETON_DATA.merged(EXTRA_LIMBS, true)
	for id in all_data.keys():
		var data: Dictionary = all_data[id]
		var node_type: int = data.get("type", -1)
		if node_type < 0:
			continue
		var pid: int = data["parent"]
		if not bones.has(pid):
			continue
		var parent_bone: Node2D = bones[pid]
		sprites[id] = _build_limb(parent_bone, id,
			data["length"], data["thickness"], node_type,
			data["x"], data["y"], thickness_scale, colors)
	return sprites


## 扫描 Skeleton2D 中已有的骨骼节点
static func collect_nodes(skeleton: Skeleton2D) -> Dictionary:
	var bones: Dictionary = {}
	_scan(skeleton, bones)
	return {"bones": bones}


# ============================================================
#  矢量肢体创建
# ============================================================

## 在 parent_bone 上创建矢量肢体段，表示从 parent 到子骨骼的肢体段。
## px, py = 子骨骼相对 parent 的偏移；容器放段的中点、旋转对齐方向，
## 内含描边 + 填充两层圆头 Line2D（几何跨度 = length + thickness，与旧位图一致）。
static func _build_limb(
	parent_bone: Node2D, id: int, length: int, thickness: int, node_type: int,
	px: float, py: float, thickness_scale: float, colors: Dictionary
) -> Node2D:
	var container := Node2D.new()
	container.name = "sprite_%d" % id
	parent_bone.add_child(container)

	var w: float = max(thickness * thickness_scale, 1.0)
	if node_type == TYPE_CIRCLE:
		container.position = Vector2(px, py)
		container.rotation = 0.0
		var r: float = max(float(length), w * 2.0) / 2.0
		container.add_child(_make_circle("stroke", r + OUTLINE_WIDTH, colors.get("outline", DEFAULT_OUTLINE)))
		container.add_child(_make_circle("fill", r, _color_for_type(node_type, colors)))
	else:
		container.rotation = Vector2(px, py).angle()
		container.position = Vector2(px / 2.0, py / 2.0)
		var pts := PackedVector2Array([Vector2(-length / 2.0, 0), Vector2(length / 2.0, 0)])
		container.add_child(_make_line("stroke", pts, w + OUTLINE_WIDTH * 2.0, colors.get("outline", DEFAULT_OUTLINE)))
		container.add_child(_make_line("fill", pts, w, _color_for_type(node_type, colors)))
	_apply_two_pass(container)
	return container


## 两遍渲染分层：全部描边层 z=-1 压到所有填充层之下。
## 效果：填充层在肢体重叠处无缝融合（关节自动"连接"），
## 描边只在整体剪影外缘露出一圈——统一外轮廓，无需邻接表。
static func _apply_two_pass(container: Node2D) -> void:
	var stroke := container.get_node_or_null("stroke") as CanvasItem
	if stroke != null:
		stroke.z_index = -1


static func _make_line(lname: String, pts: PackedVector2Array, width: float, color: Color) -> Line2D:
	var l := Line2D.new()
	l.name = lname
	l.points = pts
	l.width = width
	l.default_color = color
	l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	l.end_cap_mode = Line2D.LINE_CAP_ROUND
	# 不开自带抗锯齿：其羽化边在相机缩小后呈半透明发虚（"断断续续"观感）。
	# 项目已开 msaa_2d，几何边缘由 MSAA 平滑，任意缩放干净利落。
	return l


static func _make_circle(cname: String, radius: float, color: Color) -> Polygon2D:
	return _make_circle_at(cname, Vector2.ZERO, radius, color)


static func _make_circle_at(cname: String, pos: Vector2, radius: float, color: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.name = cname
	p.color = color
	var pts := PackedVector2Array()
	for i in range(40):
		var a := TAU * float(i) / 40.0
		pts.append(pos + Vector2(cos(a), sin(a)) * radius)
	p.polygon = pts
	return p


## 颜色更新（改线条/多边形颜色，不重建节点）
static func apply_colors(sprites: Dictionary, colors: Dictionary) -> void:
	var all_data := SKELETON_DATA.merged(EXTRA_LIMBS, true)
	for id in sprites.keys():
		var limb: Node2D = sprites[id]
		if not is_instance_valid(limb):
			continue
		var data: Dictionary = all_data.get(id, {})
		var node_type: int = data.get("type", -1)
		if node_type < 0:
			continue
		var stroke := limb.get_node_or_null("stroke")
		var fill := limb.get_node_or_null("fill")
		var outline: Color = colors.get("outline", DEFAULT_OUTLINE)
		if stroke is Line2D:
			(stroke as Line2D).default_color = outline
		elif stroke is Polygon2D:
			(stroke as Polygon2D).color = outline
		if fill is Line2D:
			(fill as Line2D).default_color = _color_for_type(node_type, colors)
		elif fill is Polygon2D:
			(fill as Polygon2D).color = _color_for_type(node_type, colors)


# ============================================================
#  内部辅助
# ============================================================

static func _scan(parent: Node, bones: Dictionary) -> void:
	for child in parent.get_children():
		if child is Bone2D:
			var id: int = BONE_NAME_TO_ID.get(child.name, -1)
			if id >= 0:
				bones[id] = child
		_scan(child, bones)


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


static func _color_for_type(node_type: int, colors: Dictionary) -> Color:
	match node_type:
		TYPE_TRIANGLE:
			return colors.get("weapon", DEFAULT_WEAPON)
		TYPE_ELLIPSE:
			return colors.get("guard", DEFAULT_GUARD)
		_:
			return colors.get("body", DEFAULT_BODY)