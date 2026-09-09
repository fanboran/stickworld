class_name StickmanSkeleton
extends RefCounted
## 火柴人骨骼数据 + 骨骼构建 + 矢量肢体渲染
##
## 使用 Skeleton2D + Bone2D 实现真正的骨骼约束。
## 骨骼命名采用"肢体段"命名法：骨骼名 = 该骨骼到子骨骼之间的肢体段。
## 大腿骨骼（thigh_outer/thigh_inner）位于髋部位置(0,0)，作为大腿肢体的容器。
## 旋转大腿骨骼 = 整条腿围绕髋部转；旋转小腿骨骼 = 小腿以下围绕膝盖转。
##
## 渲染架构（方案 B · 矢量化描边，链式两遍渲染 + 根部开口描边）：
## - 每段肢体 = 容器 Node2D（命名 sprite_<id> 保持扫描兼容），内含两层：
##   描边层（加宽深色圆头 Line2D / 外圈 Polygon2D）+ 填充层（同几何窄一层）。
## - 五链 z 栈（2026-09-09 创始人二次定稿，显式描边/填充双表）：远侧臂
##   （藏最底）→ 躯干描边 → 外腿 → 内腿 → 躯干填充 → 近侧臂。效果：
##   躯干描边压在两腿填充之下（髋部/胯部无线）；躯干填充盖住两腿描边
##   （胯部融合）；内腿描边压外腿填充（两腿分界，仅胯部以下）；近侧臂
##   描边压躯干填充（臂-躯分隔，唯一保留的分隔线）；肩膀圆圈由臂描边
##   根部留隙（OPEN_ROOT_GAP）裸出融合。
## - 根部开口描边（U 形）：前臂描边多边形根部平口无端帽——臂根方向
##   不产生环绕弧线，填充根帽直接融合进躯干填充 → 肩/肘无接缝，
##   无需任何关节补丁（补丁方案三次失败的教训：盖缝必连坐外缘描边）。
## - 不再使用位图贴图 / CanvasGroup / ID 缓冲着色器 / 邻接表。

# ===== 节点类型 =====
const TYPE_ROUND_SEG: int = 0
const TYPE_CIRCLE: int = 2
const TYPE_TRIANGLE: int = 3
const TYPE_ELLIPSE: int = 5

# ===== 描边参数 =====
## 描边宽度（逻辑像素，单侧）——zoom≥1 时的设计世界宽度（肢体比例基准）
const OUTLINE_WIDTH: float = 2.0
## 描边屏幕像素下限（单侧）：相机拉远（画布缩放 <1）时描边按 1/缩放补偿，
## 屏幕上恒定 ~2px 不再变细发糊；由 StickmanRig 在画布缩放变化时批量刷新
## 屏幕像素描边宽目标。校准口径：批次 2/3 视觉验收时的实际屏宽为 1px
## （当时补偿公式漏乘 rig 自身缩放等效减半，验收观感基于此）——565c347f
## 修缩放口径后保持 2.0 会让描边整体翻倍、分隔线被放大（创始人反馈
## "线太显眼"），故回校准值 1.0：与历史验收观感一致且体型间等宽。
const OUTLINE_SCREEN_PX: float = 1.0

## 链式分层 z 表——描边/填充显式双表（填充不再恒等于描边+1：躯干填充
## 必须越过两腿描边、同时躯干描边必须沉到两腿填充之下，两者夹住腿链）。
## 线性栈（底→顶）：远臂描边-3/填充-2 → 躯干描边-1 → 外腿描边0/填充1
## → 内腿描边2/填充3 → 躯干填充4 → 近臂描边5/填充6。
## z 取值范围 [-3, +6]：单位带 EntityHost z=3，全局 0~9，严格低于前景层 10。
const CHAIN_STROKE_Z: Dictionary = {
	14: -3, 15: -3,               # 内臂（远侧）——最底
	6: -1, 7: -1, 20: -1, 10: -1, # 躯干+头 描边（沉到两腿填充下→髋部无线）
	3: 0, 4: 0, 5: 0,             # 外腿描边
	11: 2, 12: 2, 13: 2,          # 内腿描边（压外腿填充=两腿分界线）
	1: 5, 2: 5,                   # 外臂（近侧）描边——臂-躯分隔保留
}

## 填充层 z（缺省回退 描边+1；躯干链显式越顶见上）
const CHAIN_FILL_Z: Dictionary = {
	14: -2, 15: -2,
	6: 4, 7: 4, 20: 4, 10: 4,     # 躯干+头 填充（盖两腿描边→胯部融合）
	3: 1, 4: 1, 5: 1,
	11: 3, 12: 3, 13: 3,
	1: 6, 2: 6,
}

## 根部开口描边的肢体——仅近侧臂（前臂外 1）：其根与躯干填充相交，肩关节
## 圈内不能有笔迹（两侧线自根部留隙 OPEN_ROOT_GAP 起笔，裸露填充根帽融进
## 躯干）。远侧臂（前臂内 14）整体藏于躯干之后、不与身体观感相交，肩部
## 轮廓必须完整（背侧露出的远肩全靠它读形）——曾误同开口致后肩描边丢失
## （创始人 2026-09-09 三次反馈）。上臂段无渲染（type=-1），前臂根即视觉臂根。
const OPEN_ROOT_LIMBS: Array = [1]

## 根部留隙（本地 px，自根部平面沿臂向肢端量）：肩关节圆圈直径 ≈ 肢厚+描边
## ≈26~29，取 30 保证圆圈内无笔迹（探针实测：前臂根端平面距肩点 15.9+帽 13）。
const OPEN_ROOT_GAP := {1: 30.0}

# ===== 武器挂载骨骼 =====
const WEAPON_ATTACH_R := 23
const WEAPON_ATTACH_L := 24

# ===== 骨骼名称映射（肢体段命名法）=====
## 骨骼名代表"从此骨骼到子骨骼"的肢体段
## 例如 thigh_outer = 大腿（从髋部到膝盖的段），位于髋部位置
## 21~24 为 SWL 躯干链/武器骨补译新增（2026-08-30 验收闭环计划）：
##   spine_root(21)←bone、chest_mid(22)←bone2、weapon_hand(23)←pickaxe1、
##   shield_hand(24)←Arrow1；minertorso1 复用 lower_torso(6)
const BONE_NAMES: Dictionary = {
	0:  "hip",             # 髋部（根节点）
	1:  "forearm_outer",   # 小臂外（从外肘到外手）
	2:  "hand_outer",      # 手外
	3:  "shin_outer",      # 小腿外（从外膝到外脚踝）
	4:  "foot_outer",      # 脚掌外（从外脚踝到外脚尖）
	5:  "toe_outer",       # 脚趾外（叶子节点）
	6:  "lower_torso",     # 下躯干（从髋到下腹；SWL minertorso1 通道挂载点）
	7:  "upper_torso",     # 上躯干（从胸到颈根；SWL bone3）
	9:  "neck",            # 颈部（从胸到头根）
	10: "head",            # 头部（从颈根到头顶）
	11: "shin_inner",      # 小腿内
	12: "foot_inner",      # 脚掌内
	13: "toe_inner",       # 脚趾内（叶子节点）
	14: "forearm_inner",   # 小臂内
	15: "hand_inner",      # 手内
	16: "thigh_outer",     # 大腿外（从髋到外膝，位于髋部位置）
	17: "thigh_inner",     # 大腿内（从髋到内膝，位于髋部位置）
	18: "upper_arm_outer", # 大臂外（从胸到外肘，位于胸部位置）
	19: "upper_arm_inner", # 大臂内（从胸到内肘，位于胸部位置）
	21: "spine_root",      # 脊柱根（SWL bone；hip 与腿/躯干之间的纯旋转传动骨，位于髋原点）
	22: "chest_mid",       # 胸中段（SWL bone2；插在 lower_torso 与 upper_torso 之间）
	23: "weapon_hand",     # 武器骨（SWL pickaxe1；挂 hand_inner，武器跟腕甩动的动画通道）
	24: "shield_hand",     # 盾骨（SWL Arrow1；挂 hand_outer，拉弓/举盾的动画通道）
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
	"spine_root": 21,
	"chest_mid": 22,
	"weapon_hand": 23,
	"shield_hand": 24,
}

## SWL Swordwrath 骨骼数据
## root=hip, 脊柱↑(21→6→22→7), 头↑(9→10)
## 手臂外↓(18->1->2->24), 手臂内↓(19->14->15->23)
## 腿外↓(16->3->4->5), 腿内↓(17->11->12->13)；腿挂 spine_root(21) 下（SWL 腿挂 bone 下）
## x,y = 相对父骨骼的偏移量
## type = 精灵类型，-1 = 无精灵。精灵挂在父骨骼上。
## spine_root/chest_mid/weapon_hand/shield_hand 为 SWL 躯干链与武器骨补译：
## spine_root 在髋原点纯传动（腿与躯干的共同旋转层，几何不变）；
## chest_mid 把原 6→7 躯干段拆为两段（总位移不变）；weapon/shield_hand 挂手骨原点。
const SKELETON_DATA: Dictionary = {
	0:  {"parent": -1, "x": 0.0,    "y": 0.0,    "length": 0,   "thickness": 0,  "type": -1},
	21: {"parent": 0,  "x": 0.0,    "y": 0.0,    "length": 1,   "thickness": 0,  "type": -1},
	16: {"parent": 21, "x": 0.0,    "y": 0.0,    "length": 66,  "thickness": 23, "type": -1},
	3:  {"parent": 16, "x": 25.4,   "y": 60.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	4:  {"parent": 3,  "x": 2.9,    "y": 68.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	5:  {"parent": 4,  "x": 11.0,   "y": 0.0,    "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	17: {"parent": 21, "x": 0.0,    "y": 0.0,    "length": 66,  "thickness": 23, "type": -1},
	11: {"parent": 17, "x": -4.8,   "y": 65.8,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	12: {"parent": 11, "x": -16.9,  "y": 66.9,   "length": 69,  "thickness": 23, "type": TYPE_ROUND_SEG},
	13: {"parent": 12, "x": 11.0,   "y": -0.2,   "length": 11,  "thickness": 23, "type": TYPE_ROUND_SEG},
	6:  {"parent": 21, "x": 1.8,    "y": -30.9,  "length": 31,  "thickness": 23, "type": TYPE_ROUND_SEG},
	22: {"parent": 6,  "x": 2.85,   "y": -15.25, "length": 16,  "thickness": 23, "type": TYPE_ROUND_SEG},
	7:  {"parent": 22, "x": 2.85,   "y": -15.25, "length": 15,  "thickness": 23, "type": TYPE_ROUND_SEG},
	18: {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 64,  "thickness": 23, "type": -1},
	1:  {"parent": 18, "x": -34.7,  "y": 53.9,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	2:  {"parent": 1,  "x": -3.1,   "y": 48.7,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	24: {"parent": 2,  "x": 0.0,    "y": 0.0,    "length": 1,   "thickness": 0,  "type": -1},
	19: {"parent": 7,  "x": 10.4,   "y": -29.2,  "length": 64,  "thickness": 23, "type": -1},
	14: {"parent": 19, "x": 1.1,    "y": 64.1,   "length": 64,  "thickness": 23, "type": TYPE_ROUND_SEG},
	15: {"parent": 14, "x": 33.8,   "y": 35.2,   "length": 49,  "thickness": 23, "type": TYPE_ROUND_SEG},
	23: {"parent": 15, "x": 0.0,    "y": 0.0,    "length": 1,   "thickness": 0,  "type": -1},
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
		# 关掉自动计算（否则叶骨/纯挂载骨每帧刷 "No Bone2D children" 警告，
		# 与旧 tscn 骨架的显式 false 设置一致）
		node.auto_calculate_length_and_angle = false
		node.length = float(data.get("length", 1))
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
## 腿移到躯干之前（腿在身体后面）；内臂先于外臂（外臂覆盖内臂）；
## 颈/头提到双臂之前（SWL 槽序：武器/盾盖头——武器挂臂 subtree，树序在后）。
static func reorder_render_order(skeleton: Skeleton2D) -> void:
	var thigh_outer := skeleton.get_node_or_null("thigh_outer") as Node
	var thigh_inner := skeleton.get_node_or_null("thigh_inner") as Node
	if thigh_outer != null and thigh_inner != null:
		skeleton.move_child(thigh_outer, 0)
		skeleton.move_child(thigh_inner, 1)
	var upper_torso := skeleton.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso") as Node
	if upper_torso != null:
		var arm_outer := upper_torso.get_node_or_null("upper_arm_outer") as Node
		var arm_inner := upper_torso.get_node_or_null("upper_arm_inner") as Node
		var neck := upper_torso.get_node_or_null("neck") as Node
		if arm_outer != null and arm_inner != null:
			if arm_inner.get_index() > arm_outer.get_index():
				upper_torso.move_child(arm_inner, arm_outer.get_index())
			# 头最后画会盖住武器/盾（臂 subtree 树序在内臂/外臂之后）——
			# 把 neck 提到最前，武器（内臂下）与盾（外臂下）即盖头
			if neck != null and neck.get_index() > arm_inner.get_index():
				upper_torso.move_child(neck, 0)


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
## 内含描边 + 填充两层（几何跨度 = length + thickness，与旧位图一致）。
## 链式两遍渲染：描边层 z=CHAIN_STROKE_Z[id]、填充层 z=描边+1 →
## 描边/填充 z 按 CHAIN_STROKE_Z/CHAIN_FILL_Z 双表（见表头注释）。
## 前臂（OPEN_ROOT_LIMBS）描边为根部真开口三件套（两侧线+端弧，根部留隙
## OPEN_ROOT_GAP）：肩关节圆圈内无笔迹，填充根帽裸露融合进躯干填充。
## z_index 用相对值（祖先全部 z=0；单位带 EntityHost z=3，全局 0~9 < 前景层 10）。
static func _build_limb(
	parent_bone: Node2D, id: int, length: int, thickness: int, node_type: int,
	px: float, py: float, thickness_scale: float, colors: Dictionary
) -> Node2D:
	var container := Node2D.new()
	container.name = "sprite_%d" % id
	parent_bone.add_child(container)

	var w: float = max(thickness * thickness_scale, 1.0)
	var sz: int = CHAIN_STROKE_Z.get(id, 1)
	var fz: int = CHAIN_FILL_Z.get(id, sz + 1)
	var outline: Color = colors.get("outline", DEFAULT_OUTLINE)
	if node_type == TYPE_CIRCLE:
		container.position = Vector2(px, py)
		container.rotation = 0.0
		var r: float = max(float(length), w * 2.0) / 2.0
		var st := _make_circle("stroke", r + OUTLINE_WIDTH, outline)
		var fi := _make_circle("fill", r, _color_for_type(node_type, colors))
		st.z_index = sz
		fi.z_index = fz
		container.add_child(st)
		container.add_child(fi)
	else:
		container.rotation = Vector2(px, py).angle()
		container.position = Vector2(px / 2.0, py / 2.0)
		var pts := PackedVector2Array([Vector2(-length / 2.0, 0), Vector2(length / 2.0, 0)])
		var fil := _make_line("fill", pts, w, _color_for_type(node_type, colors))
		fil.z_index = fz
		var stl: CanvasItem
		if id in OPEN_ROOT_LIMBS:
			# 根部真开口描边：两侧线自根部留隙起笔 + 末端半圆弧，无闭合边
			stl = _make_open_root_stroke("stroke", length / 2.0, w, OUTLINE_WIDTH,
					outline, float(OPEN_ROOT_GAP.get(id, 0.0)))
		else:
			stl = _make_line("stroke", pts, w + OUTLINE_WIDTH * 2.0, outline)
		stl.z_index = sz
		container.add_child(stl)
		container.add_child(fil)
	return container


## 根部真开口描边（Node2D 容器）：两侧 Line2D（平头帽，自 root_gap 起笔）
## + 末端半环 Polygon2D（外径 fill_w/2+eff、内径 fill_w/2 的半圆环，无径向
## 闭合线外露）。旧单多边形 U 形的根部闭合边会横在肩/胯关节上（创始人
## 反馈"肩膀圆圈没融合"的元凶），容器式三件套无任何越过留隙区的笔迹。
## meta 供 apply_outline_zoom 识别重建：open_root_half_len / open_root_fill_w。
## 局部坐标与 Line2D 版描边一致：-x 朝肢根、+x 朝肢端。
static func _make_open_root_stroke(lname: String, half_len: float, fill_w: float,
		eff: float, color: Color, gap: float) -> Node2D:
	var box := Node2D.new()
	box.name = lname
	box.set_meta("open_root_half_len", half_len)
	box.set_meta("open_root_fill_w", fill_w)
	box.set_meta("open_root_gap", gap)
	var y: float = fill_w / 2.0 + eff / 2.0
	var x0: float = -half_len + gap
	for side in [-1.0, 1.0]:
		var ln := _make_line("side_%s" % ("top" if side < 0 else "bottom"),
				PackedVector2Array([Vector2(x0, side * y), Vector2(half_len, side * y)]),
				eff, color)
		ln.begin_cap_mode = Line2D.LINE_CAP_NONE
		ln.end_cap_mode = Line2D.LINE_CAP_NONE
		box.add_child(ln)
	var arc := Polygon2D.new()
	arc.name = "tip_arc"
	arc.color = color
	arc.polygon = _tip_arc_pts(half_len, fill_w / 2.0, eff)
	box.add_child(arc)
	return box


## 末端半环顶点：外弧（圆心 (H,0) 半径 R，-90°→+90°）+ 内弧（半径 r，+90°→-90°）。
static func _tip_arc_pts(half_len: float, inner_r: float, eff: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := 12
	var ro: float = inner_r + eff
	for i in range(n + 1):
		var a := -PI / 2.0 + PI * float(i) / float(n)
		pts.append(Vector2(half_len, 0) + Vector2(cos(a), sin(a)) * ro)
	for i in range(n, -1, -1):
		var a := -PI / 2.0 + PI * float(i) / float(n)
		pts.append(Vector2(half_len, 0) + Vector2(cos(a), sin(a)) * inner_r)
	return pts


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
#  描边缩放补偿（屏幕像素恒定）
# ============================================================

## 描边单侧世界宽度（屏幕像素恒定补偿，思路同 world_map b443c26a"描边改固定屏幕像素"）：
## 画布缩放 s（Camera2D.zoom，含分辨率适配）下拉远时按 1/s 放大，保持屏幕
## ~OUTLINE_SCREEN_PX 像素；放大（s>1）时不低于设计世界宽度 OUTLINE_WIDTH，
## 肢体比例不变（特写描边不过细，屏幕像素随之 ≥ 下限）。
static func outline_world_width(canvas_scale: float) -> float:
	var s: float = maxf(canvas_scale, 0.0001)
	return maxf(OUTLINE_WIDTH, OUTLINE_SCREEN_PX / s)


## 描边宽度缩放补偿刷新（画布缩放变化时由 StickmanRig 批量调用，低频）：
## 线段肢体 stroke 宽 = 填充宽 + 2×eff；头部圆 stroke 重建 40 边形（半径 = r + eff）；
## 前臂 U 形描边（open_root_half_len meta 标记）按 radius = 填充宽/2 + eff 重建顶点。
## 只改描边层几何，不动填充层与颜色；缩放未变时无需调用。
static func apply_outline_zoom(sprites: Dictionary, eff: float) -> void:
	var all_data := SKELETON_DATA.merged(EXTRA_LIMBS, true)
	for id in sprites.keys():
		var limb: Node2D = sprites[id]
		if not is_instance_valid(limb):
			continue
		if int(all_data.get(id, {}).get("type", -1)) < 0:
			continue
		var stroke := limb.get_node_or_null("stroke")
		var fill := limb.get_node_or_null("fill")
		if stroke is Node2D and stroke.has_meta("open_root_half_len") 				and stroke.has_meta("open_root_fill_w"):
			# 容器式真开口描边：两侧线宽/离轴 + 端弧外径随 eff 重建
			var fw: float = float(stroke.get_meta("open_root_fill_w"))
			var hl: float = float(stroke.get_meta("open_root_half_len"))
			var gap: float = float(stroke.get_meta("open_root_gap", 0.0))
			var y_u: float = fw / 2.0 + eff / 2.0
			for side in [-1.0, 1.0]:
				var sl := stroke.get_node_or_null("side_top" if side < 0 else "side_bottom") as Line2D
				if sl != null:
					sl.width = eff
					sl.points = PackedVector2Array([
						Vector2(-hl + gap, side * y_u), Vector2(hl, side * y_u)])
			var arc := stroke.get_node_or_null("tip_arc") as Polygon2D
			if arc != null:
				arc.polygon = _tip_arc_pts(hl, fw / 2.0, eff)
		elif stroke is Line2D and fill is Line2D:
			(stroke as Line2D).width = (fill as Line2D).width + eff * 2.0
		elif stroke is Polygon2D and fill is Polygon2D:
			var r: float = _circle_radius(fill as Polygon2D)
			if r > 0.0:
				_set_circle_radius(stroke as Polygon2D, r + eff)


## 读取圆描边多边形的半径（顶点绕中心生成，取首顶点到原点距离；中心在 Vector2.ZERO）
static func _circle_radius(p: Polygon2D) -> float:
	var pts := p.polygon
	return pts[0].length() if pts.size() > 0 else 0.0


## 重建圆多边形顶点（40 边，中心 Vector2.ZERO，同 _make_circle 生成方式）
static func _set_circle_radius(p: Polygon2D, radius: float) -> void:
	var pts := PackedVector2Array()
	for i in range(40):
		var a := TAU * float(i) / 40.0
		pts.append(Vector2(cos(a), sin(a)) * radius)
	p.polygon = pts


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